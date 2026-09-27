[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $ApiUrl = $env:APP_API_URL,
    [string] $JPushAppKey = $env:JPUSH_APP_KEY,
    # 正式发布必须同时提供真实 CI 运行号、提交 SHA 和结论；单独传 passed 不再被当作验证证据。
    [string] $CiStatus = $env:RELEASE_CI_STATUS,
    [string] $CiEvidenceStatus = $env:RELEASE_CI_EVIDENCE_STATUS,
    [string] $CiRunId = $env:RELEASE_CI_RUN_ID,
    [string] $CiHeadSha = $env:RELEASE_CI_HEAD_SHA,
    [string] $CiConclusion = $env:RELEASE_CI_CONCLUSION,
    [string] $CiRepository = $env:RELEASE_CI_REPOSITORY,
    [string] $CiWorkflow = $env:RELEASE_CI_WORKFLOW,
    [string] $ReleaseDecision = $env:RELEASE_DECISION,
    [string] $SecurityEvidenceStatus = $env:RELEASE_SECURITY_EVIDENCE_STATUS,
    [string] $SecurityRunId = $env:RELEASE_SECURITY_RUN_ID,
    [string] $SecurityWorkflow = $env:RELEASE_SECURITY_WORKFLOW,
    [string] $GitHubToken = $env:GITHUB_TOKEN,
    [string] $ServerContractStatus = $env:RELEASE_SERVER_CONTRACT_STATUS,
    [string] $ServerContractCommit = $env:RELEASE_SERVER_CONTRACT_COMMIT,
    [string] $DeployedServerCompatibilityStatus = $env:RELEASE_DEPLOYED_SERVER_COMPATIBILITY_STATUS,
    [string] $DeployedServerCompatibilityVersion = $env:RELEASE_DEPLOYED_SERVER_COMPATIBILITY_VERSION,
    # App 只编译客户端源码，但运行时依赖同一份 Server API 契约。
    # Server 侧有未提交改动时，manifest 里的 source_commit 就无法代表真实生产系统，
    # 因此必须显式承认，不能像 Web 那样默默放行。
    [switch] $AllowDirtyServer,
    [switch] $AllowCandidateBuild
)

$ErrorActionPreference = 'Stop'
$clientRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $clientRoot '..')).Path
# 与既有正式发布证书一致；公钥指纹可入库，私钥仍只保存在签名环境。
$expectedReleaseCertSha256 = 'A367486B8B5D5EEBF67D2849809CB9B09C5C3E4DC90D8015134AF416077EFB9E'

function Resolve-GitHubRepository {
    param([string] $Remote)
    if ([string]::IsNullOrWhiteSpace($Remote)) { throw 'Cannot resolve origin remote for CI evidence.' }
    if ($Remote -match 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    throw "Origin remote is not a GitHub repository: $Remote"
}

function Get-GitHubWorkflowEvidence {
    param(
        [string] $Repository,
        [string] $Workflow,
        [string] $RunId,
        [string] $HeadSha,
        [string] $Token,
        [System.Collections.IDictionary] $RequiredJobSpecs
    )
    if ($RunId -notmatch '^[1-9][0-9]*$') { throw "RELEASE_CI_RUN_ID must be a numeric GitHub Actions run id; got '$RunId'." }
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'SYLUlive-release-verifier'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) { $headers.Authorization = "Bearer $Token" }
    $encodedRepo = $Repository
    $runUri = "https://api.github.com/repos/$encodedRepo/actions/runs/$RunId"
    try {
        $run = Invoke-RestMethod -Uri $runUri -Method Get -Headers $headers
    } catch {
        throw "Unable to verify GitHub Actions run $RunId for ${Repository}: $($_.Exception.Message)"
    }
    if ("$($run.id)" -ne "$RunId") { throw 'GitHub returned a different workflow run id.' }
    if ("$($run.repository.full_name)".ToLowerInvariant() -ne $Repository.ToLowerInvariant()) {
        throw "Workflow run repository mismatch: $($run.repository.full_name)"
    }
    if ("$($run.head_sha)".ToLowerInvariant() -ne $HeadSha.ToLowerInvariant()) {
        throw "Workflow run head SHA does not match release source commit: $($run.head_sha)"
    }
    $expectedWorkflow = $Workflow.TrimStart('/')
    if ($expectedWorkflow -notmatch '/') { $expectedWorkflow = ".github/workflows/$expectedWorkflow" }
    if ("$($run.path)".TrimStart('/') -ne $expectedWorkflow) {
        throw "Workflow mismatch: expected $expectedWorkflow, got $($run.path)"
    }
    if ("$($run.status)" -ne 'completed') {
        Write-Warning "GitHub Actions run $RunId is still $($run.status); required job evidence is not verified."
    }

    $jobsUri = "https://api.github.com/repos/$encodedRepo/actions/runs/$RunId/jobs?filter=latest&per_page=100"
    try {
        $jobs = (Invoke-RestMethod -Uri $jobsUri -Method Get -Headers $headers).jobs
    } catch {
        throw "Unable to verify jobs for GitHub Actions run ${RunId}: $($_.Exception.Message)"
    }
    $requiredJobs = @($RequiredJobSpecs.Keys)
    $failedJobs = @()
    $jobResults = [ordered]@{}
    foreach ($requiredJob in $requiredJobs) {
        $spec = $RequiredJobSpecs[$requiredJob]
        $matches = @()
        foreach ($job in @($jobs)) {
            $name = "$($job.name)"
            $isMatch = if ($spec.match -eq 'exact') {
                @($spec.values) -contains $name
            } elseif ($spec.match -eq 'prefix') {
                @($spec.values | Where-Object { $name.StartsWith("$_", [System.StringComparison]::Ordinal) }).Count -gt 0
            } else {
                throw "Unsupported workflow job match mode '$($spec.match)' for '$requiredJob'."
            }
            if ($isMatch) { $matches += $job }
        }
        $conclusions = @($matches | ForEach-Object { "$($_.conclusion)" })
        $names = @($matches | ForEach-Object { "$($_.name)" })
        $requiredCount = [int]$spec.required_count
        $allPassed = ($matches.Count -eq $requiredCount -and
            @($matches | Where-Object { $_.status -ne 'completed' -or $_.conclusion -ne 'success' }).Count -eq 0)
        $jobResults[$requiredJob] = [ordered]@{
            required_count = $requiredCount
            matched_count = $matches.Count
            names = $names
            conclusions = $conclusions
            passed = $allPassed
        }
        if (-not $allPassed) {
            $failedJobs += $requiredJob
        }
    }
    [ordered]@{
        run_id = [int64]$run.id
        repository = $Repository
        workflow = $expectedWorkflow
        head_sha = "$($run.head_sha)".ToLowerInvariant()
        workflow_status = "$($run.status)"
        workflow_conclusion = if ($run.conclusion) { "$($run.conclusion)" } else { $null }
        required_jobs_passed = ($run.status -eq 'completed' -and $failedJobs.Count -eq 0)
        required_jobs = $requiredJobs
        failed_jobs = $failedJobs
        job_results = $jobResults
    }
}

function Get-CleanReleaseCommit {
    $commit = & git -C $repoRoot rev-parse --verify HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve release source commit.' }
    # 发布物只依赖 App 源码；其他端的未提交修改不应阻断 App 打包。
    $changes = & git -C $repoRoot status --porcelain=v1 --untracked-files=all -- client ':(exclude)client/release-artifacts'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect release working tree.' }
    if ($changes) { throw 'Release requires clean App sources. Commit client changes before building.' }
    return $commit.Trim()
}


# 记录 App 之外各端的工作区状态。App 与 Server 共用一份 API 契约，
# 因此 Server 不干净时 source_commit 就不足以证明「这个包对应哪一套后端」。
function Get-RepositoryBoundaryState {
    $areas = [ordered]@{}
    foreach ($area in @('server', 'web', 'browser-extension')) {
        $paths = & git -C $repoRoot status --porcelain=v1 --untracked-files=all -- $area
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $area working tree." }
        # git 无变更时输出为空，@($null).Count 会得到 1，必须先按行过滤再计数。
        $changed = @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $areas[$area] = [ordered]@{
            clean = ($changed.Count -eq 0)
            changed_entries = $changed.Count
        }
    }
    return $areas
}

function Assert-ServerContractPinned {
    param([System.Collections.IDictionary] $Areas)
    $server = $Areas['server']
    if ($server.clean) { return }
    if ($AllowDirtyServer) {
        Write-Warning "Server working tree has $($server.changed_entries) uncommitted entries; manifest will record server_contract_verified=false."
        return
    }
    throw "Server sources are dirty ($($server.changed_entries) entries). App depends on the Server API contract, so an uncommitted server change makes source_commit unable to identify the backend this APK was built against. Commit them, or pass -AllowDirtyServer to release anyway (manifest records server_contract_verified=false)."
}

# 源码提交先固定；产物元数据在全部校验通过后才写回工作区。
$script:sourceCommit = Get-CleanReleaseCommit
$script:sourceTree = Get-RepositoryBoundaryState
Assert-ServerContractPinned -Areas $script:sourceTree

$ciRequiredJobSpecs = [ordered]@{
    'server-format' = [ordered]@{ match = 'exact'; values = @('server-format', 'Go format check (changed files)'); required_count = 1 }
    'server' = [ordered]@{ match = 'exact'; values = @('server'); required_count = 1 }
    'postgres-integration' = [ordered]@{ match = 'exact'; values = @('postgres-integration'); required_count = 1 }
    'migration-upgrade' = [ordered]@{ match = 'exact'; values = @('migration-upgrade'); required_count = 1 }
    'edu-service' = [ordered]@{ match = 'exact'; values = @('edu-service'); required_count = 1 }
    'rag-service' = [ordered]@{ match = 'exact'; values = @('rag-service'); required_count = 1 }
    'client' = [ordered]@{ match = 'exact'; values = @('client'); required_count = 1 }
    'pgvector-integration' = [ordered]@{ match = 'exact'; values = @('pgvector-integration'); required_count = 1 }
    'client-platform-boundary' = [ordered]@{ match = 'exact'; values = @('client-platform-boundary'); required_count = 1 }
    'release-script' = [ordered]@{ match = 'exact'; values = @('release-script', 'Release script regression (Windows)'); required_count = 1 }
}
$securityRequiredJobSpecs = [ordered]@{
    'gitleaks' = [ordered]@{ match = 'exact'; values = @('gitleaks', 'Secret scan'); required_count = 1 }
    'govulncheck' = [ordered]@{ match = 'exact'; values = @('govulncheck', 'Go vulnerability scan'); required_count = 1 }
    'pip-audit' = [ordered]@{ match = 'prefix'; values = @('Python dependency audit ('); required_count = 2 }
}

$script:releaseDecision = if ([string]::IsNullOrWhiteSpace($ReleaseDecision)) {
    'partial'
} else {
    $ReleaseDecision.Trim().ToLowerInvariant()
}
if ($script:releaseDecision -notin @('passed', 'blocked', 'partial', 'rolled_back')) {
    throw "RELEASE_DECISION must be passed, blocked, partial, or rolled_back; got '$script:releaseDecision'."
}

$legacyCiStatus = if ([string]::IsNullOrWhiteSpace($CiStatus)) {
    'unverified'
} else {
    $CiStatus.Trim().ToLowerInvariant()
}
if ($legacyCiStatus -notin @('passed', 'failed', 'unverified')) {
    throw "RELEASE_CI_STATUS must be passed, failed, or unverified; got '$legacyCiStatus'."
}
$requestedCiEvidenceStatus = if ([string]::IsNullOrWhiteSpace($CiEvidenceStatus)) {
    if ($legacyCiStatus -eq 'passed') { 'verified' } else { 'unverified' }
} else {
    $CiEvidenceStatus.Trim().ToLowerInvariant()
}
if ($requestedCiEvidenceStatus -notin @('verified', 'unverified', 'invalid')) {
    throw "RELEASE_CI_EVIDENCE_STATUS must be verified, unverified, or invalid; got '$requestedCiEvidenceStatus'."
}
$script:ciEvidenceStatus = $requestedCiEvidenceStatus
$script:ciEvidence = $null
$script:ciAppChecks = $false
if ($script:ciEvidenceStatus -eq 'verified' -and [string]::IsNullOrWhiteSpace($CiRunId)) {
    throw 'RELEASE_CI_EVIDENCE_STATUS=verified requires RELEASE_CI_RUN_ID (GitHub Actions run id) so the result can be verified automatically.'
}
if (-not [string]::IsNullOrWhiteSpace($CiRunId)) {
    if ([string]::IsNullOrWhiteSpace($CiRepository)) {
        $origin = (& git -C $repoRoot config --get remote.origin.url).Trim()
        $CiRepository = Resolve-GitHubRepository -Remote $origin
    }
    if ([string]::IsNullOrWhiteSpace($CiWorkflow)) { $CiWorkflow = '.github/workflows/ci.yml' }
    $script:ciEvidence = Get-GitHubWorkflowEvidence -Repository $CiRepository -Workflow $CiWorkflow -RunId $CiRunId -HeadSha $script:sourceCommit -Token $GitHubToken -RequiredJobSpecs $ciRequiredJobSpecs
    if (-not [string]::IsNullOrWhiteSpace($CiHeadSha) -and $CiHeadSha.Trim().ToLowerInvariant() -ne $script:ciEvidence.head_sha) {
        throw 'RELEASE_CI_HEAD_SHA disagrees with the GitHub workflow run.'
    }
    if (-not [string]::IsNullOrWhiteSpace($CiConclusion) -and "$CiConclusion".Trim().ToLowerInvariant() -ne "$($script:ciEvidence.workflow_conclusion)".ToLowerInvariant()) {
        throw 'RELEASE_CI_CONCLUSION disagrees with the GitHub workflow run.'
    }
    $script:ciEvidenceStatus = 'verified'
    $script:ciAppChecks = [bool]$script:ciEvidence.required_jobs_passed
}
$script:ciWorkflowConclusion = if ($script:ciEvidence) { $script:ciEvidence.workflow_conclusion } else { $null }
$script:ciStatus = if ($script:ciAppChecks) { 'passed' } elseif ($script:ciEvidenceStatus -eq 'verified') { 'failed' } else { 'unverified' }

$requestedSecurityEvidenceStatus = if ([string]::IsNullOrWhiteSpace($SecurityEvidenceStatus)) {
    'unverified'
} else {
    $SecurityEvidenceStatus.Trim().ToLowerInvariant()
}
if ($requestedSecurityEvidenceStatus -notin @('verified', 'unverified', 'invalid')) {
    throw "RELEASE_SECURITY_EVIDENCE_STATUS must be verified, unverified, or invalid; got '$requestedSecurityEvidenceStatus'."
}
$script:securityEvidenceStatus = $requestedSecurityEvidenceStatus
$script:securityEvidence = $null
if ($script:securityEvidenceStatus -eq 'verified' -and [string]::IsNullOrWhiteSpace($SecurityRunId)) {
    throw 'RELEASE_SECURITY_EVIDENCE_STATUS=verified requires RELEASE_SECURITY_RUN_ID.'
}
if (-not [string]::IsNullOrWhiteSpace($SecurityRunId)) {
    if ([string]::IsNullOrWhiteSpace($CiRepository)) {
        $origin = (& git -C $repoRoot config --get remote.origin.url).Trim()
        $CiRepository = Resolve-GitHubRepository -Remote $origin
    }
    if ([string]::IsNullOrWhiteSpace($SecurityWorkflow)) { $SecurityWorkflow = '.github/workflows/security.yml' }
    $script:securityEvidence = Get-GitHubWorkflowEvidence -Repository $CiRepository -Workflow $SecurityWorkflow -RunId $SecurityRunId -HeadSha $script:sourceCommit -Token $GitHubToken -RequiredJobSpecs $securityRequiredJobSpecs
    $script:securityEvidenceStatus = 'verified'
}
$script:securityWorkflowConclusion = if ($script:securityEvidence) { $script:securityEvidence.workflow_conclusion } else { $null }
$script:securityRequiredJobsPassed = if ($script:securityEvidence) { [bool]$script:securityEvidence.required_jobs_passed } else { $false }
$gitleaksResult = if ($script:securityEvidence) { $script:securityEvidence.job_results['gitleaks'] } else { $null }
$script:gitleaksStatus = if (-not $gitleaksResult -or $gitleaksResult.matched_count -eq 0) {
    'unknown'
} elseif ($gitleaksResult.passed) {
    'success'
} else {
    'failure'
}
$dependencyResults = if ($script:securityEvidence) {
    @($script:securityEvidence.job_results['govulncheck'], $script:securityEvidence.job_results['pip-audit'])
} else {
    @()
}
$script:dependencyAuditStatus = if ($dependencyResults.Count -eq 2 -and
    @($dependencyResults | Where-Object { -not $_.passed }).Count -eq 0) {
    'success'
} else {
    if ($script:securityEvidence) { 'failure' } else { 'unknown' }
}

$script:serverContractVerified = $false
$script:serverContractEvidenceSupplied = $false
$script:deployedServerCompatibilityVerified = $false
if ([string]::IsNullOrWhiteSpace($ServerContractStatus)) { $ServerContractStatus = 'unverified' }
if ($ServerContractStatus -notin @('passed', 'failed', 'unverified')) {
    throw "RELEASE_SERVER_CONTRACT_STATUS must be passed, failed, or unverified; got '$ServerContractStatus'."
}
if ([string]::IsNullOrWhiteSpace($DeployedServerCompatibilityStatus)) {
    $DeployedServerCompatibilityStatus = 'unverified'
}
if ($DeployedServerCompatibilityStatus -notin @('passed', 'failed', 'unverified')) {
    throw "RELEASE_DEPLOYED_SERVER_COMPATIBILITY_STATUS must be passed, failed, or unverified; got '$DeployedServerCompatibilityStatus'."
}
if ($script:releaseDecision -eq 'passed' -and $ServerContractStatus -eq 'failed') {
    throw 'Explicit failed server contract status blocks formal release.'
}
if ($ServerContractStatus -eq 'passed') {
    if (-not $script:sourceTree['server'].clean -or [string]::IsNullOrWhiteSpace($ServerContractCommit) -or
        $ServerContractCommit.Trim().ToLowerInvariant() -ne $script:sourceCommit.Trim().ToLowerInvariant()) {
        throw 'Server contract evidence must be passed, clean, and pinned to the release source commit.'
    }
    $script:serverContractEvidenceSupplied = $true
}
$script:serverContractVerified = [bool](
    $ServerContractStatus -eq 'passed' -and
    $script:serverContractEvidenceSupplied -and
    $script:ciAppChecks -and
    $script:sourceTree['server'].clean
)
$script:deployedServerCompatibilityVerified = [bool](
    $DeployedServerCompatibilityStatus -eq 'passed' -and
    -not [string]::IsNullOrWhiteSpace($DeployedServerCompatibilityVersion)
)

if ($script:releaseDecision -eq 'passed') {
    $missingEvidence = @()
    if ($script:ciEvidenceStatus -ne 'verified' -or -not $script:ciAppChecks) { $missingEvidence += 'CI' }
    if ($script:securityEvidenceStatus -ne 'verified' -or -not $script:securityRequiredJobsPassed) { $missingEvidence += 'security required jobs' }
    if ($script:gitleaksStatus -ne 'success') { $missingEvidence += 'gitleaks' }
    if ($script:dependencyAuditStatus -ne 'success') { $missingEvidence += 'dependency audit' }
    if (-not $script:serverContractVerified) { $missingEvidence += 'server contract' }
    if (-not $script:deployedServerCompatibilityVerified) { $missingEvidence += 'deployed server compatibility' }
    if ($missingEvidence.Count -gt 0) {
        throw "RELEASE_DECISION=passed requires verified release evidence: $($missingEvidence -join ', ')."
    }
}
if ($script:releaseDecision -ne 'passed' -or $script:ciEvidenceStatus -ne 'verified' -or $script:securityEvidenceStatus -ne 'verified') {
    Write-Warning "发布证据尚未形成 passed 决定：release_decision=$script:releaseDecision, ci_evidence_status=$script:ciEvidenceStatus, security_evidence_status=$script:securityEvidenceStatus。"
}
if ($script:releaseDecision -ne 'passed' -and -not $AllowCandidateBuild) {
    throw '正式 release 构建要求 RELEASE_DECISION=passed；仅生成候选包时显式传入 -AllowCandidateBuild。'
}
$script:isCandidateBuild = $script:releaseDecision -ne 'passed'
$script:artifactName = if ($script:isCandidateBuild) { 'shenliyuan-candidate.apk' } else { 'shenliyuan-release.apk' }
$androidRoot = Join-Path $clientRoot 'android'
$androidAppRoot = Join-Path $androidRoot 'app'
$propertiesPath = Join-Path $androidRoot 'key.properties'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $clientRoot 'release-artifacts' }
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location).Path $OutputDirectory
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($ApiUrl)) { $ApiUrl = 'https://sylulive.online/api' }
if ([string]::IsNullOrWhiteSpace($JPushAppKey)) { $JPushAppKey = 'fbbd87f741e919f39519afe6' }

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter is required and must be available on PATH.'
}
if (-not (Test-Path -LiteralPath $propertiesPath)) {
    throw 'Missing android/key.properties. Copy key.properties.example and configure signing credentials.'
}

$versionLine = Select-String -Path (Join-Path $clientRoot 'pubspec.yaml') -Pattern '^version:\s*(.+)$' | Select-Object -First 1
if (-not $versionLine -or $versionLine.Matches.Groups[1].Value.Trim() -notmatch '^([0-9A-Za-z][0-9A-Za-z._-]*)\+([1-9][0-9]*)$') {
    throw 'pubspec.yaml version must use versionName+positiveVersionCode, for example 1.6.6+1606.'
}
$versionName = $Matches[1]
$versionCode = $Matches[2]
$version = "$versionName+$versionCode"

$properties = @{}
Get-Content -LiteralPath $propertiesPath | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]*)=(.*)$') { $properties[$Matches[1].Trim()] = $Matches[2].Trim() }
}
foreach ($key in @('storeFile', 'storePassword', 'keyAlias', 'keyPassword')) {
    if ([string]::IsNullOrWhiteSpace($properties[$key]) -or $properties[$key] -match 'your_.*_here') {
        throw "Signing property $key is not configured."
    }
}
$storeFile = $properties['storeFile']
if (-not [System.IO.Path]::IsPathRooted($storeFile)) { $storeFile = Join-Path $androidAppRoot $storeFile }
if (-not (Test-Path -LiteralPath $storeFile -PathType Leaf)) { throw "Signing file does not exist: $storeFile" }

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Push-Location $clientRoot
try {
    $apk = Join-Path $clientRoot 'build\app\outputs\flutter-apk\app-release.apk'
    if (Test-Path -LiteralPath $apk) { Remove-Item -LiteralPath $apk }
    flutter build apk --release --target-platform android-arm64 `
        --build-name="$versionName" `
        --build-number="$versionCode" `
        --dart-define="APP_API_URL=$ApiUrl" `
        --dart-define="JPUSH_APP_KEY=$JPushAppKey"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed; no artifact will be delivered.' }
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw 'Flutter build completed but release APK was not found.' }

    $aapt = Get-Command aapt -ErrorAction SilentlyContinue
    if (-not $aapt -and -not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $sdkBuildTools = Join-Path $env:ANDROID_HOME 'build-tools'
        $candidate = Get-ChildItem -LiteralPath $sdkBuildTools -Directory -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'aapt.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1 } |
            Select-Object -First 1
        if ($candidate) { $aapt = $candidate }
    }
    if (-not $aapt) {
        throw 'aapt is required for APK version verification. Install Android SDK build-tools or add it to PATH.'
    }
    $aaptPath = if ($aapt.PSObject.Properties['Source']) { $aapt.Source } else { $aapt.FullName }
    $badging = (& $aaptPath dump badging $apk 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'aapt failed to read APK metadata.' }
    if ($badging -notmatch "versionCode='([^']+)'" -or $Matches[1] -ne $versionCode) {
        throw "APK versionCode does not match the locked build version $versionCode."
    }
    if ($badging -notmatch "versionName='([^']+)'" -or $Matches[1] -ne $versionName) {
        throw "APK versionName does not match the locked build version $versionName."
    }

    $apksigner = Get-Command apksigner -ErrorAction SilentlyContinue
    if (-not $apksigner -and -not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $sdkBuildTools = Join-Path $env:ANDROID_HOME 'build-tools'
        $candidate = Get-ChildItem -LiteralPath $sdkBuildTools -Directory -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'apksigner*' -File -ErrorAction SilentlyContinue | Select-Object -First 1 } |
            Select-Object -First 1
        if ($candidate) { $apksigner = $candidate }
    }
    if (-not $apksigner) {
        throw 'apksigner is required for signature verification. Install Android SDK build-tools or add it to PATH.'
    }
    $apksignerPath = if ($apksigner.PSObject.Properties['Source']) { $apksigner.Source } else { $apksigner.FullName }
    & $apksignerPath verify --verbose $apk
    if ($LASTEXITCODE -ne 0) { throw 'apksigner verification failed.' }
    $certOutput = (& $apksignerPath verify --print-certs $apk 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'apksigner certificate inspection failed.' }
    $certDigests = @([regex]::Matches($certOutput, '(?im)(?:Signer #\d+|V\d+ Signer):? certificate SHA-256 digest:\s*([0-9a-f:]+)') |
        ForEach-Object { $_.Groups[1].Value.Replace(':', '').ToUpperInvariant() } | Select-Object -Unique)
    if ($certDigests.Count -ne 1) { throw 'Release APK must have exactly one signing certificate.' }
    $actualCertSha256 = $certDigests[0]
    if ($actualCertSha256 -ne $expectedReleaseCertSha256) {
        throw "Release signing certificate mismatch: $actualCertSha256"
    }

    $currentCommit = (Get-CleanReleaseCommit)
    if ("$currentCommit".Trim() -ne "$script:sourceCommit".Trim()) {
        throw "Source commit changed during build (expected '$script:sourceCommit', got '$currentCommit'); rebuild from the intended commit."
    }
    $currentSourceTree = Get-RepositoryBoundaryState
    if ($script:sourceTree['server'].clean -and -not $currentSourceTree['server'].clean) {
        throw 'Server sources became dirty during the App build; rebuild after pinning the Server API contract.'
    }
    # 清单记录产物完成时实际观察到的仓库边界，避免构建期间的目录变化仍沿用旧快照。
    $script:sourceTree = $currentSourceTree

    $target = Join-Path $OutputDirectory $script:artifactName
    Copy-Item -LiteralPath $apk -Destination $target -Force
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$target.sha256" -Value "$hash  $($script:artifactName)" -Encoding ascii
    [ordered]@{
        artifact = $script:artifactName
        candidate = $script:isCandidateBuild
        sha256 = $hash
        version = $version
        signed = $true
        signed_by_expected_release_certificate = $true
        signing_certificate_sha256 = $actualCertSha256
        source_commit = $script:sourceCommit
        # source_commit 只能代表「客户端源码」；App 运行时依赖同一仓库的 Server API 契约，
        # 因此把服务端边界和 CI 结果一并写进清单，避免用一个 commit 号冒充整套系统状态。
        server_expected_commit = if ($script:sourceTree['server'].clean) { $script:sourceCommit } else { $null }
        server_source_clean = $script:sourceTree['server'].clean
        server_contract_status = $ServerContractStatus
        server_contract_verified = $script:serverContractVerified
        server_contract_evidence_supplied = $script:serverContractEvidenceSupplied
        server_source_contract_verified = $script:serverContractVerified
        deployed_server_compatibility_status = $DeployedServerCompatibilityStatus
        deployed_server_compatibility_version = if ($script:deployedServerCompatibilityVerified) { $DeployedServerCompatibilityVersion } else { $null }
        deployed_server_compatibility_verified = $script:deployedServerCompatibilityVerified
        source_tree = $script:sourceTree
        ci_status = $script:ciStatus
        ci_evidence_status = $script:ciEvidenceStatus
        # 兼容旧清单语义：ci_verified 表示 App 必要 jobs 全部通过；
        # 证据是否真实可核验使用 ci_evidence_status 单独记录。
        ci_verified = $script:ciAppChecks
        ci_run_id = if ($script:ciEvidence) { $script:ciEvidence.run_id } else { $null }
        ci_repository = if ($script:ciEvidence) { $script:ciEvidence.repository } else { $null }
        ci_workflow = if ($script:ciEvidence) { $script:ciEvidence.workflow } else { $null }
        ci_head_sha = if ($script:ciEvidence) { $script:ciEvidence.head_sha } else { $null }
        ci_conclusion = $script:ciWorkflowConclusion
        workflow_status = if ($script:ciEvidence) { $script:ciEvidence.workflow_status } else { $null }
        workflow_conclusion = $script:ciWorkflowConclusion
        evidence_status = $script:ciEvidenceStatus
        release_decision = $script:releaseDecision
        app_release_checks = $script:ciAppChecks
        app_release_required_jobs = if ($script:ciEvidence) { $script:ciEvidence.required_jobs } else { @() }
        app_release_failed_jobs = if ($script:ciEvidence) { $script:ciEvidence.failed_jobs } else { @() }
        security_workflow_status = if ($script:securityEvidence) { $script:securityEvidence.workflow_status } else { $null }
        security_evidence_status = $script:securityEvidenceStatus
        security_workflow_run_id = if ($script:securityEvidence) { $script:securityEvidence.run_id } else { $null }
        security_workflow = if ($script:securityEvidence) { $script:securityEvidence.workflow } else { $SecurityWorkflow }
        security_workflow_head_sha = if ($script:securityEvidence) { $script:securityEvidence.head_sha } else { $null }
        security_workflow_conclusion = $script:securityWorkflowConclusion
        security_required_jobs_passed = $script:securityRequiredJobsPassed
        gitleaks_status = $script:gitleaksStatus
        dependency_audit_status = $script:dependencyAuditStatus
        security_required_jobs = if ($script:securityEvidence) { $script:securityEvidence.required_jobs } else { @($securityRequiredJobSpecs.Keys) }
        security_failed_jobs = if ($script:securityEvidence) { $script:securityEvidence.failed_jobs } else { @() }
        built_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-manifest.json') -Encoding utf8
    Write-Host "Signed release artifact: $target"
    Write-Host "SHA-256: $hash"
} finally {
    Pop-Location
}
