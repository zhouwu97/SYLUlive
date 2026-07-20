[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BaseUrl,
    [Parameter(Mandatory = $true)] [string] $Jwt,
    [string] $AdminJwt,
    [string] $Message = '请假政策',
    [int] $TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
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
        while ([DateTime]::UtcNow -lt $deadline -and -not $reader.EndOfStream) {
            $line = $reader.ReadLine()
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

Write-Host '验证额度耗尽（脚本会使用当前账号的剩余额度，不修改预算上限）...'
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
