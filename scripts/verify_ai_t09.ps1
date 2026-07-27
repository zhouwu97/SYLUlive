[CmdletBinding()]
param(
    [string] $BaseUrl = '',
    [string] $Jwt = '',
    [string] $AdminJwt = '',
    [ValidateSet('langchain', 'legacy_go', 'either')] [string] $ExpectedRagPath = 'either',
    [int64] $RevokedChunkId = 0,
    [int] $TimeoutSeconds = 60,
    [int] $SlowClientDelayMilliseconds = 50,
    [switch] $Execute,
    [switch] $RunQuotaExhaustion,
    [string] $ConfirmQuotaExhaustion = '',
    [string] $Confirm = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Execute) {
    [pscustomobject]@{
        schema_version = 't09-e2e-plan/v1'
        writes_performed = $false
        scenarios = @(
            '问答与有界追问', '可靠拒答', '来源展开', 'SSE 终态回放', '慢客户端',
            '取消', '重复请求幂等', '额度计数', '已撤销来源不可读', 'LangChain/旧 Go 路径核验'
        )
        quota_exhaustion_default = $false
        minimum_remaining_quota = 6
        knowledge_mutation_performed = $false
    } | ConvertTo-Json -Depth 4
    return
}

if ($Confirm -ne 'RUN:T09-E2E') { throw '确认短语必须为 RUN:T09-E2E；未发出请求。' }
if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($Jwt)) {
    throw '执行演练必须提供 -BaseUrl 与测试账号 -Jwt。'
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
if ($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 180) { throw 'TimeoutSeconds 必须在 10 到 180 之间。' }
if ($SlowClientDelayMilliseconds -lt 0 -or $SlowClientDelayMilliseconds -gt 2000) {
    throw 'SlowClientDelayMilliseconds 必须在 0 到 2000 之间。'
}
if ($RunQuotaExhaustion -and $ConfirmQuotaExhaustion -ne 'CONSUME:REMAINING-QUOTA') {
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
        $request.Body = ($Body | ConvertTo-Json -Compress -Depth 8)
    }
    try {
        return Invoke-RestMethod @request
    } catch {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw }
        if ($null -ne $response.Content) {
            $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } else {
            $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
            try { $payload = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        $body = if ([string]::IsNullOrWhiteSpace($payload)) { $null } else { $payload | ConvertFrom-Json }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = $body }
    }
}

function New-Run {
    param([string] $ConversationId, [string] $Message, [string] $ClientRequestId = '')
    if ([string]::IsNullOrWhiteSpace($ClientRequestId)) { $ClientRequestId = [guid]::NewGuid().ToString() }
    $response = Invoke-Api 'Post' '/api/ai/runs' @{
        conversation_id = $ConversationId
        client_request_id = $ClientRequestId
        message = $Message
    }
    if ($response.StatusCode -and $response.StatusCode -ge 400) {
        throw "创建 AI Run 失败: $($response.Body.code)"
    }
    return $response
}

function Get-Run([string] $RunId) {
    $response = Invoke-Api 'Get' "/api/ai/runs/$RunId" $null
    if ($response.StatusCode -and $response.StatusCode -ge 400) { throw "读取 Run 失败: $($response.Body.code)" }
    return $response.run
}

function Read-RunEvents {
    param(
        [string] $RunId,
        [int64] $LastEventId = 0,
        [int] $DelayMilliseconds = 0,
        [switch] $StopAfterFirstEvent
    )
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get, "$base/api/ai/runs/$RunId/events"
    )
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Jwt)
    if ($LastEventId -gt 0) { $request.Headers.Add('Last-Event-ID', "$LastEventId") }
    $response = $null
    $reader = $null
    $events = [System.Collections.Generic.List[object]]::new()
    $currentId = 0L
    $currentType = ''
    $data = [System.Text.StringBuilder]::new()
    try {
        $response = $client.SendAsync(
            $request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "SSE HTTP $([int]$response.StatusCode)" }
        $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remainingMilliseconds = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -le 0) { break }
            $readTask = $reader.ReadLineAsync()
            if (-not $readTask.Wait($remainingMilliseconds)) {
                throw "SSE 读取超过 ${TimeoutSeconds} 秒。"
            }
            $line = $readTask.Result
            if ($null -eq $line) { break }
            if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
            if ($line -match '^id: (\d+)$') { $currentId = [int64]$Matches[1]; continue }
            if ($line -match '^event: (.+)$') { $currentType = $Matches[1]; continue }
            if ($line -match '^data: ?(.*)$') {
                if ($data.Length -gt 0) { [void]$data.Append("`n") }
                [void]$data.Append($Matches[1])
                continue
            }
            if ($line -eq '' -and $currentType) {
                $payload = if ($data.Length -gt 0) { $data.ToString() | ConvertFrom-Json } else { $null }
                $events.Add([pscustomobject]@{ Id = $currentId; Type = $currentType; Payload = $payload })
                if ($StopAfterFirstEvent -or $currentType -in @('run.completed', 'run.failed', 'run.cancelled')) { break }
                $currentType = ''
                [void]$data.Clear()
            }
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
    return @($events)
}

function Assert-TerminalRun {
    param([object] $RunResponse, [string[]] $AllowedStates = @('completed'))
    $events = Read-RunEvents $RunResponse.run.id
    $run = Get-Run $RunResponse.run.id
    if ($run.state -notin $AllowedStates) { throw "Run 终态不符合预期: $($run.state)" }
    return [pscustomobject]@{ Run = $run; Events = $events }
}

$capabilitiesBefore = Invoke-Api 'Get' '/api/ai/capabilities' $null
if (-not $capabilitiesBefore.access_allowed -or -not $capabilitiesBefore.chat_enabled) {
    throw '测试账号没有 AI 灰度资格或 Runtime 未就绪。'
}
$requiredRemainingQuota = 6
$remainingBefore = [int]$capabilitiesBefore.quota.remaining
if ($remainingBefore -lt $requiredRemainingQuota) {
    throw "完整 T09 演练至少需要 $requiredRemainingQuota 个可预留 Run；当前仅剩 $remainingBefore。请使用隔离的高额度测试账号，不得提高生产普通账号额度。"
}

if ($AdminJwt) {
    $adminHeaders = @{ Authorization = "Bearer $AdminJwt" }
    $readiness = Invoke-Api 'Get' '/api/admin/ai/knowledge/readiness' $null $adminHeaders
    if ($readiness.StatusCode -and $readiness.StatusCode -ge 400) { throw '知识库 readiness 检查失败。' }
    if (-not $readiness.ready) { throw "知识库未就绪: $($readiness.reason)" }
}

$conversation = Invoke-Api 'Post' '/api/ai/conversations' @{ title = 'T09 灰度演练' }
$conversationId = $conversation.conversation.id

$first = Assert-TerminalRun (New-Run $conversationId '补考成绩怎么算')
$routeEvent = $first.Events | Where-Object { $_.Type -eq 'run.created' } | Select-Object -First 1
$completedEvent = $first.Events | Where-Object { $_.Type -eq 'run.completed' } | Select-Object -First 1
if ($null -eq $routeEvent -or $null -eq $completedEvent) { throw '首个 Run 缺少路径或完成事件。' }
$actualPath = $routeEvent.Payload.payload.rag_path
if ($ExpectedRagPath -ne 'either' -and $actualPath -ne $ExpectedRagPath) {
    throw "RAG 路径不符合预期: expected=$ExpectedRagPath actual=$actualPath"
}

$followUp = Assert-TerminalRun (New-Run $conversationId '那实验课呢')
if ([string]::IsNullOrWhiteSpace($followUp.Run.answer_checkpoint)) { throw '追问没有产生回答。' }

$sourcesEvent = $first.Events | Where-Object { $_.Type -eq 'sources.ready' } | Select-Object -First 1
$source = @($sourcesEvent.Payload.payload.sources) | Select-Object -First 1
if ($null -eq $source -or [int64]$source.chunk_id -le 0) { throw '回答没有可展开来源。' }
$sourceContent = Invoke-Api 'Get' "/api/ai/sources/chunks/$($source.chunk_id)" $null
if ([string]::IsNullOrWhiteSpace($sourceContent.content)) { throw '来源展开未返回正文。' }

# 终态后从中间序号重连，验证 Last-Event-ID 回放不重复且可到达相同终态。
$replayAfter = [int64]$first.Events[0].Id
$replayed = Read-RunEvents $first.Run.id $replayAfter
if (-not ($replayed | Where-Object { $_.Type -eq 'run.completed' })) { throw 'SSE 终态回放失败。' }
if ($replayed | Where-Object { $_.Id -le $replayAfter }) { throw 'SSE 回放包含 Last-Event-ID 之前的重复事件。' }

$slowResponse = New-Run $conversationId '如何申请休学'
$slowEvents = Read-RunEvents $slowResponse.run.id 0 $SlowClientDelayMilliseconds
$slowRun = Get-Run $slowResponse.run.id
if ($slowRun.state -notin @('completed', 'failed')) { throw "慢客户端 Run 未进入终态: $($slowRun.state)" }
if ($slowEvents.Count -eq 0) { throw '慢客户端未收到任何事件。' }

$duplicateId = [guid]::NewGuid().ToString()
$original = New-Run $conversationId '课程重修有什么要求' $duplicateId
$duplicate = New-Run $conversationId '课程重修有什么要求' $duplicateId
if (-not $duplicate.duplicate -or $duplicate.run.id -ne $original.run.id) { throw '重复请求未命中幂等 Run。' }
[void](Assert-TerminalRun $original @('completed', 'failed'))

$refusal = Assert-TerminalRun (New-Run $conversationId '火星停车证按哪条校规办理') @('failed')
if ($refusal.Run.state -ne 'failed') { throw '无关问题没有可靠拒答。' }

$cancelResponse = New-Run $conversationId '请详细解释转专业政策'
$cancel = Invoke-Api 'Post' "/api/ai/runs/$($cancelResponse.run.id)/cancel" $null
if ($cancel.StatusCode -and $cancel.StatusCode -ge 400) { throw '取消请求失败。' }
$cancelDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Milliseconds 100
    $cancelledRun = Get-Run $cancelResponse.run.id
} while ($cancelledRun.state -notin @('cancelled', 'completed', 'failed') -and [DateTime]::UtcNow -lt $cancelDeadline)
if ($cancelledRun.state -ne 'cancelled') {
    throw "取消演练未进入 cancelled: $($cancelledRun.state)。若 Provider 在取消请求前已完成，请在带可控延迟 Provider 的隔离环境重跑，不能把该场景标为通过。"
}

if ($RevokedChunkId -gt 0) {
    $revoked = Invoke-Api 'Get' "/api/ai/sources/chunks/$RevokedChunkId" $null
    if ($revoked.StatusCode -ne 404 -or $revoked.Body.code -ne 'source_not_found') {
        throw '已撤销来源仍可展开。'
    }
}

$capabilitiesAfter = Invoke-Api 'Get' '/api/ai/capabilities' $null
if ([int]$capabilitiesAfter.quota.remaining -gt [int]$capabilitiesBefore.quota.remaining) {
    throw '演练后剩余额度异常增加。'
}

if ($RunQuotaExhaustion) {
    $remaining = [int]$capabilitiesAfter.quota.remaining
    for ($index = 0; $index -lt $remaining; $index++) {
        [void](Assert-TerminalRun (New-Run $conversationId '如何申请休学') @('completed', 'failed'))
    }
    $exhausted = Invoke-Api 'Post' '/api/ai/runs' @{
        conversation_id = $conversationId
        client_request_id = [guid]::NewGuid().ToString()
        message = '如何申请休学'
    }
    if ($exhausted.StatusCode -ne 429 -or $exhausted.Body.code -ne 'ai_quota_exceeded') {
        throw '额度耗尽未返回 ai_quota_exceeded。'
    }
}

[pscustomobject]@{
    schema_version = 't09-e2e-result/v1'
    passed = $true
    rag_path = $actualPath
    question = 'pass'
    follow_up = 'pass'
    refusal = 'pass'
    source_expansion = 'pass'
    sse_replay = 'pass'
    slow_client = 'pass'
    cancellation = 'pass'
    idempotency = 'pass'
    quota_boundary = 'pass'
    revoked_source = if ($RevokedChunkId -gt 0) { 'pass' } else { 'not_run' }
    quota_exhaustion = if ($RunQuotaExhaustion) { 'pass' } else { 'not_run' }
} | ConvertTo-Json -Depth 4
