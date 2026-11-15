# Installs the Codex CLI with npm, as a person installs it, and opens the Windows app with
# YARDLET_QA_HARNESS_CHECK=codex. The app finds it as a new task would and starts its App Server in the environment a
# task gives it, Codex's home (CODEX_HOME) among it, for `initialize` and one page of `thread/list`, which need no
# sign-in (WinUI/QAHarnessCheck.swift). Codex ends at once when CODEX_HOME names no folder Windows can open, so the
# check fails unless the app names the home as Windows writes it; the runner's profile has no .codex folder, as on a
# PC where Codex never ran, so it also shows the app makes one. The check passes when the app found npm's shim, named
# the home in the profile folder as Windows writes it, and the App Server answered. Codex is removed again so that
# later checks find only the stand-in harness. Writes the log and a summary to -OutDirectory.
# Runs in PowerShell 7; the file stays ASCII, as the other scripts here.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $OutDirectory,
    # The version the first check on a real PC ran.
    [string] $Version = '0.169.0'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'codex'
$summary = [ordered]@{ name = $Name; version = $Version }
$eventLog = Join-Path $OutDirectory "$Name-events.log"
$prefix = Join-Path $env:APPDATA 'npm'
$app = $null

function Read-Events {
    if (Test-Path $eventLog) { @(Get-Content $eventLog -Encoding UTF8) } else { @() }
}

function Wait-For([scriptblock] $condition, [int] $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $value = try { & $condition } catch { $null }
        if ($value) { return $value }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Finish([string] $result) {
    $summary.result = $result
    $summary.events = (Read-Events) -join ' | '
    if ($app -and -not $app.HasExited) { $app.Kill() }
    & npm.cmd uninstall --global --prefix $prefix '@openai/codex' | Out-Null
    $json = $summary | ConvertTo-Json -Depth 4
    $json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding utf8
    $json
    $text = $json -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Output "::notice title=Codex check::$text"
    if ($result -ne 'passed') { exit 1 }
    exit 0
}

$codexHome = Join-Path $env:USERPROFILE '.codex'
$summary.homeBefore = Test-Path $codexHome
& npm.cmd install --global --prefix $prefix "@openai/codex@$Version"
if ($LASTEXITCODE -ne 0) { Finish 'npm install failed' }
$shim = Join-Path $prefix 'codex.cmd'
if (-not (Test-Path $shim)) { Finish 'npm wrote no shim' }
$summary.shim = $shim

$env:YARDLET_QA_EVENT_LOG = $eventLog
$env:YARDLET_QA_HARNESS_CHECK = 'codex'
$app = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError (Join-Path $OutDirectory "$Name-stderr.txt") -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$verdict = Wait-For { Read-Events | Where-Object { $_ -like 'harness check*' -or $_ -like 'harness not found*' } | Select-Object -First 1 } 150
$summary.found = "$(Read-Events | Where-Object { $_ -like 'harness found: *' } | Select-Object -First 1)"
$summary.home = "$(Read-Events | Where-Object { $_ -like 'harness home: *' } | Select-Object -First 1)"
$summary.verdict = "$verdict"
$summary.homeAfter = Test-Path $codexHome -PathType Container
if (-not $verdict) { Finish 'no verdict' }
if ($summary.found -ne "harness found: codex $shim") { Finish 'the app found another runtime' }
if ($summary.home -ne "harness home: $codexHome") { Finish 'the app named another home' }
if ("$verdict" -ne 'harness check: passed') { Finish 'the check failed' }
if (-not $summary.homeAfter) { Finish 'no Codex home' }
Finish 'passed'
