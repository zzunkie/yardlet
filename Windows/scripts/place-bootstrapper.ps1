# Puts the Windows App SDK's x64 bootstrapper beside the executable, as the Windows App SDK's build
# targets do for a C# or C++ application: the DLL that scripts/generate-bindings.ps1 took from
# Microsoft's package with the import library the executable links. Beside it, in WindowsAppRuntime, go the
# x64 packages of the Windows App Runtime from the same release with their identities (MSIX.identities, which
# generate-bindings.ps1 read from their manifests), which the app puts in place for a Windows user who lacks any (docs/PLATFORM_PORTABILITY.md, "Installing and updating the
# Windows app").
param([Parameter(Mandatory)] [string] $Binaries)
$ErrorActionPreference = 'Stop'

$generated = Join-Path (Split-Path $PSScriptRoot -Parent) 'Bindings\Generated\CWindowsAppSDK'
$dll = Join-Path $generated 'bin\Microsoft.WindowsAppRuntime.Bootstrap.dll'
Copy-Item $dll $Binaries
$signature = Get-AuthenticodeSignature (Join-Path $Binaries (Split-Path $dll -Leaf))
Write-Output "$dll, signed by $($signature.SignerCertificate.Subject) ($($signature.Status))"

$runtime = (New-Item -ItemType Directory -Force (Join-Path $Binaries 'WindowsAppRuntime')).FullName
Copy-Item (Join-Path $generated 'runtime\*') $runtime
if (-not (Test-Path (Join-Path $runtime 'MSIX.identities'))) { throw "No MSIX.identities among the runtime's packages" }
Get-ChildItem $runtime | ForEach-Object { "WindowsAppRuntime\$($_.Name), $([math]::Round($_.Length / 1MB, 1)) MB" }
