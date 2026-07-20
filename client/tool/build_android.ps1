[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

& (Join-Path $PSScriptRoot 'use_standard_deps.ps1')
flutter pub get
flutter test --reporter compact
flutter build apk "--$Mode" --dart-define=APP_PLATFORM=android `
    --dart-define=APP_API_URL=https://sylulive.online/api

if ($LASTEXITCODE -ne 0) {
    throw "Android $Mode 构建失败。"
}
