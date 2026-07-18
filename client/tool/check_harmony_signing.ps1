[CmdletBinding()]
param(
    [string]$DeviceId = '127.0.0.1:5555',
    [string]$DevecoHome = $env:DEVECO_HOME,
    [switch]$Strict
)

# 计划 22.3：新增签名状态检查脚本
# 职责：
#   1. 检查 build-profile.json5 是否为无凭据模板
#   2. 检查 build-profile.local.json5 是否存在
#   3. 检查本地文件是否被 Git 跟踪（应当 untracked）
#   4. 检查当前目标 HAP 是否为 signed
#   5. 检查 unsigned HAP 是否被误选
#   6. 检查 bundleName
#   7. 输出建议的卸载或换设备命令
# 设计：无副作用只读脚本，可独立运行；-Strict 时任何严重问题非零退出，便于 CI/手动门禁调用。

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($DevecoHome)) {
    $DevecoHome = 'E:\devecostudio'
}

$issues  = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$ok      = New-Object System.Collections.Generic.List[string]

function Write-Section($title) {
    Write-Host ''
    Write-Host "==== $title ====" -ForegroundColor Cyan
}

# 1) 受跟踪的 build-profile.json5 必须为无凭据模板。
Write-Section '1. 无凭据模板校验 (build-profile.json5)'
$buildProfile = Join-Path $projectRoot 'ohos\build-profile.json5'
if (-not (Test-Path -LiteralPath $buildProfile)) {
    $issues.Add("缺少受跟踪模板：$buildProfile")
    Write-Host "  [FAIL] 缺少受跟踪模板：$buildProfile" -ForegroundColor Red
} else {
    $tmpl = Get-Content -LiteralPath $buildProfile -Raw
    if ($tmpl -match '"signingConfigs"') {
        $issues.Add('build-profile.json5 已含 signingConfigs，疑似凭据泄漏。请立即 git diff 排查并恢复无凭据模板。')
        Write-Host '  [FAIL] 模板已含 signingConfigs，疑似凭据泄漏' -ForegroundColor Red
    } else {
        $ok.Add('build-profile.json5 为无凭据模板')
        Write-Host '  [ OK ] 模板无 signingConfigs' -ForegroundColor Green
    }
}

# 2) 本机签名配置应当存在（DevEco 生成）。
Write-Section '2. 本机签名配置 (build-profile.local.json5)'
$localSigningProfile = Join-Path $projectRoot 'ohos\build-profile.local.json5'
if (-not (Test-Path -LiteralPath $localSigningProfile)) {
    $issues.Add("缺少本机签名配置：$localSigningProfile。请在 DevEco Studio 生成调试签名后创建该未跟踪文件。")
    Write-Host "  [FAIL] 缺少本机签名配置：$localSigningProfile" -ForegroundColor Red
} else {
    $ok.Add('本机签名配置存在')
    Write-Host '  [ OK ] 本机签名配置存在' -ForegroundColor Green
    $localText = Get-Content -LiteralPath $localSigningProfile -Raw
    if ($localText -match '"storePassword"\s*:\s*"([^"]*)"\s*' -or
        $localText -match '"keyPassword"\s*:\s*"([^"]*)"\s*') {
        $warnings.Add('build-profile.local.json5 看起来使用明文口令字段；不影响本机构建但请勿提交或截图外发。')
        Write-Host '  [WARN] 检测到明文口令字段，请勿提交' -ForegroundColor Yellow
    } else {
        $ok.Add('未在本机签名配置内发现明显明文口令字段')
        Write-Host '  [ OK ] 未发现明显明文口令字段' -ForegroundColor Green
    }
}

# 3) 本机签名文件绝不能被 Git 跟踪。
Write-Section '3. 本机签名是否被 Git 跟踪'
$tracked = $false
try {
    & git -C $projectRoot ls-files --error-unmatch 'ohos/build-profile.local.json5' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $tracked = $true }
} catch {
    $tracked = $false
}
if ($tracked) {
    $issues.Add('ohos/build-profile.local.json5 已被 Git 跟踪！请立即执行：git rm --cached ohos/build-profile.local.json5')
    Write-Host '  [FAIL] 已被 Git 跟踪，请立即 git rm --cached' -ForegroundColor Red
} else {
    $ok.Add('本机签名文件未被 Git 跟踪')
    Write-Host '  [ OK ] 未被 Git 跟踪' -ForegroundColor Green
}

# 4)+5) 目标 HAP 状态：检查 signed 是否存在、是否被 unsigned 误选。
Write-Section '4. 目标 HAP 状态'
$hapDir = Join-Path $projectRoot 'build\ohos\hap'
$signedHap = Join-Path $hapDir 'entry-default-signed.hap'
$unsignedHap = Join-Path $hapDir 'entry-default-unsigned.hap'
if (Test-Path -LiteralPath $signedHap) {
    $signedInfo = Get-Item -LiteralPath $signedHap
    Write-Host ("  [ OK ] signed HAP 存在：$signedHap")
    Write-Host ("         大小 $([math]::Round($signedInfo.Length / 1MB, 2)) MB，修改时间 $($signedInfo.LastWriteTime.ToString('o'))")
    if ($signedHap -match 'unsigned') {
        $issues.Add('signed HAP 路径中包含 unsigned 关键字，路径异常')
        Write-Host '  [FAIL] signed HAP 路径包含 unsigned 关键字' -ForegroundColor Red
    } else {
        $ok.Add('signed HAP 路径正常')
    }
} else {
    $warnings.Add('尚未生成 entry-default-signed.hap。请先运行 build_harmony.ps1。')
    Write-Host '  [WARN] 尚未生成 signed HAP' -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $unsignedHap) {
    $warnings.Add("发现 unsigned HAP：$unsignedHap。run_harmony.ps1 永远不会部署它，但请确认不是 DevEco 默认 Run 流程残留。")
    Write-Host "  [WARN] 残留 unsigned HAP：$unsignedHap" -ForegroundColor Yellow
}

# 6) bundleName 一致性（计划 22.5：测试阶段固定，正式发布前不动）。
Write-Section '5. bundleName'
$appJson5 = Join-Path $projectRoot 'ohos\AppScope\app.json5'
$bundleName = $null
if (Test-Path -LiteralPath $appJson5) {
    $appText = Get-Content -LiteralPath $appJson5 -Raw
    if ($appText -match '"bundleName"\s*:\s*"([^"]+)"') {
        $bundleName = $matches[1]
    }
}
if ([string]::IsNullOrWhiteSpace($bundleName)) {
    $issues.Add('无法从 AppScope/app.json5 读取 bundleName')
    Write-Host '  [FAIL] 无法读取 bundleName' -ForegroundColor Red
} else {
    $ok.Add("bundleName = $bundleName")
    Write-Host "  [ OK ] bundleName = $bundleName" -ForegroundColor Green
    if ($bundleName -eq 'com.example.shenliyuan') {
        Write-Host '  [INFO] 当前为占位包名；正式发布前需按计划 16.4 一次性冻结最终包名。' -ForegroundColor DarkGray
    }
}

# 7) 卸载 / 换设备建议
Write-Section '6. 安装冲突时建议命令'
if ($bundleName) {
    Write-Host "  设备列表：hdc list targets"
    Write-Host "  卸载当前已签名或旧签名版本（会清空 App 数据与登录）："
    Write-Host "    hdc -t $DeviceId shell bm uninstall -n $bundleName"
    Write-Host "  若 SDK 参数有差异先执行："
    Write-Host "    hdc -t $DeviceId shell bm help"
    Write-Host "  旁路方案（计划 21.1）：换一个全新模拟器首次安装 signed HAP，避免覆盖冲突。"
} else {
    Write-Host '  跳过：bundleName 未识别。' -ForegroundColor DarkGray
}

# 汇总
Write-Section '汇总'
Write-Host ("OK      : $($ok.Count)")
Write-Host ("WARN    : $($warnings.Count)") -ForegroundColor Yellow
Write-Host ("FAIL    : $($issues.Count)") -ForegroundColor Red
$warnings | ForEach-Object { Write-Host "  > [WARN] $_" -ForegroundColor Yellow }
$issues   | ForEach-Object { Write-Host "  > [FAIL] $_" -ForegroundColor Red }

if ($Strict -and $issues.Count -gt 0) {
    exit 1
}