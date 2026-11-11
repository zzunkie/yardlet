# Starts a task in the Windows app with the stand-in harness check-harness.ps1 installed (fake-harness/, an
# ACP harness the app knows as Kimi Code): New task, the harness, a message and Enter; then the stand-in's
# request is allowed from its card and its answer streams in, with no console window opened for the stand-in's
# node, and its edit's line opens to the diff. The app is then opened again, and the task's conversation must show
# the same answer from its saved history. A second message's turn is then stopped with Stop while it waits on its
# request: the stand-in must get ACP's session/cancel, the turn must end, and the stand-in must still run, since
# stopping a turn ends no process. It drives the window through UI Automation
# and reads the window's own event log (YARDLET_QA_EVENT_LOG); it writes screenshots, the log and a summary
# to -OutDirectory. Runs in Windows PowerShell 5.1, which has UI Automation and System.Drawing; the file stays
# ASCII because 5.1 reads a script without a byte order mark in the system code page.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Harness = 'Kimi Code',
    [string] $Message = 'Add the install steps to the readme'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'local'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class LocalDesktop {
    public delegate bool WindowVisitor(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(WindowVisitor visit, IntPtr data);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr window, StringBuilder name, int size);

    // Visible console windows: the classic console's and Windows Terminal's, which hosts consoles where it is the
    // default terminal.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int size);

    public static int ConsoleWindows() { return ConsoleTitles().Length; }

    // The titles of the visible console windows, for the summary.
    public static string[] ConsoleTitles() {
        System.Collections.Generic.List<string> titles = new System.Collections.Generic.List<string>();
        EnumWindows((window, data) => {
            if (IsWindowVisible(window)) {
                StringBuilder name = new StringBuilder(256);
                GetClassName(window, name, name.Capacity);
                string type = name.ToString();
                if (type == "ConsoleWindowClass" || type == "CASCADIA_HOSTING_WINDOW_CLASS") {
                    StringBuilder title = new StringBuilder(512);
                    GetWindowText(window, title, title.Capacity);
                    titles.Add(type + ": " + title.ToString());
                }
            }
            return true;
        }, IntPtr.Zero);
        return titles.ToArray();
    }

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

function Find-Named($root, [string] $text, $type) {
    $conditions = @(
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $text)),
        (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $type)))
    $root.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.AndCondition($conditions)))
}

function Find-Typed($root, $type) {
    $root.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $type)))
}

# The conversation's line that opens and closes: an element with the expand and collapse pattern that is not a
# sidebar row or a menu. What else has the pattern is kept for the summary.
function Find-Expandable($root) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($UIA::IsExpandCollapsePatternAvailableProperty, $true)
    $found = @($root.FindAll($Scope::Descendants, $condition))
    $script:summary.expandable = @($found | ForEach-Object { "$($_.Current.ClassName): $($_.Current.Name)" }) -join ' | '
    $found | Where-Object { @('NavigationViewItem', 'ComboBox', 'ListViewItem') -notcontains $_.Current.ClassName } |
        Select-Object -First 1
}

function Select-Named($root, [string] $text) {
    $item = Find-Named $root $text $Types::ListItem
    if (-not $item) { return $false }
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    return $true
}

function Open-App([string] $label) {
    $script:eventLog = Join-Path $OutDirectory "$Name-$label-events.log"
    $env:YARDLET_QA_EVENT_LOG = $script:eventLog
    $script:process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
        -RedirectStandardError (Join-Path $OutDirectory "$Name-$label-stderr.txt") `
        -RedirectStandardOutput (Join-Path $OutDirectory "$Name-$label-stdout.txt")
    $shown = Wait-For { $script:process.Refresh(); $script:process.HasExited -or $script:process.MainWindowHandle -ne [IntPtr]::Zero } 90
    if ($script:process.HasExited -or -not $shown) { Finish "$label`: no window" }
    if (-not (Wait-For { (Read-Events) -contains 'ready' } 30)) { Finish "$label`: not ready" }
    [void][LocalDesktop]::BringForward($script:process.MainWindowHandle)
    return $UIA::FromHandle($script:process.MainWindowHandle)
}

function Finish([string] $result) {
    $summary.result = $result
    $summary.events = (Read-Events) -join ' | '
    Save-Screen 'end'
    if ($script:process -and -not $script:process.HasExited) { $script:process.Kill() }
    $summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
    $summary | ConvertTo-Json
    if ($result -ne 'answered, kept and stopped') { exit 1 }
    exit 0
}

$summary = [ordered]@{ name = $Name }
$process = $null
# The control: a console program started on its own opens a console window, which the count sees.
$quiet = [LocalDesktop]::ConsoleWindows()
$control = Start-Process -FilePath cmd.exe -ArgumentList '/c', 'ping -n 4 127.0.0.1 > nul' -PassThru
$summary.consoleWindowsWithControl = Wait-For { $count = [LocalDesktop]::ConsoleWindows(); if ($count -gt $quiet) { $count } } 10
$control.WaitForExit()
Start-Sleep -Seconds 2
if (-not $summary.consoleWindowsWithControl) { Finish 'the count saw no console window for the control' }
$summary.consoleWindowsBefore = [LocalDesktop]::ConsoleWindows()
$summary.consoleTitlesBefore = @([LocalDesktop]::ConsoleTitles()) -join ' | '
$main = Open-App 'first'

# New task, the stand-in, the message.
if (-not (Wait-For { Select-Named $main 'New task' } 15)) { Finish 'no New task item' }
$listed = Wait-For { Read-Events | Where-Object { $_ -like "new task harnesses: *$Harness*" } | Select-Object -Last 1 } 60
$summary.harnesses = "$(Read-Events | Where-Object { $_ -like 'new task harnesses: *' } | Select-Object -Last 1)"
if (-not $listed) { Finish "$Harness is not listed" }
if (-not (Wait-For { Select-Named $main $Harness } 10)) { Finish "$Harness cannot be chosen" }
$prompt = Wait-For { Find-Typed $main $Types::Edit } 10
if (-not $prompt) { Finish 'no message field' }
$prompt.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Message)
Save-Screen 'new-task'
[void][LocalDesktop]::BringForward($process.MainWindowHandle)
$prompt.SetFocus()
[LocalDesktop]::Press(0x0D)
if (-not (Wait-For { (Read-Events) -contains 'new task started' } 20)) {
    # The runner now and then drops an injected key; once more.
    [void][LocalDesktop]::BringForward($process.MainWindowHandle)
    $prompt.SetFocus()
    [LocalDesktop]::Press(0x0D)
}
$started = Wait-For { Read-Events | Where-Object { $_ -eq 'new task started' -or $_ -like 'new task: *' } | Select-Object -Last 1 } 30
if (-not ((Read-Events) -contains 'new task started')) { Finish 'the task did not start' }
$summary.showing = "$(Wait-For { Read-Events | Where-Object { $_ -like 'showing: *' } | Select-Object -Last 1 } 20)"

# The stand-in's request, allowed from its card, and its answer.
$allow = Wait-For { Find-Named $main 'Allow' $Types::Button } 60
if (-not $allow) { Finish 'no request card' }
Save-Screen 'request'
# The stand-in's node runs now; a console program the app starts opens no window of its own.
$summary.consoleWindowsWhileRunning = [LocalDesktop]::ConsoleWindows()
$summary.consoleTitlesWhileRunning = @([LocalDesktop]::ConsoleTitles()) -join ' | '
if ($summary.consoleWindowsWhileRunning -gt $summary.consoleWindowsBefore) { Finish 'a console window opened' }
$allow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
if (-not (Wait-For { (Read-Events) -contains 'answered: Allow' } 10)) { Finish 'not answered' }
$summary.streamed = [bool](Wait-For { Read-Events | Where-Object { $_ -like 'answer streaming: Done. I updated*' } } 30)
$answer = Wait-For { Read-Events | Where-Object { $_ -like 'answer: Done. I updated*' } | Select-Object -Last 1 } 30
$summary.answer = "$answer"
if (-not $answer) { Finish 'no answer' }
Start-Sleep -Seconds 1
Save-Screen 'answered'
# The edit's line, opened to its diff.
$change = Find-Expandable $main
if (-not $change) { Finish 'no file change line to open' }
$change.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
Start-Sleep -Seconds 1
$summary.fileChange = "$($change.Current.ClassName)"
Save-Screen 'file-change'
# Opened, it holds more than its own line: the file's name and the diff's lines.
$texts = Wait-For { $found = @($change.FindAll($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $Types::Text)))); if ($found.Count -ge 3) { $found } } 10
$summary.fileChangeTexts = @($texts | ForEach-Object { $_.Current.Name }) -join ' | '
if (-not $texts) { Finish 'the file change opened empty' }
$process.Kill()
$process.WaitForExit()

# Opened again: the task's conversation from its saved history.
$main = Open-App 'again'
$summary.showingAgain = "$(Wait-For { Read-Events | Where-Object { $_ -like 'showing: *' } | Select-Object -Last 1 } 20)"
$kept = Wait-For { Read-Events | Where-Object { $_ -like 'answer: Done. I updated*' } | Select-Object -Last 1 } 30
$summary.kept = "$kept"
Save-Screen 'again'
if (-not $kept) { Finish 'the answer was not kept' }

# Stop: a second turn, stopped while it waits on its request.
$standIn = Join-Path $env:APPDATA 'npm\node_modules\yardlet-fake-harness'
$cancels = Join-Path $standIn 'cancels.log'
Remove-Item $cancels -ErrorAction SilentlyContinue
$composer = Wait-For { Find-Typed $main $Types::Edit } 10
if (-not $composer) { Finish 'no composer' }
$composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Stop before the edit')
[void][LocalDesktop]::BringForward($process.MainWindowHandle)
$composer.SetFocus()
[LocalDesktop]::Press(0x0D)
if (-not (Wait-For { Find-Named $main 'Allow' $Types::Button } 60)) { Finish 'no request card in the second turn' }
$stop = Wait-For { Find-Named $main 'Stop' $Types::Button } 10
if (-not $stop) { Finish 'no Stop while the turn ran' }
Save-Screen 'stop'
$stop.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
$summary.cancelled = [bool](Wait-For { Test-Path $cancels } 15)
if (-not $summary.cancelled) { Finish 'the stand-in got no session/cancel' }
$summary.stopped = [bool](Wait-For { -not (Find-Named $main 'Stop' $Types::Button) } 20)
Save-Screen 'stopped'
if (-not $summary.stopped) { Finish 'the turn did not end after Stop' }
$standInID = [int](Get-Content (Join-Path $standIn 'cli.pid'))
$summary.standInRunning = [bool](Get-Process -Id $standInID -ErrorAction SilentlyContinue)
if (-not $summary.standInRunning) { Finish 'Stop ended the harness' }
Finish 'answered, kept and stopped'
