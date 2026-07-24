[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('ohos-arm64', 'ohos-arm', 'ohos-x64')]
    [string]$TargetPlatform
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

# Set native library directory based on target platform
$nativeLibraryDirectory = switch ($TargetPlatform) {
    'ohos-arm64' { 'arm64' }
    'ohos-arm' { 'arm' }
    'ohos-x64' { 'x86_64' }
}

$embeddingRoots = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'ohos\oh_modules\.ohpm') -Directory -Filter '@ohos+flutter_ohos*' -ErrorAction SilentlyContinue

if ($embeddingRoots.Count -eq 0) {
    throw 'Cannot find @ohos/flutter_ohos. Please run flutter pub get first.'
}

$patchedCount = 0
foreach ($embeddingRoot in $embeddingRoots) {
    $loaderPath = Join-Path -Path $embeddingRoot.FullName -ChildPath 'oh_modules\@ohos\flutter_ohos\src\main\ets\embedding\engine\loader\ApplicationInfoLoader.ets'
    if (-not (Test-Path -LiteralPath $loaderPath)) {
        continue
    }

    $source = Get-Content -LiteralPath $loaderPath -Raw
    if ($source -notmatch "context\.bundleCodeDir \+ '/libs/[^']+'") {
        throw "Could not find native library path in embedding: $loaderPath"
    }

    $patched = $source -replace "context\.bundleCodeDir \+ '/libs/[^']+'", "context.bundleCodeDir + '/libs/$nativeLibraryDirectory'"
    if ($patched -ne $source) {
        Set-Content -LiteralPath $loaderPath -Value $patched -Encoding utf8 -NoNewline
    }

    $patchedCount++
}

if ($patchedCount -eq 0) {
    throw 'Could not find any ApplicationInfoLoader.ets to patch.'
}

Write-Host "Successfully set Flutter OHOS native library directory to libs/$nativeLibraryDirectory"
