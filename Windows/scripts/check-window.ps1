# Opens a window build, measures it and types Korean through the Microsoft Korean IME into its composer.
# It writes screenshots, the window's own event log (YARDLET_QA_EVENT_LOG) and a summary to -OutDirectory.
# Runs in Windows PowerShell 5.1, which has System.Drawing and the International module; the file stays
# ASCII because 5.1 reads a script without a byte order mark in the system code page.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $OutDirectory
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
# The window runs in its own folder, so it gets absolute paths.
$OutDirectory = (Resolve-Path $OutDirectory).Path

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class Desktop {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }

    public static void Press(byte key) {
        byte scan = (byte)MapVirtualKey(key, 0);
        keybd_event(key, scan, 0, UIntPtr.Zero);
        Thread.Sleep(40);
        keybd_event(key, scan, 2, UIntPtr.Zero);
        Thread.Sleep(120);
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
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

function Wait-For([scriptblock] $condition, [int] $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$summary = [ordered]@{ name = $Name }

# The Korean keyboard, so the IME is there to switch to.
$languages = Get-WinUserLanguageList
if (-not ($languages | Where-Object { $_.LanguageTag -like 'ko*' })) {
    $languages.Add('ko-KR')
    Set-WinUserLanguageList $languages -Force
}
$summary.languages = ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag) [$($_.InputMethodTips -join ', ')]" }) -join '; '

# A crash dump for a window that ends before it shows, read with the Windows SDK's debugger.
$dumps = Join-Path $env:RUNNER_TEMP "$Name-dumps"
$dumpKey = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$(Split-Path $Executable -Leaf)"
New-Item -Force $dumpKey | Out-Null
Set-ItemProperty $dumpKey DumpFolder $dumps
Set-ItemProperty $dumpKey DumpType 2

$eventLog = Join-Path $OutDirectory "$Name-events.log"
$env:YARDLET_QA_EVENT_LOG = $eventLog
$started = Get-Date
# A Swift fatal error says why on standard error, which a windowed process still inherits.
$standardError = Join-Path $OutDirectory "$Name-stderr.txt"
$process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru `
    -RedirectStandardError $standardError -RedirectStandardOutput (Join-Path $OutDirectory "$Name-stdout.txt")
$shown = Wait-For { $process.Refresh(); $process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero } 90
if ($process.HasExited -or -not $shown) {
    $summary.result = if ($process.HasExited) { "exited with $($process.ExitCode) before showing a window" } else { 'no window within 90 seconds' }
    $summary.events = (Read-Events) -join ' | '
    if (Test-Path $standardError) { $summary.standardError = (Get-Content $standardError -Tail 20) -join "`n" }
    # A crash before the window leaves its exception in the Application event log.
    $summary.eventViewer = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $started } -ErrorAction SilentlyContinue |
        Select-Object -First 6 | ForEach-Object { "$($_.ProviderName): $($_.Message)" }) -join "`n----`n"
    Save-Screen 'no-window'
    Start-Sleep -Seconds 10
    $dump = Get-ChildItem $dumps -Filter *.dmp -ErrorAction SilentlyContinue | Select-Object -First 1
    $debugger = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dump -and $debugger) {
        $analysis = & $debugger.FullName -z $dump.FullName -c '.symfix; .reload; !analyze -v; q' 2>&1
        $analysis | Set-Content (Join-Path $OutDirectory "$Name-crash.txt") -Encoding UTF8
        $summary.crash = @($analysis | Where-Object { $_ -match 'STOWED|HRESULT|ERROR_CODE|EXCEPTION_CODE_STR|SYMBOL_NAME|FAILURE_BUCKET|Error|Message|Text' } | Select-Object -First 40) -join "`n"
    } else {
        $summary.crash = "dump: $([bool] $dump), debugger: $([bool] $debugger)"
    }
    $summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
    $summary | ConvertTo-Json
    exit 1
}
$summary.windowSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$ready = Wait-For { (Read-Events) -contains 'ready' } 30
$summary.ready = $ready
$summary.readySeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

# Memory once the window has settled.
Start-Sleep -Seconds 8
$process.Refresh()
$summary.workingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
$summary.privateMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
$summary.peakWorkingSetMB = [math]::Round($process.PeakWorkingSet64 / 1MB, 1)
# Processor time while the window sits idle: a message loop that waits uses next to none.
$busy = $process.TotalProcessorTime
Start-Sleep -Seconds 5
$process.Refresh()
$summary.idleCpuMsIn5s = [math]::Round(($process.TotalProcessorTime - $busy).TotalMilliseconds)

# What the process loaded, by where it came from; the app's folder and the language runtime are what
# an installer has to carry.
$appDirectory = Split-Path $Executable
$groups = [ordered]@{ app = 0L; swiftRuntime = 0L; dotnetRuntime = 0L; windowsAppRuntime = 0L; system = 0L }
$counts = [ordered]@{ app = 0; swiftRuntime = 0; dotnetRuntime = 0; windowsAppRuntime = 0; system = 0 }
$loaded = @()
foreach ($file in ($process.Modules | ForEach-Object { $_.FileName } | Sort-Object -Unique)) {
    $group = if ($file.StartsWith($appDirectory, [StringComparison]::OrdinalIgnoreCase)) { 'app' }
        elseif ($file -match '\\Swift\\') { 'swiftRuntime' }
        elseif ($file -match '\\dotnet\\') { 'dotnetRuntime' }
        elseif ($file -match 'WindowsAppRuntime|\\WindowsApps\\') { 'windowsAppRuntime' }
        else { 'system' }
    $groups[$group] += (Get-Item $file).Length
    $counts[$group] += 1
    if ($group -ne 'system') { $loaded += "$group $([math]::Round((Get-Item $file).Length / 1KB)) KB $file" }
}
foreach ($group in @($groups.Keys)) {
    $summary["loaded_${group}_MB"] = [math]::Round($groups[$group] / 1MB, 1)
    $summary["loaded_${group}_files"] = $counts[$group]
}
$loaded | Set-Content (Join-Path $OutDirectory "$Name-modules.txt") -Encoding UTF8

$window = $process.MainWindowHandle
$summary.foreground = [Desktop]::BringForward($window)
# The window's top left corner at the screen's, so all of it is on the runner's small screen.
[void][Desktop]::SetWindowPos($window, [IntPtr]::Zero, 0, 0, 0, 0, 0x0001 -bor 0x0004)
Start-Sleep -Milliseconds 500
Save-Screen 'window'

# The second session in the sidebar, chosen as a screen reader would.
try {
    $automation = [System.Windows.Automation.AutomationElement]::FromHandle($window)
    $listItem = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $sessionItems = $automation.FindAll([System.Windows.Automation.TreeScope]::Descendants, $listItem)
    $summary.sidebarItems = $sessionItems.Count
    if ($sessionItems.Count -ge 2) {
        $sessionItems[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Seconds 1
    }
} catch {
    $summary.sidebarError = "$_"
}
$summary.showing = @(Read-Events | Where-Object { $_ -like 'showing: *' }) -join ' / '
Save-Screen 'selected'

# Click into the composer, switch the window to the Korean keyboard and Hangul mode, and type
# g k s r m f, which the IME composes as two syllables (U+D55C U+AE00), then press Enter. The runner
# now and then drops injected keys before they reach the window; when no composition began, the
# window is brought forward and the keys are typed once more.
$processId = 0
$thread = [Desktop]::GetWindowThreadProcessId($window, [ref] $processId)
$korean = [Desktop]::LoadKeyboardLayout('00000412', 1)
for ($attempt = 1; $attempt -le 2; $attempt++) {
    if ($attempt -gt 1) { [void][Desktop]::BringForward($window) }
    $rect = New-Object Desktop+Rect
    [void][Desktop]::GetWindowRect($window, [ref] $rect)
    [Desktop]::Click([int](($rect.Left + 260 + $rect.Right) / 2), $rect.Bottom - 50)
    Start-Sleep -Milliseconds 500
    [void][Desktop]::PostMessage($window, 0x0050, [IntPtr]::Zero, $korean)
    Start-Sleep -Seconds 1
    $summary.keyboardLayout = '{0:X8}' -f ([Desktop]::GetKeyboardLayout($thread).ToInt64() -band 0xFFFFFFFF)
    [Desktop]::Press(0x15)
    foreach ($key in 0x47, 0x4B, 0x53, 0x52, 0x4D, 0x46) { [Desktop]::Press([byte] $key) }
    Start-Sleep -Milliseconds 800
    Save-Screen 'composing'
    [Desktop]::Press(0x0D)
    Start-Sleep -Seconds 2
    Save-Screen 'sent'
    $summary.typingAttempts = $attempt
    if (@(Read-Events | Where-Object { $_ -like 'composition*' }).Count -gt 0) { break }
}

$expected = [string]::new([char[]] @([char] 0xD55C, [char] 0xAE00))
$events = Read-Events
$sent = @($events | Where-Object { $_ -like 'sent: *' } | ForEach-Object { $_.Substring(6) })
$summary.sent = $sent -join ' | '
$summary.sentCodePoints = ($sent | ForEach-Object { ($_.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int] $_ }) -join ' ' }) -join ' | '
$summary.tasks = @($events | Where-Object { $_ -like 'tasks:*' }) -join ' / '
$summary.compositionEvents = @($events | Where-Object { $_ -like 'composition*' }).Count
$summary.korean = if ($sent -contains $expected) { 'sent as typed' } elseif ($sent.Count) { 'sent, but not as typed' } else { 'nothing sent' }
$summary.result = 'window shown'

$process.Refresh()
$summary.workingSetAfterTypingMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
[void]$process.CloseMainWindow()
if (-not $process.WaitForExit(10000)) { $process.Kill() }

$summary | ConvertTo-Json | Set-Content (Join-Path $OutDirectory "$Name-summary.json") -Encoding UTF8
$summary | ConvertTo-Json
