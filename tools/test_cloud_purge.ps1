param([string]$Serial = 'emulator-5554')
$ErrorActionPreference = 'Stop'
if (!$Serial.StartsWith('emulator-')) { throw 'This test runner only accepts an Android emulator.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$androidSdkRoot = 'E:/DevTools/Android/Sdk'
$adb = Join-Path $androidSdkRoot 'platform-tools/adb.exe'
$flutter = 'E:/DevTools/flutter-operit2-rolelife/bin/flutter.bat'
$qaPackage = 'com.skyjjgw.independent.ski.purgeqa'
$normalPackage = 'com.skyjjgw.independent.ski'
if (!$env:SKIVU_EXECUTION_OUTPUT) { $env:SKIVU_EXECUTION_OUTPUT = Join-Path $projectRoot 'build/purge-native-proof' }
Push-Location $projectRoot
try {
    $before = & $adb -s $Serial shell dumpsys package $normalPackage
    if (!($before -match 'firstInstallTime=')) { throw 'Install the normal app before running this protected test.' }
    $firstInstall = ($before | Select-String 'firstInstallTime=').Line.Trim()
    & 'D:/anaconda3/python.exe' tools/prepare_cloud_runtime.py --abi x86_64
    if ($LASTEXITCODE -ne 0) { throw 'Runtime verification failed.' }
    & $flutter build apk --debug --no-pub --target-platform android-x64 --target integration_test/cloud_purge_native_test.dart --dart-define=SKIVU_PURGE_QA=true
    if ($LASTEXITCODE -ne 0) { throw 'QA build failed.' }
    $binary = (Get-Item -LiteralPath build/app/outputs/flutter-apk/app-debug.apk).FullName
    $aapt = Get-ChildItem -LiteralPath (Join-Path $androidSdkRoot 'build-tools') -Directory | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'aapt.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $badging = & $aapt dump badging $binary
    $packageLine = ($badging | Select-String "^package: name='([^']+)'" | Select-Object -First 1)
    if (!$packageLine -or $packageLine.Matches[0].Groups[1].Value -ne $qaPackage) { throw 'Refusing to launch a binary with an unexpected package ID.' }
    # The default drive cleanup uninstalls its cached application package.
    # A prebuilt, verified ID plus keep-app-running avoids that cleanup entirely.
    & $flutter drive --no-pub -d $Serial --target integration_test/cloud_purge_native_test.dart --driver test_driver/execution_acceptance.dart --use-application-binary $binary --keep-app-running
    $result = $LASTEXITCODE
    & $adb -s $Serial shell am force-stop $qaPackage
    & $adb -s $Serial shell pm disable-user --user 0 $qaPackage
    $after = & $adb -s $Serial shell dumpsys package $normalPackage
    if (!(($after | Select-String 'firstInstallTime=').Line.Trim() -eq $firstInstall)) { throw 'Normal application identity changed during the QA run.' }
    if ($result -ne 0) { throw "Native test failed ($result)." }
} finally {
    Pop-Location
}
