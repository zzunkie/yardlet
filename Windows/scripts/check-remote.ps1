# Opens the Windows app, pairs it with a host from -Link through Connect to a Mac in Settings, opens a task in the host's
# window, sends a message and waits for the answer to stream in, captures the host's other tasks, answers an approval
# on the host from its card, then removes the host from Connect to a Mac. It drives the window through UI Automation
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

# A control in any of the app's top-level windows: a ContentDialog's buttons are in a popup of its own, outside the
# main window's tree.
function Find-InApp([string] $text, $type) {
    $windows = $UIA::RootElement.FindAll($Scope::Children,
        (New-Object System.Windows.Automation.PropertyCondition($UIA::ProcessIdProperty, $process.Id)))
    foreach ($window in $windows) {
        $found = Find-Named $window $text $type
        if ($found) { return $found }
    }
    return $null
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

# Settings, the link pasted under Connect to a Mac, Connect.
# A list redrawn meanwhile leaves an item that no longer takes a pattern, so finding and choosing go together. Just
# after launch a choice made through UI Automation now and then takes the item's focus but not its selection, so the
# item is chosen again, once by invoking it, until its pane shows; the summary keeps how many tries it took and how long
# UI Automation took to answer, which would show a window that stopped answering.
$summary.connectTries = 0
$field = $null
$deadline = (Get-Date).AddSeconds(30)
while (-not $field -and (Get-Date) -lt $deadline) {
    $summary.connectTries += 1
    $chosen = Wait-For { $found = Find-Item $main 'Settings'; if ($found) {
        if ($summary.connectTries % 2 -eq 0) {
            $found.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        } else {
            Select-Item $found
        }
        $true } } 10
    if (-not $chosen) { Finish 'no Settings item' }
    $field = Wait-For { Find-Named $main 'Connection link' ([System.Windows.Automation.ControlType]::Edit) } 4
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
# The window opens below and right of the main one, past the runner's small screen; it is moved to the screen's corner
# so the captures show all of it.
try {
    $hostWindow.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Move(0, 0)
} catch {
    $summary.hostWindowMoved = "$_"
}
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
# While the answer streams, Stop stands where Send was.
$summary.stopWhileStreaming = [bool](Find-Named $hostWindow 'Stop' ([System.Windows.Automation.ControlType]::Button))
Save-Screen 'streaming'
$answered = Wait-For { Read-Events | Where-Object { $_ -like 'remote answer: Done.*' } | Select-Object -Last 1 } 40
$summary.answer = "$answered"
$summary.answeredSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
if (-not $answered) { Finish 'no answer' }
Save-Screen 'answered'

# Edit message under the message just sent, as the host offers it (section 15.23): the message goes back into the
# composer with the edit's banner over it, and Cancel edit gives the composer back what it held.
$edit = Wait-For { Find-Named $hostWindow 'Edit message' ([System.Windows.Automation.ControlType]::Button) } 10
if ($edit) {
    $edit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $summary.editStarted = [bool](Wait-For { Read-Events | Where-Object { $_ -like 'remote edit message: *' } } 10)
    Start-Sleep -Seconds 1
    Save-Screen 'edit-message'
    $cancelEdit = Wait-For { Find-Named $hostWindow 'Cancel edit' ([System.Windows.Automation.ControlType]::Button) } 10
    if ($cancelEdit) { $cancelEdit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $summary.editCancelled = [bool](Wait-For { (Read-Events) -contains 'remote cancel edit' } 10)
} else {
    $summary.editStarted = 'no Edit message'
}

# The host's tasks that wait on the person or ended on an error, each drawn as its card draws it: an approval, a
# question, a failed turn, a finished conversation, a plan limit with its actions, and the release, which runs now and
# then. Only looked at here.
$cards = [ordered]@{ approval = 'Approve the index migration'; question = 'Pick the release name';
    failed = 'Regenerate the screenshots'; history = 'Summarize the crash reports'; limit = 'Write the migration guide';
    running = 'Build the release bundle' }
foreach ($card in $cards.GetEnumerator()) {
    $found = Wait-For { Find-Item $hostWindow $card.Value } 10
    if (-not $found) { $summary["card $($card.Key)"] = 'not listed'; continue }
    Select-Item $found
    $summary["card $($card.Key)"] = [bool](Wait-For { (Read-Events) -contains "remote showing: $($card.Value)" } 10)
    Start-Sleep -Seconds 2
    Save-Screen "card-$($card.Key)"
    if ($card.Key -eq 'limit') {
        $summary.limitActions = [bool](Find-Named $hostWindow 'Continue with another account' ([System.Windows.Automation.ControlType]::Button))
    }
}

# The approval answered on the host from its card, as the Mac's window answers it: the answer that saves a rule on the
# host is asked about first, and cancelled; then Allow goes, and the card reads as allowed once the host takes it.
$approval = 'Approve the index migration'
$found = Wait-For { Find-Item $hostWindow $approval } 10
if (-not $found) { Finish 'no approval task' }
Select-Item $found
[void](Wait-For { (Read-Events) -contains "remote showing: $approval" } 10)
$standing = Wait-For { Find-Named $hostWindow 'Always allow in this project (saved to .claude/settings.local.json)' ([System.Windows.Automation.ControlType]::Button) } 10
if ($standing) {
    $standing.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $summary.standingAsked = [bool](Wait-For { Read-Events | Where-Object { $_ -like 'remote asks: *' } } 10)
    Start-Sleep -Seconds 1
    Save-Screen 'card-standing-asked'
    # As for Remove's question below, UI Automation does not always reach the popup a question is in; Escape answers
    # it with Cancel then, sent only while the question is up, since Escape in the composer stops a running turn.
    $cancel = Wait-For { Find-InApp 'Cancel' ([System.Windows.Automation.ControlType]::Button) } 10
    if ($cancel) {
        $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    } elseif ($summary.standingAsked) {
        $summary.cancelledWithEscape = $true
        [void][RemoteDesktop]::BringForward([IntPtr]$hostWindow.Current.NativeWindowHandle)
        [RemoteDesktop]::Press(0x1B)
    }
    Start-Sleep -Seconds 1
}
$allow = Wait-For { Find-Named $hostWindow 'Allow' ([System.Windows.Automation.ControlType]::Button) } 10
if (-not $allow) { Finish 'no Allow on the approval card' }
$allow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
if (-not (Wait-For { (Read-Events) -contains 'remote answered: Allow' } 10)) { Finish 'not answered on the host' }
$summary.answeredOnHost = $true
$summary.standingSent = [bool]((Read-Events) | Where-Object { $_ -like 'remote answered: Always allow*' })
Start-Sleep -Seconds 3
Save-Screen 'card-approval-answered'

# Remove... on the host under Connect to a Mac in Settings: asked first, then its window closes, the host is forgotten
# and the list no longer has it. Settings is chosen again until it shows, as for pairing above.
[void][RemoteDesktop]::BringForward($process.MainWindowHandle)
$removeName = "Remove $hostName"
$remove = $null
$tries = 0
$deadline = (Get-Date).AddSeconds(30)
while (-not $remove -and (Get-Date) -lt $deadline) {
    $tries += 1
    [void](Wait-For { $found = Find-Item $main 'Settings'; if ($found) {
        if ($tries % 2 -eq 0) {
            $found.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        } else {
            Select-Item $found
        }
        $true } } 10)
    $remove = Wait-For { Find-Named $main $removeName ([System.Windows.Automation.ControlType]::Button) } 4
}
if (-not $remove) { Finish 'no Remove button' }
Save-Screen 'paired'
$remove.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
# The dialog's own Remove, beside Cancel; the row's button is named for its host. UI Automation does not always reach
# the popup the question is in (seen on the runner with the question on screen), and its Remove has the focus, so
# Enter answers it then; the app's log says whether the host was removed.
$confirm = Wait-For { Find-InApp 'Remove' ([System.Windows.Automation.ControlType]::Button) } 10
Save-Screen 'remove-asked'
if ($confirm) {
    $confirm.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
} else {
    $summary.removedWithEnter = $true
    [void][RemoteDesktop]::BringForward($process.MainWindowHandle)
    [RemoteDesktop]::Press(0x0D)
}
if (-not (Wait-For { (Read-Events) -contains "remote host removed: $hostName" } 10)) { Finish 'not removed' }
$closed = Wait-For { -not $UIA::RootElement.FindFirst($Scope::Children, (New-Object System.Windows.Automation.AndCondition(@(
    (New-Object System.Windows.Automation.PropertyCondition($UIA::ProcessIdProperty, $process.Id)),
    (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $hostName)))))) } 10
if (-not $closed) { Finish 'host window still open' }
if (-not (Wait-For { -not (Find-Named $main $removeName ([System.Windows.Automation.ControlType]::Button)) } 15)) { Finish 'host still listed' }
# The sidebar still has Settings chosen, as the pane beside it shows.
$summary.connectChosen = [bool](Wait-For { $item = Find-Item $main 'Settings'
    $item -and $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } 10)
if (-not $summary.connectChosen) { Finish 'Settings no longer chosen' }
$summary.removed = $true
Save-Screen 'removed'
Finish 'answered'
