param([string]$DeviceId)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskBuildRoot = 'D:/CodexBuilds/ski-independent-ui'
$taskFlutter = "$taskBuildRoot/flutter-sdk/bin/flutter.bat"
$taskAdb = 'E:/DevTools/Android/Sdk/platform-tools/adb.exe'
$env:ANDROID_HOME = 'E:/DevTools/Android/Sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:JAVA_HOME = 'E:/DevTools/AndroidStudio/jbr'
$env:PUB_CACHE = 'E:/DevTools/flutter-operit2-pub-cache'
$env:TEMP = $taskBuildRoot
$env:TMP = $taskBuildRoot
if (!$DeviceId) {
  $taskDevices = @(& $taskAdb devices | ForEach-Object {
    if ($_ -match '^(\S+)\s+device\s*$' -and $Matches[1] -notlike 'emulator-*') {
      $Matches[1]
    }
  })
  if ($taskDevices.Count -ne 1) {
    throw 'Connect and authorize one physical phone, or specify -DeviceId.'
  }
  $DeviceId = $taskDevices[0]
}
Set-Location $taskRoot
Write-Host 'Android debug: press r for hot reload, R for restart, d to detach.'
& $taskFlutter run --debug --no-pub -d $DeviceId
exit $LASTEXITCODE
