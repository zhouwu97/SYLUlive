[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $ApiUrl = $env:APP_API_URL,
    [string] $JPushAppKey = $env:JPUSH_APP_KEY
)

$ErrorActionPreference = 'Stop'
$clientRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$androidRoot = Join-Path $clientRoot 'android'
$androidAppRoot = Join-Path $androidRoot 'app'
$propertiesPath = Join-Path $androidRoot 'key.properties'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $clientRoot 'release-artifacts' }
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
    flutter build apk --release --target-platform android-arm64 `
        --build-name="$versionName" `
        --build-number="$versionCode" `
        --dart-define="APP_API_URL=$ApiUrl" `
        --dart-define="JPUSH_APP_KEY=$JPushAppKey"
    $apk = Join-Path $clientRoot 'build\app\outputs\flutter-apk\app-release.apk'
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

    $target = Join-Path $OutputDirectory 'shenliyuan-release.apk'
    Copy-Item -LiteralPath $apk -Destination $target -Force
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$target.sha256" -Value "$hash  shenliyuan-release.apk" -Encoding ascii
    [ordered]@{
        artifact = (Resolve-Path $target).Path
        sha256 = $hash
        version = $version
        signed = $true
        built_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-manifest.json') -Encoding utf8
    Write-Host "Signed release artifact: $target"
    Write-Host "SHA-256: $hash"
} finally {
    Pop-Location
}
