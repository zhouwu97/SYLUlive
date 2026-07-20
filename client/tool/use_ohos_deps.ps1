[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path $PSScriptRoot 'pubspec_overrides.ohos.yaml'
$target = Join-Path $projectRoot 'pubspec_overrides.yaml'

if (-not (Test-Path -LiteralPath $template)) {
    throw "缺少鸿蒙依赖模板：$template"
}

# 只把已在 docs/harmony/01-plugin-audit.md 中确认的兼容 fork 写入覆盖文件。
# 当前模板故意不包含未经真机验证的第三方 fork，避免永久污染标准依赖树。
Copy-Item -LiteralPath $template -Destination $target -Force
Write-Host "已启用鸿蒙依赖覆盖：$target"
