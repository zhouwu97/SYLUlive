[CmdletBinding()]
param(
    [string] $ApiUrl = 'https://sylulive.online/api'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$clientRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $clientRoot '..')).Path

function Assert-Matches([string] $Path, [string] $Pattern, [string] $Message) {
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch $Pattern) { throw $Message }
}

$versionLine = Select-String -Path (Join-Path $clientRoot 'pubspec.yaml') -Pattern '^version:\s*(.+)$' | Select-Object -First 1
if (-not $versionLine -or $versionLine.Matches.Groups[1].Value.Trim() -notmatch '^\d+\.\d+\.\d+-beta\.\d+\+[1-9]\d*$') {
    throw 'Beta-0 version must use x.y.z-beta.n+versionCode.'
}

[Uri] $apiUri = $null
if (-not [Uri]::TryCreate($ApiUrl, [UriKind]::Absolute, [ref] $apiUri) -or $apiUri.Scheme -ne 'https') {
    throw 'Beta-0 Android API URL must be an absolute HTTPS URL.'
}

$policyPath = Join-Path $clientRoot 'lib\config\beta_release_policy.dart'
foreach ($flag in @(
    'graduationWarningResults',
    'aiGraduationAssistant',
    'aiCompetitionFit',
    'aiTeamMatching',
    'competitionRecommendations',
    'awardArchive',
    'policyBenefits',
    'clientAcademicProbe'
)) {
    Assert-Matches $policyPath "static const bool $flag = false;" "Frozen Beta-0 feature is enabled: $flag"
}

$trackedProbeOutput = & git -C $repoRoot ls-files -- 'python-edu-service/private-probe-output/'
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect tracked probe output.' }
if ($trackedProbeOutput) { throw 'Private probe output must not be tracked.' }

& git -C $repoRoot check-ignore -q 'python-edu-service/private-probe-output/'
if ($LASTEXITCODE -ne 0) { throw 'Private probe output is not ignored.' }

# Graduation warning removed — credit requirements now replace it
Assert-Matches (Join-Path $clientRoot 'lib\widgets\edu_grade\academic_requirement_overview.dart') 'AcademicRequirementOverview' 'Credit requirement overview widget is missing.'
Assert-Matches (Join-Path $clientRoot 'lib\models\edu_credit_requirement.dart') 'EduCreditRequirementOverview' 'Credit requirement model is missing.'
Assert-Matches (Join-Path $clientRoot 'lib\widgets\edu_grade\academic_privacy_notice.dart') 'AcademicPrivacyNotice' 'Academic privacy notice is missing.'

Write-Host 'Beta-0 static release gate passed.'
