[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $ApiUrl = $env:APP_API_URL,
    [string] $JPushAppKey = $env:JPUSH_APP_KEY
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ApiUrl)) { $ApiUrl = 'https://sylulive.online/api' }

& (Join-Path $PSScriptRoot 'verify_beta_release.ps1') -ApiUrl $ApiUrl

$arguments = @{
    ApiUrl = $ApiUrl
}
if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $arguments.OutputDirectory = $OutputDirectory
}
if (-not [string]::IsNullOrWhiteSpace($JPushAppKey)) {
    $arguments.JPushAppKey = $JPushAppKey
}

& (Join-Path $PSScriptRoot 'build_release.ps1') @arguments
