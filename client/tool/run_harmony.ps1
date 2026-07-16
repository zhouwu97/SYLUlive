[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [ValidateSet('ohos-arm64', 'ohos-arm', 'ohos-x64')]
    [string]$TargetPlatform = 'ohos-x64',
    [string]$DeviceId = '127.0.0.1:5555',
    [string]$OhosFlutterHome = $env:OHOS_FLUTTER_HOME,
    [string]$DevecoHome = $env:DEVECO_HOME,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($DevecoHome)) {
    $DevecoHome = 'E:\devecostudio'
}

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

# 先通过受控脚本注入本机签名配置；脚本结束后会恢复仓库中的无凭据模板。
& $buildScript @buildArgs

$hap = Join-Path $projectRoot 'build\ohos\hap\entry-default-signed.hap'
if (-not (Test-Path -LiteralPath $hap)) {
    throw "没有找到已签名 HAP：$hap"
}

$hdc = Join-Path $DevecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path -LiteralPath $hdc)) {
    throw "找不到 hdc：$hdc"
}

$remoteDir = "data/local/tmp/shenliyuan-$([guid]::NewGuid().ToString('N'))"
try {
    & $hdc -t $DeviceId shell aa force-stop com.example.shenliyuan
    & $hdc -t $DeviceId shell mkdir $remoteDir
    & $hdc -t $DeviceId file send $hap $remoteDir
    & $hdc -t $DeviceId shell bm install -p $remoteDir
    if ($LASTEXITCODE -ne 0) {
        throw '已签名 HAP 安装失败。请确认模拟器在线且其调试签名材料未变更。'
    }
} finally {
    & $hdc -t $DeviceId shell rm -rf $remoteDir
}

& $hdc -t $DeviceId shell aa start -a EntryAbility -b com.example.shenliyuan
if ($LASTEXITCODE -ne 0) {
    throw 'HAP 已安装，但启动鸿蒙应用失败。'
}

Write-Host "已部署并启动：$DeviceId"
