# Installs, updates and removes the packed Windows app as a person would, with a feed in a folder on the runner
# (docs/PLATFORM_PORTABILITY.md, "Installing and updating the Windows app"). pack.ps1 packs the build twice, as
# -FirstVersion and -NextVersion, both reading the folder -Feed for updates. The first's Setup.exe installs it
# without a window; the installed app must answer Velopack's install hook at once, have Yardlet's icon and a Start
# menu shortcut, and find no update. The next version's files then replace the feed's: the app opened again must
# download it and, once its window is closed, hand it to Velopack's updater, which puts it in place; opened once
# more it must be that version. Removing it must take the installed folder, the shortcut and the entry in
# Settings > Apps, and leave %LOCALAPPDATA%\Yardlet, the app's own data, as it was. It writes the event logs,
# Velopack's logs, screenshots and a summary to -OutDirectory.
param(
    [Parameter(Mandatory)] [string] $Binaries,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Feed = (Join-Path $env:RUNNER_TEMP 'yardlet-feed'),
    [string] $FirstVersion = '0.0.1-ci.1',
    [string] $NextVersion = '0.0.1-ci.2'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'install'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class InstalledFile {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
    // How many icons the file carries.
    public static uint Icons(string file) { return ExtractIconEx(file, -1, null, null, 0); }
}
'@

$summary = [ordered]@{ name = $Name }
$installRoot = Join-Path $env:LOCALAPPDATA 'YardletApp'
$executable = Join-Path $installRoot 'current\NativeHarnessClient.exe'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Yardlet.lnk'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\YardletApp'
$data = Join-Path $env:LOCALAPPDATA 'Yardlet'
$script:process = $null

function Save-Screen([string] $file) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $OutDirectory "$Name-$file.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
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
    if ($script:process -and -not $script:process.HasExited) { $script:process.Kill() }
    $summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
    $summary | ConvertTo-Json
    if ($result -ne 'installed, updated and removed') { exit 1 }
    exit 0
}

# What the app's data folder holds, by name, size and time of the last write, to compare after installing and
# removing. The files are not opened: another process may hold one, as the session index was once held on the runner.
function Data-Listing {
    if (-not (Test-Path $data)) { return '(none)' }
    (Get-ChildItem $data -Recurse -File | Sort-Object FullName | ForEach-Object {
        "$($_.FullName.Substring($data.Length)) $($_.Length) $($_.LastWriteTimeUtc.Ticks)"
    }) -join "`n"
}

function Installed-Version {
    $manifest = Join-Path $installRoot 'current\sq.version'
    if (-not (Test-Path $manifest)) { return $null }
    ([xml](Get-Content $manifest -Raw)).package.metadata.version
}

# Opens the installed app with its own event log, waits for its window and for the line its updater writes once
# it has looked, and returns that line. The app stays open.
function Open-Installed([string] $label) {
    $log = Join-Path $OutDirectory "$Name-$label-events.log"
    $env:YARDLET_QA_EVENT_LOG = $log
    $script:process = Start-Process -FilePath $executable -WorkingDirectory (Split-Path $executable) -PassThru `
        -RedirectStandardError (Join-Path $OutDirectory "$Name-$label-stderr.txt") `
        -RedirectStandardOutput (Join-Path $OutDirectory "$Name-$label-stdout.txt")
    $shown = Wait-For { $script:process.Refresh(); $script:process.HasExited -or $script:process.MainWindowHandle -ne [IntPtr]::Zero } 90
    if ($script:process.HasExited -or -not $shown) {
        $summary["$label-exit"] = if ($script:process.HasExited) { $script:process.ExitCode } else { 'running' }
        Finish "$label`: no window"
    }
    $looked = Wait-For { Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'update: *' -and $_ -notlike 'update: current *' } | Select-Object -First 1 } 120
    $summary["$label"] = (Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'update: *' }) -join ' | '
    # The window, drawn: its tasks are read and shown a moment after it is ready.
    [void](Wait-For { (Get-Content $log -ErrorAction SilentlyContinue) -contains 'ready' } 30)
    Start-Sleep -Seconds 3
    Save-Screen $label
    return $looked
}

# Closes the app's window as a person would, so it quits through its own end, and waits for it to exit.
function Close-Installed([string] $label) {
    [void]$script:process.CloseMainWindow()
    if (-not (Wait-For { $script:process.HasExited } 30)) { Finish "$label`: did not quit when its window closed" }
}

# The first version, installed.
$first = Join-Path $env:RUNNER_TEMP 'yardlet-pack-first'
$next = Join-Path $env:RUNNER_TEMP 'yardlet-pack-next'
foreach ($folder in @($Feed, $first, $next)) {
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory $folder | Out-Null
}
& (Join-Path $PSScriptRoot 'pack.ps1') -Binaries $Binaries -OutDirectory $first -Version $FirstVersion -UpdateFeed $Feed
& (Join-Path $PSScriptRoot 'pack.ps1') -Binaries $Binaries -OutDirectory $next -Version $NextVersion -UpdateFeed $Feed
Copy-Item "$first\*" $Feed
$before = Data-Listing
$setup = Join-Path $Feed 'YardletApp-win-Setup.exe'
$started = Get-Date
$installer = Start-Process -FilePath $setup -ArgumentList '--silent', '--log', (Join-Path $OutDirectory "$Name-setup.log") -Wait -PassThru
$summary.setupSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
if ($installer.ExitCode -ne 0) { Finish "Setup ended with $($installer.ExitCode)" }
$summary.installHook = [bool](Select-String -Path (Join-Path $OutDirectory "$Name-setup.log") -Pattern 'Hook executed successfully' -Quiet)
if (-not $summary.installHook) { Finish 'the install hook did not end at once' }
if (-not (Test-Path $executable)) { Finish 'not installed' }
$summary.executables = @(Get-ChildItem (Join-Path $installRoot 'current') -Recurse -File -Filter '*.exe' | ForEach-Object Name) -join ', '
if ($summary.executables -ne 'NativeHarnessClient.exe') { Finish "other executables installed: $($summary.executables)" }
$summary.icons = [InstalledFile]::Icons($executable)
if ($summary.icons -lt 1) { Finish 'the executable has no icon' }
if (-not (Test-Path $shortcut)) { Finish 'no Start menu shortcut' }
$entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
$summary.appsEntry = "$($entry.DisplayName) $($entry.DisplayVersion)"
if (-not $entry) { Finish 'no entry in Settings > Apps' }
$summary.version = Installed-Version
if ($summary.version -ne $FirstVersion) { Finish "installed $($summary.version), not $FirstVersion" }
if ((Data-Listing) -ne $before) { Finish 'installing changed the data folder' }

# Nothing newer in the feed yet.
$looked = Open-Installed 'first'
if ("$looked" -ne 'update: none') { Finish "first: $looked" }
Close-Installed 'first'

# The next version in the feed: downloaded while the app runs, put in place once it quits.
Get-ChildItem $Feed | Remove-Item -Recurse -Force
Copy-Item "$next\*" $Feed
$looked = Open-Installed 'update'
if ("$looked" -ne "update: downloaded $NextVersion") { Finish "update: $looked" }
Close-Installed 'update'
$handed = Get-Content (Join-Path $OutDirectory "$Name-update-events.log") | Where-Object { $_ -like 'update: applying *' }
$summary.handed = "$handed"
if (-not $handed) { Finish 'the update was not handed to the updater' }
if (-not (Wait-For { (Installed-Version) -eq $NextVersion } 90)) { Finish "still $(Installed-Version) after quitting" }
# The updater runs the new version's hook after it swaps the folder, and then ends whatever runs from the installed
# folder; the app is opened once it has finished.
if (-not (Wait-For { -not (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($installRoot) }) } 90)) {
    Finish 'the updater did not finish'
}
$summary.updatedVersion = Installed-Version
$looked = Open-Installed 'updated'
if ("$looked" -ne 'update: none') { Finish "updated: $looked" }
if (-not (Get-Content (Join-Path $OutDirectory "$Name-updated-events.log") | Where-Object { $_ -eq "update: current $NextVersion" })) {
    Finish "updated: not $NextVersion"
}
Close-Installed 'updated'

# Removed, as Settings > Apps removes it. The app wrote to its data folder while it was open; removing it must
# change nothing there. Any Yardlet still running is recorded, since one would hold the data folder's files.
$summary.running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*NativeHarnessClient.exe' } |
    ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; '
$before = Data-Listing
$updater = Join-Path $installRoot 'Update.exe'
$remover = Start-Process -FilePath $updater -ArgumentList 'uninstall', '--silent', '--log', (Join-Path $OutDirectory "$Name-uninstall.log") -Wait -PassThru
if ($remover.ExitCode -ne 0) { Finish "uninstall ended with $($remover.ExitCode)" }
$summary.uninstallHook = [bool](Select-String -Path (Join-Path $OutDirectory "$Name-uninstall.log") -Pattern 'Hook executed successfully' -Quiet)
if (-not $summary.uninstallHook) { Finish 'the uninstall hook did not end at once' }
if (-not (Wait-For { -not (Test-Path $executable) } 30)) { Finish 'the app is still installed' }
if (Test-Path $shortcut) { Finish 'the Start menu shortcut is left' }
if (Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue) { Finish 'the entry in Settings > Apps is left' }
if ((Data-Listing) -ne $before) { Finish 'removing changed the data folder' }
$summary.left = @(Get-ChildItem $installRoot -Force -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', '
Finish 'installed, updated and removed'
