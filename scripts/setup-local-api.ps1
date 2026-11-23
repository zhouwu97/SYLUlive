$ErrorActionPreference = 'Stop'

$targets = @(
    [pscustomobject]@{ Name = '本机桌面'; Address = '127.0.0.1' }
    [pscustomobject]@{ Name = 'Android Studio 模拟器'; Address = '10.0.2.2' }
)
# 多网卡机器由开发者选择真机可达的地址，避免误选 VPN 或虚拟网卡。
$targets += @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue |
    Where-Object { -not $_.SkipAsSource -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    Sort-Object InterfaceIndex |
    ForEach-Object { [pscustomobject]@{ Name = "同网真机 · $($_.InterfaceAlias)"; Address = $_.IPAddress } })

Write-Host '请选择 Flutter App 连接本机 Go 服务的方式'
for ($index = 0; $index -lt $targets.Count; $index++) {
    Write-Host ('  {0}. {1} ({2})' -f ($index + 1), $targets[$index].Name, $targets[$index].Address)
}
Write-Host '输入编号并回车（直接回车选本机桌面，0 取消）'
$choice = [Console]::ReadLine()
if ($null -eq $choice) { exit 1 }
if ($choice -eq '0') { exit 0 }
if ($choice -eq '') { $choice = '1' }
$number = 0
if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $targets.Count) {
    Write-Error '请输入列表中的编号。'
}

$apiUrl = 'http://{0}:8080/api' -f $targets[$number - 1].Address
$configPath = Join-Path $PSScriptRoot '../client/.env.local-api.json'
$config = @{ APP_API_URL = $apiUrl } | ConvertTo-Json
[System.IO.File]::WriteAllText($configPath, $config)

Write-Host "已写入 client/.env.local-api.json，App 接口地址为 $apiUrl"
Write-Host '启动 Go 服务后，在 client 目录运行 flutter run --dart-define-from-file=.env.local-api.json'
Write-Host '也可以用 VS Code 打开 client，选择 SYLUlive (Local/Configured) 启动。'
