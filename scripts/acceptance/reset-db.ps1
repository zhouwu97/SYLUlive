#Requires -Version 7.0
# 删除并重建本机验收库，补齐空库启动所需的前置迁移，最后写入种子数据。
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

# 空库首次启动会先 AutoMigrate 再校验 AI 授权表约束；校验失败时进程自行退出，成功时等健康检查通过后停止。
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

    if (-not (Invoke-ServerOnce $exe (Join-Path $report 'reset-bootstrap-1.log'))) {
        # AutoMigrate 建出的 ai_user_permissions 不带仓库 SQL 中的 CHECK 约束，这里按 SQL 原文补齐。
        Invoke-Psql $Database @('-f', 'sql/20260726_ai_external_model_permission.sql', '-c',
            "ALTER TABLE ai_user_permissions DROP CONSTRAINT IF EXISTS chk_ai_user_permissions_policy, ADD CONSTRAINT chk_ai_user_permissions_policy CHECK (policy IN ('ask', 'always', 'never'))")
        # 该命令只把含 host= 的 DSN 当作 PostgreSQL。
        $env:DSN = "host=127.0.0.1 port=$port user=$user password=$env:PGPASSWORD dbname=$Database sslmode=disable"
        go run ./cmd/migrate_competition_calendar --apply --backup-confirmed
        if ($LASTEXITCODE) { throw 'migrate_competition_calendar failed.' }
        $env:DSN = $settings.DSN
        if (-not (Invoke-ServerOnce $exe (Join-Path $report 'reset-bootstrap-2.log'))) {
            throw 'Server still fails on the rebuilt database; see reset-bootstrap-2.log.'
        }
    }

    go run ./cmd/seed_acceptance
    if ($LASTEXITCODE) { throw 'seed_acceptance failed.' }
} finally {
    Pop-Location
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
Write-Host "$Database rebuilt and seeded."
