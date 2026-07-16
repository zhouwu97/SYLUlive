[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $projectRoot 'pubspec_overrides.yaml'

if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Force
    Write-Host '已移除鸿蒙依赖覆盖，恢复标准 pub.dev 依赖。'
} else {
    Write-Host '未发现 pubspec_overrides.yaml，标准依赖已生效。'
}
