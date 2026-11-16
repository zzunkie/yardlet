# Installs, updates and removes the packed Windows app as a person would, with a feed in a folder on the runner
# (docs/PLATFORM_PORTABILITY.md, "Installing and updating the Windows app"). pack.ps1 packs the build twice, as
# -FirstVersion and -NextVersion, both reading the folder -Feed for updates. The Windows App Runtime's packages are
# first taken from this Windows user where Windows lets them go (on the runner the framework stays, as on a PC that
# has the framework alone, the case a PC showed), and the first's Setup.exe installs the app
# without a window; its install hook must put the runtime's packages the app carries in place and end in time, and
# the installed app must have Yardlet's icon and a Start menu shortcut, and find no update. The next version's files then replace the feed's: the app opened again must
# download it and, once its window is closed, hand it to Velopack's updater, which puts it in place; opened once
# more it must be that version. The next version is signed with a certificate made for the check, as a release is
# signed with Yardlet's (vpk's signtool with a certificate in this user's store): its Setup.exe and the executable it
# installs must carry that signature, and the Windows App SDK's bootstrapper keeps Microsoft's. Opened as a person opens it,
# not elevated, the app must register for notifications. Removing it, also not elevated, must take the installed folder,
# the shortcut, the entry in Settings > Apps and the notifications' registration, and leave %LOCALAPPDATA%\Yardlet, the
# app's own data, as it was. It writes the event logs, Velopack's logs, screenshots and a summary to -OutDirectory.
param(
    [Parameter(Mandatory)] [string] $Binaries,
    [Parameter(Mandatory)] [string] $OutDirectory,
    [string] $Feed = (Join-Path $env:RUNNER_TEMP 'yardlet-feed'),
    [string] $FirstVersion = '0.0.1-ci.1',
    [string] $NextVersion = '0.0.1-ci.2'
)
$ErrorActionPreference = 'Stop'
$Binaries = (Resolve-Path $Binaries).Path
New-Item -ItemType Directory -Force $OutDirectory | Out-Null
$OutDirectory = (Resolve-Path $OutDirectory).Path
$Name = 'install'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class InstalledFile {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
    // How many icons the file carries.
    public static uint Icons(string file) { return ExtractIconEx(file, -1, null, null, 0); }
}
// Starts a program as this user at medium integrity, as Explorer starts one for a person: every process on the runner is
// elevated, and the Windows App SDK offers notifications only to a process that is not. The token is this process's own
// with its integrity lowered, as Microsoft's "Designing Applications to Run at a Low Integrity Level" lowers it, and the
// program inherits this process's environment. It starts suspended until its handle is held, so its exit code stays
// readable however soon it ends.
public static class MediumIntegrity {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo {
        public int cb; public string reserved; public string desktop; public string title;
        public int x; public int y; public int width; public int height; public int columns; public int rows;
        public int fillAttribute; public int flags; public short showWindow; public short reserved2Size;
        public IntPtr reserved2; public IntPtr input; public IntPtr output; public IntPtr error;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInformation { public IntPtr process; public IntPtr thread; public int processId; public int threadId; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MandatoryLabel { public IntPtr sid; public uint attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr copy);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ConvertStringSidToSid(string text, out IntPtr sid);
    [DllImport("advapi32.dll")]
    static extern int GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool SetTokenInformation(IntPtr token, int infoClass, ref MandatoryLabel label, int length);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr token, string application, string commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInformation information);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    public static System.Diagnostics.Process Start(string commandLine, string directory) {
        IntPtr token, copy, sid;
        // TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_QUERY and TOKEN_ADJUST_DEFAULT.
        if (!OpenProcessToken(GetCurrentProcess(), 0x0001 | 0x0002 | 0x0008 | 0x0080, out token)) throw new Win32Exception();
        // MAXIMUM_ALLOWED, as a primary token (SecurityImpersonation, TokenPrimary).
        bool copied = DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out copy);
        CloseHandle(token);
        if (!copied) throw new Win32Exception();
        try {
            // Medium integrity, S-1-16-8192; SE_GROUP_INTEGRITY; TokenIntegrityLevel.
            if (!ConvertStringSidToSid("S-1-16-8192", out sid)) throw new Win32Exception();
            var label = new MandatoryLabel { sid = sid, attributes = 0x20 };
            bool lowered = SetTokenInformation(copy, 25, ref label, Marshal.SizeOf(label) + GetLengthSid(sid));
            LocalFree(sid);
            if (!lowered) throw new Win32Exception();
            var startup = new StartupInfo();
            startup.cb = Marshal.SizeOf(startup);
            ProcessInformation information;
            // CREATE_SUSPENDED.
            if (!CreateProcessAsUser(copy, null, commandLine, IntPtr.Zero, IntPtr.Zero, false, 0x4, IntPtr.Zero, directory,
                                     ref startup, out information)) throw new Win32Exception();
            var process = System.Diagnostics.Process.GetProcessById(information.processId);
            GC.KeepAlive(process.Handle);
            ResumeThread(information.thread);
            CloseHandle(information.thread);
            CloseHandle(information.process);
            return process;
        } finally {
            CloseHandle(copy);
        }
    }
}
'@

$summary = [ordered]@{ name = $Name }
$installRoot = Join-Path $env:LOCALAPPDATA 'YardletApp'
$executable = Join-Path $installRoot 'current\NativeHarnessClient.exe'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Yardlet.lnk'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\YardletApp'
$data = Join-Path $env:LOCALAPPDATA 'Yardlet'
# The AppUserModelID Velopack gives the installed app, which its notifications are registered under, and the entry
# registering writes for it.
$appUserModelID = 'velopack.YardletApp'
$appUserModelIDKey = "HKCU:\Software\Classes\AppUserModelId\$appUserModelID"
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
# it has looked, and returns that line. The app stays open. With -Medium it is not elevated (MediumIntegrity).
function Open-Installed([string] $label, [switch] $Medium) {
    $log = Join-Path $OutDirectory "$Name-$label-events.log"
    $env:YARDLET_QA_EVENT_LOG = $log
    if ($Medium) {
        $script:process = [MediumIntegrity]::Start("`"$executable`"", (Split-Path $executable))
    } else {
        $script:process = Start-Process -FilePath $executable -WorkingDirectory (Split-Path $executable) -PassThru `
            -RedirectStandardError (Join-Path $OutDirectory "$Name-$label-stderr.txt") `
            -RedirectStandardOutput (Join-Path $OutDirectory "$Name-$label-stdout.txt")
    }
    # Its handle, taken while it runs, keeps the exit code readable once it has quit.
    [void]$script:process.Handle
    $shown =Wait-For { $script:process.Refresh(); $script:process.HasExited -or $script:process.MainWindowHandle -ne [IntPtr]::Zero } 90
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

# Closes the app's window as a person would, so it quits through its own end, and waits for it to exit. It must
# end cleanly: a crash as the process ends shows only in its exit code, such as 0xC0000409 for an abort.
function Close-Installed([string] $label) {
    [void]$script:process.CloseMainWindow()
    if (-not (Wait-For { $script:process.HasExited } 30)) { Finish "$label`: did not quit when its window closed" }
    $code = $script:process.ExitCode
    if ($code -ne 0) { Finish ("$label`: quit with exit code 0x{0:X8}" -f $code) }
}

# The first version, installed.
$first = Join-Path $env:RUNNER_TEMP 'yardlet-pack-first'
$next = Join-Path $env:RUNNER_TEMP 'yardlet-pack-next'
foreach ($folder in @($Feed, $first, $next)) {
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory $folder | Out-Null
}
& (Join-Path $PSScriptRoot 'pack.ps1') -Binaries $Binaries -OutDirectory $first -Version $FirstVersion -UpdateFeed $Feed
# Windows PowerShell's PKI module makes the certificate, in this user's store, where signtool finds it by thumbprint.
$thumbprint = (powershell.exe -NoProfile -Command ("(New-SelfSignedCertificate -Type CodeSigningCert -Subject " +
    "'CN=Yardlet install check' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)).Thumbprint")).Trim()
if ($thumbprint -notmatch '^[0-9A-F]{40}$') { Finish "no certificate for the check: $thumbprint" }
try {
    & (Join-Path $PSScriptRoot 'pack.ps1') -Binaries $Binaries -OutDirectory $next -Version $NextVersion -UpdateFeed $Feed `
        -SignParameters "/sha1 $thumbprint /fd sha256"
} finally {
    Remove-Item "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
}
function Signer([string] $file) { "$((Get-AuthenticodeSignature $file).SignerCertificate.Thumbprint)" }
$summary.nextSetupSigned = (Signer (Join-Path $next 'YardletApp-win-Setup.exe')) -eq $thumbprint
if (-not $summary.nextSetupSigned) { Finish "the next version's Setup.exe is not signed with the certificate given" }
Copy-Item "$first\*" $Feed
$before = Data-Listing

# The Windows App Runtime's packages for x64 the app carries, by the names MSIX.identities gives, taken from this user:
# the packages that depend on the framework first. The runner's installer added them for every user earlier; Windows
# keeps the framework for the user, and the rest go.
$runtimePackages = @(Get-Content (Join-Path $Binaries 'WindowsAppRuntime\MSIX.identities') | ForEach-Object {
    (($_ -split '=', 2)[1] -split '_')[0]
} | Sort-Object { if ($_ -like '*.Singleton*') { 0 } elseif ($_ -like '*.Main*') { 1 } elseif ($_ -like '*.DDLM*') { 2 } else { 3 } })
$summary.runtimePackages = $runtimePackages -join ', '
function Runtime-Listing {
    @($runtimePackages | ForEach-Object { Get-AppxPackage -Name $_ } | Where-Object Architecture -eq 'X64' |
        ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
}
foreach ($package in $runtimePackages) {
    Get-AppxPackage -Name $package | Where-Object Architecture -eq 'X64' | ForEach-Object {
        try { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Stop } catch { $summary["remove $package"] = "$_" }
    }
}
$summary.runtimeBefore = Runtime-Listing

# The install hook writes what it put in place to the event log the installer's environment names.
$hookLog = Join-Path $OutDirectory "$Name-hooks-events.log"
New-Item -ItemType File -Force $hookLog | Out-Null
$env:YARDLET_QA_EVENT_LOG = $hookLog
$setup = Join-Path $Feed 'YardletApp-win-Setup.exe'
$started = Get-Date
$installer = Start-Process -FilePath $setup -ArgumentList '--silent', '--log', (Join-Path $OutDirectory "$Name-setup.log") -Wait -PassThru
$summary.setupSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
if ($installer.ExitCode -ne 0) { Finish "Setup ended with $($installer.ExitCode)" }
$summary.installHook = [bool](Select-String -Path (Join-Path $OutDirectory "$Name-setup.log") -Pattern 'Hook executed successfully' -Quiet)
$summary.runtimeHook = (Get-Content $hookLog -ErrorAction SilentlyContinue | Where-Object { $_ -like 'runtime: *' }) -join ' | '
$summary.runtimeAfter = Runtime-Listing
if (-not $summary.installHook) { Finish 'the install hook did not end in time' }
if ($summary.runtimeHook -notlike 'runtime: added *') { Finish "the install hook did not put the runtime in place: $($summary.runtimeHook)" }
$absent = @($runtimePackages | Where-Object { -not (Get-AppxPackage -Name $_ | Where-Object Architecture -eq 'X64') })
if ($absent.Count) { Finish "not in place after Setup: $($absent -join ', ')" }
if (-not (Test-Path $executable)) { Finish 'not installed' }
$summary.executables = @(Get-ChildItem (Join-Path $installRoot 'current') -Recurse -File -Filter '*.exe' | ForEach-Object Name) -join ', '
if ($summary.executables -ne 'NativeHarnessClient.exe') { Finish "other executables installed: $($summary.executables)" }
$summary.relay = Test-Path (Join-Path $installRoot 'current\YardletRelayURL')
if (-not $summary.relay) { Finish 'the relay the app was built with is not installed' }
$summary.icons = [InstalledFile]::Icons($executable)
if ($summary.icons -lt 1) { Finish 'the executable has no icon' }
if (-not (Test-Path $shortcut)) { Finish 'no Start menu shortcut' }
$entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
$summary.appsEntry = "$($entry.DisplayName) $($entry.DisplayVersion)"
if (-not $entry) { Finish 'no entry in Settings > Apps' }
$summary.version = Installed-Version
if ($summary.version -ne $FirstVersion) { Finish "installed $($summary.version), not $FirstVersion" }
if ((Data-Listing) -ne $before) { Finish 'installing changed the data folder' }

# Nothing newer in the feed yet, and nothing of the runtime missing.
$looked = Open-Installed 'first'
if ("$looked" -ne 'update: none') { Finish "first: $looked" }
$summary.runtimeAtStart = (Get-Content (Join-Path $OutDirectory "$Name-first-events.log") | Where-Object { $_ -like 'runtime: *' }) -join ' | '
if ($summary.runtimeAtStart -notlike 'runtime: in place*') { Finish "first: $($summary.runtimeAtStart)" }
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
$summary.updatedSigner = (Get-AuthenticodeSignature $executable).SignerCertificate.Subject
if ((Signer $executable) -ne $thumbprint) { Finish "the updated executable is signed by $($summary.updatedSigner)" }
$bootstrapper = Get-AuthenticodeSignature (Join-Path $installRoot 'current\Microsoft.WindowsAppRuntime.Bootstrap.dll')
$summary.bootstrapperSigner = "$($bootstrapper.SignerCertificate.Subject) ($($bootstrapper.Status))"
if ($bootstrapper.Status -ne 'Valid' -or $bootstrapper.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    Finish "the bootstrapper's signature changed: $($summary.bootstrapperSigner)"
}
$looked = Open-Installed 'updated'
if ("$looked" -ne 'update: none') { Finish "updated: $looked" }
if (-not (Get-Content (Join-Path $OutDirectory "$Name-updated-events.log") | Where-Object { $_ -eq "update: current $NextVersion" })) {
    Finish "updated: not $NextVersion"
}
Close-Installed 'updated'

# Notifications, as a person's app has them: opened not elevated, the app registers for them as it starts, which writes
# its AppUserModelID's entry and the CLSID of its activator under HKCU\Software\Classes. A notification is then posted
# under its AppUserModelID for the notification center to keep, where Windows lets one be read on the runner.
$looked = Open-Installed 'registered' -Medium
if ("$looked" -ne 'update: none') { Finish "registered: $looked" }
$summary.notifications = (Get-Content (Join-Path $OutDirectory "$Name-registered-events.log") | Where-Object { $_ -like 'notifications: *' }) -join ' | '
if ($summary.notifications -ne 'notifications: registered') { Finish "registered: $($summary.notifications)" }
$activator = (Get-ItemProperty $appUserModelIDKey -ErrorAction SilentlyContinue).CustomActivator
$summary.activator = "$activator"
if (-not $activator -or -not (Test-Path "HKCU:\Software\Classes\CLSID\$activator")) { Finish 'registered: no AppUserModelId or CLSID entry' }
Close-Installed 'registered'
# The notifications Windows keeps for the app, or the error reading them gave, through Windows PowerShell, which reaches
# Windows' notification API; with -Post one is posted first.
function Notification-Count([switch] $Post) {
    $command = @"
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
if (`$$($Post.IsPresent)) {
    `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    `$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Yardlet install check</text></binding></visual></toast>')
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$appUserModelID').Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
    Start-Sleep -Seconds 2
}
@([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory('$appUserModelID')).Count
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    "$(powershell.exe -NoProfile -EncodedCommand $encoded 2>&1 | Select-Object -Last 1)"
}
$summary.notificationsKept = Notification-Count -Post

# Removed, as Settings > Apps removes it, not elevated, so its uninstall hook can let go of the notifications. The app
# wrote to its data folder while it was open; removing it must change nothing there. Any Yardlet still running is
# recorded, since one would hold the data folder's files.
$summary.running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*NativeHarnessClient.exe' } |
    ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; '
$before = Data-Listing
$updater = Join-Path $installRoot 'Update.exe'
$uninstallLog = Join-Path $OutDirectory "$Name-uninstall.log"
$uninstallEvents = Join-Path $OutDirectory "$Name-uninstall-events.log"
New-Item -ItemType File -Force $uninstallEvents | Out-Null
$env:YARDLET_QA_EVENT_LOG = $uninstallEvents
$remover = [MediumIntegrity]::Start("`"$updater`" uninstall --silent --log `"$uninstallLog`"", (Get-Location).Path)
if (-not $remover.WaitForExit(120000)) { Finish 'uninstall did not end' }
if ($remover.ExitCode -ne 0) { Finish "uninstall ended with $($remover.ExitCode)" }
$summary.uninstallHook = [bool](Select-String -Path $uninstallLog -Pattern 'Hook executed successfully' -Quiet)
if (-not $summary.uninstallHook) { Finish 'the uninstall hook did not end at once' }
$summary.uninstallNotifications = (Get-Content $uninstallEvents -ErrorAction SilentlyContinue | Where-Object { $_ -like 'notifications: *' }) -join ' | '
if (-not (Wait-For { -not (Test-Path $executable) } 30)) { Finish 'the app is still installed' }
if (Test-Path $shortcut) { Finish 'the Start menu shortcut is left' }
if (Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue) { Finish 'the entry in Settings > Apps is left' }
if ($summary.uninstallNotifications -ne 'notifications: removed the notifications, unregistered') {
    Finish "uninstall: $($summary.uninstallNotifications)"
}
if (Test-Path $appUserModelIDKey) { Finish 'the notifications'' AppUserModelId entry is left' }
if (Test-Path "HKCU:\Software\Classes\CLSID\$activator") { Finish 'the notifications'' CLSID entry is left' }
# A count read before and after: a notification the notification center kept must be gone. Where Windows does not let
# the runner read them, the summary says so and the registration above is the check.
$summary.notificationsLeft = Notification-Count
if (($summary.notificationsKept -as [int]) -ge 1 -and ($summary.notificationsLeft -as [int]) -ge 1) {
    Finish 'notifications are left in the notification center'
}
if ((Data-Listing) -ne $before) { Finish 'removing changed the data folder' }
$summary.left = @(Get-ChildItem $installRoot -Force -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', '
Finish 'installed, updated and removed'
