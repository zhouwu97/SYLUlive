[CmdletBinding()]
param(
    [string] $BaseUrl = '',
    [string] $Jwt = '',
    [string] $AdminJwt = '',
    [string] $Message = '请假政策',
    [int] $TimeoutSeconds = 45,
    [switch] $Execute,
    [switch] $ConsumeQuota,
    [string] $ConfirmQuotaExhaustion = '',
    [string] $Confirm = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Execute) {
    Write-Host 'dry-run：将检查 capabilities、SSE、取消与额度边界；默认不发出请求。'
    Write-Host '执行非额度耗尽验收需提供 -Execute -Confirm RUN:AI-PRODUCTION。'
    Write-Host '额度耗尽演练还必须提供 -ConsumeQuota -ConfirmQuotaExhaustion CONSUME:REMAINING-QUOTA，且只能在获批的测试账号上执行。'
    return
}
if ($Confirm -ne 'RUN:AI-PRODUCTION') {
    throw '确认短语必须为 RUN:AI-PRODUCTION；未发出请求。'
}
if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($Jwt)) {
    throw '执行验收必须提供 -BaseUrl 与测试账号 -Jwt。'
}
try { $targetUri = [uri]$BaseUrl } catch { throw 'BaseUrl 必须是合法的绝对 HTTP(S) 地址。' }
if (-not $targetUri.IsAbsoluteUri -or $targetUri.Scheme -notin @('http', 'https') -or
    -not [string]::IsNullOrEmpty($targetUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($targetUri.Query) -or
    -not [string]::IsNullOrEmpty($targetUri.Fragment)) {
    throw 'BaseUrl 必须是无用户信息、查询参数和片段的绝对 HTTP(S) 地址。'
}
$isLocalTarget = $targetUri.Host -in @('127.0.0.1', 'localhost', '::1')
if (-not $isLocalTarget -and $targetUri.Scheme -ne 'https') {
    throw '远程验收目标必须使用 HTTPS，未发出请求。'
}
if ($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 180) {
    throw 'TimeoutSeconds 必须在 10 到 180 之间。'
}
if ($ConsumeQuota -and $ConfirmQuotaExhaustion -ne 'CONSUME:REMAINING-QUOTA') {
    throw '额度耗尽演练还必须提供 -ConfirmQuotaExhaustion CONSUME:REMAINING-QUOTA。'
}
$base = $BaseUrl.TrimEnd('/')
$headers = @{ Authorization = "Bearer $Jwt" }

function Invoke-Api {
    param([string] $Method, [string] $Path, [object] $Body, [hashtable] $RequestHeaders = $headers)
    $request = @{
        Method = $Method
        Uri = "$base$Path"
        Headers = $RequestHeaders
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = ($Body | ConvertTo-Json -Compress)
    }
    try {
        return Invoke-RestMethod @request
    } catch {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw }
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
        try { $payload = $reader.ReadToEnd() } finally { $reader.Dispose() }
        [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = ($payload | ConvertFrom-Json) }
    }
}

function New-Run([string] $conversationId) {
    $body = @{ conversation_id = $conversationId; client_request_id = ([guid]::NewGuid().ToString()); message = $Message }
    $response = Invoke-Api 'Post' '/api/ai/runs' $body
    if ($response.StatusCode -and $response.StatusCode -ge 400) { throw "创建 AI Run 失败: $($response.Body.code)" }
    return $response.run
}

function Get-Run([string] $runId) {
    $response = Invoke-Api 'Get' "/api/ai/runs/$runId" $null
    if ($response.StatusCode -and $response.StatusCode -ge 400) { throw "读取 AI Run 失败: $($response.Body.code)" }
    return $response.run
}

function Read-SseUntilTerminal([string] $runId, [int64] $lastEventId = 0, [int] $maxMilliseconds = 45000, [switch] $StopAfterFirstEvent) {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$base/api/ai/runs/$runId/events")
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Jwt)
    if ($lastEventId -gt 0) { $request.Headers.Add('Last-Event-ID', "$lastEventId") }
    $response = $null
    $reader = $null
    $last = $lastEventId
    $terminal = $false
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "SSE HTTP $([int]$response.StatusCode)" }
        $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
        $deadline = [DateTime]::UtcNow.AddMilliseconds($maxMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remainingMilliseconds = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -le 0) { break }
            $readTask = $reader.ReadLineAsync()
            if (-not $readTask.Wait($remainingMilliseconds)) {
                throw "SSE 读取超过 $maxMilliseconds 毫秒。"
            }
            $line = $readTask.Result
            if ($null -eq $line) { break }
            if ($line -match '^id: (\d+)$') {
                $last = [int64]$Matches[1]
                if ($StopAfterFirstEvent) { break }
            }
            if ($line -match '^event: run\.(completed|failed|cancelled)$') { $terminal = $true; break }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
    [pscustomobject]@{ LastEventId = $last; Terminal = $terminal }
}

Write-Host '检查 capabilities...'
$capabilities = Invoke-Api 'Get' '/api/ai/capabilities' $null
if (-not $capabilities.access_allowed -or -not $capabilities.chat_enabled) {
    throw '当前 JWT 没有 AI 内测权限，或生产 AI Runtime/RAG 未就绪。'
}

if (-not [string]::IsNullOrWhiteSpace($AdminJwt)) {
    Write-Host '检查管理员知识库 readiness...'
    $adminHeaders = @{ Authorization = "Bearer $AdminJwt" }
    $readiness = Invoke-Api 'Get' '/api/admin/ai/knowledge/readiness' $null $adminHeaders
    if ($readiness.StatusCode -and $readiness.StatusCode -ge 400) {
        throw "读取知识库 readiness 失败: $($readiness.Body.code)"
    }
    if (-not $readiness.ready -or [int64]$readiness.effective_chunks -le 0) {
        throw "生产知识库未就绪: $($readiness.reason)，effective_chunks=$($readiness.effective_chunks)"
    }
}

Write-Host '创建会话并验证 SSE 断线恢复...'
$conversation = Invoke-Api 'Post' '/api/ai/conversations' @{ title = '生产验收' }
$conversationId = $conversation.conversation.id
$run = New-Run $conversationId
$first = Read-SseUntilTerminal $run.id 0 15000 -StopAfterFirstEvent
if ($first.LastEventId -le 0) { throw 'SSE 未收到可用于断线恢复的事件。' }
$recovered = Read-SseUntilTerminal $run.id $first.LastEventId ($TimeoutSeconds * 1000)
if (-not $recovered.Terminal) { throw 'SSE 断线后未能通过 Last-Event-ID 回放到终态。' }
$completedRun = Get-Run $run.id
if ($completedRun.state -ne 'completed' -or [string]::IsNullOrWhiteSpace($completedRun.answer_checkpoint)) {
    throw "真实提问未产生可核验回答，实际状态为 $($completedRun.state)"
}

Write-Host '验证取消...'
$cancelRun = New-Run $conversationId
$cancelResponse = Invoke-Api 'Post' "/api/ai/runs/$($cancelRun.id)/cancel" $null
if ($cancelResponse.StatusCode -and $cancelResponse.StatusCode -ge 400) { throw "取消 Run 失败: $($cancelResponse.Body.code)" }
$cancelDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Milliseconds 250
    $cancelled = Get-Run $cancelRun.id
} while ($cancelled.state -notin @('cancelled', 'completed', 'failed') -and [DateTime]::UtcNow -lt $cancelDeadline)
if ($cancelled.state -ne 'cancelled') { throw "Run 未进入 cancelled，实际状态为 $($cancelled.state)" }

if (-not $ConsumeQuota) {
    Write-Host '跳过额度耗尽演练；未提供 -ConsumeQuota。'
    Write-Host 'AI 生产端到端非破坏性验收通过。'
    return
}

Write-Host '验证额度耗尽（仅允许使用明确获批的测试账号）...'
$quotaCapabilities = Invoke-Api 'Get' '/api/ai/capabilities' $null
if (-not $quotaCapabilities.access_allowed -or -not $quotaCapabilities.chat_enabled) {
    throw '取消测试后 AI 能力不可用，无法继续额度验收。'
}
$remaining = [int]$quotaCapabilities.quota.remaining
for ($i = 0; $i -lt $remaining; $i++) {
    $quotaRun = New-Run $conversationId
    $quotaSse = Read-SseUntilTerminal $quotaRun.id 0 ($TimeoutSeconds * 1000)
    if (-not $quotaSse.Terminal) { throw '额度耗尽前的 Run 未完成。' }
}
$exhausted = Invoke-Api 'Post' '/api/ai/runs' @{ conversation_id = $conversationId; client_request_id = ([guid]::NewGuid().ToString()); message = $Message }
if ($exhausted.StatusCode -ne 429 -or $exhausted.Body.code -ne 'ai_quota_exceeded') {
    throw "额度耗尽未返回 ai_quota_exceeded，实际为 HTTP $($exhausted.StatusCode) / $($exhausted.Body.code)"
}

Write-Host 'AI 生产端到端验收通过。'
