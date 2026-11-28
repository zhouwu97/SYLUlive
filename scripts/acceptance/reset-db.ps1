#Requires -Version 7.0
# 删除并重建本机验收库：空库启动一次完成建表和迁移，再写入种子数据。
# 只操作 env.acceptance 中 127.0.0.1 上以 _acceptance 结尾的库；运行前先停止正在使用该库的 Go 服务。
[CmdletBinding()]
param([string]$Database = 'sylulive_acceptance', [int]$BootstrapPort = 18080)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$report = Join-Path $root 'docs/reports/launch-acceptance'
$pgBin = 'E:\pgsql15-acceptance\bin'
$settings = Get-Content -LiteralPath (Join-Path $report 'env.acceptance') -Raw | ConvertFrom-StringData
$dsn = [uri]$settings.DSN
if ($dsn.Host -ne '127.0.0.1' -or -not $Database.EndsWith('_acceptance')) {
    throw 'Only a loopback *_acceptance database can be reset.'
}
$user, $password = $dsn.UserInfo.Split(':', 2)
$port = $dsn.Port
$builder = [UriBuilder]::new($dsn)
$builder.Path = "/$Database"
$settings.DSN = $builder.Uri.AbsoluteUri
$settings.SERVER_LISTEN_ADDR = "127.0.0.1:$BootstrapPort"

foreach ($key in $settings.Keys) { [Environment]::SetEnvironmentVariable($key, $settings[$key], 'Process') }
$env:PGPASSWORD = [uri]::UnescapeDataString($password)
$psql = @('-h', '127.0.0.1', '-p', $port, '-U', $user, '-w', '-v', 'ON_ERROR_STOP=1')

function Invoke-Psql([string]$db, [string[]]$arguments) {
    & (Join-Path $pgBin 'psql.exe') @psql -d $db @arguments
    if ($LASTEXITCODE) { throw "psql failed on $db." }
}

# 启动一次服务完成建表与迁移，健康检查通过后停止；进程提前退出即视为空库启动失败。
function Invoke-ServerOnce([string]$exe, [string]$log) {
    $process = Start-Process -FilePath $exe -WorkingDirectory (Join-Path $root 'server') -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    for ($i = 0; $i -lt 180 -and -not $process.HasExited; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:$BootstrapPort/health" -NoProxy -TimeoutSec 2 | Out-Null
            Stop-Process -Id $process.Id
            $process.WaitForExit()
            return $true
        } catch {}
    }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id; throw "Server did not become healthy; see $log." }
    return $false
}

$exe = Join-Path $report 'acceptance-server.exe'
Push-Location (Join-Path $root 'server')
try {
    go build -o $exe ./cmd
    if ($LASTEXITCODE) { throw 'go build ./cmd failed.' }

    Invoke-Psql 'postgres' @('-c', "DROP DATABASE IF EXISTS $Database WITH (FORCE)", '-c', "CREATE DATABASE $Database")

    if (-not (Invoke-ServerOnce $exe (Join-Path $report 'reset-bootstrap.log'))) {
        throw 'Server failed to start on the empty database; see reset-bootstrap.log.'
    }

    go run ./cmd/seed_acceptance
    if ($LASTEXITCODE) { throw 'seed_acceptance failed.' }
} finally {
    Pop-Location
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
Write-Host "$Database rebuilt and seeded."
