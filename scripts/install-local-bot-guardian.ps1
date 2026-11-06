param([string]$BotRoot = 'D:\AI\QQ')
$ErrorActionPreference = 'Stop'
$guardianRoot = Join-Path $BotRoot 'guardian'
$python = Join-Path $BotRoot 'AstrBot\.venv\Scripts\pythonw.exe'
$source = Join-Path $PSScriptRoot 'local-bot-guardian.py'
$target = Join-Path $guardianRoot 'local-bot-guardian.py'
if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath (Join-Path $BotRoot 'secrets\local-access.json'))) {
    throw 'Install and configure the local bot before enabling its guardian.'
}
New-Item -ItemType Directory -Path $guardianRoot -Force | Out-Null
if (Test-Path -LiteralPath $target) {
    Copy-Item -LiteralPath $target -Destination ($target + '.before-' + (Get-Date -Format 'yyyyMMddHHmmss'))
}
Copy-Item -LiteralPath $source -Destination $target
$taskName = 'SYLUlive-LocalBot-Guardian'
$arguments = '"' + $target + '" --root "' + $BotRoot + '"'
$mode = 'scheduled_task'
try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $python -Argument $arguments -WorkingDirectory $guardianRoot
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logon,$repeat) -Settings $settings -Principal $principal -Description 'Supervise the local QQ bot without sending messages or changing permissions.' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
} catch {
    # Current-user startup requires no elevated rights; report its narrower scope.
    $mode = 'user_startup'
    $startup = [Environment]::GetFolderPath('Startup')
    $startupFile = Join-Path $startup 'SYLUlive-LocalBot-Guardian.vbs'
    $command = '"' + $python + '" ' + $arguments
    $vbsCommand = $command.Replace('"','""')
    Set-Content -LiteralPath $startupFile -Value ('CreateObject("WScript.Shell").Run "' + $vbsCommand + '", 0, False') -Encoding Unicode
    Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $guardianRoot -WindowStyle Hidden
    Write-Warning 'Task Scheduler registration was unavailable; current-user login startup is installed instead.'
}
[ordered]@{mode=$mode;task_name=if($mode -eq 'scheduled_task'){$taskName}else{$null};script_sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();installed_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $guardianRoot 'installation.json') -Encoding utf8
Write-Output ('Guardian installed: ' + $mode)
