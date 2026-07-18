[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('ohos-arm64', 'ohos-arm', 'ohos-x64')]
    [string]$TargetPlatform
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

# Flutter OHOS 嵌入层当前将 ICU 动态库目录固定为 libs/arm64。
# 模拟器为 x86_64 时必须在 ArkTS 编译前改为对应目录，否则引擎能启动但不能渲染首帧。
$nativeLibraryDirectory = switch ($TargetPlatform) {
    'ohos-arm64' { 'arm64' }
    'ohos-arm' { 'arm' }
    'ohos-x64' { 'x86_64' }
}

# 当前 Flutter OHOS 嵌入层默认就是 libs/arm64。实体机 arm64 构建无需修改
# 任何依赖产物，而且 flutter pub get 也不会预先展开 flutter_ohos HAR。
# 仅在目标 ABI 与默认值不一致时才定位并修补展开后的嵌入层。
if ($nativeLibraryDirectory -eq 'arm64') {
    Write-Host 'Flutter OHOS 嵌入层默认使用 libs/arm64，无需修补。'
    return
}

$embeddingRoots = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'ohos\oh_modules\.ohpm') `
    -Directory -Filter '@ohos+flutter_ohos*' -ErrorAction SilentlyContinue

if ($embeddingRoots.Count -eq 0) {
    throw '未找到 @ohos/flutter_ohos。请先执行 flutter pub get。'
}

$patchedCount = 0
foreach ($embeddingRoot in $embeddingRoots) {
    $loaderPath = Join-Path $embeddingRoot.FullName `
        'oh_modules\@ohos\flutter_ohos\src\main\ets\embedding\engine\loader\ApplicationInfoLoader.ets'
    if (-not (Test-Path -LiteralPath $loaderPath)) {
        continue
    }

    $source = Get-Content -LiteralPath $loaderPath -Raw
    if ($source -notmatch "context\.bundleCodeDir \+ '/libs/[^']+'") {
        throw "未在嵌入层中找到原生库路径：$loaderPath"
    }

    $patched = $source -replace "context\.bundleCodeDir \+ '/libs/[^']+'", `
        "context.bundleCodeDir + '/libs/$nativeLibraryDirectory'"
    if ($patched -ne $source) {
        Set-Content -LiteralPath $loaderPath -Value $patched -Encoding utf8 -NoNewline
    }

    $patchedCount++
}

if ($patchedCount -eq 0) {
    throw '未找到可修补的 ApplicationInfoLoader.ets。'
}

Write-Host "已将 Flutter OHOS 嵌入层原生库目录设为 libs/$nativeLibraryDirectory。"
