#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$report = Join-Path $root 'docs/reports/launch-acceptance'
$settings = Get-Content -LiteralPath (Join-Path $report 'env.acceptance') -Raw | ConvertFrom-StringData
$dsn = [uri]$settings.DSN
if ($dsn.Scheme -ne 'postgres' -or $dsn.Host -ne '127.0.0.1' -or
    $dsn.AbsolutePath -ne '/sylulive_acceptance' -or $dsn.Query -cne '?sslmode=disable' -or $dsn.Fragment -or
    $settings.GIN_MODE -ne 'debug' -or $settings.SERVER_LISTEN_ADDR -ne '127.0.0.1:8080') {
    throw 'Invalid local acceptance configuration.'
}
Get-ChildItem Env: | Where-Object Name -Match '^(PG|HTTP_PROXY$|HTTPS_PROXY$|ALL_PROXY$)' |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }
foreach ($key in $settings.Keys) { [Environment]::SetEnvironmentVariable($key, $settings[$key], 'Process') }
Push-Location (Join-Path $root 'server')
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    go run ./cmd 2>&1 | Tee-Object -FilePath (Join-Path $report 'server.log')
    if ($LASTEXITCODE) { throw "go run ./cmd exited with status $LASTEXITCODE." }
} finally {
    Pop-Location
}
