# Installs a stand-in harness the way npm installs a program (fake-harness/, packed and installed globally
# into %APPDATA%\npm, where npm writes its .cmd shim beside the package under node_modules), then opens the
# Windows app with YARDLET_QA_HARNESS_CHECK. The app finds the stand-in as a new task would, starts it
# through the shim for its version and the ACP handshake, and stops it (WinUI/QAHarnessCheck.swift). Under
# acp the stand-in starts a detached process of its own. The check passes when the app found the shim,
# the handshake passed, and the stand-in and its process both ended when the app stopped it. First the
# stand-in is started and its own process alone is stopped without the app, which must leave the detached
# process running, or the check would show nothing. Writes the logs and a summary to -OutDirectory.
# Runs in PowerShell 7; the file stays ASCII, as the other scripts here.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Harness = 'kimi-code',
    [string] $Program = 'kimi'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'harness'
$summary = [ordered]@{ name = $Name }
$eventLog = Join-Path $OutDirectory "$Name-events.log"
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

function Test-Running([int] $id) {
    [bool](Get-Process -Id $id -ErrorAction SilentlyContinue)
}

function Finish([string] $result) {
    $summary.result = $result
    $summary.events = (Read-Events) -join ' | '
    if ($app -and -not $app.HasExited) { $app.Kill() }
    $json = $summary | ConvertTo-Json -Depth 4
    $json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding utf8
    $json
    $text = $json -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Output "::notice title=Harness check::$text"
    if ($result -ne 'passed') { exit 1 }
    exit 0
}

# The stand-in, installed as `npm install --global` installs a package.
$work = Join-Path ([IO.Path]::GetTempPath()) "yardlet-fake-harness-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$prefix = Join-Path $env:APPDATA 'npm'
& npm.cmd pack (Join-Path $PSScriptRoot 'fake-harness') --pack-destination $work
if ($LASTEXITCODE -ne 0) { Finish 'npm pack failed' }
$tarball = Get-ChildItem $work -Filter *.tgz | Select-Object -First 1
& npm.cmd install --global --prefix $prefix $tarball.FullName
if ($LASTEXITCODE -ne 0) { Finish 'npm install failed' }
$shim = Join-Path $prefix "$Program.cmd"
$installed = Join-Path $prefix 'node_modules\yardlet-fake-harness'
if (-not (Test-Path $shim)) { Finish 'npm wrote no shim' }
Copy-Item $shim (Join-Path $OutDirectory "$Name-shim.cmd")
$summary.shim = $shim
$summary.shimLines = @(Get-Content $shim)
$summary.npmFolderInPath = @($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -eq $prefix }).Count -gt 0
$grandchildFile = Join-Path $installed 'grandchild.pid'
$rootFile = Join-Path $installed 'cli.pid'

# Without the app: the stand-in's detached process outlives a stop of the stand-in alone.
$node = (Get-Command node.exe).Source
$empty = Join-Path $work 'empty.txt'
Set-Content $empty '' -NoNewline
$control = Start-Process -FilePath $node -ArgumentList "`"$(Join-Path $installed 'cli.js')`"", 'acp' -PassThru -NoNewWindow `
    -RedirectStandardInput $empty -RedirectStandardOutput (Join-Path $OutDirectory "$Name-control-stdout.txt")
if (-not (Wait-For { (Test-Path $grandchildFile) -and (Test-Path $rootFile) } 30)) { Finish 'the stand-in started no process' }
$controlChild = [int](Get-Content $grandchildFile)
Stop-Process -Id $control.Id -Force
Start-Sleep -Seconds 2
$summary.controlChildOutlivedItsParent = Test-Running $controlChild
if (-not $summary.controlChildOutlivedItsParent) { Finish 'the detached process ended with its parent, so the check would show nothing' }
Stop-Process -Id $controlChild -Force
Remove-Item $grandchildFile, $rootFile -ErrorAction SilentlyContinue

# The app finds the stand-in, starts it through the shim and stops it.
$env:YARDLET_QA_EVENT_LOG = $eventLog
$env:YARDLET_QA_HARNESS_CHECK = $Harness
$app = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError (Join-Path $OutDirectory "$Name-stderr.txt") -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$verdict = Wait-For { Read-Events | Where-Object { $_ -like 'harness check*' -or $_ -like 'harness not found*' } | Select-Object -First 1 } 120
$summary.found = "$(Read-Events | Where-Object { $_ -like 'harness found: *' } | Select-Object -First 1)"
$summary.verdict = "$verdict"
if (Test-Path (Join-Path $installed 'calls.log')) { $summary.calls = @(Get-Content (Join-Path $installed 'calls.log')) }
if (-not $verdict) { Finish 'no verdict' }
if ($summary.found -ne "harness found: $Harness $shim") { Finish 'the app found another runtime' }
if ("$verdict" -ne 'harness check: passed') { Finish 'the check failed' }
if (-not ((Test-Path $rootFile) -and (Test-Path $grandchildFile))) { Finish 'the stand-in did not start under acp' }
$root = [int](Get-Content $rootFile)
$grandchild = [int](Get-Content $grandchildFile)
$summary.ended = [bool](Wait-For { -not (Test-Running $root) -and -not (Test-Running $grandchild) } 10)
$summary.standInEnded = -not (Test-Running $root)
$summary.detachedProcessEnded = -not (Test-Running $grandchild)
if (-not $summary.ended) {
    foreach ($id in $root, $grandchild) { if (Test-Running $id) { Stop-Process -Id $id -Force } }
    Finish 'a process was left running'
}
Finish 'passed'
