# Serves the Windows app's tasks to a phone on the same computer, over the app's direct listener and through a local
# relay (start-remote-host.ps1 without a fixture, in the same step). The app opens with the remote off, as it ships,
# and neither listens nor holds a relay room; the check turns it on in Settings > Remote and waits until it listens on
# its direct port (Same Wi-Fi) and has reached the relay. It then pairs two phones on the engine's client connection
# (yardlet-remote-fixture --pair), each from a link the app copies: the first from the link without its relay, so it
# pairs and connects over a direct address (the runner's own network address, not loopback), the second from the link
# without its direct addresses, so it goes through the relay. Each lists the host's tasks, opens the task
# check-local.ps1 started, sends a message and waits for the answer, while this check allows the stand-in's request in
# the host's window. A .NET WebSocket then shows the direct listener refuses a browser's handshake (Origin) and closes a
# text frame with 1003, and what Windows' own DNS-SD browse finds is noted. The host's devices must then name the
# phones, and turning the remote off must close the relay room, the listening socket and a connection still open. (The
# Windows app's own Connect is check-remote.ps1's; a second copy of the app would share this one's settings and keys,
# which are the user's, and so host the same room.)
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
    [string] $Message = 'Add a section on updates',
    [string] $RelayMessage = 'Add a section on removal'
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

// What Windows' own DNS-SD browse (DnsServiceBrowse, the counterpart of the app's DnsServiceRegister) finds of a
// service type in a few seconds: the instance names its PTR records name.
public static class ServeBonjour {
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    public delegate void BrowseCallback(uint status, IntPtr context, IntPtr records);

    [StructLayout(LayoutKind.Sequential)]
    struct BrowseRequest {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public BrowseCallback Callback;
        public IntPtr Context;
    }

    // The cancel handle Windows fills, which must stay where it is until the browse is cancelled.
    [DllImport("dnsapi.dll")] static extern int DnsServiceBrowse(ref BrowseRequest request, IntPtr cancel);
    [DllImport("dnsapi.dll")] static extern int DnsServiceBrowseCancel(IntPtr cancel);
    [DllImport("dnsapi.dll")] static extern void DnsRecordListFree(IntPtr records, int type);

    static readonly System.Collections.Generic.List<string> found = new System.Collections.Generic.List<string>();
    static BrowseCallback kept;

    public static string[] Browse(string service, int milliseconds) {
        kept = (reported, context, records) => {
            // DNS_RECORDW on x64: pNext at 0, wType at 16, and a PTR record's pNameHost at 32.
            for (IntPtr record = records; record != IntPtr.Zero; record = Marshal.ReadIntPtr(record)) {
                if (Marshal.ReadInt16(record, 16) == 12) {
                    lock (found) { found.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, 32))); }
                }
            }
            if (records != IntPtr.Zero) DnsRecordListFree(records, 1);
        };
        var request = new BrowseRequest { Version = 1, QueryName = Marshal.StringToHGlobalUni(service), Callback = kept };
        IntPtr cancel = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(cancel, IntPtr.Zero);
        int started = DnsServiceBrowse(ref request, cancel);
        if (started != 9506) return new[] { "DnsServiceBrowse returned " + started };
        Thread.Sleep(milliseconds);
        DnsServiceBrowseCancel(cancel);
        lock (found) { return found.ToArray(); }
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

# Whether anything accepts a connection on this computer's $port.
function Test-Listening([int] $port) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        return $tcp.ConnectAsync('127.0.0.1', $port).Wait(3000) -and $tcp.Connected
    } catch {
        return $false
    } finally {
        $tcp.Dispose()
    }
}

# A .NET WebSocket to the direct listener, opened or refused within 10 s.
function Open-Socket([string] $url, [string] $origin) {
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    if ($origin) { $socket.Options.SetRequestHeader('Origin', $origin) }
    try { $socket.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None).Wait(10000) | Out-Null } catch {}
    return $socket
}

# Whether the socket is closed within $seconds, receiving until it is.
function Wait-Closed($socket, [int] $seconds) {
    $buffer = [ArraySegment[byte]]::new((New-Object byte[] 1024))
    $deadline = (Get-Date).AddSeconds($seconds)
    $receiving = $null
    while ((Get-Date) -lt $deadline -and $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            if (-not $receiving -or $receiving.IsCompleted) { $receiving = $socket.ReceiveAsync($buffer, [Threading.CancellationToken]::None) }
            $null = $receiving.Wait(500)
        } catch {
            break
        }
    }
    return $socket.State -ne [System.Net.WebSockets.WebSocketState]::Open
}

# A link the app copies, without the query items named.
function Without-Items([string] $link, [string[]] $names) {
    $parts = $link -split '\?', 2
    $kept = @($parts[1] -split '&' | Where-Object { $names -notcontains ($_ -split '=', 2)[0] })
    return $parts[0] + '?' + ($kept -join '&')
}

# Settings > Remote, chosen first unless it shows: a new pairing, its link copied; the link, once it differs from
# $previous.
function Copy-PairingLink([string] $previous, [switch] $showing) {
    if (-not $showing) {
        $settingsShown = @(Read-Events | Where-Object { $_ -eq 'showing settings' }).Count
        if (-not (Wait-For { Select-Item $main 'Settings' } 15)) { Finish 'no Settings item' }
        if (-not (Wait-For { @(Read-Events | Where-Object { $_ -eq 'showing settings' }).Count -gt $settingsShown } 10)) { Finish 'settings not shown' }
    }
    $shown = @(Read-Events | Where-Object { $_ -eq 'remote host pairing shown' }).Count
    $copied = @(Read-Events | Where-Object { $_ -eq 'remote host link copied' }).Count
    $pair = 'Pair' + [char]0x2026
    if (-not (Wait-For { Invoke-Named $main $pair } 10)) { Finish 'no Pair button' }
    if (-not (Wait-For { @(Read-Events | Where-Object { $_ -eq 'remote host pairing shown' }).Count -gt $shown } 15)) { Finish 'no pairing shown' }
    Start-Sleep -Seconds 1
    if (-not $previous) { Save-Screen 'pairing' }
    if (-not (Wait-For { Invoke-Named $main 'Copy link' } 10)) { Finish 'no Copy link button' }
    if (-not (Wait-For { @(Read-Events | Where-Object { $_ -eq 'remote host link copied' }).Count -gt $copied } 10)) { Finish 'the link was not copied' }
    $link = Wait-For { $text = [System.Windows.Forms.Clipboard]::GetText(); if ($text -like 'yardlet-remote://pair*' -and $text -ne $previous) { $text } } 10
    if (-not $link) { Finish 'no link on the clipboard' }
    return $link
}

# The phone, on the engine's client connection (yardlet-remote-fixture --pair): it pairs from $link, lists the tasks,
# opens the task and sends $text, and waits for the answer, while the host's card allows the stand-in's request. Its
# lines, joined; it must exit 0.
function Run-Phone([string] $label, [string] $link, [string] $text) {
    if (-not (Wait-For { Select-Item $main $Task } 15)) { Finish "no task named $Task" }
    $log = Join-Path $OutDirectory "$Name-phone-$label.log"
    $phone = Start-Process -FilePath $Fixture -PassThru -NoNewWindow -RedirectStandardOutput $log `
        -RedirectStandardError (Join-Path $OutDirectory "$Name-phone-$label-errors.log") `
        -ArgumentList '--pair', "`"$link`"", '--task', "`"$Task`"", '--send', "`"$text`""
    $script:client = $phone
    # Held now, or Windows PowerShell reports no exit code for a process it started.
    $null = $phone.Handle
    $deadline = (Get-Date).AddSeconds(240)
    $allowed = 0
    while (-not $phone.HasExited -and (Get-Date) -lt $deadline) {
        # The stand-in asks to edit a file for each message; only a request waiting has an Allow button.
        $clicked = try { Invoke-Named $main 'Allow' } catch { $false }
        if ($clicked) {
            $allowed += 1
            if ($allowed -eq 1) { Save-Screen "allowed-$label" }
        }
        Start-Sleep -Milliseconds 500
    }
    $summary["allowedOnHost-$label"] = $allowed
    if (-not $phone.HasExited) { Finish "the $label phone did not finish" }
    $phone.WaitForExit()
    $lines = (@(Get-Content $log -Encoding UTF8) | Where-Object { $_ -like 'Phone: *' }) -join ' | '
    $summary["phone-$label"] = $lines
    if ($phone.ExitCode -ne 0) { Finish "the $label phone was not answered" }
    return $lines
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

# Off as it ships: a few seconds open, and the app neither listens nor has opened a room on the relay.
Start-Sleep -Seconds 3
$summary.roomSocketsWhileOff = Host-Sockets
if ($summary.roomSocketsWhileOff -ne 0) { Finish 'the remote opened a room while off' }
$summary.listeningWhileOff = Test-Listening 47616
if ($summary.listeningWhileOff) { Finish 'the remote listened while off' }
# Whether Windows' firewall filters what other devices would send, and on which kind of network the runner is.
$summary.firewall = (Get-NetFirewallProfile | ForEach-Object { "$($_.Name): $($_.Enabled), inbound $($_.DefaultInboundAction)" }) -join '; '
$summary.networks = (Get-NetConnectionProfile | ForEach-Object { "$($_.InterfaceAlias): $($_.NetworkCategory)" }) -join '; '

# Settings > Remote, turned on: the direct listener up and the relay reached.
if (-not (Wait-For { Select-Item $main 'Settings' } 15)) { Finish 'no Settings item' }
if (-not (Wait-For { (Read-Events) -contains 'showing settings' } 10)) { Finish 'settings not shown' }
# The event is written as the pane is chosen, a frame before it draws: the pane's switch shows once it has.
if (-not (Wait-For { Find-Toggle } 10)) { Finish 'no remote switch' }
Start-Sleep -Milliseconds 500
Save-Screen 'settings-off'
if (-not (Wait-For { Toggle-Remote } 10)) { Finish 'no remote switch' }
if (-not (Wait-For { (Read-Events) -contains 'remote host: on' } 10)) { Finish 'the remote did not turn on' }
$reach = Wait-For { Read-Events | Where-Object { $_ -like 'remote host reach: *Same Wi-Fi*' -and $_ -like '*Yardlet server' } } 60
$summary.reach = "$(Read-Events | Where-Object { $_ -like 'remote host reach: *' } | Select-Object -Last 1)"
if (-not $reach) { Finish 'the remote did not listen and reach the relay' }
# The rules Windows' firewall holds for the app, such as those its prompt on the first listen makes.
$filters = @(Get-NetFirewallApplicationFilter -Program $Executable -ErrorAction SilentlyContinue)
$summary.firewallRules = if ($filters.Count -gt 0) {
    @($filters | Get-NetFirewallRule | ForEach-Object { "$($_.DisplayName): $($_.Direction) $($_.Action) $($_.Profile)" }) -join '; '
} else { 'none' }

# The first phone, from the link without its relay: paired and answered over a direct address.
$link = Copy-PairingLink '' -showing
$room = [regex]::Match($link, '[?&]i=([a-z2-7]+)').Groups[1].Value
$summary.linkHasRelay = $link -like '*r=*'
$hosts = @([regex]::Matches($link, '[?&]h=([^&]+)') | ForEach-Object { [uri]::UnescapeDataString($_.Groups[1].Value) })
$summary.directHosts = $hosts -join ', '
if ($hosts.Count -eq 0) { Finish 'the link names no direct address' }
$port = [int](($hosts[0] -split ':')[-1])
$summary.listeningWhileOn = Test-Listening $port
$direct = Run-Phone 'direct' (Without-Items $link @('r', 'i', 'a')) $Message
if ($direct -notlike '*Phone: connected through direct(*') { Finish 'the phone did not connect directly' }

# The direct listener as another WebSocket client sees it: a browser's handshake refused, a text frame closed with 1003.
$browser = Open-Socket "ws://$($hosts[0])/" 'https://example.test'
$summary.browserRefused = $browser.State -ne [System.Net.WebSockets.WebSocketState]::Open
$browser.Dispose()
if (-not $summary.browserRefused) { Finish 'a browser opened the direct listener' }
$text = Open-Socket "ws://$($hosts[0])/" ''
$summary.socketOpened = $text.State -eq [System.Net.WebSockets.WebSocketState]::Open
if (-not $summary.socketOpened) { Finish 'a WebSocket did not open on the direct listener' }
try {
    $bytes = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes('{}'))
    $text.SendAsync($bytes, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
} catch {}
$null = Wait-Closed $text 10
$summary.textClosedWith = "$([int]$text.CloseStatus)"
$text.Dispose()
if ($summary.textClosedWith -ne '1003') { Finish 'a text frame did not close with 1003' }
$summary.bonjour = try { ([ServeBonjour]::Browse('_yardlet._tcp.local', 5000)) -join ', ' } catch { "browse failed: $($_.Exception.Message)" }

# The second phone, from a new link without its direct addresses: paired and answered through the relay.
$relayLink = Copy-PairingLink $link
$relayed = Run-Phone 'relay' (Without-Items $relayLink @('h')) $RelayMessage
if ($relayed -notlike '*Phone: connected through relay*') { Finish 'the phone did not connect through the relay' }

# The host's devices name the phones; turning the remote off closes the relay room, the listening socket and a
# connection still open.
$shownBefore = @(Read-Events | Where-Object { $_ -eq 'showing settings' }).Count
if (-not (Wait-For { Select-Item $main 'Settings' } 15)) { Finish 'no Settings item' }
if (-not (Wait-For { @(Read-Events | Where-Object { $_ -eq 'showing settings' }).Count -gt $shownBefore } 10)) { Finish 'settings not shown again' }
$devices = Wait-For { Read-Events | Where-Object { $_ -like 'remote host devices: *Fixture phone*Fixture phone*' } | Select-Object -Last 1 } 15
$summary.devices = "$devices"
if (-not (Wait-For { Find-Named $main 'Fixture phone' } 10)) { Finish 'the phone is not shown' }
Start-Sleep -Milliseconds 500
Save-Screen 'devices'
if (-not $devices) { Finish 'the paired devices are not listed' }
$summary.roomHeldWhileOn = Test-Room $room
if (-not $summary.roomHeldWhileOn) { Finish 'the room was not held while on' }
$summary.roomSocketsWhileOn = Host-Sockets
$open = Open-Socket "ws://$($hosts[0])/" ''
if ($open.State -ne [System.Net.WebSockets.WebSocketState]::Open) { Finish 'a WebSocket did not open on the direct listener' }
$turnedOff = Get-Date
if (-not (Wait-For { Toggle-Remote } 10)) { Finish 'no remote switch' }
if (-not (Wait-For { (Read-Events) -contains 'remote host: off' } 10)) { Finish 'the remote did not turn off' }
# Well inside the 10 s a connection has to finish its handshake, so the listener's stop closed it.
$summary.connectionClosedWhenOff = (Wait-Closed $open 5) -and ((Get-Date) - $turnedOff).TotalSeconds -lt 8
$open.Dispose()
$summary.roomClosedWhenOff = Wait-For { -not (Test-Room $room) } 15
$summary.listeningWhenOff = Test-Listening $port
Save-Screen 'off'
if (-not $summary.roomClosedWhenOff) { Finish 'the room stayed open once off' }
if ($summary.listeningWhenOff) { Finish 'the listener stayed open once off' }
if (-not $summary.connectionClosedWhenOff) { Finish 'a connection stayed open once off' }
Finish 'served'
