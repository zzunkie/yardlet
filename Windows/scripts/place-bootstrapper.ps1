# Puts the Windows App SDK's x64 bootstrapper beside the executable, as the Windows App SDK's build
# targets do for a C# or C++ application: the DLL that scripts/generate-bindings.ps1 took from
# Microsoft's package with the import library the executable links.
param([Parameter(Mandatory)] [string] $Binaries)
$ErrorActionPreference = 'Stop'

$dll = Join-Path (Split-Path $PSScriptRoot -Parent) 'Bindings\Generated\CWindowsAppSDK\bin\Microsoft.WindowsAppRuntime.Bootstrap.dll'
Copy-Item $dll $Binaries
$signature = Get-AuthenticodeSignature (Join-Path $Binaries (Split-Path $dll -Leaf))
Write-Output "$dll, signed by $($signature.SignerCertificate.Subject) ($($signature.Status))"
