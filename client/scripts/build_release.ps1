[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $ApiUrl = $env:APP_API_URL,
    [string] $JPushAppKey = $env:JPUSH_APP_KEY,
    # 正式发布必须同时提供真实 CI 运行号、提交 SHA 和结论；单独传 passed 不再被当作验证证据。
    [string] $CiStatus = $env:RELEASE_CI_STATUS,
    [string] $CiRunId = $env:RELEASE_CI_RUN_ID,
    [string] $CiHeadSha = $env:RELEASE_CI_HEAD_SHA,
    [string] $CiConclusion = $env:RELEASE_CI_CONCLUSION,
    [string] $ServerContractStatus = $env:RELEASE_SERVER_CONTRACT_STATUS,
    [string] $ServerContractCommit = $env:RELEASE_SERVER_CONTRACT_COMMIT,
    # App 只编译客户端源码，但运行时依赖同一份 Server API 契约。
    # Server 侧有未提交改动时，manifest 里的 source_commit 就无法代表真实生产系统，
    # 因此必须显式承认，不能像 Web 那样默默放行。
    [switch] $AllowDirtyServer
)

$ErrorActionPreference = 'Stop'
$clientRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $clientRoot '..')).Path
# 与既有正式发布证书一致；公钥指纹可入库，私钥仍只保存在签名环境。
$expectedReleaseCertSha256 = 'A367486B8B5D5EEBF67D2849809CB9B09C5C3E4DC90D8015134AF416077EFB9E'

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
$script:ciStatus = if ([string]::IsNullOrWhiteSpace($CiStatus)) { 'unverified' } else { $CiStatus.Trim().ToLowerInvariant() }
if ($script:ciStatus -notin @('passed', 'failed', 'unverified')) {
    throw "RELEASE_CI_STATUS must be passed, failed, or unverified; got '$script:ciStatus'."
}
if ([string]::IsNullOrWhiteSpace($ServerContractStatus)) { $ServerContractStatus = 'unverified' }
if ($ServerContractStatus -notin @('passed', 'failed', 'unverified')) {
    throw "RELEASE_SERVER_CONTRACT_STATUS must be passed, failed, or unverified; got '$ServerContractStatus'."
}
$script:ciVerified = $false
if ($script:ciStatus -eq 'passed') {
    if ([string]::IsNullOrWhiteSpace($CiRunId) -or [string]::IsNullOrWhiteSpace($CiHeadSha) -or [string]::IsNullOrWhiteSpace($CiConclusion)) {
        throw 'RELEASE_CI_STATUS=passed requires RELEASE_CI_RUN_ID, RELEASE_CI_HEAD_SHA and RELEASE_CI_CONCLUSION.'
    }
    if ($CiHeadSha.Trim().ToLowerInvariant() -ne $script:sourceCommit.Trim().ToLowerInvariant() -or $CiConclusion.Trim().ToLowerInvariant() -ne 'success') {
        throw 'CI evidence must reference the release source commit and have conclusion=success.'
    }
    $script:ciVerified = $true
}
$script:serverContractVerified = $false
if ($ServerContractStatus -eq 'passed') {
    if (-not $script:sourceTree['server'].clean -or [string]::IsNullOrWhiteSpace($ServerContractCommit) -or
        $ServerContractCommit.Trim().ToLowerInvariant() -ne $script:sourceCommit.Trim().ToLowerInvariant()) {
        throw 'Server contract evidence must be passed, clean, and pinned to the release source commit.'
    }
    $script:serverContractVerified = $true
}
if ($script:ciStatus -ne 'passed') {
    Write-Warning "RELEASE_CI_STATUS=$script:ciStatus —— 清单会如实记录，正式发布前请补上全绿的 CI 结果。"
}
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

    $target = Join-Path $OutputDirectory 'shenliyuan-release.apk'
    Copy-Item -LiteralPath $apk -Destination $target -Force
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$target.sha256" -Value "$hash  shenliyuan-release.apk" -Encoding ascii
    [ordered]@{
        artifact = 'shenliyuan-release.apk'
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
        source_tree = $script:sourceTree
        ci_status = $script:ciStatus
        ci_verified = $script:ciVerified
        ci_run_id = if ($script:ciVerified) { $CiRunId.Trim() } else { $null }
        ci_head_sha = if ($script:ciVerified) { $CiHeadSha.Trim().ToLowerInvariant() } else { $null }
        ci_conclusion = if ($script:ciVerified) { $CiConclusion.Trim().ToLowerInvariant() } else { $null }
        built_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-manifest.json') -Encoding utf8
    Write-Host "Signed release artifact: $target"
    Write-Host "SHA-256: $hash"
} finally {
    Pop-Location
}
