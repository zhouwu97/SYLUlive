[CmdletBinding()]
param(
    [switch]$IncludeHarmony
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

& (Join-Path $PSScriptRoot 'use_standard_deps.ps1')
flutter pub get
flutter test --reporter compact
flutter analyze --no-fatal-warnings
if ($LASTEXITCODE -ne 0) {
    throw '标准 Flutter 静态检查未通过。'
}

if ($IncludeHarmony) {
    & (Join-Path $PSScriptRoot 'build_harmony.ps1')
}
