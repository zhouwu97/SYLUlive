param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('emoji-chain-' + [guid]::NewGuid().ToString('N'))
}
$runRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$fixturePath = Join-Path $runRoot 'fixture.json'
if (Test-Path -LiteralPath $fixturePath) { throw "此目录已有联调实例，请使用新的输出目录：$runRoot" }
$savedConfig = $env:EMOJI_CHAIN_CONFIG
$savedQA = $env:EMOJI_QA_DIR
$serverProcess = $null
$testCode = 1
try {
    $env:EMOJI_CHAIN_CONFIG = $fixturePath
    $env:EMOJI_QA_DIR = Join-Path $runRoot 'screenshots'
    $goExe = (Get-Command go -ErrorAction Stop).Source
    $serverProcess = Start-Process -FilePath $goExe -ArgumentList @('test', './cmd', '-run', '^TestEmojiFrontendChainServer$', '-count=1', '-v', '-timeout', '15m') -WorkingDirectory (Join-Path $repoRoot 'server') -RedirectStandardOutput (Join-Path $runRoot 'api.log') -RedirectStandardError (Join-Path $runRoot 'api-error.log') -PassThru -WindowStyle Hidden
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(120)
    while (-not (Test-Path -LiteralPath $fixturePath)) {
        if ($serverProcess.HasExited) { throw "隔离 API 启动失败，见 $runRoot" }
        if ([DateTime]::UtcNow -gt $readyDeadline) { throw "隔离 API 启动超时，见 $runRoot" }
        Start-Sleep -Milliseconds 100
    }
    $apiBase = (Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json).base_url
    Push-Location (Join-Path $repoRoot 'client')
    try {
        & flutter test --no-pub "--dart-define=APP_API_URL=$apiBase" test/integration/emoji_frontend_chain_test.dart --reporter expanded *> (Join-Path $runRoot 'flutter.log')
        $testCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Get-Content -LiteralPath (Join-Path $runRoot 'flutter.log') -Tail 30
} finally {
    # 只控制本次创建的服务，服务关闭后由 Go 测试回收临时 DB/文件和 fixture JWT。
    [IO.File]::WriteAllText($fixturePath + '.stop', 'stop')
    if ($serverProcess) {
        if (-not $serverProcess.WaitForExit(20000)) {
            Write-Warning "隔离服务尚未退出；测试自身有 12 分钟超时，见 $runRoot"
            $testCode = 1
        } elseif ($serverProcess.ExitCode -ne 0) {
            $testCode = 1
        }
    }
    $env:EMOJI_CHAIN_CONFIG = $savedConfig
    $env:EMOJI_QA_DIR = $savedQA
}
Write-Output "Emoji chain evidence: $runRoot"
exit $testCode
