[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [string]$OhosFlutterHome = $env:OHOS_FLUTTER_HOME,
    [string]$DevecoHome = $env:DEVECO_HOME,
    [switch]$SkipTests,
    [ValidateSet('ohos-arm64', 'ohos-arm', 'ohos-x64')]
    [string]$TargetPlatform = 'ohos-arm64'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($OhosFlutterHome)) {
    $OhosFlutterHome = 'D:\kaifa\Flutter-OHOS\flutter'
}
if ([string]::IsNullOrWhiteSpace($DevecoHome)) {
    $DevecoHome = 'E:\devecostudio'
}

$flutter = Join-Path $OhosFlutterHome 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
    throw "找不到 OpenHarmony Flutter：$flutter。请设置 OHOS_FLUTTER_HOME。"
}

$devecoSdkRoot = Join-Path $DevecoHome 'sdk'
$flutterSdk = Join-Path $devecoSdkRoot 'default'
$ohpmBin = Join-Path $DevecoHome 'tools\ohpm\bin'
$hvigorBin = Join-Path $DevecoHome 'tools\hvigor\bin'
$nodeBin = Join-Path $DevecoHome 'tools\node'
$hdcBin = Join-Path $flutterSdk 'openharmony\toolchains'
$devecoJbr = Join-Path $DevecoHome 'jbr'

foreach ($requiredPath in @($flutterSdk, $ohpmBin, $hvigorBin, $nodeBin, $hdcBin)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "DevEco/OpenHarmony 组件不完整：$requiredPath。请检查 DEVECO_HOME。"
    }
}

# Flutter 使用 default 目录；Hvigor 则必须从 sdk 根目录扫描版本组件，二者不能混用。
$env:DEVECO_HOME = $DevecoHome
$env:DEVECO_SDK_HOME = $devecoSdkRoot
$env:HDC_HOME = $hdcBin
if (Test-Path -LiteralPath $devecoJbr) {
    $env:JAVA_HOME = $devecoJbr
}
$env:FLUTTER_GIT_URL = 'https://gitcode.com/openharmony-sig/flutter_flutter.git'

# 放在 PATH 首位，防止 Android Flutter、系统 Node 或旧版 hdc 被误用。
$env:PATH = "$(Join-Path $OhosFlutterHome 'bin');$ohpmBin;$hvigorBin;$nodeBin;$hdcBin;$env:PATH"
Set-Location $projectRoot

& (Join-Path $PSScriptRoot 'use_ohos_deps.ps1')
& $flutter config --ohos-sdk $flutterSdk
& $flutter config --ohpm-home (Join-Path $DevecoHome 'tools\ohpm')
& $flutter doctor -v
if ($LASTEXITCODE -ne 0) {
    throw 'OpenHarmony 工具链检查未通过。请先配置 HarmonyOS SDK、ohpm 和 hvigorw。'
}

& $flutter pub get
& (Join-Path $PSScriptRoot 'patch_ohos_embedding.ps1') -TargetPlatform $TargetPlatform
if (-not $SkipTests) {
    & $flutter test --reporter compact
    if ($LASTEXITCODE -ne 0) {
        throw 'Flutter 测试未通过，已停止 HarmonyOS 构建。可在已知基线失败时显式传入 -SkipTests。'
    }
}
$buildProfile = Join-Path $projectRoot 'ohos\build-profile.json5'
$localSigningProfile = Join-Path $projectRoot 'ohos\build-profile.local.json5'
$buildProfileTemplate = Get-Content -LiteralPath $buildProfile -Raw

if (-not (Test-Path -LiteralPath $localSigningProfile)) {
    throw "缺少本机签名配置：$localSigningProfile。请在 DevEco Studio 生成调试签名材料后创建该未跟踪文件。"
}

$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$pubspecContent = Get-Content -LiteralPath $pubspecPath -Raw
if ($pubspecContent -match 'version:\s*(?<versionName>[\d\.]+)\+(?<versionCode>\d+)') {
    $versionName = $matches['versionName']
    $versionCode = $matches['versionCode']
} else {
    throw "Cannot extract version from pubspec.yaml."
}

$appJson5Path = Join-Path $projectRoot 'ohos\AppScope\app.json5'
$appJson5Content = Get-Content -LiteralPath $appJson5Path -Raw

$appJson5Template = $appJson5Content
$appJson5Modified = $appJson5Content -replace '"versionCode"\s*:\s*\d+', "`"versionCode`": $versionCode"
$appJson5Modified = $appJson5Modified -replace '"versionName"\s*:\s*"[^"]+"', "`"versionName`": `"$versionName`""

Set-Content -LiteralPath $appJson5Path -Value $appJson5Modified -Encoding utf8 -NoNewline

# 签名材料只允许存在于已忽略的本地文件中，构建结束后立即恢复无凭据模板。
Copy-Item -LiteralPath $localSigningProfile -Destination $buildProfile -Force
try {
    & $flutter build hap "--$Mode" --no-pub -t lib/main_ohos.dart --dart-define=APP_PLATFORM=ohos `
        "--dart-define=APP_VERSION_NAME=$versionName" `
        "--dart-define=APP_VERSION_CODE=$versionCode" `
        --target-platform=$TargetPlatform `
        --dart-define=APP_API_URL=https://sylulive.online/api

    if ($LASTEXITCODE -ne 0) {
        throw "HarmonyOS $Mode HAP 构建失败。"
    }
} finally {
    Set-Content -LiteralPath $buildProfile -Value $buildProfileTemplate -Encoding utf8 -NoNewline
    Set-Content -LiteralPath $appJson5Path -Value $appJson5Template -Encoding utf8 -NoNewline
}
