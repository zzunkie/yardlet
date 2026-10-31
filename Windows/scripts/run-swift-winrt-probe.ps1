# Builds Windows/Probes/SwiftWinRT on the generated bindings, runs it and writes what it found to
# -Output. The bindings must have been generated and the Windows App Runtime installed.
param([Parameter(Mandatory)] [string] $Output)
$ErrorActionPreference = 'Stop'

$package = Join-Path (Split-Path $PSScriptRoot -Parent) 'Probes\SwiftWinRT'
swift build --package-path $package
if ($LASTEXITCODE -ne 0) { throw "The probe did not build" }
$bin = swift build --package-path $package --show-bin-path
& (Join-Path $PSScriptRoot 'place-bootstrapper.ps1') -Binaries $bin

$env:SWIFT_WINRT_PROBE_OUTPUT = $Output
$process = Start-Process -FilePath (Join-Path $bin 'SwiftWinRTProbe.exe') -WorkingDirectory $bin -PassThru -NoNewWindow
if (-not $process.WaitForExit(300000)) {
    $process.Kill()
    throw 'The probe did not finish within five minutes'
}
if (-not (Test-Path $Output)) { throw "The probe ended with $($process.ExitCode) and wrote nothing" }
Get-Content $Output
