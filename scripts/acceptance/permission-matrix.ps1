#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$report = Join-Path $PSScriptRoot '../../docs/reports/launch-acceptance'
$settings = Get-Content -LiteralPath (Join-Path $report 'env.acceptance') -Raw | ConvertFrom-StringData
$access = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'route-access.psd1')
$output = Join-Path $report 'permission-matrix.csv'
$transport = [Net.Http.HttpClientHandler]::new()
$transport.AllowAutoRedirect = $false
$transport.UseProxy = $false
$transport.UseCookies = $false
$client = [Net.Http.HttpClient]::new($transport)
$client.BaseAddress = [uri]'http://127.0.0.1:8080'
$client.Timeout = [TimeSpan]::FromSeconds(15)

function Invoke-LocalRequest($method, $path, $token, $json) {
    if ($path -notmatch '^/(api|health)(/|$)' -or $path -match '[\\?#]') { throw "Invalid local request path: $path" }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method), $path)
    try {
        if ($token) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token) }
        if ($null -ne $json) { $request.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.Send($request)
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return @{ Status = [int]$response.StatusCode; Body = $body; RequestID = ($response.Headers | Where-Object Key -eq 'X-Request-Id').Value -join '' }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

try {
    $health = Invoke-LocalRequest GET /health $null $null
    if ($health.Status -ne 200 -or ($health.Body | ConvertFrom-Json).status -ne 'ok') { throw 'Acceptance server is unhealthy.' }
    $tokens = @{}
    foreach ($identity in 'U1', 'A1', 'S1') {
        $key = if ($identity -eq 'S1') { 'SUPER_ADMIN' } else { $identity }
        $json = @{ account = $settings["${key}_ID"]; password = $settings["${key}_PASSWORD"] } | ConvertTo-Json -Compress
        $login = Invoke-LocalRequest POST /api/login $null $json
        if ($login.Status -ne 200) { throw "Acceptance login failed for $identity (HTTP $($login.Status))." }
        $payload = $login.Body | ConvertFrom-Json
        $role = @{ U1 = 'user'; A1 = 'admin'; S1 = 'super_admin' }[$identity]
        if (!$payload.token -or $payload.user.role -ne $role) { throw "Acceptance login returned unexpected credentials for $identity." }
        $tokens[$identity] = $payload.token
    }

    $rows = foreach ($route in Import-Csv (Join-Path $report 'routes.csv')) {
        $target = "$($route.method) $($route.path)"
        $superRule = $access.Super.Keys | Where-Object { $target -cmatch $_ } | Select-Object -First 1
        $adminRule = $access.Admin.Keys | Where-Object { $target -cmatch $_ } | Select-Object -First 1
        if (!$superRule -and !$adminRule) { continue }
        $source = if ($superRule) { $access.Super[$superRule] } else { $access.Admin[$adminRule] }
        foreach ($identity in 'guest', 'U1', 'A1', 'S1') {
            $expected = if ($identity -eq 'guest') { '401' } elseif ($identity -eq 'U1' -or ($identity -eq 'A1' -and $superRule)) { '403' } else { 'non-401/403' }
            [pscustomobject]@{ route = $target; identity = $identity; expected = $expected; actual = ''; conforms = ''; request_id = ''; source = $source; note = '未执行'; method = $route.method; path = $route.path }
        }
    }
    $stop = $null
    foreach ($row in $rows) {
        if ($row.route -eq 'POST /api/super/checkin/rebuild-all' -and $row.identity -eq 'S1') {
            $inspect = Invoke-LocalRequest GET /api/super/checkin/inspect $tokens.S1 $null
            if ($inspect.Status -ne 200 -or ($inspect.Body | ConvertFrom-Json).total_count -ne 0) {
                $stop = '签到对账预检未通过，继续会触及批量改写。'
                break
            }
        }
        $path = $row.path -replace '[:*][A-Za-z_][A-Za-z_0-9]*', '2147483647'
        $answer = Invoke-LocalRequest $row.method $path $tokens[$row.identity] $null
        $row.actual = $answer.Status
        $row.request_id = $answer.RequestID
        $row.note = ''
        $row.conforms = if ($row.expected -eq 'non-401/403') { $answer.Status -notin 401,403 } else { $answer.Status -eq [int]$row.expected }
        if ($row.expected -in '401','403' -and $answer.Status -notin 401,403,429,500,502,503,504) {
            $row.note = '达到方案 §7.4 权限停止条件'
            $stop = "$($row.identity) $($row.route) returned HTTP $($row.actual)"
            break
        }
    }
    $rows | Select-Object route,identity,expected,actual,conforms,request_id,source,note | Export-Csv -LiteralPath $output -Encoding utf8BOM
    if ($stop) { throw $stop }
    $failed = @($rows | Where-Object conforms -eq $false)
    Write-Output "Routes: $($rows.Count / 4); checks: $($rows.Count); mismatches: $($failed.Count)"
    if ($failed.Count) { exit 1 }
} finally { $client.Dispose() }
