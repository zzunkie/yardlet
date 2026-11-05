# Serves the Windows app's tasks to another copy of it through a local relay (start-remote-host.ps1 without a
# fixture, in the same step). The app opens with the remote off, as it ships; the check turns it on in
# Settings > Remote, waits for the relay, pairs and copies the link. A phone on the engine's client connection
# (yardlet-remote-fixture --pair) then pairs from the link, lists the host's tasks, opens the task check-local.ps1
# started, sends a message and waits for the answer, while this check allows the stand-in's request in the host's
# window. The host's devices must then name the phone, and turning the remote off must close the relay room. (The
# Windows app's own Connect is check-remote.ps1's; a second copy of the app would share this one's settings and
# keys, which are the user's, and so host the same room.)
# It drives the windows through UI Automation and reads each window's event log (YARDLET_QA_EVENT_LOG); it writes
# screenshots, the logs and a summary to -OutDirectory. Runs in Windows PowerShell 5.1, which has UI Automation,
# System.Drawing and a single-threaded apartment for the clipboard; the file stays ASCII because 5.1 reads a script
# without a byte order mark in the system code page.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $Fixture,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Relay = 'ws://127.0.0.1:8787',
    [string] $RelayLog = 'serve-relay.log',
    [string] $Task = 'Add the install steps to the readme',
    [string] $Message = 'Add a section on updates'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'serve'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class ServeDesktop {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    // Windows lets a process bring a window forward only after input of its own; Alt counts.
    public static bool BringForward(IntPtr window) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(window);
        Thread.Sleep(300);
        return GetForegroundWindow() == window;
    }
}
'@

$UIA = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$Types = [System.Windows.Automation.ControlType]

function Save-Screen([string] $file) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $OutDirectory "$Name-$file.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
}

function Read-Events {
    if (Test-Path $eventLog) { @(Get-Content $eventLog -Encoding UTF8) } else { @() }
}

# UI Automation now and then times out while a window is busy; a lookup that does is tried again.
function Wait-For([scriptblock] $condition, [int] $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $value = try { & $condition } catch { $null }
        if ($value) { return $value }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Find-Named($root, [string] $text) {
    $root.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $text)))
}

# A list item whose text contains $text, as a NavigationViewItem's name is the text of its content.
function Select-Item($root, [string] $text) {
    $items = $root.FindAll($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $Types::ListItem)))
    foreach ($item in $items) {
        $inner = $item.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $text)))
        if ($item.Current.Name -like "*$text*" -or $inner) {
            $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            return $true
        }
    }
    return $false
}

function Invoke-Named($root, [string] $text) {
    $button = Find-Named $root $text
    if (-not $button) { return $false }
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $true
}

# The switch, not the title beside it that has the same name.
function Find-Toggle {
    $main.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition(@(
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, 'Allow remote connections')),
        (New-Object System.Windows.Automation.PropertyCondition($UIA::IsTogglePatternAvailableProperty, $true))))))
}

function Toggle-Remote {
    $switch = Find-Toggle
    if (-not $switch) { return $false }
    $switch.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    return $true
}

# Whether a Mac (here the app) holds the relay room: a phone's socket to it opens, or the relay refuses it with 404.
function Test-Room([string] $room) {
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        $socket.ConnectAsync([Uri]"$Relay/v1/rooms/$room/connect", [Threading.CancellationToken]::None).Wait(10000) | Out-Null
        return $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open
    } catch {
        return $false
    } finally {
        $socket.Dispose()
    }
}

function Host-Sockets {
    $log = Join-Path $OutDirectory $RelayLog
    if (Test-Path $log) { @(Get-Content $log | Where-Object { $_ -match '/host 101' }).Count } else { 0 }
}

function Finish([string] $result) {
    $summary.result = $result
    $summary.events = (Read-Events) -join ' | '
    Save-Screen 'end'
    if ($client -and -not $client.HasExited) { $client.Kill() }
    if ($process -and -not $process.HasExited) { $process.Kill() }
    $summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
    $summary | ConvertTo-Json
    if ($result -ne 'served') { exit 1 }
    exit 0
}

$summary = [ordered]@{ name = $Name }
$client = $null
$eventLog = Join-Path $OutDirectory "$Name-events.log"
$env:YARDLET_QA_EVENT_LOG = $eventLog
# The app reaches -Relay as the relay its build carries (place-relay.ps1 beside -Executable), not from the environment.
$process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError (Join-Path $OutDirectory "$Name-stderr.txt") -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$shown = Wait-For { $process.Refresh(); $process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero } 90
if ($process.HasExited -or -not $shown) { Finish 'no window' }
if (-not (Wait-For { (Read-Events) -contains 'ready' } 30)) { Finish 'not ready' }
$main = $UIA::FromHandle($process.MainWindowHandle)
[void][ServeDesktop]::BringForward($process.MainWindowHandle)

# Off as it ships: a few seconds open, and the app has opened no room on the relay.
Start-Sleep -Seconds 3
$summary.roomSocketsWhileOff = Host-Sockets
if ($summary.roomSocketsWhileOff -ne 0) { Finish 'the remote opened a room while off' }

# Settings > Remote, turned on, and the relay reached.
if (-not (Wait-For { Select-Item $main 'Settings' } 15)) { Finish 'no Settings item' }
if (-not (Wait-For { (Read-Events) -contains 'showing settings' } 10)) { Finish 'settings not shown' }
# The event is written as the pane is chosen, a frame before it draws: the pane's switch shows once it has.
if (-not (Wait-For { Find-Toggle } 10)) { Finish 'no remote switch' }
Start-Sleep -Milliseconds 500
Save-Screen 'settings-off'
if (-not (Wait-For { Toggle-Remote } 10)) { Finish 'no remote switch' }
if (-not (Wait-For { (Read-Events) -contains 'remote host: on' } 10)) { Finish 'the remote did not turn on' }
$reach = Wait-For { Read-Events | Where-Object { $_ -eq 'remote host reach: Yardlet server' } } 60
$summary.reach = "$(Read-Events | Where-Object { $_ -like 'remote host reach: *' } | Select-Object -Last 1)"
if (-not $reach) { Finish 'the relay was not reached' }

# Pairing: the QR code and the link on the clipboard.
$pair = 'Pair' + [char]0x2026
if (-not (Wait-For { Invoke-Named $main $pair } 10)) { Finish 'no Pair button' }
if (-not (Wait-For { (Read-Events) -contains 'remote host pairing shown' } 15)) { Finish 'no pairing shown' }
Start-Sleep -Seconds 1
Save-Screen 'pairing'
if (-not (Wait-For { Invoke-Named $main 'Copy link' } 10)) { Finish 'no Copy link button' }
if (-not (Wait-For { (Read-Events) -contains 'remote host link copied' } 10)) { Finish 'the link was not copied' }
$link = Wait-For { $text = [System.Windows.Forms.Clipboard]::GetText(); if ($text -like 'yardlet-remote://pair*') { $text } } 10
if (-not $link) { Finish 'no link on the clipboard' }
$room = [regex]::Match($link, '[?&]i=([a-z2-7]+)').Groups[1].Value
$summary.linkHasRelay = $link -like '*r=*'

# The task shown in the host's window, for its request card.
if (-not (Wait-For { Select-Item $main $Task } 15)) { Finish "no task named $Task" }

# The phone, on the engine's client connection (yardlet-remote-fixture --pair): it pairs from the link, lists the
# tasks, opens the task and sends the message, and waits for the answer.
$phoneLog = Join-Path $OutDirectory "$Name-phone.log"
$client = Start-Process -FilePath $Fixture -PassThru -NoNewWindow -RedirectStandardOutput $phoneLog `
    -RedirectStandardError (Join-Path $OutDirectory "$Name-phone-errors.log") `
    -ArgumentList '--pair', "`"$link`"", '--task', "`"$Task`"", '--send', "`"$Message`""
# Held now, or Windows PowerShell reports no exit code for a process it started.
$null = $client.Handle

# The stand-in asks to edit a file for the message the phone sends; the host's card allows it.
$deadline = (Get-Date).AddSeconds(240)
$summary.allowedOnHost = $false
while (-not $client.HasExited -and (Get-Date) -lt $deadline) {
    if (-not $summary.allowedOnHost) {
        $allowed = try { Invoke-Named $main 'Allow' } catch { $false }
        if ($allowed) {
            $summary.allowedOnHost = $true
            Save-Screen 'allowed'
        }
    }
    Start-Sleep -Milliseconds 500
}
if (-not $client.HasExited) { Finish 'the phone did not finish' }
$client.WaitForExit()
$summary.phone = (@(Get-Content $phoneLog -Encoding UTF8) | Where-Object { $_ -like 'Phone: *' }) -join ' | '
if ($client.ExitCode -ne 0) { Finish 'the phone was not answered' }

# The host's devices name the phone; turning the remote off closes the relay room.
$shownBefore = @(Read-Events | Where-Object { $_ -eq 'showing settings' }).Count
if (-not (Wait-For { Select-Item $main 'Settings' } 15)) { Finish 'no Settings item' }
if (-not (Wait-For { @(Read-Events | Where-Object { $_ -eq 'showing settings' }).Count -gt $shownBefore } 10)) { Finish 'settings not shown again' }
$devices = Wait-For { Read-Events | Where-Object { $_ -like 'remote host devices: *Fixture phone*' } | Select-Object -Last 1 } 15
$summary.devices = "$devices"
if (-not (Wait-For { Find-Named $main 'Fixture phone' } 10)) { Finish 'the phone is not shown' }
Start-Sleep -Milliseconds 500
Save-Screen 'devices'
if (-not $devices) { Finish 'no paired device listed' }
$summary.roomHeldWhileOn = Test-Room $room
if (-not $summary.roomHeldWhileOn) { Finish 'the room was not held while on' }
$summary.roomSocketsWhileOn = Host-Sockets
if (-not (Wait-For { Toggle-Remote } 10)) { Finish 'no remote switch' }
if (-not (Wait-For { (Read-Events) -contains 'remote host: off' } 10)) { Finish 'the remote did not turn off' }
$summary.roomClosedWhenOff = Wait-For { -not (Test-Room $room) } 15
Save-Screen 'off'
if (-not $summary.roomClosedWhenOff) { Finish 'the room stayed open once off' }
Finish 'served'
