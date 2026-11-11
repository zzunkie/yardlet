# Engine portability

Yardlet runs on macOS. Windows is in progress: the engine is kept in cross-platform Swift, and each platform gets its
own screens. The engine builds on its own on macOS, Linux and Windows. The Windows app, the engine with WinUI 3
screens ("The Windows app" below), builds and opens its window on Windows, finds, starts and ends harness CLIs by
Windows' rules, starts tasks of its own as chats with them and reads their saved history, follows another computer's
Yardlet over the remote protocol, and serves its own tasks to other devices from Settings › Remote; what it does not
have yet is listed at the end of that section. For dependencies and Foundation behavior on Windows, what was checked
in the official source or a build is marked "confirmed"; the rest is "not confirmed".

## Engine and platform layers

- **Engine:** every Swift file of the `NativeHarnessClient` target and of `YardletAgentTools` (the library the app
  shares with the Yardlet MCP server, `yardlet-mcp`), except the screen and platform layers below. New folders count as
  engine by default.
- **Screen and platform layers (outside the check):** `Views/`, `WinUI/` (the Windows app's screens), `Browser/` (the
  WebKit preview), `Development/` (visual fixtures and QA), `Platform/` and `NativeHarnessClientApp.swift`.
- Engine code names the platform's parts directly, and each platform defines them under the same names in its own
  folder: `Platform/macOS/` for the Mac app, `Platform/Windows/` for the Windows app, and `Platform/Portable/` for a
  build of the engine on its own and for what the Windows layer does not provide yet. Some parts
  are protocols the engine owns with a platform's implementation (`LocalSystemNotificationCenter` implements
  `SystemNotificationCenter`, `LiveProcessTable` implements `ProcessTableReading`); others are types or extensions the
  engine calls by name. The app's model is put together in `Platform/macOS/AppModel+Live.swift`, which hands the engine
  the Mac's browser host; the Windows app's in `Platform/Windows/AppModel+Live.swift`.

## Building the engine on its own

```sh
YARDLET_ENGINE_ONLY=1 swift build --build-system native --target NativeHarnessClient --force-resolved-versions
```

With `YARDLET_ENGINE_ONLY=1`, `Package.swift` turns the app target into a library that leaves out `Views/`, `WinUI/`,
`Browser/`, `Development/`, `Platform/macOS/`, `Platform/Windows/` and `NativeHarnessClientApp.swift`, and drops the
SwiftTerm and Sparkle packages and the test target. This is the build a platform other than macOS makes, and on a Mac it checks that the engine still
stands without the screens. `--force-resolved-versions` keeps `Package.resolved` as the full build pins it; without
it, the build rewrites the file without the packages it leaves out.

`Platform/Portable/` is written in Foundation alone. Where Foundation offers nothing, its parts do nothing and report
nothing: no notifications, an empty process table, no shell, file access that refuses. It is the list of what a new
platform's layer has to provide:

| Name | What it is | In `Platform/macOS/` |
| --- | --- | --- |
| `LocalSystemNotificationCenter` | System notifications | UserNotifications |
| `LiveProcessTable` | The process table for Task Resource Usage | libproc |
| `MacConditionReader` | Disk, memory pressure and heat for the new-task notice and the session tools | `sysctlbyname`, `getloadavg` |
| `MemoryPressureWatch` | The memory saver's pressure warnings | Dispatch memory pressure source |
| `NativeProcessTree` | Ending a process Yardlet started, with what it started | `proc_listchildpids`, signals |
| `ScopedFiles`, `OpenFile` | Reading Claude's transcripts without following links | `openat` with `O_NOFOLLOW` |
| `WorkspaceFileReplacement` | Saving a reviewed workspace file | no-follow descriptors, `renameat` |
| `FileCloning`, `Trash`, `FileTypes` | Block-sharing copies, the Trash, file types | `copyfile`, `trashItem`, UTType |
| `ShellLaunchEnvironment.userLoginShell` | The person's login shell | the user database |
| `ClaudeConversationCatalog.runningSessionIDs` | Which Claude Code sessions run elsewhere | `kill(pid, 0)`, `sysctl` |
| `HarnessAccountBroker.antigravityCredentialState` | Whether Antigravity is signed in | Keychain |
| `AccountLoginController`, `NativeTerminalSession`, `TaskShellProcess` | The sign-in terminal, each terminal tab's shell, bash mode's shell | SwiftTerm and a PTY |
| `BrowserPreviewModel`, `ConversationRenderState` | A tab's preview page, the conversation's cached turn views | WebKit, AppKit |
| `RemoteHostPlatform.current`, `LidSleepHelper` | The phone remote's listener, interfaces, network changes and keeping the computer awake; the lid helper | Network.framework, BSD sockets, a process activity, XPC |

The phone remote itself, `RemoteControlService` (`Remote/RemoteControlService.swift`), is engine code on every
platform, with its keys behind `RemoteIdentityStoring`: the Keychain on the Mac, Credential Manager on Windows.

The Windows layer provides `NativeProcessTree` (`Platform/Windows/NativeProcessTree.swift`) and
`RemoteHostPlatform.current` (`Platform/Windows/WindowsRemoteHost.swift`), so the Windows app leaves
`PortableProcesses.swift` and `PortableRemoteHost.swift` out (`portableFilesWindowsReplaces` in `Package.swift`).

`Platform/Portable/PortableFoundation.swift` also holds the few names Foundation outside Apple's platforms lacks
(`InlinePresentationIntent`, Combine's `ObservableObject` and `Published`, `autoreleasepool`), and
`URLSession.bytes(for:)`, which there streams a response's body through a delegate and refuses redirects, as the app's
own sessions do.

**Foundation outside Apple's platforms.** Where the engine uses something only Apple's Foundation has, it keeps that
under `#if canImport(Darwin)` and says the same thing another way elsewhere: `L10n` takes plain string keys,
`RelativeTime` uses `Date.RelativeFormatStyle`, `NSNumber` tells JSON booleans and fractions apart by `objCType`
(`JSONNumberKind`), Gmail's charsets go through `String.Encoding(ianaName:)`. Files that use `URLSession` import
`FoundationNetworking` when it exists, and files that use `@Observable` import `Observation`.

**Cryptography.** The engine and the phone remote import `Crypto` from swift-crypto, which has CryptoKit's API: on
macOS it re-exports CryptoKit and adds nothing to the app; elsewhere it builds BoringSSL.

**The phone remote off macOS.** Its direct-path listener on the Mac (`RemoteSecureListener` on Network.framework) is
left out of a build on another platform. Windows has its own, `RemoteWinsockListener` (`#if os(Windows)`): Winsock on
every interface, one thread serving every socket with `WSAPoll`, and DNS-SD from Windows itself (`DnsServiceRegister`,
Windows 10 1903 and later) for the Bonjour advertisement. Its sockets are made non-inheritable: Winsock's are
inheritable, and a harness Yardlet started while the remote was on held the listening socket open after the remote was
turned off (seen on the CI runner). Winsock hands it bytes, so it speaks the WebSocket with
`RemoteWebSocket`, which builds everywhere and which the Mac tests: the opening request read up to 8 KB and answered
only for a WebSocket upgrade without Origin, and the phone's frames read back into whole messages, so the Windows
listener needs none of the piece joining below. The Mac's listener shares its Origin rule, its accepted header and how
a phone's address names its path (`RemoteAddressSelection.path(ofPeer:)`). Elsewhere the remote serves the relay
alone (`RemoteHostPlatform.current` in `Platform/Portable/`). `RemoteAddresses` builds everywhere: it reads an
address with `inet_pton`; the Mac lists its interfaces with `getifaddrs`, Windows with `GetAdaptersAddresses` and
watches them with IP Helper's change notifications, and both look up the MagicDNS name. The rest of `YardletRemote`
builds: its random bytes fall back to `SystemRandomNumberGenerator`, its free-space check to
`attributesOfFileSystem`, and `RemoteLimits.host(of:)` exists only with Network.framework. Foundation there hands a
WebSocket frame over in the pieces libcurl reads it in, each as a message of its own (`WebSocketURLProtocol` drops
`curl_ws_meta`'s `bytesleft`), so the remote's sockets join a piece that does not read (a Noise frame that does not
decrypt, a relay message that is not JSON) to the next one before reading it again, up to the frame's limit
(`RemoteFramePieces`); with Apple's Foundation a frame that does not read is refused at once.

**Where it has been built.** On Linux in the `swift:6.4-bookworm` image (confirmed, 2026-10-31), and since 2026-11-09
in GitHub Actions: `.github/workflows/linux-engine.yml` makes the build in that image, pinned by digest, for the same
pull requests and `main` as the Windows build below, as a check to read. Without it a name only Darwin has went
unnoticed (`memmem`, which Glibc's module leaves out). On a Mac, a folder on the desktop cannot be mounted into Docker,
so the sources go in as an archive:

```sh
tar --exclude ./.build --exclude ./.git --exclude ./docs -cf - . | docker run -i --rm swift:6.4-bookworm bash -c \
  'mkdir /src && tar -xf - -C /src && cd /src && YARDLET_ENGINE_ONLY=1 swift build --target NativeHarnessClient'
```

On Windows (x64, Swift 6.4.1 from swift.org's installer) in GitHub Actions (confirmed, 2026-10-31):
`.github/workflows/windows-engine.yml` makes the same build for every pull request that changes more than documents,
`main` and `windows-*` branches; a commit a pull request's run built is not built again when it lands on `main`.
It is a check to read, not a required one. A run's logs need a GitHub sign-in, so a failed run also reports its
compiler errors in the check run's annotations, which the API gives without one. The macOS engine-only build cannot
stand in for it: Apple's platforms have names the others lack (Combine's `objectWillChange`, for one).

**Why one target per platform.** A separate engine library would need every declaration the screens and tests use
opened with the `package` access level, a change to nearly every engine file. Choosing the platform's folder in
`Package.swift` keeps one module on each platform, so engine code and `@testable import` stay as they are.

## The Windows app

On Windows, without `YARDLET_ENGINE_ONLY`, `Package.swift` makes the app target the Windows app: the engine,
`Platform/Portable/`, `Platform/Windows/` and the screens in `WinUI/`, in one module as on the Mac. The Mac's build and
the engine-only builds leave `WinUI/` and `Platform/Windows/` out. When the Windows layer comes to provide one of
`Platform/Portable/`'s parts, the Windows app leaves that portable file out.

- **Assembly.** `Platform/Windows/AppModel+Live.swift` makes the model with its stores in `%LOCALAPPDATA%\Yardlet`
  and no browser host. `WinUI/YardletApp.swift` makes it once WinUI has started and opens `WinUI/MainWindow.swift`:
  the store's tasks in the sidebar, followed through Observation, with their titles and harness marks as the Mac's
  rows show them, and a composer that sends through the model, with Stop beside it while the task's turn runs, which
  stops it through the harness's own cancel (`AppModel.interrupt`). New task at the top (`WinUI/NewTaskPane.swift`)
  starts a task as the Mac's new-task screen does, from the Mac's home draft: a harness whose CLI Yardlet found,
  where it works (a project, a folder chosen in Windows' own folder dialog, `Platform/Windows/WindowsFolderPicker.swift`,
  or a chat with no project), and the model, effort and permission the harness takes before its task exists, from
  the menus the Mac's controls read and with the Mac's question before a choice that skips asking. Choosing a task
  reads its saved history as the Mac does (`refreshConversationStatus`, which starts no turn), and its conversation
  draws from the projection the Mac's timeline reads; a change to files opens to each file's diff, and a request in it
  shows its card's answers as buttons, carried out as the Mac's card carries them out.
- **Conversations.** `WinUI/ConversationTimeline.swift` draws the engine's `ConversationPresentation` turn by turn,
  for a task's own conversation and a host's: what was sent, a line for each step of the work, the answers, the
  requests waiting and how the turn ended. A turn that did not change keeps what it drew. As on the Mac, only the
  latest turns are drawn (`ConversationTurnWindow`, 10 at first) and Load more history draws 10 more, so what an
  update compares and draws in the window is bounded by those turns however long the history. Answers draw their
  Markdown from the engine's reading of it (`WinUI/MarkdownView.swift`, `TranscriptMarkdownDocument`): bold,
  italic, code, struck and linked words, lists, quotes, code blocks, tables and rules.
- **Language.** The app's words follow Windows' display language, as WinUI's own controls do. Foundation outside
  Apple's platforms looks for the preferred languages only in `AppleLanguages`, which nothing writes on Windows, so
  it answered in English on a Korean Windows while WinUI drew Settings and its switches in Korean (seen on a PC).
  A bundle made from a `.lproj` folder searches the same list, so `L10n` (`Localization.swift`) asks Windows for the
  user's display languages (`GetUserPreferredUILanguages`), chooses the bundle's localization they name, and reads its
  `Localizable.strings` itself, unless Yardlet's own defaults name a language. The QA event log's `language:` line says
  which it chose.
- **No console windows.** The release app is a windowed program with no console, and Foundation's `Process` passes
  `CreateProcessW` no `CREATE_NO_WINDOW` (confirmed in its source), so each console program the app started, a
  harness's node or Git, opened a console window of its own, in Windows Terminal where that is the default terminal
  (seen on the CI runner). At launch the app makes a console with no window for those programs to share
  (`Platform/Windows/WindowsConsole.swift`, `AllocConsoleWithOptions` with `ALLOC_CONSOLE_MODE_NO_WINDOW`, Windows 11
  24H2 and later); a Windows without that call keeps the console windows.
- **Another computer's Yardlet.** Connect to a Mac, below the tasks in the main window, pairs with the link a host
  copies in Settings › Remote, as File › Connect to Mac… does on the Mac (docs/REMOTE_PROTOCOL.md, "Yardlet as a
  client"), and lists the paired Macs with Open and Remove…, which forgets the host and asks it to forget this
  computer when it can be reached. `WinUI/RemoteHostWindow.swift` opens each paired host in a window of its own: the host's tasks as it
  lists them, the chosen task's conversation as it streams, and a composer that sends to the host. The client is the
  engine's `RemoteHostDirectory` and `RemoteHostModel`; `Platform/Windows/WindowsRemoteClientKeys.swift` keeps each
  host's key in Credential Manager and the list and cache under `%LOCALAPPDATA%\Yardlet`. Without Bonjour, a host is
  reached at the direct addresses it named, on the same network or over Tailscale, and through its relay. A host's
  sidebar is drawn again only when what it shows changes, not as a task's marks and times change while it streams.
- **This computer's tasks elsewhere.** Settings, at the foot of the sidebar, holds Settings › Remote as the Mac's
  (`WinUI/RemoteSettingsPane.swift`): Allow remote connections, off until turned on and then served on the same
  network and over Tailscale by a listener on every interface at port 47616, advertised with DNS-SD, and through the
  relay; the paths a device can take now; pairing with a QR code (Swift QR Code Generator) and Copy link, which keeps the link
  out of the clipboard's history and off other devices; and the paired devices with their permissions and Remove. The
  remote is the engine's `RemoteControlService`, as on the Mac. `Platform/Windows/WindowsRemoteHost.swift` keeps its
  keys in Credential Manager and its devices and audit log under `%LOCALAPPDATA%\Yardlet\remote`, in the Mac's
  format. While the remote is off it opens nothing, and turning it off closes its listener, its connections and its
  room on the relay. The first time the listener opens, Windows Defender Firewall asks whether Yardlet may take
  connections on private and on public networks; a phone on the same network reaches it only on a network whose
  profile was allowed. A build carries
  its relay as the Mac's does, written from `YARDLET_RELAY_URL` or Packaging/RelayURL (out of git), but in a file
  beside the executable, `YardletRelayURL`, rather than in Info.plist (`Windows/scripts/place-relay.ps1`); a build
  without it has no relay, and the app CI gathers carries `https://relay.yardlet.app`, as a public Mac build does.
- **Harness CLIs.** The engine finds a harness's runtime by Windows' rules (`Runtime/ExecutableLookup.swift`, "Paths
  and executable lookup" below), so Claude Code's `claude.exe` in `%USERPROFILE%\.local\bin` and npm's shims in
  `%APPDATA%\npm` are found as a person's own terminal would find them. Harnesses, their account commands and
  checks, MCP servers and the Git and `gh` commands Yardlet may stop start with `NativeProcessTree.run(_:)`, which on
  Windows starts what npm's `.cmd` shim would, Node.js on the package's script, and refuses any other batch file
  (`Runtime/NPMCommandShim.swift`, "Foundation `Process`" below), then puts the process in a job object of its own
  (`Platform/Windows/NativeProcessTree.swift`): `terminate(process:)` ends the job, and so the node and MCP servers
  a CLI started, and when Yardlet exits Windows ends whatever is left in its jobs.
- **Application and message loop.** `Windows/Bindings/Sources/WinUIApplication/XamlApplication.swift` is the
  application type the app derives from. Its `main()` starts the Windows App Runtime through the Windows App SDK's
  bootstrapper, creates the application as the type `@main` names, and runs the thread's message loop. Between
  messages the loop waits for the next one, the main dispatch queue's event or Foundation's next timer, so Swift's
  main actor runs on the window's thread and an idle window uses no processor time.
- **The WinUI bindings.** [swift-winrt](https://github.com/thebrowsercompany/swift-winrt) generates them from the
  metadata (.winmd) in Microsoft's NuGet packages (the Windows App SDK 1.7.250909003, the Windows SDK contracts and
  WebView2), whose versions and SHA-512 hashes `Windows/Bindings/projections.json` pins. It projects the types that
  file includes and every type their members reach, into `Windows/Bindings/Generated/`, which git ignores; the
  bindings are generated before a build, not kept in the repository. `Windows/Bindings/Package.swift` links them
  into the executable, not into DLLs, and a release build optimizes them for size without reflection metadata.
  swift-winrt's exclusions are not used: it still writes members whose generic arguments name an excluded type.
- **The bootstrapper.** The app links the Windows App SDK package's x64 import library for
  `Microsoft.WindowsAppRuntime.Bootstrap.dll`, and `Windows/scripts/place-bootstrapper.ps1` puts the DLL from the
  same package beside the executable, as the Windows App SDK's build targets do. The Windows App Runtime 1.7 is
  installed on its own, as for any unpackaged WinUI app.

On Windows, with Swift 6.4.1 and Visual Studio's C++ tools (swift-winrt is C++):

```powershell
Windows/scripts/generate-bindings.ps1
swift build --product NativeHarnessClient --force-resolved-versions
Windows/scripts/place-bootstrapper.ps1 -Binaries (swift build --show-bin-path)
```

`windows-engine.yml` builds the Windows app for the same pull requests and branches, beside the
engine, as a check to read. `windows-app.yml`, for `windows-*` branches only, builds a release, opens it on the
runner, measures it and types Korean into its composer through the Microsoft Korean IME
(`Windows/scripts/check-window.ps1`). It then starts the relay (`relay/`) and the fixture host on it
(`Windows/scripts/start-remote-host.ps1`) and, in the same step, since a Windows runner ends the programs a step
started when the step ends, pairs the app with the host through Connect to a Mac, opens a task, sends a message and
waits for the answer to stream in (`Windows/scripts/check-remote.ps1`, through UI Automation). It installs a
stand-in harness the way npm installs one (`Windows/scripts/fake-harness/`, whose `kimi.cmd` npm itself writes into
`%APPDATA%\npm`) and opens the app with `YARDLET_QA_HARNESS_CHECK=kimi-code` (`WinUI/QAHarnessCheck.swift`, a QA
variable like `YARDLET_QA_EVENT_LOG`): the app finds the shim as a new task would and runs the engine's verification
probe on it, which starts it through Node.js for `--version` and the ACP handshake and stops it. The stand-in starts
a detached process of its own, which outlives a stop of the stand-in alone, as the check shows first without the
app; the check passes when that process ended with the app's stop (`Windows/scripts/check-harness.ps1`). With that
stand-in, which serves one ACP turn that asks to edit a file, the app then starts a task from New task, allows the
request from its card, opens the edit's line to its diff, waits for the answer to stream in, and opens again to find
the answer kept; a second turn is then stopped with Stop while it waits on its request, which must reach the stand-in
as ACP's `session/cancel`, end the turn and leave the stand-in running (`Windows/scripts/check-local.ps1`); while the stand-in runs, no console window opens beside the ones already there,
which a console program started on its own first shows the count would see. That task is then served to phones
on the engine's client connection (`yardlet-remote-fixture --pair`, `Windows/scripts/check-remote-host.ps1`): the app
neither listens nor holds a room while the remote is off, turns it on in Settings › Remote, pairs and copies the link;
one phone pairs from the link without its relay and so over the runner's own network address, another from a new link
without its direct addresses and so through a local relay, and each lists the tasks and has a message answered,
allowed on the app's card. A .NET WebSocket shows the listener refuses a browser's handshake and closes a text frame
with 1003; the phones are listed among the devices, and turning the remote off closes the listener, a connection
still open and the room. The runner's phone reaches the listener from the same computer, which Windows' firewall
does not filter, so what another device on the network needs is the firewall's permission above. The run
gathers the app with its resource folder and the Swift runtime beside it, opens what it gathered from another folder with the
build folder out of reach, and uploads it (`windows-app-bin`), to open on a PC that has the Windows App Runtime 1.7 but
no Swift.

**Why the screens are Swift.** Before the app target, the same window (sidebar, conversation, composer) was built in
Swift and in C# with WinUI 3 and opened on a GitHub Actions Windows runner (2026-10-31). Both held 28–30 MB of private
memory idle and sent Korean typed through the Microsoft Korean IME as typed. C# with Native AOT shipped 6.6 MB and built
in under a minute; Swift shipped a 50 MB executable with its bindings, plus the Swift runtime (56 MB, 37 MB of it ICU,
which the engine needs in any case), and built in about five minutes. Swift was chosen because its screens share the
engine's module and `@Observable` models; C# screens would need a layer that carries the engine's state and events,
and would ship the Swift runtime all the same.

**The generator's version.** `Windows/Bindings/swift-winrt.json` pins swift-winrt at commit `3b20c713`, six commits
after its latest tag `v0.1.404` (`79ffa65c`); they fix dangling pointers in the include filter the bindings rely on
and leaked ownership in generated bridges. `generate-bindings.ps1` builds swift-winrt from that commit, because its
builds are published to a package feed that needs a sign-in, and stops if the checkout is at any other commit.
swift-winrt is still at v0.1, is maintained in practice by one company, and that company archived its prebuilt WinUI
bindings (`swift-winui`, `swift-windowsappsdk`) in October 2025, so the version stays pinned and moves only on purpose.

A fix the app needs before swift-winrt merges it goes on the pinned commit as a patch in
`Windows/Bindings/swift-winrt-patches/`, which `generate-bindings.ps1` applies in name order, is offered upstream as a
pull request, and comes out once a pinned commit includes it. The patches carry one fix now: a projected object passed
where WinRT takes an `Object` goes as itself rather than as a wrapper made for the call, so the callee sees its COM
identity (without it, `IVector<Object>.IndexOf` does not find an item appended through the bindings, such as one in
`NavigationView.MenuItems`). The same patch keeps what that change would otherwise break: the runtime class name of a
Swift subclass of a class without overridable methods, and resolving a weak reference that WinRT holds to a projected
object. The second patch is their tests in swift-winrt's own test app. When the pin or the patches change on a
`windows-*` branch, `swift-winrt-tests.yml` builds swift-winrt and runs its tests twice: with the tests
alone, which must fail and so show what the fixes are for, and with the fixes, which must pass.

**If swift-winrt stops being maintained,** in this order: keep the pinned version, which keeps generating the same
bindings; fork it and keep only the fixes the app needs; as a last resort, write the screens in C# with WinUI 3 and
keep the engine in Swift, which needs a layer that carries the engine's state and events to the C# screens.

**What the Windows app does not have yet:** a Windows layer for the rest of what `Platform/Portable/` stands in for:
the ConPTY terminal for sign-in and the terminal panel, notifications, and credential storage for the vault and
Antigravity; a request's answers given in a form (questions, a plan's review); a new task's account, attachments,
worktree and slash commands; and a browser host. A
connector's program gets a POSIX environment (`Connectors/ConnectorProgram.swift`), and npm's `npx.cmd`, which is not
one of npm's shims, is refused. A host's window shows a request card's words without its answers, and none of the
host's panels, new tasks or Settings. The remote has no relay account to sign in to or link through
(docs/REMOTE_PROTOCOL.md, "12.1 Linking through an account"), and nothing that keeps the computer awake on power. Until Foundation
there hands frames over whole (swiftlang/swift-corelibs-foundation#5255), its relay socket cannot tell a frame that
does not decrypt from a piece of one: a paired device that sends such a frame holds the frames after it, other phones'
too, until the bytes reach the limit (4 + 65,535 bytes) and are dropped, and a phone whose frame was dropped is out of
step with its cipher's nonce and has to connect again.

## The check that blocks new violations

`Tests/NativeHarnessClientTests/EnginePortabilityTests.swift` scans every engine file.

- It looks for forbidden imports (SwiftUI, AppKit, UIKit, Cocoa, WebKit, SwiftTerm, Darwin, Security,
  UserNotifications, CryptoKit, CoreServices, Carbon, ServiceManagement, IOKit, CoreGraphics, QuartzCore, Combine,
  OSLog and os) and macOS-only API rules: names qualified with `Darwin.`, POSIX process control (signals, `waitpid`,
  `pid_t` and the like), `proc_*` and `sysctl`, PTY functions, `posix_spawn`, `copyfile` and cloning, Keychain, `UN*`
  notification types, AppKit types, FSEvents and kqueue, Foundation APIs missing outside Apple platforms
  (`NSDataDetector` and others) and `x-apple.` URLs. Line comments are skipped.
- The allow list is a set of rule names per file, and it is empty. The ceiling is 0.
- A violation in a file that is not on the allow list, or a new kind of violation in an allowed file, fails.
- Path assumptions and `Process` semantics (below) are string and behavior problems, so they are not in the check.
- The engine-only build is the stronger check: it fails on any engine reference to a screen or macOS-layer name, which
  the scan cannot see. Every pull request that changes code makes it on Windows (`windows-engine.yml`), as a check to
  read.

## What a Windows layer needs

| Part | macOS today | What Windows needs |
| --- | --- | --- |
| `NativeProcessTree` | Collects descendants with `proc_listchildpids` and ends the tree with `kill` (also on the process group), `waitpid` and `usleep`. Every harness transport, Git, the account commands and the protocol process host start processes with `run(_:)` and end them with `terminate(process:)` | Provided (`Platform/Windows/NativeProcessTree.swift`). Foundation's `Process` creates no job object on Windows, and `terminate()` ends only the root with `TerminateProcess`, so grandchildren such as node and MCP servers would stay behind (confirmed: [swift-corelibs-foundation `Process.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/Process.swift)). `run(_:)` puts each process in a job object of its own (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) right after it starts, `terminate(process:)` ends it with `TerminateJobObject`, and a job is closed once a completion port reports its last process ended. Foundation's `Process` takes no creation flags, so a process the child starts in the moment before it is in the job stays outside it |
| `AccountLoginController` | A `LocalProcessTerminalViewDelegate` driving a PTY through SwiftTerm, `NSWorkspace.open`, URL detection with `NSDataDetector`. The engine keeps the output parsing (`Account/AccountLoginOutput.swift`: `stripANSI`, device codes, input prompts) | A ConPTY (`CreatePseudoConsole`) host with the members the portable one has. Find URLs with a regular expression, because `NSDataDetector` does not exist in Foundation outside Apple platforms (confirmed: [swift-corelibs-foundation #4305](https://github.com/swiftlang/swift-corelibs-foundation/issues/4305)) |
| `NativeTerminalSession`, `TaskShellProcess` | SwiftTerm `LocalProcess` and a PTY | ConPTY and a Windows terminal view |
| `ScopedFiles`, `WorkspaceFileReplacement` | No-follow descriptors | Opening without following reparse points (`FILE_FLAG_OPEN_REPARSE_POINT`); the portable versions refuse |
| `CanonicalPath` (`Files/CanonicalPath.swift`) | `realpath(3)` | An opened file's final path (`GetFinalPathNameByHandleW`); for now Foundation resolves the links |
| The file chooser's private copy (`BrowserAgentDialogs.privateCopy`) | `openat` one folder at a time without following links | The same with reparse points refused; refused on Windows until then |
| Removing an account folder's links (`ClaudeAccountHome.unlinkShared`) | `unlink(2)`, which never follows the link | `DeleteFileW` for a file link and `RemoveDirectoryW` for a folder link, never a recursive removal; refused on Windows until then |
| Claude Code's background task output (`ClaudeTaskOutputReader`) | `claude-<uid>` under the temporary folders | Where the CLI keeps it on Windows is not confirmed; nothing is looked up there |
| SQLite | The macOS SDK's libsqlite3 | Windows's own `winsqlite3` with the Windows SDK's header (`Sources/CSQLiteWindows`), chosen in `Package.swift` when building on Windows |

Other macOS-specific values that the check does not catch:

- `Domain/HarnessKind.swift`: `symbolName` holds SF Symbols names. The screen layer should pick the icon by harness ID;
  Windows uses the logo assets.
- `Account/HarnessAccountBroker.swift`: the user-facing text names macOS Keychain as the Antigravity CLI credential
  location. Where Antigravity CLI keeps credentials on Windows is not confirmed.

## Paths and executable lookup

| Where | Assumption | Recommended handling |
| --- | --- | --- |
| `Runtime/RuntimeProcessEnvironment.swift` | Splits and joins `PATH` with `:`. Fixed `~/.local/bin`, `~/.bun/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and the system folders; `searchDirectories` adds package managers' folders (`~/.volta/bin`, `~/.cargo/bin`, `~/.deno/bin`, `~/.npm-global/bin`, `~/Library/pnpm`), nvm's `~/.nvm/versions/node/*/bin` and Docker Desktop's `bin` | On Windows (`Runtime/ExecutableLookup.swift`): `Path` split and joined with `;`, each folder once in any case, a variable's name read and replaced in any case and the search path named `Path`, `USERPROFILE` as home. A runtime gets its own folder, `%USERPROFILE%\.local\bin`, `%USERPROFILE%\.bun\bin` and `%APPDATA%\npm` ahead of `Path`; `searchDirectories` looks in those, `%LOCALAPPDATA%\pnpm`, `.cargo\bin`, `.deno\bin` and Scoop's `scoop\shims`, then `Path` |
| `Runtime/RuntimeSelectionStore.swift`, `Runtime/RuntimeRelocation.swift` | Install candidates are `searchDirectories`, the ChatGPT app's bundled Codex under `/Applications/ChatGPT.app` and the Claude app's `~/Library/Application Support/Claude/claude-code/…`; relative paths are split at `/` | On Windows a candidate without an extension is the program it names with PATHEXT's extensions Windows starts, `.exe` and `.com` before `.cmd` and `.bat` (`ExecutableLookup.program(at:)`, which the adapters' and the task's runtime checks also use), and Antigravity's `agy.exe` counts as `agy`. The desktop apps' bundled runtimes are looked for at their macOS paths only: where they keep them on Windows is not confirmed |
| `Domain/HarnessKind.swift` | `relativeExecutablePaths` are POSIX paths without extensions (`.local/bin/codex`, `.hermes/hermes-agent/venv/bin/hermes` and others) | The extension comes from the lookup above; a Python virtual environment's program is in `Scripts` on Windows (`HarnessCatalog.virtualEnvironmentProgram`) |
| `Diff/GitExecutableLocator.swift` | `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/opt/local/bin/git`, then `/usr/bin/git` | On Windows (`windowsCandidates`): `git.exe` in the folders of `Path` that are absolute, then where Git for Windows is installed for everyone (`%ProgramFiles%\Git\cmd`, `%ProgramFiles(x86)%\Git\cmd`), for one person (`%LOCALAPPDATA%\Programs\Git\cmd`) or by Scoop (`%USERPROFILE%\scoop\apps\git\current\cmd`) |
| `Diff/GitDiffService.swift` | `/dev/null` as a Git argument (`hash-object -t tree`, `diff --no-index`) | Whether Git for Windows accepts this path is not confirmed. For the empty tree, a way without a path, such as `git hash-object -t tree --stdin`. The `/dev/null` that `UnifiedDiffParser` reads is Git's output format and stays |
| `Files/PathRules.swift`: `isReadAsAnotherNameOnWindows` | A name is the file or folder its text spells | On Windows a name that ends in a period or a space is read without them, and a device's name (`NUL`, `CON`, `COM1`, also before an extension or a colon) is that device in any folder. The text of a path with such a name does not say where it leads, so the path is in no folder (`relativePath(of:in:)` is nil) |
| `Files/PathRules.swift`: `isAbsolute`, `isRelative`, `names`, `url(for:in:)` | An absolute path starts with `/`, and `/` separates names | One rule for every engine check. On Windows an absolute path starts with a drive (`C:\`, or `/C:/` as a file URL's path writes it) or names a share (`\\server\share`, also in the `\\?\` forms), `\x` and `C:x` are neither absolute nor relative, and `\` and `/` both separate names. Paths from another computer (a remote host's, a personal agent's execution host's) keep their own checks |
| `Files/PathRules.swift`: `relativePath(of:in:)`, `isInside`, `isStrictlyInside` | Whether a path is in a folder is decided by whole names after `.` and `..` are taken out by their text, never by a string prefix; nothing is looked up, so a check that must not follow links resolves them first. macOS and Linux compare names as Swift compares strings | On Windows names compare in any case, one character for one, as NTFS compares them, and keep their composition. The Windows rules are pure functions over strings, so the Mac tests run them (`WorkspaceFileTests`). A folder's identity (which project a task is in, a sidebar group, the tasks in one folder) compares `ProjectSidebarPresentation.folderKey`, which is `PathRules.key`: on Windows `C:\Repo`, `c:/repo` and `\\?\C:\Repo` are one folder, and on macOS the key is the path as written, as before. What is shown and passed to a CLI keeps the path's own spelling (`normalizedPath`) |
| `Account/HarnessAccountBroker.swift` | Finds the Grok home from the `HOME` environment variable (usually missing on Windows) | Use `homeDirectoryForCurrentUser` |
| `Store/SessionRepository.swift`, `Domain/ProviderSessionTitleResolver.swift` | Pass the `URL.path(percentEncoded: false)` string to SQLite | `withUnsafeFileSystemRepresentation`. Whether `path()` becomes `/C:/…` on Windows is not confirmed |

Foundation also provides `~/.yardlet`, `applicationSupportDirectory` and `UserDefaults` on Windows. The actual storage
location there (AppData, the registry and so on) is not confirmed.

## Foundation `Process`, `FileHandle` and file permissions on Windows

| Item | Windows behavior | Recommended handling |
| --- | --- | --- |
| `Process.run()` | Quotes the arguments by MSVCRT's rules and passes the command line to `CreateProcessW` with no application name and only `CREATE_UNICODE_ENVIRONMENT` (confirmed in its source). `CreateProcessW` starts a `.cmd` or `.bat` through `cmd.exe`, which reads the arguments by its own rules (the BatBadBut family) | Yardlet never starts a batch file: lookup prefers a real `.exe`, and for npm's shim (cmd-shim's format, `Runtime/NPMCommandShim.swift`) `NativeProcessTree.run(_:)` starts Node.js, the `node.exe` beside the shim or else the first in `Path`, on the script under `node_modules` the shim names, with the same arguments. Any other batch file is refused with an error that says so |
| `isExecutableFile(atPath:)` | swift-foundation decides with `SHGetFileInfoW(SHGFI_EXETYPE)` | Not used on Windows: a program is a file with one of PATHEXT's `.exe`, `.com`, `.cmd` and `.bat` (`ExecutableLookup`). Whether `SHGetFileInfoW` treats a `.cmd` as executable is not confirmed |
| `terminate()` / `interrupt()` | Both are `TerminateProcess` and end only the root (confirmed) | `NativeProcessTree.terminate(process:)` ends the job above. A turn stops through the harness's own cancel, which ends no process: Codex's `turn/interrupt`, Claude Code's `interrupt` control request, ACP's `session/cancel`, Pi's `abort` and MSP's `turn/interrupt`. Only Cursor Agent's print mode, whose turn is the process itself, has no cancel; `Adapters/Headless/StructuredHeadlessAdapter.swift` stops it with `NativeProcessTree.interrupt(process:)`, SIGINT on macOS and Linux and the end of the process's job on Windows. Windows has no SIGINT, and a Control-C or Control-Break event would reach every program in the console the app's children share. Whether Cursor Agent keeps a turn stopped that way in its chat is not confirmed |
| A write to a child's standard input after it stopped reading | No SIGPIPE on Windows: the write fails with an error | `Runtime/ChildInputPipe.swift` (`Pipe.childInput()`, used for every child's standard input) sets `F_SETNOSIGPIPE` on macOS only (`#if canImport(Darwin)`), so a CLI that exits before it reads fails the write instead of ending Yardlet. Linux has no such flag: ignore SIGPIPE in the app and restore it for children. Every writer already handles the error. It also marks Yardlet's end close-on-exec, because a terminal's shell is forked with everything Yardlet has open, and a shell that outlived Yardlet would keep the child's input open. On Windows the same end must not be inheritable by other children; whether Foundation's pipes are is not confirmed |
| `readabilityHandler` | Supported through `DuplicateHandle`, `_open_osfhandle` and a Dispatch read source (confirmed: [`FileHandle.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/FileHandle.swift)) | No change needed |
| `process.environment` | Windows environment variable names are case-insensitive. Foundation adds the app's own `Path` to a child's environment that has none under exactly that name (confirmed in its source) | `NativeProcessTree.run(_:)` names each variable once, the search path as `Path` (`ExecutableLookup.normalized`) |
| `.posixPermissions` 0o600 and 0o700 (private files such as provider connections, drafts and the vault: `ProviderConnections`, `ComposerDraftRepository`, `VaultCenter` and others) | There are no POSIX modes, so access by the user alone is not guaranteed | Store under the user profile with an ACL. How Foundation applies this attribute on Windows is not confirmed |

## External dependencies

| Dependency | Engine use | Windows | Evidence | Recommended handling |
| --- | --- | --- | --- | --- |
| swift-markdown 0.8.0 (swift-cmark 0.8.0) | `Transcript/TranscriptInlineContent`, `Transcript/TranscriptMarkdownDocument`, `Diff/MarkdownReviewDiff`, `Domain/TaskAttention` | The manifest has Windows-specific settings. Builds on Linux (confirmed); Windows not confirmed | `CMARK_GFM_STATIC_DEFINE` `.when(platforms: [.windows])` in swift-markdown's `Package.swift`, `#if os(Windows)` in swift-cmark's `Package.swift` | Keep it in the engine |
| swift-crypto 5.0.3 (in place of CryptoKit) | `CodexEnvironmentManager`, `ClaudeSubagentTranscriptReader`, `YardletRemote` | Windows builds in its own CI; its README names ARM64 Windows. Not confirmed with Yardlet's build | Builds on Linux (confirmed) | Keep |
| SwiftTerm 1.18.0 | None; the macOS layer and screens only | Only the terminal parser builds. No PTY or view (confirmed) | The manifest's `os(Windows)` branch leaves out the `Apple`, `Mac` and `iOS` sources, and `LocalProcess.swift`, `Pty.swift` and `HeadlessTerminal.swift` are under `#if !os(iOS) && !os(Windows)` | The Windows terminal uses ConPTY and a Windows view |
| Sparkle 2.10.1 | None; only the macOS layer imports it (`Platform/macOS/YardletSparkle.swift`), and it is linked only on macOS (`.when(platforms: [.macOS])`) | Not used | `Package.swift` | Windows needs its own update mechanism |
| CSQLite (`systemLibrary`, `link "sqlite3"`; on Windows a C target linking `winsqlite3`) | `Store/SessionRepository`, `Domain/ProviderSessionTitleResolver` | Windows ships SQLite as `winsqlite3.dll` with the header in the Windows SDK. Builds on Linux with the system's libsqlite3 (confirmed) | `Package.swift`, `Sources/CSQLite/module.modulemap`, `Sources/CSQLiteWindows` | Keep the system's SQLite on each platform |
| Observation | Many `@Observable` models | A Swift toolchain module, imported explicitly outside Apple's platforms. Builds on Linux (confirmed) | The Linux build | Keep as is |
