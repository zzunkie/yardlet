# Puts the Yardlet relay a Windows build carries beside its executable, as scripts/build-app.sh puts the Mac's in
# Info.plist (relay/README.md): YARDLET_RELAY_URL, or else the first line of Packaging/RelayURL
# (out of git), in YardletRelayURL; and with it YARDLET_RELAY_ALTERNATE_URL, or else the first line of
# Packaging/RelayAlternateURL, in YardletRelayAlternateURL. A build without a relay carries none, and any left in
# -Destination goes. The addresses are not printed: one may name the account that deployed the relay.
param([Parameter(Mandatory)] [string] $Destination)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)

function First-Line([string] $value, [string] $file) {
    if ($value) { return $value.Trim() }
    $path = Join-Path $root $file
    if (Test-Path $path) { return ((Get-Content $path -TotalCount 1) -replace '\s', '') }
    return ''
}

$relay = First-Line $env:YARDLET_RELAY_URL 'Packaging/RelayURL'
$alternate = if ($relay) { First-Line $env:YARDLET_RELAY_ALTERNATE_URL 'Packaging/RelayAlternateURL' } else { '' }
foreach ($entry in @(@('YardletRelayURL', $relay), @('YardletRelayAlternateURL', $alternate))) {
    $file = Join-Path $Destination $entry[0]
    if ($entry[1]) {
        Set-Content -Path $file -Value $entry[1] -NoNewline -Encoding ascii
    } elseif (Test-Path $file) {
        Remove-Item $file
    }
}
if ($relay) { 'Relay: built in' + $(if ($alternate) { ', with a second address' } else { '' }) } else { 'Relay: none built in' }
