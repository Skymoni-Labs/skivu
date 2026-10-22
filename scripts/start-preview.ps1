param([int]$Port = 18781, [switch]$Rebuild)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskBuildRoot = 'D:/CodexBuilds/ski-independent-ui'
$taskFlutter = "$taskBuildRoot/flutter-sdk/bin/flutter.bat"
$env:PUB_CACHE = 'E:/DevTools/flutter-operit2-pub-cache'
$env:TEMP = $taskBuildRoot
$env:TMP = $taskBuildRoot
if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
  throw "Port $Port is already in use. Choose another -Port; existing servers are never stopped."
}
Set-Location $taskRoot
if ($Rebuild -or !(Test-Path "$taskBuildRoot/build/web/index.html")) {
  & $taskFlutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
  & $taskFlutter build web --release --no-web-resources-cdn --pwa-strategy=none
  if ($LASTEXITCODE -ne 0) { throw 'Web build failed' }
}
python "$PSScriptRoot/package_preview.py"
if ($LASTEXITCODE -ne 0) { throw 'Preview packaging failed' }
Write-Host "ski preview: http://127.0.0.1:$Port/"
python "$PSScriptRoot/serve.py" --port $Port --directory "$taskBuildRoot/build/web"
