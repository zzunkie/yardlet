# Engine portability

Yardlet runs on macOS. Windows is in progress: the engine is kept in cross-platform Swift, and each platform gets its
own screens. The engine builds on its own on macOS, Linux and Windows. On Linux it is also a headless host, `yardlet
host`, which serves the computer's tasks to the other apps over the remote (docs/LINUX_HOST.md). The Windows app, the engine with WinUI 3
screens ("The Windows app" below), builds and opens its window on Windows, finds, starts and ends harness CLIs by
Windows' rules, signs in to them, starts tasks of its own with them and reads their saved history, answers
their requests in the Mac's forms, notifies when a task waits or finishes, follows another computer's Yardlet over the
remote protocol, and serves its own tasks to other devices from Settings › Remote; what it does not have yet is listed
at the end of that section. For dependencies and Foundation behavior on Windows, what was checked
in the official source or a build is marked "confirmed"; the rest is "not confirmed".

## Engine and platform layers

- **Engine:** every Swift file of the `NativeHarnessClient` target and of `YardletAgentTools` (the library the app
  shares with the Yardlet MCP server, `yardlet-mcp`), except the screen and platform layers below. New folders count as
  engine by default.
- **Screen and platform layers (outside the check):** `Views/`, `WinUI/` (the Windows app's screens), `Browser/` (the
  WebKit preview), `Development/` (visual fixtures and QA), `Platform/` and `NativeHarnessClientApp.swift`.
- Engine code names the platform's parts directly, and each platform defines them under the same names in its own
  folder: `Platform/macOS/` for the Mac app, `Platform/Windows/` for the Windows app, `Platform/Linux/` for the Linux
  host, `Platform/POSIX/` for what the Mac app and the Linux host build from the same POSIX calls, and
  `Platform/Portable/` for a build of the engine on its own and for what the Windows and Linux layers do not
  provide yet. Some parts
  are protocols the engine owns with a platform's implementation (`LocalSystemNotificationCenter` implements
  `SystemNotificationCenter`, `LiveProcessTable` implements `ProcessTableReading`); others are types or extensions the
  engine calls by name. The app's model is put together in `Platform/macOS/AppModel+Live.swift`, which hands the engine
  the Mac's browser host; the Windows app's in `Platform/Windows/AppModel+Live.swift`, and the Linux host's in
  `Platform/Linux/AppModel+Live.swift`.

## Building the engine on its own

```sh
YARDLET_ENGINE_ONLY=1 swift build --build-system native --target NativeHarnessClient --force-resolved-versions
```

With `YARDLET_ENGINE_ONLY=1`, `Package.swift` turns the app target into a library that leaves out `Views/`, `WinUI/`,
`Browser/`, `Development/`, `Platform/macOS/`, `Platform/Windows/`, `Platform/Linux/`, `Platform/POSIX/` and
`NativeHarnessClientApp.swift`, and drops the
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
| `ScopedFiles` | Reading Claude's transcripts and a restore's files without following links; reading the file it opens in parts (`OpenFile`, `Files/OpenFile.swift`) is engine code | `openat` with `O_NOFOLLOW` (`Platform/POSIX/`) |
| `WorkspaceFileReplacement` | Saving a reviewed workspace file, from the Files panel and from another device (docs/REMOTE_PROTOCOL.md §15.27) | no-follow descriptors, `renameat` (`Platform/POSIX/`) |
| `FileCloning`, `Trash`, `FileTypes` | Block-sharing copies, the Trash, file types | `copyfile`, `trashItem`, UTType |
| `ShellLaunchEnvironment.userLoginShell` | The person's login shell | the user database |
| `ClaudeConversationCatalog.runningSessionIDs` | Which Claude Code sessions run elsewhere | `kill(pid, 0)`, `sysctl` |
| `HarnessAccountBroker.antigravityCredentialState` | Whether Antigravity is signed in | Keychain |
| `AccountLoginController`, `NativeTerminalSession`, `TaskShellProcess` | The sign-in terminal, each terminal tab's shell, bash mode's shell | SwiftTerm and a PTY |
| `BrowserPreviewModel`, `ConversationRenderState` | A tab's preview page, the conversation's cached turn views | WebKit, AppKit |
| `RemoteHostPlatform.current`, `LidSleepHelper` | The phone remote's listener, interfaces, network changes and keeping the computer awake; the lid helper | Network.framework, BSD sockets, a process activity, XPC |

The phone remote itself, `RemoteControlService` (`Remote/RemoteControlService.swift`), is engine code on every
platform, with its keys behind `RemoteIdentityStoring`: the Keychain on the Mac, Credential Manager on Windows.

The Windows layer provides `NativeProcessTree` (`Platform/Windows/NativeProcessTree.swift`),
`RemoteHostPlatform.current` (`Platform/Windows/WindowsRemoteHost.swift`), `LocalSystemNotificationCenter`
(`Platform/Windows/WindowsNotifications.swift`), `HarnessAccountBroker.antigravityCredentialState`
(`Platform/Windows/WindowsAccounts.swift`), `ScopedFiles` (`Platform/Windows/WindowsScopedFiles.swift`) and
`WorkspaceFileReplacement` (`Platform/Windows/WindowsWorkspaceFileReplacement.swift`), so the Windows app leaves
`PortableProcesses.swift`, `PortableRemoteHost.swift`, `PortableNotifications.swift`, `PortableAccounts.swift`,
`PortableScopedFiles.swift` and `PortableWorkspaceFileReplacement.swift` out (`portableFilesWindowsReplaces` in
`Package.swift`).

`Platform/POSIX/` holds `ScopedFiles` and `WorkspaceFileReplacement`, written once on the calls Darwin and Glibc share,
so the Linux host reads Claude Code's transcripts and saves a reviewed file with the Mac's own code. A read opens the
root as it is, a link included, then each name beneath it with `O_NOFOLLOW` through the descriptor of the folder above
it, and refuses a pipe or device before reading it. A save walks to the file's folder the same way from a root that is
not a link, and only while the file still holds the reviewed bytes puts a new file written beside it in its place with
`renameat`. As with an editor's save, the file is then modified at the time of the save. The two systems differ only
in what a save keeps beyond the bytes: on the Mac everything `fcopyfile` copies as metadata (permissions, owner, flags,
ACL and extended attributes, but not the old times) and the creation date, on Linux the file's permissions. With
`NativeProcessTree` (`Platform/Linux/NativeProcessTree.swift`) and `RemoteHostPlatform.current`
(`Platform/Linux/LinuxRemoteHost.swift`), the Linux host leaves
`PortableProcesses.swift`, `PortableRemoteHost.swift`, `PortableScopedFiles.swift` and
`PortableWorkspaceFileReplacement.swift` out (`portableFilesLinuxReplaces`). The Windows app and the engine-only build
leave `Platform/POSIX/` out.

`Platform/Portable/PortableFoundation.swift` also holds the few names Foundation outside Apple's platforms lacks
(`InlinePresentationIntent`, Combine's `ObservableObject` and `Published`, `autoreleasepool`), and
`URLSession.bytes(for:)`, which there streams a response's body through a delegate and refuses redirects, as the app's
own sessions do.

**Foundation outside Apple's platforms.** Where the engine uses something only Apple's Foundation has, it keeps that
under `#if canImport(Darwin)` and says the same thing another way elsewhere: `L10n` takes plain string keys,
`RelativeTime` uses `Date.RelativeFormatStyle`, `NSNumber` tells JSON booleans and fractions apart by `objCType`
(`Domain/JSONNumberKind.swift`), Gmail's charsets go through `String.Encoding(ianaName:)`. Files that use `URLSession` import
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
alone (`RemoteHostPlatform.current` in `Platform/Portable/`). `RemoteAddressSelection` builds everywhere: it reads an
address with `inet_pton`; the Mac lists its interfaces with `getifaddrs`, Windows with `GetAdaptersAddresses` and
watches them with IP Helper's change notifications, and both look up the MagicDNS name. The rest of `YardletRemote`
builds: its random bytes fall back to `SystemRandomNumberGenerator`, its free-space check to
`attributesOfFileSystem`, and `RemoteHandshakeAdmission.host(of:)` exists only with Network.framework. Foundation there hands a
WebSocket frame over in the pieces libcurl reads it in, each as a message of its own (`WebSocketURLProtocol` drops
`curl_ws_meta`'s `bytesleft`), so the remote's sockets join a piece that does not read (a Noise frame that does not
decrypt, a relay message that is not JSON) to the next one before reading it again, up to the frame's limit
(`RemoteFramePieces`); with Apple's Foundation a frame that does not read is refused at once.

**Where it is built.** On Linux in the `swift:6.4-bookworm` image, in GitHub Actions:
`.github/workflows/linux-engine.yml` makes the build in that image, pinned by digest, for the same pull requests and
`main` as the Windows build below, as a check to read. It catches a name only Darwin has (`memmem`, for one, which
Glibc's module leaves out). On a Mac, a folder on the desktop cannot be mounted into Docker,
so the sources go in as an archive:

```sh
tar --exclude ./.build --exclude ./.git --exclude ./docs -cf - . | docker run -i --rm swift:6.4-bookworm bash -c \
  'mkdir /src && tar -xf - -C /src && cd /src && YARDLET_ENGINE_ONLY=1 swift build --target NativeHarnessClient'
```

On Windows (x64, Swift 6.4.1 from swift.org's installer) in GitHub Actions:
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
`Platform/Portable/`, `Platform/Windows/` and the screens in `WinUI/`, in one module as on the Mac. As for the Linux
host, the package there leaves out the Mac's own targets: the browser host's parts and the lid helper. The Mac's build and
the engine-only builds leave `WinUI/` and `Platform/Windows/` out. When the Windows layer comes to provide one of
`Platform/Portable/`'s parts, the Windows app leaves that portable file out.

- **Assembly.** `Platform/Windows/AppModel+Live.swift` makes the model with its stores in `%LOCALAPPDATA%\Yardlet`
  and no browser host. `WinUI/YardletApp.swift` makes it once WinUI has started and opens `WinUI/MainWindow.swift`,
  framed as Windows 11's own apps frame their windows (`WinUI/WindowChrome.swift`): Mica behind it, the content up to
  a tall title bar of Yardlet's own with Yardlet's mark and the window's title, and Windows' caption buttons. Its
  colors and measures are the Mac's (`WinUI/WindowsTheme.swift`, from `ParityTheme`), light or dark as Windows is set;
  pictures the app carries, such as the harnesses' marks, are read from their files (`WinUI/PackagedImage.swift`),
  since XAML does not load a `file:` URI from a folder whose path holds characters beyond ASCII. The window's sidebar
  (`WinUI/TaskSidebar.swift`) is the Mac's: Home and Search tasks at the top, then Pinned, Chats and Projects, each
  project under its name, which collapses it and opens its menu, listing five tasks until Show more, and each task
  nested under the task it was started from, with its harness's mark, its title (semibold while unread, until the
  window shows it) and its state at the end. What it lists, in what order and with what state is the Mac's reading
  (`SidebarProjection`, `SidebarTaskIndicatorProjection`), followed through Observation; a row whose state changes is
  redrawn in place and a list is filled again only when its rows change. A task's and a project's menus are the Mac's,
  with Show in File Explorer for Show in Finder (`WinUI/TaskActions.swift`); the search narrows by titles and project
  names. With no task the window opens New task, as the Mac opens its home. Above a task's conversation, its header
  (`WinUI/TaskHeader.swift`) is the Mac's: the title, which opens the task's menu, the harness, and a progress ring
  while it works. The Mac's Task menu keys work with Ctrl for ⌘ and Alt for ⌥ (`WinUI/TaskKeys.swift`): Ctrl+N,
  Ctrl+Shift+[ and ], Ctrl+Alt+A, Ctrl+Alt+P, Ctrl+Shift+U, Ctrl+Shift+A and Ctrl+Shift+M, the Mac's Control+Shift+M
  for the model menu, and F2 renames the shown task as Windows renames what is chosen; Ctrl+Alt keys pressed with AltGr
  are left to typing. Below the conversation is the task's
  composer as the Mac's (`WinUI/TaskComposer.swift`, `WinUI/ComposerParts.swift`): a
  rounded card at most as wide as the conversation, its text above a bottom row with the task's session controls
  (the mode or Codex's Plan indicator, the permissions and the model menu, from `ComposerSessionOptionsProjection`,
  in Windows' own menus, `WinUI/ComposerOptionChips.swift`), the context ring where the harness reports its window,
  and Send, which Stop replaces while the turn runs and which stops it through the harness's own cancel
  (`AppModel.interrupt`). While a turn runs, Enter sends as the follow-up setting says, steered into the turn or
  queued for after it, Ctrl+Enter sends the other way, and the queue-or-steer button beside Stop chooses either; the
  queued messages stand above the text with the Mac's actions for each (`ComposerQueueChip`), and Escape denies a
  waiting tool approval or stops the turn. "+" at the start of the bottom row adds files or photos and folders
  through Windows' own dialog, and a paste of copied files or of a picture with no text joins the draft rather than
  the text (`WinUI/ComposerAttachments.swift`, `Platform/Windows/WindowsClipboard.swift`): each is taken as the Mac's
  pickers and paste take it (`ComposerAttachmentIntake`, `ComposerDraftEditing.attachPastedImage`), a picture an app
  offered only as a bitmap is made a PNG first (`DeviceIndependentBitmap`), and each stands as a chip above the text,
  an image as its thumbnail. The Mac's slash commands and connectors in "+" are not on Windows yet. The composer
  holds the task's draft, the one the Mac's composer edits,
  and Send sends that draft (`AppModel.sendDraft`), taking the message as the Mac's composer takes it
  (`TaskComposerDraft.takeMessage`) and sending it as the person's message, which also declines a request the task
  waits on (`AppModel.sendPersonsMessage`, docs/REMOTE_PROTOCOL.md, `sendMessage`): a message the task does not take
  comes back to it and the card says why, as the line above the card says that the task's folder is gone
  (`TaskFolderMissing`) once the task is shown or the window comes to the front. The composer redraws its controls
  only when what they show changes, not for every event a turn streams. As in the Mac's composer and the harnesses'
  own apps, Enter sends and Shift+Enter starts a new line (`WinUI/ComposerKeys.swift`); New task and a host's window
  have the same field and Send. New task, under Home (`WinUI/NewTaskPane.swift`),
  starts a task as the Mac's new-task screen does, from the Mac's home draft: a harness whose CLI Yardlet found,
  where it works (a project, a folder chosen in Windows' own folder dialog, `Platform/Windows/WindowsFolderPicker.swift`,
  or a chat with no project), and the model, effort and permission the harness takes before its task exists, from
  the menus the Mac's controls read and with the Mac's question before a choice that skips asking. Choosing a task
  reads its saved history as the Mac does (`refreshConversationStatus`, which starts no turn), and its conversation
  draws from the projection the Mac's timeline reads; a change to files opens to each file's diff.
- **Import conversation.** Import conversation, below the tasks (`WinUI/ImportConversationPane.swift`), continues a
  conversation a harness's own CLI or app started, as the Mac's File › Import conversation… does
  (docs/NATIVE_SESSION_STORAGE.md, "Importing conversations from other apps"): Claude Code, Codex, Antigravity CLI and
  each other ACP agent installed whose history Yardlet reads; a project's folder, or one chosen in Windows' folder
  dialog with Choose project…; and the account the harness's new tasks start on, with a menu when there are others.
  The list is the engine's (`AppModel.importableConversations`), each conversation with its title and when it was last
  active, and Load more history when the harness has more. Choosing one imports it, or finds the task that already
  continues it, and the main window shows that task with its row chosen; the task reads the harness's own history as
  it opens and attaches on the first send. A folder goes to a harness as Windows writes it (`PathRules.nativePath`,
  `C:\Users\me\proj`), not as a file URL's path (`/C:/Users/me/proj/`): ACP's `cwd`, which an agent compares
  character for character with the folder it saved a session in, and the name Claude Code gives the folder's history
  under `projects` (`C--Users-me-proj`), and every folder a Codex request names (`CodexProtocol.folderPath`: a thread's
  `cwd` as it starts, resumes and lists, its configuration, skills and plugins, and its other roots), which Codex
  resolves as a terminal's `codex` would. Without `CLAUDE_CONFIG_DIR`, Claude Code's
  config folder is `.claude` in the profile folder (`USERPROFILE`), as Node.js's `os.homedir()` finds it on Windows
  whatever `HOME` says. Codex's history search is the Mac's alone.
- **Conversations.** `WinUI/ConversationTimeline.swift` draws the engine's `ConversationPresentation` for a task's
  own conversation and a host's, in the Mac's column: at most 768 wide and centered, a 32 gutter, text at 14 with the
  Mac's spacing between lines, blocks and turns. Each turn is laid out as the Mac's (`WinUI/ConversationTurnElement.swift`):
  what was sent as the Mac's gray bubble on the right with no name over it, clipped past 20 lines; the header that
  folds a finished turn's work under how long it worked; runs of calls folded on their summary lines, which open into a
  ringed box with a line for each call (`WinUI/ConversationWorkLines.swift`); while the turn runs, one live line with
  what the provider does now, its steps and time; the answers; and how the turn ended, with Retry and sign-in where the
  Mac's error card offers them. The grouping, the summaries, the live line, the fold and where each line starts are the
  engine's (`ConversationWorkGrouping`, `ConversationWorkSummary`, `ConversationLiveWork`, `ConversationWorkDisclosure`,
  `ConversationTurn.drawsHeader`), and what the person opened stays open as a turn redraws. A line that opens is a
  toggle, which tells assistive apps whether it is open. A conversation opens at its latest turn and follows its end
  while the view is there. A turn that did not change keeps what it drew. As on the Mac,
  only the latest turns are drawn (`ConversationTurnWindow`, 10 at first) and Load more history draws 10 more, so what
  an update compares and draws in the window is bounded by those turns however long the history. Answers draw their
  Markdown from the engine's reading of it (`WinUI/MarkdownView.swift`, `TranscriptMarkdownDocument`): bold,
  italic, code, struck and linked words, lists, quotes, code blocks with their language, Copy and the Mac's colors
  (`TranscriptCodeSyntax`), tables and rules; code is in Cascadia Mono, or Consolas where it is missing. A message's
  copy shows while the pointer is over it or the keyboard's focus is in it. A file's change opens to the Mac's diff box
  (`WinUI/FileChangeView.swift`). Pictures are drawn as the Mac draws them (`WinUI/ConversationImages.swift`): a sent
  message's images as squares above its bubble, and a call's pictures (`ConversationTool.pictures`: its own, then its
  MCP result's) small at the end of its folded line and whole when it opens; one that cannot be read shows its name,
  and a click opens nothing yet, where the Mac opens its image viewer. A compaction is the Mac's marker between two
  rules, and a plan limit's card offers what the Mac's does from the same actions (`AppModel.providerNotices`):
  continuing under another account, continuing on its own when the limit resets, or Resume; the Mac's list of the
  limit's windows and its banked resets stay on the Mac (`WinUI/ConversationNotices.swift`). A turn's sent message
  offers Edit message where the turn can be edited (`ConversationTurnActions`), which starts the engine's edit in the
  composer (`AppModel.beginCodexEdit`, `AppModel.beginClaudeEdit`) with the Mac's banner and Cancel edit above it,
  and a failed turn's error card offers Edit request, which puts its request back in the composer. Sizes are the
  Mac's, except that none goes under 12, Windows' Caption size.
- **Requests.** `WinUI/RequestCard.swift` draws the `ConversationRequest` the Mac's request card draws, in its look,
  waiting or answered where it happened in the work: the request's mark on a tile in its state's color, the state over
  the title, what the request would do (an edit's diff, a file's new contents or a command,
  `PermissionRequestPreviewProjection`), and the provider's own options as the Mac's gray buttons, the prominent one in
  the accent; questions one at a time with their options as filled rows (radio buttons or check boxes), the picked
  option's preview beside them where the options have previews, the person's own answer, Skip and Next
  (`ConversationQuestionStepper`);
  a plan with what to change; and an MCP form field by field with what each field takes and why it cannot be sent yet
  (`CodexMCPElicitationForm`). An answer goes back by the route the form makes of what was entered
  (`ConversationRequest.route(for:input:)`), carried out as the Mac's card carries it out, and an answered form reads
  as its answers. The card's state title and an MCP field's words come from the engine, as the Mac's do. The timeline
  keeps one card per request, so a form keeps what was entered while its turn redraws.
- **Sign-in.** Each harness keeps its own login, and Yardlet runs its own sign-in and reads the result
  (`WinUI/HarnessSignIn.swift`). New task says when the chosen harness's account reads signed out and offers Sign
  in, by the reading the Mac's new task uses, and a turn that failed for its sign-in offers it too. Codex signs in in
  the browser as a Codex client starts it (`Account/CodexBrowserSignIn.swift`): its App Server's
  `account/login/start` hosts the callback and answers with the address Yardlet opens, and `account/login/completed`
  says how that login ended. Every other harness, and a Codex whose App Server starts no browser sign-in, runs its
  sign-in command (`HarnessAccountBroker.loginCommand`) in a console window of its own, which Windows opens in the
  default terminal (`Platform/Windows/WindowsSignInConsole.swift`); the CLI opens the browser itself, and the login
  is read again once the window closes, or while it is open for a CLI that stays open after signing in (Antigravity,
  Pi). Whether the Antigravity CLI is signed in is read from Credential Manager, where its keyring library
  (go-keyring, as on the Mac) keeps the generic credential `gemini:antigravity`; only whether it exists is asked.
- **Notifications.** The engine decides when to notify by the Mac's rules (`AppModel+SystemNotifications.swift`): a
  task that waits for an approval, finished a turn the person asked for, or failed, while it is not the task the main
  window shows. `Platform/Windows/WindowsNotifications.swift` posts them as the Windows App SDK's app notifications:
  none while a Yardlet window is in front, as the Mac shows none while Yardlet is active, an approval's with "Allow
  once", withdrawn once its request is answered, and a click brings the main window forward and shows its task
  (`Platform/Windows/WindowsApplicationAttention.swift`). Whether they show is the person's switch in Windows'
  Settings › System › Notifications, which the app reads; Windows asks no permission first. A new approval while
  Yardlet is behind flashes the main window's taskbar button until it comes forward, as the Mac bounces its Dock icon.
  The count of tasks that need the person, which the Mac's Dock badge shows, is an overlay icon on that button
  (`ITaskbarList3::SetOverlayIcon`, `Platform/Windows/WindowsTaskbarBadge.swift`): the number in white on a red disc,
  with the count as its spoken description. Windows' Settings › Personalization › Taskbar decides whether it shows.
  An app without a package registers at launch (`AppNotificationManager.Register()`), which writes its entry under
  `HKCU\Software\Classes` (`AppUserModelId` and the click's COM activator under `CLSID`) and takes its name and icon
  from its Start menu shortcut, else from its executable; removing the app calls `UnregisterAll()`, which removes the
  entry ("Installing and updating the Windows app" below). A click after the app
  quit opens it without choosing the task. The Windows App SDK offers app notifications only to a process that is not
  elevated (`AppNotificationManager.IsSupported()`, confirmed in its source), so Yardlet run as administrator shows
  none, nor does the app on a GitHub Actions runner, whose processes run elevated (its event log says
  `notifications: not supported`) unless the install check opens it at medium integrity.
- **Language.** The app's words follow Windows' display language, as WinUI's own controls do. Foundation outside
  Apple's platforms looks for the preferred languages only in `AppleLanguages`, which nothing writes on Windows, so
  it answered in English on a Korean Windows while WinUI drew Settings and its switches in Korean (seen on a PC).
  A bundle made from a `.lproj` folder searches the same list, so `L10n` (`Localization.swift`) asks Windows for the
  user's display languages (`GetUserPreferredUILanguages`), chooses the bundle's localization they name, and reads its
  `Localizable.strings` itself, unless Yardlet's own defaults name a language. The QA event log's `language:` line says
  which it chose.
- **Time zone.** Foundation on Windows names the current time zone from `GetTimeZoneInformation`'s `StandardName`
  (confirmed in swift-foundation's source), which Windows writes in its display language, while ICU maps only the
  zone's registry name (`Korea Standard Time`); on a Korean Windows `TimeZone.current` was GMT, and a chat started at
  07:22 in Seoul got the day before's folder (seen on a PC). Before anything reads a time, the app asks the system's
  ICU (`icu.dll`, Windows 10 1903 and later) for the zone Windows is set to (`ucal_getDefaultTimeZone`, `Asia/Seoul`)
  and has Foundation read it again from `TZ`, which names it only for that read, so no program the app starts inherits
  it (`Platform/Windows/WindowsTimeZone.swift`). A `TZ` already set is left as it is. The QA event log's `time zone:`
  line says what Foundation reads; the window check sets Windows to Seoul's zone and needs `Asia/Seoul`.
- **No console windows.** The release app is a windowed program with no console, and Foundation's `Process` passes
  `CreateProcessW` no `CREATE_NO_WINDOW` (confirmed in its source), so each console program the app started, a
  harness's node or Git, opened a console window of its own, in Windows Terminal where that is the default terminal
  (seen on the CI runner). At launch the app makes a console with no window for those programs to share
  (`Platform/Windows/WindowsConsole.swift`, `AllocConsoleWithOptions` with `ALLOC_CONSOLE_MODE_NO_WINDOW`, Windows 11
  24H2 and later); a Windows without that call keeps the console windows.
- **Another computer's Yardlet.** Connect to a Mac, a group of Settings, pairs with the link a host
  copies in Settings › Remote, as File › Connect to Mac… does on the Mac (docs/REMOTE_PROTOCOL.md, "Yardlet as a
  client"), and lists the paired Macs with Open and Remove…, which forgets the host and asks it to forget this
  computer when it can be reached. `WinUI/RemoteHostWindow.swift` opens each paired host in a window of its own: the host's tasks as it
  lists them, the chosen task's conversation as it streams, and a composer that sends to the host. The client is the
  engine's `RemoteHostDirectory` and `RemoteHostModel`; `Platform/Windows/WindowsRemoteClientKeys.swift` keeps each
  host's key in Credential Manager and the list and cache under `%LOCALAPPDATA%\Yardlet`. Without Bonjour, a host is
  reached at the direct addresses it named, on the same network or over Tailscale, and through its relay. A host's
  sidebar is drawn again only when what it shows changes, not as a task's marks and times change while it streams.
- **This computer's tasks elsewhere.** Settings, at the foot of the sidebar, draws its settings as Windows 11 Settings
  does, a card for each in its group (`WinUI/SettingsPane.swift`), and holds Settings › Remote as the Mac's
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
  main actor runs on the window's thread and an idle window uses no processor time. The wait returns for any message
  left in the queue (`MWMO_INPUTAVAILABLE`): Foundation's main run loop on Windows dispatches one Windows message in
  each pass and leaves the rest marked as seen, and a wait for new messages alone slept through them (seen as a UI
  Automation request unanswered for a minute). Once the loop ends, the application lets go of its window and updater
  (`shutDown(exitCode:)`) and `main()` runs the dispatcher queue down, as the Windows App SDK asks of a thread that
  runs its own loop. XAML lets go of the application only as the process ends and XAML's DLL is unloaded, after the
  windowing layer's, and the window the application still held then ended the process in an abort each time the
  window was closed; the install check fails when the app quits with any exit code but 0.
- **The WinUI bindings.** [swift-winrt](https://github.com/thebrowsercompany/swift-winrt) generates them from the
  metadata (.winmd) in Microsoft's NuGet packages (the Windows App SDK 2.6.5's Foundation, InteractiveExperiences and
  WinUI, the Windows SDK contracts and WebView2), whose versions and SHA-512 hashes `Windows/Bindings/projections.json`
  pins. From 2.0 the Windows App SDK package only names those it is made of, and a restore from a list of packages
  takes each one named and none it depends on, so the list names each. It projects the types that
  file includes and every type their members reach, into `Windows/Bindings/Generated/`, which git ignores; the
  bindings are generated before a build, not kept in the repository. `Windows/Bindings/Package.swift` links them
  into the executable, not into DLLs, and a release build optimizes them for size without reflection metadata.
  swift-winrt's exclusions are not used: it still writes members whose generic arguments name an excluded type.
- **The bootstrapper.** The app links the x64 import library for `Microsoft.WindowsAppRuntime.Bootstrap.dll` from
  the Windows App SDK's Foundation package, and `Windows/scripts/place-bootstrapper.ps1` puts the DLL from the same
  package beside the executable, as the Windows App SDK's build targets do. From 2.0 the bootstrapper matches the
  runtime by its major version alone, so the app also asks for at least the version its bindings were generated from
  (2.6.5), and the bootstrapper offers to install the runtime when it finds none that new.
- **The Windows App Runtime.** An unpackaged WinUI app runs on the Windows App Runtime's packages: the framework it
  starts against, and the Main and Singleton packages and the DDLM beside it. The app carries the x64 packages of the
  release its bindings come from, which `place-bootstrapper.ps1` puts in `WindowsAppRuntime` beside the executable
  with each one's identity as its manifest gives it (`MSIX.identities`, written by `generate-bindings.ps1`: Microsoft's
  `MSIX.inventory` names the DDLM and the Singleton by a pattern, not as they install), and puts in place those this
  Windows user lacks
  (`Platform/Windows/WindowsAppRuntimeDeployment.swift`): one counts as there when the user has its family for x64 at
  that version or later (kernel32's `GetPackagesByPackageFamily`), as the Windows App SDK's own deployment counts one,
  and the rest are added with Windows' package manager (`PackageManager.AddPackageAsync`), the framework first and the
  Singleton with its process shut down, as the Windows App SDK adds them. It needs no administrator and shows nothing.
  A PC can have the framework alone, as an app from the Store brings it; there the app started, but registering for
  notifications failed with "Class not registered", since an unpackaged app's registration goes through the
  Singleton's process (`AppNotificationManager::Register` in the Windows App SDK's source). The packages are put in
  place in the installer's hooks ("Installing and updating the Windows app" below) and, for a hook that ran out of
  time or a copy Setup did not install, as the app starts, before the runtime does; with nothing missing that reads
  four package lists and adds nothing.

On Windows, with Swift 6.4.1 and Visual Studio's C++ tools (swift-winrt is C++):

```powershell
Windows/scripts/generate-bindings.ps1
swift build --product NativeHarnessClient --force-resolved-versions
Windows/scripts/place-bootstrapper.ps1 -Binaries (swift build --show-bin-path)
```

`windows-engine.yml` builds the Windows app for the same pull requests and branches, beside the
engine, as a check to read, and runs the Windows layer's own tests (`Tests/YardletWindowsTests/`) against it. They
build with `YARDLET_WINDOWS_TESTS=1`, which declares their target and leaves out the release's windowed entry point:
SwiftPM 6.4 hands an executable's linker settings to the test library in every configuration.
`windows-app.yml` runs for pull requests, `main` and `windows-*` branches when what it builds changes (the engine and
the Windows layer, the targets beside them, the relay, the package's manifest, the Windows scripts and the workflow;
not the Mac's layers or documents), so each such commit on `main` has an installer to try, and a `windows-*` branch's
pull request does not run it a second time. It builds a release, opens it on the
runner, measures it, types Korean into its composer through the Microsoft Korean IME, and checks that Shift+Enter
starts a new line and sends nothing (`Windows/scripts/check-window.ps1`). It then starts the relay (`relay/`) and the fixture host on it
(`Windows/scripts/start-remote-host.ps1`) and, in the same step, since a Windows runner ends the programs a step
started when the step ends, pairs the app with the host through Connect to a Mac, opens a task, sends a message and
waits for the answer to stream in, captures the host's tasks that wait on an approval or a question, ended on an error
or finished, then removes the host with Remove… and its question, which closes its window and
takes it off the list (`Windows/scripts/check-remote.ps1`, through UI Automation). It installs a
stand-in harness the way npm installs one (`Windows/scripts/fake-harness/`, whose `kimi.cmd` npm itself writes into
`%APPDATA%\npm`) and opens the app with `YARDLET_QA_HARNESS_CHECK=kimi-code` (`WinUI/QAHarnessCheck.swift`, a QA
variable like `YARDLET_QA_EVENT_LOG`): the app finds the shim as a new task would and runs the engine's verification
probe on it, which starts it through Node.js for `--version` and the ACP handshake and stops it. The stand-in starts
a detached process of its own, which outlives a stop of the stand-in alone, as the check shows first without the
app; the check passes when that process ended with the app's stop (`Windows/scripts/check-harness.ps1`). With that
stand-in, which serves one ACP turn that asks to edit a file, the app then starts a task from New task with its Send, allows the
request from its card, opens the turn's folded work and the edit's line until its diff shows, waits for the answer to stream in, and opens again to find
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
does not filter, so what another device on the network needs is the firewall's permission above. The run then
imports a conversation the stand-in saved before the app saw it: Import conversation, the stand-in, a folder chosen in
Windows' folder dialog through Choose project…, the conversation the stand-in lists only for a folder written as
Windows writes it, and its turns, which the stand-in replays as it loads, drawn in the main window with the task's row
chosen (`Windows/scripts/check-import.ps1`). It installs the Codex CLI with npm on the runner's profile, where Codex
never ran, and opens the app with `YARDLET_QA_HARNESS_CHECK=codex`: the probe starts Codex's App Server in the
environment a task gives it, Codex's home among it, for `initialize` and one page of `thread/list`, which need no
sign-in, and Codex ends at once unless that home is a folder written as Windows writes it
(`Windows/scripts/check-codex.ps1`). The run
gathers the app with its resource folder and the Swift runtime beside it, opens what it gathered from another folder with the
build folder out of reach, and uploads it (`windows-app-bin`) with the Windows App Runtime's packages it puts in place,
to open on a PC that has no Swift. Last, it packs the app, installs it, updates it and removes it (`Windows/scripts/check-install.ps1`, "Installing
and updating the Windows app" below), and uploads the first installer it packed (`windows-app-setup`).

**Why the screens are Swift.** Before the app target, the same window (sidebar, conversation, composer) was built in
Swift and in C# with WinUI 3 and opened on a GitHub Actions Windows runner. Both held 28–30 MB of private
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

**What the Windows app does not have yet:** a signature: the installer and what it installs are unsigned. Settings has no
switch for checking for updates and no Check for Updates, as the Mac's has. The
Yardlet MCP server: its endpoint is a Unix domain socket (`Sources/YardletAgentTools/Platform/UnixDomainSocket.swift`)
with no named pipe in its place, and the app carries no `yardlet-mcp.exe`, so a Windows task has no connectors and none
of Yardlet's session, schedule, task or browser tools. A Windows layer for the rest of what `Platform/Portable/` stands in for:
the ConPTY terminal for the terminal panel, credential storage for the vault, and which Claude Code processes hold a conversation (`ClaudeConversationCatalog.runningSessionIDs`
finds none), so a Claude conversation still open in another app is neither marked so in Import conversation nor kept
from a send here; an accounts page (signing in to a saved account, signing out); answering the questions Codex asks
in a message while it works (`request_user_input_async`); a new task's account, attachments, worktree and slash
commands; and a browser host. Until the app is installed with a Start menu shortcut, its notifications carry the
executable's name. A
connector's program gets a POSIX environment (`Connectors/ConnectorProgram.swift`), and npm's `npx.cmd`, which is not
one of npm's shims, is refused. A host's window shows a request card's words without its answers, and none of the
host's panels, new tasks or Settings. The remote has no relay account to sign in to or link through
(docs/REMOTE_PROTOCOL.md, "12.1 Linking through an account"), and nothing that keeps the computer awake on power. Until Foundation
there hands frames over whole (swiftlang/swift-corelibs-foundation#5255), its relay socket cannot tell a frame that
does not decrypt from a piece of one: a paired device that sends such a frame holds the frames after it, other phones'
too, until the bytes reach the limit (4 + 65,535 bytes) and are dropped, and a phone whose frame was dropped is out of
step with its cipher's nonce and has to connect again.

## Installing and updating the Windows app

`Windows/scripts/pack.ps1` packs the app with [Velopack](https://velopack.io) into a per-user installer,
`YardletApp-win-Setup.exe`, which installs without administrator rights into `%LOCALAPPDATA%\YardletApp` with a Start
menu shortcut and an entry in Settings › Apps; a portable zip; and the update package with the feed an installed app
reads (`releases.win.json`). The pack id is `YardletApp`, not `Yardlet`: Velopack installs into `%LOCALAPPDATA%\<pack
id>`, moves aside a folder it finds there that is not empty and deletes it once the install succeeds, and empties that
folder when the app is removed (its `install.rs` and `uninstall.rs`), and `%LOCALAPPDATA%\Yardlet` is the app's data.

What goes in is the app's executable and only that executable, so a program the build made for a check, such as
`yardlet-remote-fixture.exe`, stays out; the libraries and resource folder the build put beside it; the Windows App
SDK's bootstrapper and the Windows App Runtime's x64 packages (about 50 MB, nearly all of it the framework); the Swift
runtime; the relay the build carries (`place-relay.ps1`); Velopack's C library,
`velopack_libc_win_x64_msvc.dll`, at the version and SHA-256 the script pins; and, when `-UpdateFeed` names one, the
feed in `YardletUpdateFeed`. `Windows/scripts/set-app-icon.ps1` writes Yardlet's icon into the packed copy of the
executable, from which the taskbar button, the shortcut and the Apps entry take theirs, and gives the installer the
same icon. In the same resource update, before signing, it writes `VS_VERSIONINFO`: `FileDescription` and
`ProductName` are `Yardlet`, `FileVersion` and `ProductVersion` keep the full pack version, and their fixed numeric
fields use its version core with a zero fourth component when omitted. The resource and its Unicode string table
use English (US), with a matching `Translation`. This supplies the executable's name to Windows surfaces that read
file descriptions. The window draws its own title bar with Yardlet's mark (`WinUI/WindowChrome.swift`).

The icon is also packed beside the executable as `Yardlet.ico`, for notification registration. Packed builds pass
the name `Yardlet` and this icon to `AppNotificationManager.Register`: the Windows App SDK's automatic shortcut
lookup can fail, and its process fallback uses the executable's filename, even with a version resource. Each
registration overwrites `DisplayName` in its AppUserModelID entry, including one left by an older install, so the
next unelevated launch refreshes an old name without a migration. Builds without the packed icon use the SDK's
automatic lookup.

In the app (`Platform/Windows/WindowsUpdates.swift`), the library is looked for in the executable's folder alone, with
its dependencies from System32, so a build run from its build folder has none and runs as before. Velopack's start
runs first, before the Windows App Runtime (`XamlApplication.willStart()`): it answers an installer's hook (installed,
updated, replaced, about to be removed) and ends the process, as Setup.exe and Update.exe wait for it to, after the
install and update hooks have put the Windows App Runtime's packages in place within the time Velopack gives them
(25 of the install hook's 30 seconds, 12 of the update hook's 15), and the uninstall hook has let go of the app's
notifications (45 of its 60 seconds); it
puts in an update downloaded earlier that is not yet in place and opens the app again; and it gives the process the
AppUserModelID of the app's shortcut (`velopack.YardletApp`). An installed app whose package names a feed then does
what Sparkle does on the Mac: it looks for an update when it opens and once a day, downloads one in the background,
and once its window has closed and it quits, hands the update to Velopack's updater, which waits for the process to
end and puts the update in place without showing anything or opening the app again. A feed that is a GitHub
repository's address is read from its newest ten releases, for the `releases.win.json` among their files, so a release
made for the Mac alone in between does no harm. Velopack checks a download against the SHA-256 the feed lists; nothing
else vouches for it until the files are signed, where the Mac's updates also carry an EdDSA signature that Sparkle
checks.

Signing takes a certificate and nothing more. `-SignParameters`, or `YARDLET_WINDOWS_SIGN_PARAMETERS`, hands the
signtool `vpk` carries the arguments for a certificate in the Windows user's store, as a smart card's or a cloud
signing service's own tool puts one there (`/sha1 <thumbprint> /fd sha256 /tr <timestamp URL> /td sha256`);
`-SignTemplate`, or `YARDLET_WINDOWS_SIGN_TEMPLATE`, instead gives it a command that signs one file, with `{{file}}`
for its path. `vpk` signs every executable and library it packs that no one Windows trusts has signed, so Microsoft's
keep their signatures, and then Setup.exe. Without either nothing is signed.

A release is packed where its certificate is. `windows-app.yml`, run on the release's tag, gathers the app
(`windows-app-bin`: the executable, its libraries and resource folder, the Swift runtime, the relay it was built with
and the Windows App Runtime's packages). On a Windows computer that holds the certificate, with this repository
checked out at that tag and the .NET SDK for `vpk`, but no Swift, `pack.ps1 -Binaries <that folder> -OutDirectory
<folder> -UpdateFeed https://github.com/zzunkie/yardlet -SignParameters '…'` writes the signed installer, the portable
zip, the package and `releases.win.json`, which go on the release beside the Mac's disk images. `scripts/release.sh`,
which prepares the Mac's, does not do this part.

Removing the app takes its notifications with it: before Velopack deletes the app, its uninstall hook clears what
the app left in Windows' notification center and lets go of its notifications' registration, the
`HKCU\Software\Classes\AppUserModelId\velopack.YardletApp` entry, the activator's `CLSID` and the notification
platform's record of the app (`Platform/Windows/WindowsNotifications.swift`), since none of it means anything once the
app is gone. The Windows App SDK offers notifications only to a process that is not elevated, so an app only ever run
elevated has none to take, and a removal run elevated leaves them. Removing the app leaves `%LOCALAPPDATA%\Yardlet`, its
keys in Credential Manager and the firewall's permission, as moving the Mac app to the Trash leaves its data, and
Velopack's log of its installs, updates and removal, `%LOCALAPPDATA%\velopack\velopack_YardletApp.log`. The chats'
folders, `%USERPROFILE%\Documents\Yardlet\<date>\<name>`, stay as the person's own files, which the harnesses worked
in, as `~/Documents/Yardlet` stays on the Mac. The Windows App Runtime's packages stay too: they are Microsoft's,
shared with every app that uses that release, as the Visual C++ runtime is. The
harnesses' own folders, such as `%USERPROFILE%\.claude`, are theirs and are never touched.

`windows-app.yml` checks all of it on the runner (`Windows/scripts/check-install.ps1`): it packs the build twice, as
two versions that read a feed in a folder on the runner. It first removes the Windows App Runtime's x64 packages for
the runner's user; Windows keeps the framework there, so the runner is a PC that has the framework alone, as the PC
that could not register for notifications was, and adding the framework itself is not checked. The first one's
Setup.exe then installs the app without a window,
Velopack's log must show the app answered the install hook in time, the hook's event log must say it added the
runtime's packages, and each must then be there; the installed app opened must find them in place. The installed
folder must hold no other executable, the
executable must carry an icon, `FileDescription` and `ProductName` must be `Yardlet`, and both version strings must
match the pack version before and after updating. The shortcut, the Apps entry and the version must be there, with
the data folder unchanged. Opened, the app must find nothing newer. With the second version's files in the feed, the app opened again
must download it and, once its window is closed, hand it to the updater, after which the installed version must be the
second; opened once more it must say so and find nothing newer. It packs what the run gathered (`windows-app-bin`), as
a computer that holds the certificate does, and signs the second version with a certificate made for the check and
taken out of the store again: its Setup.exe and the executable the update puts in place must carry that signature,
and the Windows App SDK's bootstrapper must keep Microsoft's. Every process on the runner is elevated, where the
Windows App SDK has no notifications, so the app is then opened at medium integrity, as Explorer opens it for a
person, and must register for them, writing its `AppUserModelId` entry and its activator's `CLSID`; a notification is
posted under its AppUserModelID. Removing it, also at medium integrity, must answer the uninstall hook, which must say
it removed the notifications and the registration, and take the installed app, the shortcut, the Apps entry and both
registry entries, and leave the data folder as it was. Where the runner lets the notification center be read, the
notification posted must be gone too.

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
| `ScopedFiles` | No-follow descriptors | Provided (`Platform/Windows/WindowsScopedFiles.swift`). The root is opened as it is, links included, as on the Mac; each name beneath it is opened as itself (`FILE_FLAG_OPEN_REPARSE_POINT`), one at a time below the root's final path (`GetFinalPathNameByHandleW`), and refused when it is a reparse point of any kind: a symbolic link, a junction, or a cloud file's placeholder. The folders on the way stay open without `FILE_SHARE_DELETE` until the next name is open, so none can be renamed or replaced by a link meanwhile; a file is opened sharing everything, so Claude Code goes on appending to it, or removes it, while it is read. A folder is listed through its own handle (`GetFileInformationByHandleEx`), and a name that is not a plain one (a separator, a drive, a stream, a pattern, `..`) is refused |
| `WorkspaceFileReplacement` | No-follow descriptors, `renameat` | Provided (`Platform/Windows/WindowsWorkspaceFileReplacement.swift`). The folders down to the file's are held by `ScopedFiles`' walk, and the file is opened as itself, refused when it is a reparse point, and shared for reading and removing only: a program writing to it makes the save fail, and none can write to it from the digest check until it is replaced. A new file is written beside it with its creation time and its hidden, system and not-indexed attributes (`FileBasicInfo`; Windows marks it for archiving, as any changed file) and its access list (`GetKernelObjectSecurity`, `SetKernelObjectSecurity`; a read-only file is refused, and alternate data streams are not carried over), so that, as on the Mac, only its modification time is the save's. The name is checked to hold the same file, and the new file is renamed over it through its own handle (`SetFileInformationByHandle`, `FileRenameInfoEx` with replace and POSIX semantics). Another program reading the file and sharing its removal goes on reading the old bytes; one reading it without sharing its removal makes the save fail and leaves the file as it was. A volume without POSIX renames (FAT, some network shares) gets a plain replacing rename, for which Yardlet's own handle on the old file closes just before |
| `CanonicalPath` (`Files/CanonicalPath.swift`) | `realpath(3)` | An opened file's final path (`GetFinalPathNameByHandleW`); for now Foundation resolves the links |
| The file chooser's private copy (`BrowserAgentWorkspaceFile.privateCopy`) | `openat` one folder at a time without following links | The same with reparse points refused; refused on Windows until then |
| Removing an account folder's links (`ClaudeAccountHome.unlinkShared`) | `unlink(2)`, which never follows the link | `DeleteFileW` for a file link and `RemoveDirectoryW` for a folder link, never a recursive removal; refused on Windows until then |
| Claude Code's background task output (`ClaudeTaskOutputReader`) | `claude-<uid>` under the temporary folders | Where the CLI keeps it on Windows is not confirmed; nothing is looked up there |
| SQLite | The macOS SDK's libsqlite3 | Windows's own `winsqlite3` with the Windows SDK's header (`Sources/CSQLiteWindows`), chosen in `Package.swift` when building on Windows |

Other macOS-specific values that the check does not catch:

- `Domain/HarnessKind.swift`: `symbolName` holds SF Symbols names. The screen layer should pick the icon by harness ID;
  Windows uses the logo assets.
- `Account/HarnessAccountBroker.swift`: the user-facing text names macOS Keychain as the Antigravity CLI credential
  location, which on Windows is Credential Manager. The Windows app does not show that text yet.

## Paths and executable lookup

| Where | Assumption | Recommended handling |
| --- | --- | --- |
| `Runtime/RuntimeProcessEnvironment.swift` | Splits and joins `PATH` with `:`. Fixed `~/.local/bin`, `~/.bun/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and the system folders; `searchDirectories` adds package managers' folders (`~/.volta/bin`, `~/.cargo/bin`, `~/.deno/bin`, `~/.npm-global/bin`, `~/Library/pnpm`), nvm's `~/.nvm/versions/node/*/bin` and Docker Desktop's `bin` | On Windows (`Runtime/ExecutableLookup.swift`): `Path` split and joined with `;`, each folder once in any case, a variable's name read and replaced in any case and the search path named `Path`, `USERPROFILE` as home. A runtime gets its own folder, `%USERPROFILE%\.local\bin`, `%USERPROFILE%\.bun\bin` and `%APPDATA%\npm` ahead of `Path`; `searchDirectories` looks in those, `%LOCALAPPDATA%\pnpm`, `.cargo\bin`, `.deno\bin` and Scoop's `scoop\shims`, then `Path` |
| `Runtime/RuntimeSelectionStore.swift`, `Runtime/RuntimeRelocation.swift` | Install candidates are `searchDirectories`, the ChatGPT app's bundled Codex under `/Applications/ChatGPT.app` and the Claude app's `~/Library/Application Support/Claude/claude-code/…`; relative paths are split at `/` | On Windows a candidate without an extension is the program it names with PATHEXT's extensions Windows starts, `.exe` and `.com` before `.cmd` and `.bat` (`ExecutableLookup.program(at:)`, which the adapters' and the task's runtime checks also use), and Antigravity's `agy.exe` counts as `agy`. The desktop apps' bundled runtimes are looked for at their macOS paths only: where they keep them on Windows is not confirmed |
| `Domain/HarnessKind.swift` | `relativeExecutablePaths` are POSIX paths without extensions (`.local/bin/codex`, `.hermes/hermes-agent/venv/bin/hermes` and others) | The extension comes from the lookup above; a Python virtual environment's program is in `Scripts` on Windows (`HarnessCatalog.virtualEnvironmentProgram`) |
| `Diff/GitExecutableLocator.swift` | `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/opt/local/bin/git`, then `/usr/bin/git` | On Windows (`windowsCandidates`): `git.exe` in the folders of `Path` that are absolute, then where Git for Windows is installed for everyone (`%ProgramFiles%\Git\cmd`, `%ProgramFiles(x86)%\Git\cmd`), for one person (`%LOCALAPPDATA%\Programs\Git\cmd`) or by Scoop (`%USERPROFILE%\scoop\apps\git\current\cmd`) |
| `Diff/GitDiffService.swift` | `/dev/null` as a Git argument (`hash-object -t tree`, `diff --no-index`) | Whether Git for Windows accepts this path is not confirmed. For the empty tree, a way without a path, such as `git hash-object -t tree --stdin`. The `/dev/null` that `UnifiedDiffParser` reads is Git's output format and stays |
| `YardletRemote/PathRules.swift`: `isReadAsAnotherNameOnWindows` | A name is the file or folder its text spells | On Windows a name that ends in a period or a space is read without them, and a device's name (`NUL`, `CON`, `COM1`, also before an extension or a colon) is that device in any folder. The text of a path with such a name does not say where it leads, so the path is in no folder (`relativePath(of:in:)` is nil) |
| `YardletRemote/PathRules.swift`: `isAbsolute`, `isRelative`, `names`, `url(for:in:)` | An absolute path starts with `/`, and `/` separates names | One rule for every engine check. On Windows an absolute path starts with a drive (`C:\`, or `/C:/` as a file URL's path writes it) or names a share (`\\server\share`, also in the `\\?\` forms), `\x` and `C:x` are neither absolute nor relative, and `\` and `/` both separate names. Paths from another computer (a remote host's, a personal agent's execution host's) keep their own checks |
| `YardletRemote/PathRules.swift`: `relativePath(of:in:)`, `isInside`, `isStrictlyInside` | Whether a path is in a folder is decided by whole names after `.` and `..` are taken out by their text, never by a string prefix; nothing is looked up, so a check that must not follow links resolves them first. macOS and Linux compare names as Swift compares strings. The rules live in `YardletRemote`, under the engine and the phone app, and the engine reads them as its own (`Files/SharedPathRules.swift`) | On Windows names compare in any case, one character for one, as NTFS compares them, and keep their composition. The Windows rules are pure functions over strings, so the Mac tests run them (`WorkspaceFileTests`). A folder's identity (which project a task is in, a sidebar group, the tasks in one folder) compares `ProjectSidebarPresentation.folderKey`, which is `PathRules.key`: on Windows `C:\Repo`, `c:/repo` and `\\?\C:\Repo` are one folder, and on macOS the key is the path as written, as before. What is shown and passed to a CLI keeps the path's own spelling (`normalizedPath`) |
| `YardletRemote/RemoteTaskFiles.swift` (`RemoteFileReader`) | The host's boundary for another device's file reads, listing and saves (docs/REMOTE_PROTOCOL.md §15.22, §15.27) | These rules, with POSIX names compared byte for byte (`comparingBytes`): Swift's strings read two spellings of a name (`é` composed, or `e` and an accent) as one, and a file system that keeps names as bytes, as Linux's do, holds two folders under them. On Windows they compare as NTFS does. The file access beneath the rules (resolving links, `O_NOFOLLOW_ANY`, no-follow descriptors) is the Mac's alone so far, so only a Mac host serves files (`taskFiles`) |
| `Adapters/ACP/ACPProtocol.swift` (`cwd`), `Domain/ClaudeConversationCatalog.swift` (`projectFolderName`), `Adapters/Codex/CodexProtocol.swift` (`folderPath`) | A folder is written as its file URL's path | On Windows as Windows writes it (`PathRules.nativePath`): a file URL's `path(percentEncoded:)` there is `/C:/Users/me/proj/` and its `path` is `C:/Users/me/proj` (confirmed in swift-foundation's source). An ACP agent finds no sessions under the first, Claude Code names its history folder `C--Users-me-proj`, and the first is no absolute path to Codex, whose `thread/start` and `thread/resume` sent it; on macOS and Linux each Codex request sends the URL's path as before |
| `Runtime/CodexEnvironmentManager.swift` (`CODEX_HOME`, the snapshot's files and `sqlite_home`), `AppModel.refreshCodexCloudTasks` | A file URL's `path()` is its path | `path()` escapes it as a URL does on every platform (`Application%20Support`, a non-ASCII name as `%XX`), which names no file, and on Windows a file URL's path starts `/C:/`, which no program there reads as absolute: Codex ended with os error 123 on `CODEX_HOME`. A path handed to a file API, a program or its environment is `URL.nativePath` (`PathRules.nativePath(of:)`): `C:\Users\me` on Windows, the unescaped path elsewhere |
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
| `FileHandle.nullDevice` as a child's standard input, output or error | Swift 6.4's `Process` opens NUL for it without making the handle inheritable, so the child gets a handle that names nothing (seen on a PC: the standard error in `agy acp`'s process parameters was no handle in it, and `agy acp` waited on its first log line and never answered `initialize`). swift-corelibs-foundation's later change that duplicates each handle for the child (#5619) passes NUL inheritable; which toolchain carries it is not confirmed | `FileHandle.childNullDevice()` (`Runtime/ChildInputPipe.swift`) opens `\\.\NUL` itself, which `Process` hands over as it does any other file, for each child Yardlet starts with no input or with an output it drops |
| `readabilityHandler` | Supported through `DuplicateHandle`, `_open_osfhandle` and a Dispatch read source (confirmed: [`FileHandle.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/FileHandle.swift)) | No change needed |
| `process.environment` | Windows environment variable names are case-insensitive. Foundation adds the app's own `Path` to a child's environment that has none under exactly that name (confirmed in its source) | `NativeProcessTree.run(_:)` names each variable once, the search path as `Path` (`ExecutableLookup.normalized`) |
| `.posixPermissions` 0o600 and 0o700 (private files such as provider connections, drafts and the vault: `ProviderConnections`, `ComposerDraftRepository`, `VaultCenter` and others) | There are no POSIX modes, so access by the user alone is not guaranteed | Store under the user profile with an ACL. How Foundation applies this attribute on Windows is not confirmed |

## External dependencies

| Dependency | Engine use | Windows | Evidence | Recommended handling |
| --- | --- | --- | --- | --- |
| swift-markdown 0.8.0 (swift-cmark 0.8.0) | `Transcript/TranscriptInlineContent`, `Transcript/TranscriptMarkdownDocument`, `Diff/MarkdownReviewDiff`, `Domain/TaskAttention` | The manifest has Windows-specific settings. Builds on Linux (confirmed); Windows not confirmed | `CMARK_GFM_STATIC_DEFINE` `.when(platforms: [.windows])` in swift-markdown's `Package.swift`, `#if os(Windows)` in swift-cmark's `Package.swift` | Keep it in the engine |
| swift-crypto 5.0.3 (in place of CryptoKit) | `CodexEnvironmentManager`, `ClaudeSubagentTranscriptReader`, `YardletRemote` | Windows builds in its own CI; its README names ARM64 Windows. Not confirmed with Yardlet's build | Builds on Linux (confirmed) | Keep |
| SwiftTerm 1.18.0 | None; the macOS layer and screens only | Only the terminal parser builds. No PTY or view (confirmed) | The manifest's `os(Windows)` branch leaves out the `Apple`, `Mac` and `iOS` sources, and `LocalProcess.swift`, `Pty.swift` and `HeadlessTerminal.swift` are under `#if !os(iOS) && !os(Windows)` | The Windows terminal uses ConPTY and a Windows view |
| Sparkle 2.10.1 | None; only the macOS layer imports it (`Platform/macOS/YardletSparkle.swift`), and it is linked only on macOS (`.when(platforms: [.macOS])`) | Not used | `Package.swift` | Windows updates through Velopack |
| Velopack 1.2.161 (`vpk` and its C library `velopack_libc`) | None; the Windows layer loads the library at run time (`Platform/Windows/WindowsUpdates.swift`) and links nothing of it | Packs, installs and updates the Windows app ("Installing and updating the Windows app" above) | `Windows/scripts/pack.ps1` pins the version and the library's SHA-256; `windows-app.yml` installs, updates and removes the app | Keep the packer and the library at one version |
| CSQLite (`systemLibrary`, `link "sqlite3"`; on Windows a C target linking `winsqlite3`) | `Store/SessionRepository`, `Domain/ProviderSessionTitleResolver` | Windows ships SQLite as `winsqlite3.dll` with the header in the Windows SDK. Builds on Linux with the system's libsqlite3 (confirmed) | `Package.swift`, `Sources/CSQLite/module.modulemap`, `Sources/CSQLiteWindows` | Keep the system's SQLite on each platform |
| Observation | Many `@Observable` models | A Swift toolchain module, imported explicitly outside Apple's platforms. Builds on Linux (confirmed) | The Linux build | Keep as is |
