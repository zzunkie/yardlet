# Imports a conversation that the stand-in harness check-harness.ps1 installed (fake-harness/, an ACP harness the app
# knows as Kimi Code) saved before the app saw it: Import conversation, the harness, a folder chosen in Windows' own
# folder dialog through Choose project..., the conversation the stand-in lists for that folder, and its turns drawn in
# the main window with the task's row chosen once it is imported. The stand-in lists it only for a folder written as
# Windows writes one, as an agent compares the folder it saved a session in, and replays it when it loads. It drives
# the window and the dialog through UI Automation and reads the window's own event log (YARDLET_QA_EVENT_LOG); it
# writes screenshots, the log and a summary to -OutDirectory. Runs in Windows PowerShell 5.1, which has UI Automation
# and System.Drawing; the file stays ASCII because 5.1 reads a script without a byte order mark in the system code
# page.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Harness = 'Kimi Code',
    [string] $Title = 'Summarize the open issues',
    [string] $Answer = 'Two issues are open'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'import'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class ImportDesktop {
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

function All-Of([object[]] $conditions) {
    New-Object System.Windows.Automation.AndCondition($conditions)
}

function Property($property, $value) {
    New-Object System.Windows.Automation.PropertyCondition($property, $value)
}

function Find-Named($root, [string] $text, $type) {
    $root.FindFirst($Scope::Descendants, (All-Of @((Property $UIA::NameProperty $text), (Property $UIA::ControlTypeProperty $type))))
}

# A list item whose text contains $text, as a NavigationViewItem's name is the text of its content.
function Find-Item($root, [string] $text) {
    $items = $root.FindAll($Scope::Descendants, (Property $UIA::ControlTypeProperty $Types::ListItem))
    foreach ($item in $items) {
        if ($item.Current.Name -like "*$text*") { return $item }
        $inner = $item.FindFirst($Scope::Descendants, (Property $UIA::NameProperty $text))
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

function Invoke-Element($element) {
    $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# Windows' folder dialog, a window of the app's own: the common item dialog's frame.
function Find-Dialog {
    $UIA::RootElement.FindFirst($Scope::Children,
        (All-Of @((Property $UIA::ProcessIdProperty $process.Id), (Property $UIA::ClassNameProperty '#32770'))))
}

function Finish([string] $result) {
    $summary.result = $result
    $summary.events = (Read-Events) -join ' | '
    if (Test-Path $lists) { $summary.listedFolders = @(Get-Content $lists) -join ' | ' }
    if (Test-Path $standardError) { $summary.standardError = (Get-Content $standardError -Tail 20) -join "`n" }
    Save-Screen 'end'
    if ($process -and -not $process.HasExited) { $process.Kill() }
    $summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
    $summary | ConvertTo-Json
    if ($result -ne 'imported') { exit 1 }
    exit 0
}

$summary = [ordered]@{ name = $Name }
$process = $null
# The folder the conversation is in, and what the stand-in is asked to list.
$folder = Join-Path $OutDirectory 'import-folder'
New-Item -ItemType Directory -Force $folder | Out-Null
$folder = (Resolve-Path $folder).Path
$summary.folder = $folder
$lists = Join-Path $env:APPDATA 'npm\node_modules\yardlet-fake-harness\lists.log'
Remove-Item $lists -ErrorAction SilentlyContinue
$eventLog = Join-Path $OutDirectory "$Name-events.log"
$env:YARDLET_QA_EVENT_LOG = $eventLog
$standardError = Join-Path $OutDirectory "$Name-stderr.txt"
$process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError $standardError -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$shown = Wait-For { $process.Refresh(); $process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero } 90
if ($process.HasExited -or -not $shown) { Finish 'no window' }
if (-not (Wait-For { (Read-Events) -contains 'ready' } 30)) { Finish 'not ready' }
$main = $UIA::FromHandle($process.MainWindowHandle)
[void][ImportDesktop]::BringForward($process.MainWindowHandle)

# Import conversation, chosen again until its pane shows, once by invoking it, as check-remote.ps1 chooses Connect to
# a Mac: just after launch a choice made through UI Automation now and then takes the item's focus but not its
# selection.
$chooseName = 'Choose project' + [char]0x2026
$summary.importTries = 0
$choose = $null
$deadline = (Get-Date).AddSeconds(30)
while (-not $choose -and (Get-Date) -lt $deadline) {
    $summary.importTries += 1
    $chosen = Wait-For { $found = Find-Item $main 'Import conversation'; if ($found) {
        if ($summary.importTries % 2 -eq 0) { Invoke-Element $found } else { Select-Item $found }
        $true } } 10
    if (-not $chosen) { Finish 'no Import conversation item' }
    $choose = Wait-For { Find-Named $main $chooseName $Types::Button } 4
}
if (-not $choose) { Finish 'the import pane did not show' }

# The stand-in among the harnesses.
$listed = Wait-For { Read-Events | Where-Object { $_ -like "import harnesses: *$Harness*" } | Select-Object -Last 1 } 60
$summary.harnesses = "$(Read-Events | Where-Object { $_ -like 'import harnesses: *' } | Select-Object -Last 1)"
if (-not $listed) { Finish "$Harness is not listed" }
$picked = Wait-For { $found = Find-Named $main $Harness $Types::ListItem; if ($found) { Select-Item $found }
    (Read-Events) -contains "import harness: $Harness" } 15
if (-not $picked) { Finish "$Harness cannot be chosen" }
Save-Screen 'pane'

# Choose project... opens Windows' folder dialog, which runs modally on the window's thread until it closes, so the
# button is pressed from a runspace of its own while this one fills in the dialog; if no dialog comes, the button is
# pressed with Enter.
$press = [PowerShell]::Create()
[void]$press.AddScript({ param($button)
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }).AddArgument($choose)
$pressing = $press.BeginInvoke()
$dialog = Wait-For { Find-Dialog } 15
if (-not $dialog) {
    $summary.dialogWithEnter = $true
    [void][ImportDesktop]::BringForward($process.MainWindowHandle)
    $choose.SetFocus()
    [ImportDesktop]::Press(0x0D)
    $dialog = Wait-For { Find-Dialog } 15
}
if (-not $dialog) { Finish 'no folder dialog' }
$summary.dialog = "$($dialog.Current.Name)"
# The dialog's folder field (cmb13, 1148) and its Select Folder button (IDOK), by their control IDs and else their
# English names.
$field = Wait-For {
    $found = $dialog.FindFirst($Scope::Descendants, (All-Of @((Property $UIA::AutomationIdProperty '1148'), (Property $UIA::ControlTypeProperty $Types::Edit))))
    if (-not $found) { $found = Find-Named $dialog 'Folder:' $Types::Edit }
    $found } 10
if (-not $field) { Finish 'no folder field in the dialog' }
$field.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($folder)
Save-Screen 'dialog'
# The dialog may first go into the folder typed; Select Folder then chooses the folder it is in.
for ($try = 0; $try -lt 3 -and (Find-Dialog); $try += 1) {
    $select = Wait-For {
        $found = $dialog.FindFirst($Scope::Descendants, (All-Of @((Property $UIA::AutomationIdProperty '1'), (Property $UIA::ControlTypeProperty $Types::Button))))
        if (-not $found) { $found = Find-Named $dialog 'Select Folder' $Types::Button }
        $found } 5
    if ($select) { try { Invoke-Element $select } catch { } }
    [void](Wait-For { -not (Find-Dialog) } 5)
}
if (Find-Dialog) { Finish 'the folder dialog stayed open' }
[void](Wait-For { $pressing.IsCompleted } 10)
try { [void]$press.EndInvoke($pressing) } catch { $summary.pressError = "$_" }
$press.Dispose()
$leaf = Split-Path $folder -Leaf
if (-not (Wait-For { (Read-Events) -contains "import folder: $leaf" } 10)) { Finish 'the folder was not chosen' }

# The conversation the stand-in saved there, listed for a folder written as Windows writes it.
$conversations = Wait-For { Read-Events | Where-Object { $_ -like "import conversations: *$Title*" } | Select-Object -Last 1 } 60
$summary.conversations = "$(Read-Events | Where-Object { $_ -like 'import conversations: *' -or $_ -like 'import list failed: *' } | Select-Object -Last 1)"
$summary.listedFolder = "$(if (Test-Path $lists) { Get-Content $lists | Select-Object -Last 1 })"
Save-Screen 'listed'
if (-not $conversations) { Finish 'the conversation was not listed' }
if ($summary.listedFolder -ne $folder) { Finish 'the folder did not go to the harness as Windows writes it' }

# Imported, and drawn from the stand-in's replay in the main window with its row chosen.
$row = Wait-For { Find-Named $main $Title $Types::Button } 10
if (-not $row) { Finish 'no row for the conversation' }
Invoke-Element $row
$imported = Wait-For { Read-Events | Where-Object { $_ -eq "imported: $Title" -or $_ -like 'import failed: *' } | Select-Object -Last 1 } 30
$summary.imported = "$imported"
if ("$imported" -ne "imported: $Title") { Finish 'not imported' }
$summary.showing = "$(Wait-For { Read-Events | Where-Object { $_ -eq "showing: $Title" } | Select-Object -Last 1 } 20)"
if (-not $summary.showing) { Finish 'the imported task was not shown' }
$answer = Wait-For { Read-Events | Where-Object { $_ -like "answer: $Answer*" } | Select-Object -Last 1 } 60
$summary.answer = "$answer"
Start-Sleep -Seconds 1
Save-Screen 'imported'
if (-not $answer) { Finish 'the conversation was not drawn' }
$summary.paneClosed = [bool](Wait-For { -not (Find-Named $main $chooseName $Types::Button) } 10)
if (-not $summary.paneClosed) { Finish 'the import pane stayed' }
$summary.rowChosen = [bool](Wait-For { $item = Find-Item $main $Title
    $item -and $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } 10)
if (-not $summary.rowChosen) { Finish "the task's row was not chosen" }
Finish 'imported'
