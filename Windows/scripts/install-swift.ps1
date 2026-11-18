# Installs Swift from swift.org's own installer once its signature is checked to be valid and its
# publisher's (Apple signs the Windows toolchain), since the repository allows only GitHub's and its own
# actions, and hands its paths to later steps. Every Windows job installs Swift with it.
param([Parameter(Mandatory)] [string] $Version)
$ErrorActionPreference = 'Stop'

$installer = Join-Path $env:RUNNER_TEMP 'swift.exe'
Invoke-WebRequest -Uri "https://download.swift.org/swift-$Version-release/windows10/swift-$Version-RELEASE/swift-$Version-RELEASE-windows10.exe" -OutFile $installer
$signature = Get-AuthenticodeSignature $installer
Write-Output "Signed by: $($signature.SignerCertificate.Subject)"
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Apple Inc\.') {
    throw "The installer's signature is $($signature.Status), by $($signature.SignerCertificate.Subject)"
}
$process = Start-Process -Wait -PassThru -FilePath $installer -ArgumentList '/quiet', '/norestart', '/log', (Join-Path $env:RUNNER_TEMP 'swift-install.log')
if ($process.ExitCode -ne 0) { throw "The installer ended with $($process.ExitCode)" }
foreach ($scope in 'Machine', 'User') {
    $path = [Environment]::GetEnvironmentVariable('Path', $scope)
    if ($path) { $path -split ';' | Where-Object { $_ -match 'Swift' } | Add-Content $env:GITHUB_PATH }
    $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', $scope)
    if ($sdk) { "SDKROOT=$sdk" | Add-Content $env:GITHUB_ENV }
}

# MSVC 14.52 (Visual Studio 18.12) and later stop clang before 22 in their C++ headers (error STL1000), and
# Swift 6.4's clang is 21; swift-crypto's BoringSSL is C++. The define the headers name for this goes in the
# configuration file clang reads from its own folder, so every compile Swift's build makes passes it. Remove it
# once the Swift installed here ships clang 22 or later.
$clang = Get-Item "$env:LOCALAPPDATA\Programs\Swift\Toolchains\*\usr\bin\clang.exe" | Select-Object -First 1
if (-not $clang) { throw 'The toolchain has no clang.exe' }
'-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH' | Set-Content (Join-Path $clang.DirectoryName 'clang.cfg') -Encoding ascii
# Its version and, once clang reads it, the configuration file.
& $clang.FullName --version
