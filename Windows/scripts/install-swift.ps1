# Installs Swift from swift.org's own installer once its signature is checked, as windows-engine.yml
# does (the repository allows only GitHub's and its own actions), and hands its paths to later steps.
param([Parameter(Mandatory)] [string] $Version)
$ErrorActionPreference = 'Stop'

$installer = Join-Path $env:RUNNER_TEMP 'swift.exe'
Invoke-WebRequest -Uri "https://download.swift.org/swift-$Version-release/windows10/swift-$Version-RELEASE/swift-$Version-RELEASE-windows10.exe" -OutFile $installer
$signature = Get-AuthenticodeSignature $installer
Write-Output "Signed by: $($signature.SignerCertificate.Subject)"
if ($signature.Status -ne 'Valid') { throw "The installer's signature is $($signature.Status)" }
$process = Start-Process -Wait -PassThru -FilePath $installer -ArgumentList '/quiet', '/norestart', '/log', (Join-Path $env:RUNNER_TEMP 'swift-install.log')
if ($process.ExitCode -ne 0) { throw "The installer ended with $($process.ExitCode)" }
foreach ($scope in 'Machine', 'User') {
    $path = [Environment]::GetEnvironmentVariable('Path', $scope)
    if ($path) { $path -split ';' | Where-Object { $_ -match 'Swift' } | Add-Content $env:GITHUB_PATH }
    $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', $scope)
    if ($sdk) { "SDKROOT=$sdk" | Add-Content $env:GITHUB_ENV }
}
