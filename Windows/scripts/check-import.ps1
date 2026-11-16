# Imports a conversation that the stand-in harness check-harness.ps1 installed (fake-harness/, an ACP harness the app
# knows as Kimi Code) saved before the app saw it: Import conversation from New task's link, the harness in its dialog,
# a folder chosen in Windows' own folder dialog through the project menu's Choose project..., the conversation the
# stand-in lists for that folder, and its turns drawn in
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
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class ImportDesktop {
    public delegate bool WindowVisitor(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(WindowVisitor visit, IntPtr data);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
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

    // A process's visible top-level windows, each with its class, its title and its handle.
    public static List<KeyValuePair<IntPtr, string>> Windows(int process) {
        List<KeyValuePair<IntPtr, string>> found = new List<KeyValuePair<IntPtr, string>>();
        EnumWindows((window, data) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == (uint)process && IsWindowVisible(window)) {
                StringBuilder name = new StringBuilder(256);
                GetClassName(window, name, name.Capacity);
                StringBuilder title = new StringBuilder(512);
                GetWindowText(window, title, title.Capacity);
                found.Add(new KeyValuePair<IntPtr, string>(window, name.ToString() + ": " + title.ToString()));
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [StructLayout(LayoutKind.Sequential)] public struct Box { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct ThreadFocus {
        public int Size; public int Flags; public IntPtr Active; public IntPtr Focus; public IntPtr Capture;
        public IntPtr MenuOwner; public IntPtr MoveSize; public IntPtr Caret; public Box CaretBox;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref ThreadFocus info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, string lParam);

    // Writes `text` into the control with the keyboard focus on `window`'s thread (WM_SETTEXT); that control's class,
    // or "" when no control has the focus.
    public static string SetFocusedText(IntPtr window, string text) {
        uint process;
        uint thread = GetWindowThreadProcessId(window, out process);
        ThreadFocus info = new ThreadFocus();
        info.Size = Marshal.SizeOf(typeof(ThreadFocus));
        if (!GetGUIThreadInfo(thread, ref info) || info.Focus == IntPtr.Zero) return "";
        SendMessage(info.Focus, 0x000C, IntPtr.Zero, text);
        StringBuilder name = new StringBuilder(256);
        GetClassName(info.Focus, name, name.Capacity);
        return name.ToString();
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

# The dialog and the menus over the window are in windows of their own, looked for among the app's windows.
function Find-InApp([string] $text, $type) {
    foreach ($window in $UIA::RootElement.FindAll($Scope::Children, (Property $UIA::ProcessIdProperty $process.Id))) {
        $found = Find-Named $window $text $type
        if ($found) { return $found }
    }
    return $null
}

function Find-InAppById([string] $id) {
    foreach ($window in $UIA::RootElement.FindAll($Scope::Children, (Property $UIA::ProcessIdProperty $process.Id))) {
        $found = $window.FindFirst($Scope::Descendants, (Property $UIA::AutomationIdProperty $id))
        if ($found) { return $found }
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

# A menu's radio and check items answer Toggle, which chooses them as a click does; the rest answer Invoke.
function Invoke-Element($element) {
    if ($element.GetSupportedPatterns() -contains [System.Windows.Automation.TogglePattern]::Pattern) {
        $element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    } else {
        $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
}

# Windows' folder dialog, a window of the app's own other than the main window: the common item dialog's frame, or
# the window with the dialog's title. It is looked for among the app's windows rather than through UI Automation's
# desktop, which would ask the main window too.
function Find-Dialog {
    foreach ($window in [ImportDesktop]::Windows($process.Id)) {
        if ($window.Key -eq $process.MainWindowHandle) { continue }
        if ($window.Value -like '#32770: *' -or $window.Value -like '*: Choose project') { return $window.Key }
    }
    return $null
}

function App-Windows {
    @([ImportDesktop]::Windows($process.Id) | ForEach-Object { $_.Value }) -join ' | '
}

function Finish([string] $result) {
    $summary.result = $result
    if ($process -and -not $process.HasExited) { $summary.windows = App-Windows }
    $summary.events = (Read-Events) -join ' | '
    if ($lists -and (Test-Path $lists)) { $summary.listedFolders = @(Get-Content $lists) -join ' | ' }
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
$lists = $null
$standardError = Join-Path $OutDirectory "$Name-stderr.txt"
$eventLog = Join-Path $OutDirectory "$Name-events.log"
# Whatever stops the check still leaves its summary, screenshot and log.
trap {
    $summary.error = "$_"
    Finish 'stopped by an error'
}
# The folder the conversation is in, and what the stand-in is asked to list.
$folder = Join-Path $OutDirectory 'import-folder'
New-Item -ItemType Directory -Force $folder | Out-Null
$folder = (Resolve-Path $folder).Path
$summary.folder = $folder
$lists = Join-Path $env:APPDATA 'npm\node_modules\yardlet-fake-harness\lists.log'
Remove-Item $lists -ErrorAction SilentlyContinue
$env:YARDLET_QA_EVENT_LOG = $eventLog
$process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError $standardError -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$shown = Wait-For { $process.Refresh(); $process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero } 90
if ($process.HasExited -or -not $shown) { Finish 'no window' }
if (-not (Wait-For { (Read-Events) -contains 'ready' } 30)) { Finish 'not ready' }
$main = $UIA::FromHandle($process.MainWindowHandle)
[void][ImportDesktop]::BringForward($process.MainWindowHandle)

# Import conversation, New task's link, which opens its dialog over the window; invoked again until the window's event
# log says it opened, as a choice made through UI Automation just after launch now and then does not take. The window
# reopens the task an earlier check chose, so Home comes first.
$homeItem = Wait-For { Find-Named $main 'Home' $Types::ListItem } 15
if (-not $homeItem) { Finish 'no Home item' }
$homeItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
$chooseName = 'Choose project' + [char]0x2026
$summary.importTries = 0
$opened = $false
$deadline = (Get-Date).AddSeconds(30)
while (-not $opened -and (Get-Date) -lt $deadline) {
    $summary.importTries += 1
    $link = Wait-For { Find-Named $main 'Import conversation' $Types::Button } 10
    if (-not $link) { Finish 'no Import conversation link' }
    Invoke-Element $link
    $opened = [bool](Wait-For { (Read-Events) -contains 'import opened' } 4)
}
if (-not $opened) { Finish 'the import dialog did not open' }

# The stand-in among the harnesses, side by side at the dialog's top.
$listed = Wait-For { Read-Events | Where-Object { $_ -like "import harnesses: *$Harness*" } | Select-Object -Last 1 } 60
$summary.harnesses = "$(Read-Events | Where-Object { $_ -like 'import harnesses: *' } | Select-Object -Last 1)"
if (-not $listed) { Finish "$Harness is not listed" }
$picked = Wait-For { $found = Find-InApp $Harness $Types::Button; if ($found) { Invoke-Element $found }
    (Read-Events) -contains "import harness: $Harness" } 15
if (-not $picked) { Finish "$Harness cannot be chosen" }
# Choose project... is the last item of the project's menu.
$choose = Wait-For { $picker = Find-InAppById 'ImportProject'; if ($picker) { Invoke-Element $picker }
    Wait-For { Find-InApp $chooseName $Types::MenuItem } 3 } 15
if (-not $choose) { Finish 'no Choose project in the project menu' }
Save-Screen 'pane'

# Choose project... opens Windows' folder dialog, which runs modally on the window's thread until it closes. The pane
# opens it after the click returns, so invoking the button through UI Automation returns at once (a click that opened
# it within the call left UI Automation waiting, seen on the runner). If no dialog comes, the button is pressed with
# the keyboard, as a person presses it.
$dialogHandle = $null
Invoke-Element $choose
$dialogHandle = Wait-For { Find-Dialog } 15
if (-not $dialogHandle) {
    $summary.dialogWithKeyboard = $true
    [void][ImportDesktop]::BringForward($process.MainWindowHandle)
    $choose.SetFocus()
    [ImportDesktop]::Press(0x20)
    $dialogHandle = Wait-For { Find-Dialog } 15
}
$summary.windowsWithDialog = App-Windows
Save-Screen 'dialog-opened'
if (-not $dialogHandle) { Finish 'no folder dialog' }
$dialog = $UIA::FromHandle($dialogHandle)
$summary.dialog = "$($dialog.Current.ClassName): $($dialog.Current.Name)"
# The folder field has the dialog's keyboard focus as the dialog opens. The path goes into it through UI Automation's
# focused element, or else with Win32's WM_SETTEXT to the window with the focus: on the runner a search of the dialog's
# elements found neither its control ID nor its name.
[void][ImportDesktop]::BringForward($dialogHandle)
$field = Wait-For { $focused = $UIA::FocusedElement
    if ($focused -and $focused.Current.ProcessId -eq $process.Id -and $focused.Current.ControlType -eq $Types::Edit) { $focused } } 10
if ($field) {
    $summary.field = "$($field.Current.Name) ($($field.Current.AutomationId), $($field.Current.ClassName))"
    try { $field.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($folder) }
    catch { $summary.fieldError = "$_"; $field = $null }
}
if (-not $field) { $summary.fieldThroughWin32 = [ImportDesktop]::SetFocusedText($dialogHandle, $folder) }
Save-Screen 'dialog'
# Select Folder (IDOK), else Enter in the field, which is the dialog's default button; the dialog may first go into
# the folder typed, and then chooses the folder it is in.
for ($try = 0; $try -lt 3 -and (Find-Dialog); $try += 1) {
    $select = if ($try -eq 0) { Wait-For {
        $found = $dialog.FindFirst($Scope::Children, (All-Of @((Property $UIA::AutomationIdProperty '1'), (Property $UIA::ControlTypeProperty $Types::Button))))
        if (-not $found) { $found = Find-Named $dialog 'Select Folder' $Types::Button }
        $found } 5 }
    if ($select) {
        try { Invoke-Element $select } catch { $summary.selectError = "$_" }
    } else {
        $summary.selectedWithEnter = $true
        [void][ImportDesktop]::BringForward($dialogHandle)
        [ImportDesktop]::Press(0x0D)
    }
    [void](Wait-For { -not (Find-Dialog) } 5)
}
if (Find-Dialog) { Finish 'the folder dialog stayed open' }
$leaf = Split-Path $folder -Leaf
if (-not (Wait-For { (Read-Events) -contains "import folder: $leaf" } 10)) { Finish 'the folder was not chosen' }

# The conversation the stand-in saved there, listed for a folder written as Windows writes it.
$conversations = Wait-For { Read-Events | Where-Object { $_ -like "import conversations: *$Title*" } | Select-Object -Last 1 } 60
$summary.conversations = "$(Read-Events | Where-Object { $_ -like 'import conversations: *' -or $_ -like 'import list failed: *' } | Select-Object -Last 1)"
$summary.listedFolder = "$(if (Test-Path $lists) { Get-Content $lists | Select-Object -Last 1 })"
Save-Screen 'listed'
if (-not $conversations) { Finish 'the conversation was not listed' }
# A drive, then names between backslashes; the folder itself unless links lead elsewhere.
$summary.listedFolderIsChosen = $summary.listedFolder -eq $folder
if ($summary.listedFolder -notmatch '^[A-Za-z]:\\[^/]*$') { Finish 'the folder did not go to the harness as Windows writes it' }

# Imported, and drawn from the stand-in's replay in the main window with its row chosen.
$row = Wait-For { Find-InApp $Title $Types::Button } 10
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
$summary.paneClosed = [bool](Wait-For { (Read-Events) -contains 'import closed' } 10)
if (-not $summary.paneClosed) { Finish 'the import dialog stayed' }
$summary.rowChosen = [bool](Wait-For { $item = Find-Item $main $Title
    $item -and $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } 10)
if (-not $summary.rowChosen) { Finish "the task's row was not chosen" }
Finish 'imported'
