# Opens the Windows app, pairs it with a host from -Link through Connect to a Mac, opens a task in the host's
# window, sends a message and waits for the answer to stream in. It drives the window through UI Automation
# and reads the window's own event log (YARDLET_QA_EVENT_LOG); it writes screenshots, the log and a summary
# to -OutDirectory. The CI host is yardlet-remote-fixture on a local relay (docs/REMOTE_PROTOCOL.md, sections 9 and 14).
# Runs in Windows PowerShell 5.1, which has UI Automation and System.Drawing; the file stays ASCII because 5.1
# reads a script without a byte order mark in the system code page.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $Link,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Task = 'Fix the footer links',
    [string] $Message = 'Point the links at the docs'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'remote'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class RemoteDesktop {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);

    public static void Press(byte key) {
        byte scan = (byte)MapVirtualKey(key, 0);
        keybd_event(key, scan, 0, UIntPtr.Zero);
        Thread.Sleep(40);
        keybd_event(key, scan, 2, UIntPtr.Zero);
        Thread.Sleep(120);
    }

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

function Find-Named($root, [string] $text, $type) {
    $conditions = @(
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $text)),
        (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $type)))
    $root.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition($conditions)))
}

function Find-Typed($root, $type) {
    $root.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $type)))
}

# A list item whose text contains $text, as a NavigationViewItem's name is the text of its content.
function Find-Item($root, [string] $text) {
    $items = $root.FindAll($Scope::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)))
    foreach ($item in $items) {
        if ($item.Current.Name -like "*$text*") { return $item }
        $inner = $item.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $text)))
        if ($inner) { return $item }
    }
    return $null
}

function Select-Item($item) {
    try {
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    } catch {
        $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
}

function Finish([string] $result) {
    $summary.result = $result
    $summary.events = (Read-Events) -join ' | '
    if (Test-Path $standardError) { $summary.standardError = (Get-Content $standardError -Tail 20) -join "`n" }
    Save-Screen 'end'
    if ($process -and -not $process.HasExited) { $process.Kill() }
    $summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
    $summary | ConvertTo-Json
    if ($result -ne 'answered') { exit 1 }
    exit 0
}

$summary = [ordered]@{ name = $Name }
$eventLog = Join-Path $OutDirectory "$Name-events.log"
$env:YARDLET_QA_EVENT_LOG = $eventLog
$standardError = Join-Path $OutDirectory "$Name-stderr.txt"
$started = Get-Date
$process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError $standardError -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$shown = Wait-For { $process.Refresh(); $process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero } 90
if ($process.HasExited -or -not $shown) { Finish 'no window' }
if (-not (Wait-For { (Read-Events) -contains 'ready' } 30)) { Finish 'not ready' }
$main = $UIA::FromHandle($process.MainWindowHandle)
[void][RemoteDesktop]::BringForward($process.MainWindowHandle)

# Connect to a Mac, the link pasted, Connect.
# A list redrawn meanwhile leaves an item that no longer takes a pattern, so finding and choosing go together. Just
# after launch a choice made through UI Automation now and then takes the item's focus but not its selection, so the
# item is chosen again, once by invoking it, until its pane shows; the summary keeps how many tries it took and how long
# UI Automation took to answer, which would show a window that stopped answering.
$summary.connectTries = 0
$field = $null
$deadline = (Get-Date).AddSeconds(30)
while (-not $field -and (Get-Date) -lt $deadline) {
    $summary.connectTries += 1
    $chosen = Wait-For { $found = Find-Item $main 'Connect to a Mac'; if ($found) {
        if ($summary.connectTries % 2 -eq 0) {
            $found.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        } else {
            Select-Item $found
        }
        $true } } 10
    if (-not $chosen) { Finish 'no Connect to a Mac item' }
    # The pane's Connect button, which the task's pane does not have; the pane's one field is then the link's.
    if (Wait-For { Find-Named $main 'Connect' ([System.Windows.Automation.ControlType]::Button) } 4) {
        $field = Wait-For { Find-Typed $main ([System.Windows.Automation.ControlType]::Edit) } 4
    }
}
$summary.uiaAnswerSeconds = [math]::Round((Measure-Command { try { [void]$main.FindFirst($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition) } catch {} }).TotalSeconds, 2)
if (-not $field) { Finish 'no link field' }
$field.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Link)
$button = Wait-For { Find-Named $main 'Connect' ([System.Windows.Automation.ControlType]::Button) } 10
if (-not $button) { Finish 'no Connect button' }
Save-Screen 'connect'
$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
$paired = Wait-For { Read-Events | Where-Object { $_ -like 'remote paired: *' -or $_ -like 'remote pairing failed: *' } } 60
$summary.paired = "$paired"
if (-not $paired -or "$paired" -like 'remote pairing failed: *') { Finish 'not paired' }
$summary.pairedSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

# The host's window, its tasks and the connection.
$hostName = ("$paired" -replace '^remote paired: ', '')
$hostWindow = Wait-For {
    $UIA::RootElement.FindFirst($Scope::Children, (New-Object System.Windows.Automation.AndCondition(@(
        (New-Object System.Windows.Automation.PropertyCondition($UIA::ProcessIdProperty, $process.Id)),
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $hostName))))))
} 20
if (-not $hostWindow) { Finish 'no host window' }
$connected = Wait-For { Read-Events | Where-Object { $_ -like 'remote connection: Connected*' } | Select-Object -Last 1 } 60
$summary.connection = "$connected"
if (-not $connected) { Finish 'not connected' }
$tasks = Wait-For { Read-Events | Where-Object { $_ -match '^remote tasks: [1-9]' } | Select-Object -Last 1 } 30
$summary.tasks = "$tasks"
if (-not $tasks) { Finish 'no tasks' }
[void][RemoteDesktop]::BringForward([IntPtr]$hostWindow.Current.NativeWindowHandle)
Save-Screen 'host'

# The task, a message and its answer streaming in.
$item = Wait-For { $found = Find-Item $hostWindow $Task; if ($found) { Select-Item $found; $true } } 20
if (-not $item) { Finish "no task named $Task" }
if (-not (Wait-For { (Read-Events) -contains "remote showing: $Task" } 20)) { Finish 'task not shown' }
Start-Sleep -Seconds 2
Save-Screen 'task'
$composer = Wait-For { Find-Typed $hostWindow ([System.Windows.Automation.ControlType]::Edit) } 10
if (-not $composer) { Finish 'no composer' }
$composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Message)
[void][RemoteDesktop]::BringForward([IntPtr]$hostWindow.Current.NativeWindowHandle)
$composer.SetFocus()
[RemoteDesktop]::Press(0x0D)
if (-not (Wait-For { (Read-Events) -contains "remote sent: $Message" } 10)) {
    # The runner now and then drops an injected key; once more.
    [void][RemoteDesktop]::BringForward([IntPtr]$hostWindow.Current.NativeWindowHandle)
    $composer.SetFocus()
    [RemoteDesktop]::Press(0x0D)
}
if (-not (Wait-For { (Read-Events) -contains "remote sent: $Message" } 10)) { Finish 'not sent' }
$summary.streamed = [bool](Wait-For { Read-Events | Where-Object { $_ -like 'remote answer streaming: Done.*' } } 40)
$answered = Wait-For { Read-Events | Where-Object { $_ -like 'remote answer: Done.*' } | Select-Object -Last 1 } 40
$summary.answer = "$answered"
$summary.answeredSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
if (-not $answered) { Finish 'no answer' }
Finish 'answered'
