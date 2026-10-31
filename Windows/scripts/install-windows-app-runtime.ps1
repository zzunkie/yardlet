# Installs the Windows App Runtime that an unpackaged WinUI 3 window starts against, from Microsoft's
# installer once its signature is checked.
param([Parameter(Mandatory)] [string] $Url)
$ErrorActionPreference = 'Stop'

$installer = Join-Path $env:RUNNER_TEMP 'windowsappruntimeinstall-x64.exe'
Invoke-WebRequest -Uri $Url -OutFile $installer
$signature = Get-AuthenticodeSignature $installer
Write-Output "Signed by: $($signature.SignerCertificate.Subject)"
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "The installer's signature is $($signature.Status), by $($signature.SignerCertificate.Subject)"
}
$process = Start-Process -Wait -PassThru -FilePath $installer -ArgumentList '--quiet', '--force'
if ($process.ExitCode -ne 0) { throw "The installer ended with $($process.ExitCode)" }
Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime*' | ForEach-Object { Write-Output "$($_.Name) $($_.Version)" }
