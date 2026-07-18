[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [ValidateSet('ohos-arm64', 'ohos-arm', 'ohos-x64')]
    [string]$TargetPlatform = 'ohos-x64',
    [string]$DeviceId = '127.0.0.1:5555',
    [string]$OhosFlutterHome = $env:OHOS_FLUTTER_HOME,
    [string]$DevecoHome = $env:DEVECO_HOME,
    [switch]$SkipTests,
    [switch]$SkipBuild
)

# 计划 22.1：强化 run_harmony.ps1
#   1. 只接受 entry-default-signed.hap
#   2. 路径含 unsigned 时立即终止
#   3. HAP 生成时间必须晚于本次构建开始时间（avoid 误部署上一次旧产物）
#   4. 构建后确认文件大小大于合理下限
#   5. 安装失败时输出：bundleName / DeviceId / TargetPlatform / HAP 路径 / 是否可能为签名冲突
# 计划 22.4 / 24：禁止直接部署 entry-default-unsigned.hap；禁止仅靠“卸载后能装”当作覆盖升级通过。

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($DevecoHome)) {
    $DevecoHome = 'E:\devecostudio'
}

# 计划 22.1（诊断信息）：从 AppScope/app.json5 读取 bundleName，安装失败时打印。
$appJson5 = Join-Path $projectRoot 'ohos\AppScope\app.json5'
$bundleName = 'com.example.shenliyuan'
if (Test-Path -LiteralPath $appJson5) {
    $appText = Get-Content -LiteralPath $appJson5 -Raw
    if ($appText -match '"bundleName"\s*:\s*"([^"]+)"') {
        $bundleName = $matches[1]
    }
}

# 计划 22.1：硬拒绝 unsigned HAP 路径——即使路径被外部修改也防御到位。
$hap = Join-Path $projectRoot 'build\ohos\hap\entry-default-signed.hap'
if ($hap -match 'unsigned') {
    throw "禁止部署 unsigned HAP：$hap"
}

# 解析本机签名是否曾被 Git 跟踪（诊断用，不影响部署，但会告警）。
$localSigningTracked = $false
try {
    $null = git -C $projectRoot ls-files --error-unmatch 'ohos/build-profile.local.json5' 2>$null
    if ($LASTEXITCODE -eq 0) { $localSigningTracked = $true }
} catch {
    $localSigningTracked = $false
}

$buildStart = $null
if (-not $SkipBuild) {
    $buildScript = Join-Path $PSScriptRoot 'build_harmony.ps1'
    $buildArgs = @{
        Mode = $Mode
        TargetPlatform = $TargetPlatform
        DevecoHome = $DevecoHome
    }
    if (-not [string]::IsNullOrWhiteSpace($OhosFlutterHome)) {
        $buildArgs.OhosFlutterHome = $OhosFlutterHome
    }
    if ($SkipTests) {
        $buildArgs.SkipTests = $true
    }

    # 计划 22.1（3）：记录本次调用构建开始时间，构建结束后用它校验 HAP 新于该时间。
    $buildStart = Get-Date
    & $buildScript @buildArgs

    # build_harmony.ps1 同时会把开始时间写入 marker 文件，作为另一独立来源。
    $buildStartMarker = Join-Path $projectRoot 'build\ohos\.last_harmony_build_start.txt'
    if (Test-Path -LiteralPath $buildStartMarker) {
        $markerText = (Get-Content -LiteralPath $buildStartMarker -Raw).Trim()
        $markerDate = [datetime]::Parse($markerText, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        # 取 marker（build 脚本真实开始）和本地读取两者中较早的，作为下限判断基准。
        if ($markerDate -lt $buildStart) { $buildStart = $markerDate }
    }
}

# 计划 22.1（1）+（2）：再次硬校验，确保构建后部署的不是 unsigned HAP。
if ($hap -match 'unsigned') {
    throw "禁止部署 unsigned HAP：$hap"
}
if (-not (Test-Path -LiteralPath $hap)) {
    throw "没有找到已签名 HAP：$hap"
}

$hapInfo = Get-Item -LiteralPath $hap
# 计划 22.1（3）：HAP 生成时间必须晚于本次构建开始时间。
if ($null -ne $buildStart -and $hapInfo.LastWriteTime -lt $buildStart.AddSeconds(-2)) {
    # 给 2 秒容差，避免文件系统时间戳截断。
    throw "entry-default-signed.hap 的修改时间 ($($hapInfo.LastWriteTime.ToString('o'))) 早于本次构建开始时间 ($($buildStart.ToString('o')))，疑似部署了上一次旧产物。请重新运行构建。"
}
# 计划 22.1（4）：HAP 大小必须大于合理下限。1 MiB 仅作截断/异常防护，不是质量门槛。
$minHapSize = 1MB
if ($hapInfo.Length -lt $minHapSize) {
    throw "entry-default-signed.hap 大小仅 $($hapInfo.Length) 字节，小于下限 $minHapSize 字节。疑似构建异常。"
}
Write-Host "[run_harmony] 准备部署：$hap ($($hapInfo.Length) 字节，$($hapInfo.LastWriteTime.ToString('o'))) → $DeviceId"

$hdc = Join-Path $DevecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path -LiteralPath $hdc)) {
    throw "找不到 hdc：$hdc"
}

if ($localSigningTracked) {
    Write-Warning "ohos/build-profile.local.json5 已被 Git 跟踪，存在凭据泄漏风险。请立即 git rm --cached 并补 .gitignore。"
}

$remoteDir = "data/local/tmp/shenliyuan-$([guid]::NewGuid().ToString('N'))"
try {
    & $hdc -t $DeviceId shell aa force-stop $bundleName
    & $hdc -t $DeviceId shell mkdir $remoteDir
    & $hdc -t $DeviceId file send $hap $remoteDir
    & $hdc -t $DeviceId shell bm install -p $remoteDir
    if ($LASTEXITCODE -ne 0) {
        # 计划 22.1（5）：安装失败时打印诊断信息，便于排查 9568332 / install sign info inconsistent 等问题。
        Write-Host ''
        Write-Host '======== run_harmony.ps1 安装失败诊断 ========' -ForegroundColor Red
        Write-Host ("bundleName      : $bundleName")
        Write-Host ("DeviceId        : $DeviceId")
        Write-Host ("TargetPlatform  : $TargetPlatform")
        Write-Host ("Mode            : $Mode")
        Write-Host ("HAP 路径        : $hap")
        Write-Host ("HAP 大小        : $($hapInfo.Length) 字节")
        Write-Host ("HAP 修改时间    : $($hapInfo.LastWriteTime.ToString('o'))")
        Write-Host ("buildStart      : $(if ($null -ne $buildStart) { $buildStart.ToString('o') } else { '<跳过构建>' })")
        Write-Host ("local profile tracked : $localSigningTracked")
        Write-Host '---- 可能根因 / 排查建议 ----' -ForegroundColor Yellow
        Write-Host '① 设备已存在不同签名的同 bundleName 应用 → 请先卸载：'
        Write-Host "    hdc -t $DeviceId shell bm uninstall -n $bundleName"
        Write-Host '   或参考计划 21.1：换装一个干净模拟器/真机首次安装。'
        Write-Host '② 部署了 unsigned HAP → 不要使用 DevEco 默认 Run；统一走本脚本。'
        Write-Host '③ 开发模拟器与正式签名为不同身份 → 计划 22.5：测试阶段固定新调试签名。'
        Write-Host '④ bundleName 须保持一致（计划 22.5），不可每次签名冲突都改包名规避。'
        Write-Host '===============================================' -ForegroundColor Red
        throw '已签名 HAP 安装失败。请确认模拟器在线、bundleName 一致、签名身份与已安装版本相同。'
    }
} finally {
    & $hdc -t $DeviceId shell rm -rf $remoteDir
}

& $hdc -t $DeviceId shell aa start -a EntryAbility -b $bundleName
if ($LASTEXITCODE -ne 0) {
    throw 'HAP 已安装，但启动鸿蒙应用失败。'
}

Write-Host "已部署并启动：$DeviceId ($bundleName)"