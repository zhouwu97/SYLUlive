param(
    [ValidateSet('Start','Stop','Restart','Status')][string]$Action = 'Status',
    [ValidateSet('All','AstrBot','SnowLuma')][string]$Service = 'All'
)
$ErrorActionPreference = 'Stop'
$qqRoot = 'D:\AI\QQ'
$pidPath = Join-Path $qqRoot 'services.json'
$tracked = @{}
if (Test-Path -LiteralPath $pidPath) {
    $previous = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
    foreach ($item in $previous.PSObject.Properties) { $tracked[$item.Name] = [int]$item.Value }
}
$targets = if ($Service -eq 'All') { @('astrbot','snowluma') } else { @($Service.ToLowerInvariant()) }

function Test-OwnedProcess($proc, [string]$name) {
    if (-not $proc -or -not $proc.CommandLine) { return $false }
    if ($name -eq 'astrbot') {
        return $proc.CommandLine.Contains($qqRoot + '\AstrBot\.venv\Scripts\astrbot.exe') -and $proc.CommandLine -match '\brun\b'
    }
    return $proc.ExecutablePath -eq ($qqRoot + '\SnowLuma\node.exe') -and $proc.CommandLine.Contains('index.mjs')
}

function Find-TrackedProcess([string]$name) {
    if ($tracked.ContainsKey($name)) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($tracked[$name])" -ErrorAction SilentlyContinue
        if (Test-OwnedProcess $proc $name) { return $proc }
    }
    Get-CimInstance Win32_Process | Where-Object { Test-OwnedProcess $_ $name } | Select-Object -First 1
}

if ($Action -in @('Stop','Restart')) {
    foreach ($name in $targets) {
        $parent = Find-TrackedProcess $name
        if (-not $parent) { continue }
        $all = @(Get-CimInstance Win32_Process)
        $family = @($all | Where-Object { Test-OwnedProcess $_ $name })
        for ($depth=0; $depth -lt 8; $depth++) {
            $ids = @($family | ForEach-Object ProcessId)
            $children = @($all | Where-Object {
                $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids -and
                $_.CommandLine -and $_.CommandLine.Contains($qqRoot + '\')
            })
            if ($children.Count -eq 0) { break }
            $family += $children
        }
        [array]::Reverse($family)
        foreach ($proc in $family) { Stop-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue }
        $family | ForEach-Object { Wait-Process -Id $_.ProcessId -Timeout 5 -ErrorAction SilentlyContinue }
        $tracked.Remove($name)
    }
}

if ($Action -in @('Start','Restart')) {
    $env:PYTHONUTF8 = '1'
    $env:PYTHONUNBUFFERED = '1'
    foreach ($name in $targets) {
        if (Find-TrackedProcess $name) { continue }
        if ($name -eq 'astrbot') {
            $proc = Start-Process -FilePath "$qqRoot\AstrBot\.venv\Scripts\astrbot.exe" -ArgumentList 'run' -WorkingDirectory "$qqRoot\AstrBot" -WindowStyle Hidden -RedirectStandardOutput "$qqRoot\logs\astrbot.stdout.log" -RedirectStandardError "$qqRoot\logs\astrbot.stderr.log" -PassThru
        } else {
            $env:SNOWLUMA_WEBUI_HOST = '127.0.0.1'
            $env:SNOWLUMA_UPDATE_CHECK = '0'
            # 语音上传有时超过默认 15 秒；等待明确结果，避免过早超时后重发。
            $env:SNOWLUMA_PACKET_TIMEOUT_MS = '60000'
            # Use saved hookAutoLoad; do not inherit a temporary diagnostic override.
            Remove-Item Env:SNOWLUMA_HOOK_AUTOLOAD -ErrorAction SilentlyContinue
            $proc = Start-Process -FilePath "$qqRoot\SnowLuma\node.exe" -ArgumentList 'index.mjs' -WorkingDirectory "$qqRoot\SnowLuma" -WindowStyle Hidden -RedirectStandardOutput "$qqRoot\logs\snowluma.stdout.log" -RedirectStandardError "$qqRoot\logs\snowluma.stderr.log" -PassThru
        }
        $tracked[$name] = $proc.Id
    }
    if ($Service -ne 'AstrBot' -and (Test-Path -LiteralPath "$qqRoot\bot-target.json")) {
        & "$qqRoot\AstrBot\.venv\Scripts\python.exe" "$qqRoot\connect-bot.py"
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Services started, but the pinned QQ account requires verification.' }
    }
}
$tracked | ConvertTo-Json | Set-Content -LiteralPath $pidPath -Encoding utf8
$status = foreach ($name in @('astrbot','snowluma')) {
    $proc = Find-TrackedProcess $name
    [pscustomobject]@{Service=$name;Running=[bool]$proc;PID=if($proc){$proc.ProcessId}else{$null}}
}
$status | Format-Table -AutoSize
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object LocalPort -in @(6185,6199,5099,3000) |
    Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
