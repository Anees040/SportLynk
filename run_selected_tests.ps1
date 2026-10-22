$ErrorActionPreference = 'Continue'

$repositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not (Test-Path (Join-Path $repositoryRoot 'backend')) -and (Test-Path (Join-Path (Split-Path -Parent $repositoryRoot) 'backend'))) {
    $repositoryRoot = Split-Path -Parent $repositoryRoot
}
$backendRoot = Join-Path $repositoryRoot 'backend'

Write-Host 'SportLynk Separate Selected Automated Test Suite'
Write-Host '================================================'
Write-Host ''

Set-Location $repositoryRoot
& flutter test test\selected_automated_suite_test.dart
$flutterExit = $LASTEXITCODE

Set-Location $backendRoot
& node --test test\selected_automated_suite.test.js
$backendExit = $LASTEXITCODE

if ($flutterExit -ne 0 -or $backendExit -ne 0) {
    exit 1
}
