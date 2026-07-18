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
if ($LASTEXITCODE -ne 0) {
    throw 'OpenHarmony 依赖解析失败。'
}

# 阶段 4：OHOS 编译入口只能依赖中性通知契约。若 Android 实现细节回流到入口、
# 平台聚合层或应用协调器，立即停止构建，避免运行时判断掩盖静态依赖污染。
$notificationBoundaries = @(
    @{
        Path = Join-Path $projectRoot 'lib\main.dart'
        Pattern = '(?i)AndroidNotificationService|android_notification_service|JPush'
    },
    @{
        Path = Join-Path $projectRoot 'lib\platform\platform_services.dart'
        Pattern = '(?i)AndroidNotificationService|android_notification_service'
    },
    @{
        Path = Join-Path $projectRoot 'lib\platform\notification\app_notification_service.dart'
        Pattern = '(?i)AndroidFlutterLocalNotificationsPlugin|flutter_local_notifications|MethodChannel'
    },
    @{
        Path = Join-Path $projectRoot 'packages\sylulive_push_bridge_ohos\lib\sylulive_push_bridge.dart'
        Pattern = '(?i)jpush_flutter|flutter_local_notifications|AndroidFlutterLocalNotificationsPlugin'
    }
)
foreach ($boundary in $notificationBoundaries) {
    $source = Get-Content -LiteralPath $boundary.Path -Raw
    if ($source -match $boundary.Pattern) {
        throw "OHOS 通知编译隔离失败，检测到 Android 实现引用：$($boundary.Path)"
    }
}

# OHOS 首版不接入 JPush。依赖切换若失效，必须在生成原生工程前立即停止，
# 避免官方插件通过 OHPM 合并权限、metadata 和原生 SDK。
$pluginDependencies = Join-Path $projectRoot '.flutter-plugins-dependencies'
$generatedRegistrant = Join-Path $projectRoot 'ohos\entry\src\main\ets\plugins\GeneratedPluginRegistrant.ets'
foreach ($dependencyState in @($pluginDependencies, $generatedRegistrant)) {
    if ((Test-Path -LiteralPath $dependencyState) -and
        (Get-Content -LiteralPath $dependencyState -Raw) -match '(?i)jpush_flutter|JpushHarmony') {
        throw "OHOS 依赖隔离失败，仍检测到 JPush：$dependencyState"
    }
}
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

# 计划 5.4 / 22.4：仓库模板必须保持无凭据，禁止把本地 .p12/.cer/.p7b 路径或口令写进受跟踪的 build-profile.json5。
# 一旦发现模板已含 signingConfigs，说明上次构建未恢复或被人误提交，立即终止以避免凭据泄漏。
if ($buildProfileTemplate -match '"signingConfigs"') {
    throw "受跟踪的 build-profile.json5 已含 signingConfigs，疑似凭据泄漏。请立即检查 git log 并恢复为无凭据模板。"
}

if (-not (Test-Path -LiteralPath $localSigningProfile)) {
    throw "缺少本机签名配置：$localSigningProfile。请在 DevEco Studio 生成调试签名材料后创建该未跟踪文件。"
}

# 计划 22.2：构建前删除旧 signed/unsigned 产物，避免脚本误拿上一次构建留下的旧 HAP。
$hapOutputDir = Join-Path $projectRoot 'build\ohos\hap'
if (Test-Path -LiteralPath $hapOutputDir) {
    $staleHaps = Get-ChildItem -LiteralPath $hapOutputDir -Filter 'entry-default-*.hap' -File -ErrorAction SilentlyContinue
    foreach ($staleHap in $staleHaps) {
        Remove-Item -LiteralPath $staleHap.FullName -Force
    }
}

# 计划 22.2：记录构建开始时间，供 run_harmony.ps1 校验 HAP 确实由本次构建生成。
$buildStartMarker = Join-Path $projectRoot 'build\ohos\.last_harmony_build_start.txt'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $buildStartMarker) -Force
$buildStart = Get-Date
Set-Content -LiteralPath $buildStartMarker -Value $buildStart.ToString('o') -Encoding utf8

# 签名材料只允许存在于已忽略的本地文件中，构建结束后立即恢复无凭据模板。
Copy-Item -LiteralPath $localSigningProfile -Destination $buildProfile -Force
try {
    # 计划 22.2：签名配置注入后校验 signingConfigs 存在，否则后续 HAP 必为 unsigned。
    $injectedProfile = Get-Content -LiteralPath $buildProfile -Raw
    if ($injectedProfile -notmatch '"signingConfigs"') {
        throw "本机 build-profile.local.json5 注入后未发现 signingConfigs。请检查该文件是否完整。"
    }

    & $flutter build hap "--$Mode" --no-pub --dart-define=APP_PLATFORM=ohos `
        --target-platform=$TargetPlatform `
        --dart-define=APP_API_URL=https://sylulive.online/api

    if ($LASTEXITCODE -ne 0) {
        throw "HarmonyOS $Mode HAP 构建失败。"
    }

    # 计划 22.2：构建后确认 signed HAP 是新生成、大小过下限。
    $expectedSigned = Join-Path $hapOutputDir 'entry-default-signed.hap'
    if (-not (Test-Path -LiteralPath $expectedSigned)) {
        throw "构建完成但缺少 entry-default-signed.hap。请检查本机签名材料是否已被 DevEco 默认 Run 覆盖为 unsigned 流程。"
    }
    $signedInfo = Get-Item -LiteralPath $expectedSigned
    if ($signedInfo.LastWriteTime -lt $buildStart) {
        throw "entry-default-signed.hap 的修改时间早于本次构建开始时间，疑似旧产物未清理。请重新运行构建。"
    }
    $minHapSize = 1MB
    if ($signedInfo.Length -lt $minHapSize) {
        throw "entry-default-signed.hap 大小仅 $($signedInfo.Length) 字节，小于下限 $minHapSize 字节，疑似构建截断或产出异常。"
    }

    # 产物级复核，防止旧 OHPM 锁文件或缓存把 JPush HAR 合并回新 HAP。
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($expectedSigned)
    try {
        $manifestText = New-Object System.Text.StringBuilder
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notin @('module.json', 'pkgContextInfo.json')) {
                continue
            }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try {
                $null = $manifestText.AppendLine($reader.ReadToEnd())
            } finally {
                $reader.Dispose()
            }
        }
        if ($manifestText.ToString() -match '(?i)jpush_flutter|@jg/push|jg_md5_push|APP_TRACKING_CONSENT') {
            throw '签名 HAP 仍包含 JPush 依赖、metadata 或注入权限，已拒绝交付。'
        }
    } finally {
        $archive.Dispose()
    }
    Write-Host "[build_harmony] 已生成最新签名 HAP：$expectedSigned ($($signedInfo.Length) 字节，$($signedInfo.LastWriteTime.ToString('o')))"
} finally {
    # 计划 22.4：无论构建成功与否，finally 中始终恢复无凭据模板，阻止凭据回流入受跟踪文件。
    Set-Content -LiteralPath $buildProfile -Value $buildProfileTemplate -Encoding utf8 -NoNewline
    $restored = Get-Content -LiteralPath $buildProfile -Raw
    if ($restored -match '"signingConfigs"') {
        Write-Warning "build-profile.json5 恢复后仍含 signingConfigs，请手动核对 git status 并确认没有凭据被提交。"
    }
}
