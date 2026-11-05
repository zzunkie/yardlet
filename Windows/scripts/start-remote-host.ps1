# Starts the relay (relay/, wrangler dev, installed with npm ci beforehand) and the fixture host on it
# (yardlet-remote-fixture, built beforehand), waits until the fixture prints its pairing link, and writes the link
# to pairing-link.txt in -OutDirectory, beside both programs' logs.
param(
    [Parameter(Mandatory)] [string] $Fixture,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Name = 'host'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$env:WRANGLER_SEND_METRICS = 'false'
Start-Process -FilePath npm.cmd -ArgumentList 'run', 'dev' -WorkingDirectory relay `
    -RedirectStandardOutput "$OutDirectory/$Name-relay.log" -RedirectStandardError "$OutDirectory/$Name-relay-errors.log"
$deadline = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 2
    $up = try { (Invoke-WebRequest http://127.0.0.1:8787/v1/health -UseBasicParsing).StatusCode -eq 200 } catch { $false }
} until ($up -or (Get-Date) -gt $deadline)
if (-not $up) { throw 'The relay did not start' }
Start-Process -FilePath $Fixture -ArgumentList '--relay', 'ws://127.0.0.1:8787' `
    -RedirectStandardOutput "$OutDirectory/$Name-fixture.log" -RedirectStandardError "$OutDirectory/$Name-fixture-errors.log"
$deadline = (Get-Date).AddSeconds(60)
do {
    Start-Sleep -Seconds 1
    $line = Get-Content "$OutDirectory/$Name-fixture.log" -ErrorAction SilentlyContinue | Where-Object { $_ -like 'Pairing URL*' } | Select-Object -First 1
} until ($line -or (Get-Date) -gt $deadline)
if (-not $line) { throw 'The fixture host printed no pairing link' }
$line -replace '^Pairing URL[^:]*: ', '' | Set-Content "$OutDirectory/pairing-link.txt"
