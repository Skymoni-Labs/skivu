param(
    [Parameter(Mandatory = $true)][ValidateSet('arm64-v8a', 'x86_64')][string]$Abi,
    [string]$OutputDirectory,
    [switch]$Legacy096,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = 'E:/DevTools/flutter-operit2-rolelife/bin/flutter.bat'
$sdkRoot = 'E:/DevTools/Android/Sdk'
if (!$env:JAVA_HOME) { $env:JAVA_HOME = 'D:/a_fl/java/jdk-17.0.2' }
$env:ANDROID_HOME = $sdkRoot
if (!$OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'build/update-delivery' }
Push-Location $projectRoot
try {
    $dirty = & git status --porcelain=v1 --untracked-files=all
    if ($dirty) { throw 'Commit release sources before building an update.' }
    $versionLine = Get-Content -LiteralPath pubspec.yaml | Where-Object { $_ -match '^version:' }
    if ($versionLine -notmatch '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') { throw 'Explicit version and build code are required.' }
    $releaseVersion = $Matches[1]
    $releaseBuildCode = $Matches[2]
    $buildTarget = if ($Abi -eq 'x86_64') { 'android-x64' } else { 'android-arm64' }
    $label = if ($Abi -eq 'x86_64') { 'x64' } else { 'arm64' }
    & D:/anaconda3/python.exe tools/prepare_cloud_runtime.py --abi $Abi --delivery download
    if ($LASTEXITCODE -ne 0) { throw 'Runtime identity validation failed.' }
    # Refresh dependencies offline when requested; release mode regenerates
    # registration with dev-only plugins excluded.
    $buildArgs = @('build', 'apk', '--release', '--target-platform', $buildTarget, "--build-number=$releaseBuildCode", "--build-name=$releaseVersion")
    if ($Offline) {
        & $flutter pub get --offline
        if ($LASTEXITCODE -ne 0) { throw 'Offline dependency validation failed.' }
        $buildArgs += '--no-pub'
    }
    & $flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
    $apk = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk'
    $signing = & "$sdkRoot/build-tools/36.1.0/apksigner.bat" verify --print-certs $apk
    if ($LASTEXITCODE -ne 0 -or !($signing -match 'SHA-256 digest: 39b262ea602a2c91dc914a7f7ba2dc86e6640e1ad11ca1f07ff61a076b435523')) { throw 'APK does not match the installed production signer.' }
    $badging = & "$sdkRoot/build-tools/36.1.0/aapt.exe" dump badging $apk
    $expected = "package: name='com.skyjjgw.independent.ski' versionCode='$releaseBuildCode' versionName='$releaseVersion'"
    if (!(($badging | Select-Object -First 1).StartsWith($expected))) { throw 'Refusing a QA, stale or mismatched release APK.' }
    if ($Legacy096 -and (Get-Item -LiteralPath $apk).Length -gt 262144000) { throw 'This bridge APK cannot be received by the already-installed 0.2.96 updater.' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $destination = Join-Path $OutputDirectory "Skivu-$releaseVersion-$label-v$releaseBuildCode.apk"
    Copy-Item -LiteralPath $apk -Destination $destination
    [ordered]@{
        file = $destination
        abi = $Abi
        version = $releaseVersion
        versionCode = [long]$releaseBuildCode
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        size = (Get-Item -LiteralPath $destination).Length
        sourceCommit = (& git rev-parse HEAD)
        runtimeDelivery = 'download-or-reuse'
        legacy096Checked = [bool]$Legacy096
    } | ConvertTo-Json | Set-Content -LiteralPath "$destination.json" -Encoding utf8
    Get-Content -LiteralPath "$destination.json"
} finally { Pop-Location }
