# Engine portability

Yardlet runs on macOS. Windows is planned: the engine is kept in cross-platform Swift, and each platform gets its own
screens. The engine builds on its own on macOS and on Linux; nothing has been built or run on Windows yet. For
dependencies and Foundation behavior on Windows, what was checked in the official source or a build is marked
"confirmed"; the rest is "not confirmed".

## Engine and platform layers

- **Engine:** every Swift file of the `NativeHarnessClient` target and of `YardletAgentTools` (the library the app
  shares with the Yardlet MCP server, `yardlet-mcp`), except the screen and platform layers below. New folders count as
  engine by default.
- **Screen and platform layers (outside the check):** `Views/`, `Browser/` (the WebKit preview), `Development/` (visual
  fixtures and QA), `Platform/` and `NativeHarnessClientApp.swift`.
- Engine code names the platform's parts directly, and each platform defines them under the same names in its own
  folder: `Platform/macOS/` for the Mac app, and `Platform/Portable/` for a build of the engine on its own. Some parts
  are protocols the engine owns with a platform's implementation (`LocalSystemNotificationCenter` implements
  `SystemNotificationCenter`, `LiveProcessTable` implements `ProcessTableReading`); others are types or extensions the
  engine calls by name. The app's model is put together in `Platform/macOS/AppModel+Live.swift`, which hands the engine
  the Mac's browser host.

## Building the engine on its own

```sh
YARDLET_ENGINE_ONLY=1 swift build --build-system native --target NativeHarnessClient --force-resolved-versions
```

With `YARDLET_ENGINE_ONLY=1`, `Package.swift` turns the app target into a library that leaves out `Views/`, `Browser/`,
`Development/`, `Platform/macOS/` and `NativeHarnessClientApp.swift`, and drops the SwiftTerm and Sparkle packages and
the test target. This is the build a platform other than macOS makes, and on a Mac it checks that the engine still
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
| `AccountLoginController`, `NativeTerminalSession`, `TaskShellProcess` | The sign-in terminal, the terminal panel's shell, bash mode's shell | SwiftTerm and a PTY |
| `BrowserPreviewModel`, `ConversationRenderState` | A tab's preview page, the conversation's cached turn views | WebKit, AppKit |
| `RemoteControlService`, `LidSleepHelper` | The phone remote, the lid helper | Network.framework, XPC |

`Platform/Portable/PortableFoundation.swift` also holds the few names Foundation outside Apple's platforms lacks
(`InlinePresentationIntent`, Combine's `ObservableObject` and `Published`, `autoreleasepool`), and
`URLSession.bytes(for:)`, which there streams a response's body through a delegate and refuses redirects, as the app's
own sessions do.

**Foundation outside Apple's platforms.** Where the engine uses something only Apple's Foundation has, it keeps that
under `#if canImport(Darwin)` and says the same thing another way elsewhere: `L10n` takes plain string keys,
`RelativeTime` uses `Date.RelativeFormatStyle`, `TaskAttention` reads Markdown with swift-markdown, `NSNumber` tells
JSON booleans and fractions apart by `objCType` (`JSONNumberKind`), Gmail's charsets go through
`String.Encoding(ianaName:)`. Files that use `URLSession` import `FoundationNetworking` when it exists, and files that
use `@Observable` import `Observation`.

**Cryptography.** The engine and the phone remote import `Crypto` from swift-crypto, which has CryptoKit's API: on
macOS it re-exports CryptoKit and adds nothing to the app; elsewhere it builds BoringSSL.

**The phone remote off macOS.** Its listeners and interface addresses (`RemoteSecureListener` on Network.framework,
`RemoteAddresses` on BSD sockets) are left out of a build on another platform until that platform has its own. The
rest of `YardletRemote` builds: its random bytes fall back to `SystemRandomNumberGenerator`, its free-space check to
`attributesOfFileSystem`, and `RemoteLimits.host(of:)` exists only with Network.framework.

**Where it has been built.** On Linux in the `swift:6.4-bookworm` image (confirmed, 2026-10-31). A folder on the Mac's
desktop cannot be mounted into Docker, so the sources go in as an archive:

```sh
tar --exclude ./.build --exclude ./.git --exclude ./docs -cf - . | docker run -i --rm swift:6.4-bookworm bash -c \
  'mkdir /src && tar -xf - -C /src && cd /src && YARDLET_ENGINE_ONLY=1 swift build --target NativeHarnessClient'
```

On Windows, `.github/workflows/windows-engine.yml` makes the same build for `windows-*` branches and by hand, apart
from the checks a pull request needs.

**Why one target per platform.** A separate engine library would need every declaration the screens and tests use
opened with the `package` access level, a change to nearly every engine file. Choosing the platform's folder in
`Package.swift` keeps one module on each platform, so engine code and `@testable import` stay as they are.

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
  the scan cannot see. It is not in the pull request checks yet.

## What a Windows layer needs

| Part | macOS today | What Windows needs |
| --- | --- | --- |
| `NativeProcessTree` | Collects descendants with `proc_listchildpids` and ends the tree with `kill` (also on the process group), `waitpid` and `usleep`. Every harness transport, Git, the account commands and the protocol process host end processes through `terminate(process:)` | Put the process in a job object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) right after it starts and end it with `TerminateJobObject`. Adding it after Foundation `Process` has started leaves a short gap, so also consider creating the process with `CREATE_SUSPENDED`. Foundation's `Process` creates no job object on Windows, and `terminate()` ends only the root with `TerminateProcess`, so grandchildren such as node and MCP servers would stay behind (confirmed: [swift-corelibs-foundation `Process.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/Process.swift)) |
| `AccountLoginController` | A `LocalProcessTerminalViewDelegate` driving a PTY through SwiftTerm, `NSWorkspace.open`, URL detection with `NSDataDetector`. The engine keeps the output parsing (`Account/AccountLoginOutput.swift`: `stripANSI`, device codes, input prompts) | A ConPTY (`CreatePseudoConsole`) host with the members the portable one has. Find URLs with a regular expression, because `NSDataDetector` does not exist in Foundation outside Apple platforms (confirmed: [swift-corelibs-foundation #4305](https://github.com/swiftlang/swift-corelibs-foundation/issues/4305)) |
| `NativeTerminalSession`, `TaskShellProcess` | SwiftTerm `LocalProcess` and a PTY | ConPTY and a Windows terminal view |
| `ScopedFiles`, `WorkspaceFileReplacement` | No-follow descriptors | Opening without following reparse points (`FILE_FLAG_OPEN_REPARSE_POINT`); the portable versions refuse |

Other macOS-specific values that the check does not catch:

- `Domain/HarnessKind.swift`: `symbolName` holds SF Symbols names. The screen layer should pick the icon by harness ID;
  Windows uses the logo assets.
- `Account/HarnessAccountBroker.swift`: the user-facing text names macOS Keychain as the Antigravity CLI credential
  location. Where Antigravity CLI keeps credentials on Windows is not confirmed.

## Paths and executable lookup

| Where | Assumption | Recommended handling |
| --- | --- | --- |
| `Runtime/RuntimeProcessEnvironment.swift` | Splits and joins `PATH` with `:`. Fixed `~/.local/bin`, `~/.bun/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and the system folders; `searchDirectories` adds package managers' folders (`~/.volta/bin`, `~/.cargo/bin`, `~/.deno/bin`, `~/.npm-global/bin`, `~/Library/pnpm`), nvm's `~/.nvm/versions/node/*/bin` and Docker Desktop's `bin` | Abstract: the platform provides the separator and the default folders. On Windows: `;`, a case-insensitive `Path` key, `USERPROFILE`, `%APPDATA%\npm` and so on |
| `Runtime/RuntimeSelectionStore.swift`, `Runtime/RuntimeRelocation.swift` | Install candidates are `searchDirectories`, the ChatGPT app's bundled Codex under `/Applications/ChatGPT.app` and the Claude app's `~/Library/Application Support/Claude/claude-code/…`; relative paths are split at `/` | Abstract: the platform provides the install candidates per harness. The Windows install locations of each CLI are not confirmed |
| `Domain/HarnessKind.swift` | `relativeExecutablePaths` are POSIX paths without extensions (`.local/bin/codex`, `.hermes/hermes-agent/venv/bin/hermes` and others) | Candidates per platform. A Windows venv uses `Scripts\*.exe` |
| `Diff/GitExecutableLocator.swift` | `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/opt/local/bin/git`, then `/usr/bin/git` | The platform provides the candidates. On Windows: `git.exe` in `PATH` and the Git for Windows install path |
| `Diff/GitDiffService.swift` | `/dev/null` as a Git argument (`hash-object -t tree`, `diff --no-index`) | Whether Git for Windows accepts this path is not confirmed. For the empty tree, a way without a path, such as `git hash-object -t tree --stdin`. The `/dev/null` that `UnifiedDiffParser` reads is Git's output format and stays |
| `Account/ProviderConnections.swift`, `Domain/ProviderSessionTitleResolver.swift`, `Domain/WorkspaceGitOrigin.swift` and others | Absolute paths are recognized with `hasPrefix("/")` | One shared check that also accepts `C:\` and UNC paths |
| `Files/WorkspaceFileService.swift`, `Domain/TaskWorktree.swift`, `Domain/Project.swift` and others | Whether a path is inside a folder is a `root + "/"` string prefix | Compare path components instead, and account for the case-insensitive file system on Windows. Workspace containment is a security boundary, so it needs tests during the Windows work |
| `Account/HarnessAccountBroker.swift` | Finds the Grok home from the `HOME` environment variable (usually missing on Windows) | Use `homeDirectoryForCurrentUser` |
| `Store/SessionRepository.swift`, `Domain/ProviderSessionTitleResolver.swift` | Pass the `URL.path(percentEncoded: false)` string to SQLite | `withUnsafeFileSystemRepresentation`. Whether `path()` becomes `/C:/…` on Windows is not confirmed |

Foundation also provides `~/.yardlet`, `applicationSupportDirectory` and `UserDefaults` on Windows. The actual storage
location there (AppData, the registry and so on) is not confirmed.

## Foundation `Process`, `FileHandle` and file permissions on Windows

| Item | Windows behavior | Recommended handling |
| --- | --- | --- |
| `Process.run()` | Quotes the arguments by Windows rules, passes them to `CreateProcessW`, and does not send `.cmd` and `.bat` to `cmd.exe` (confirmed) | Find the real `.exe` during lookup. If there is only a shim, wrap it in `cmd.exe /d /s /c`, with care for argument escaping (the BatBadBut family). `PATHEXT` and npm's `.cmd` shims have to be handled in lookup |
| `isExecutableFile(atPath:)` | swift-foundation decides with `SHGetFileInfoW(SHGFI_EXETYPE)` | Whether it treats a `.cmd` shim as executable is not confirmed. Put the check in the lookup abstraction |
| `terminate()` / `interrupt()` | Both are `TerminateProcess` and end only the root (confirmed) | The job object above. `Adapters/Headless/StructuredHeadlessAdapter.swift` stops a turn with `process.interrupt()` (SIGINT on macOS), which becomes an immediate kill on Windows: use the harness's own cancel first, and otherwise consider `CREATE_NEW_PROCESS_GROUP` with `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)`. Whether each CLI treats that as a stop is not confirmed |
| A write to a child's standard input after it stopped reading | No SIGPIPE on Windows: the write fails with an error | `Runtime/ChildInputPipe.swift` (`Pipe.childInput()`, used for every child's standard input) sets `F_SETNOSIGPIPE` on macOS only (`#if canImport(Darwin)`), so a CLI that exits before it reads fails the write instead of ending Yardlet. Linux has no such flag: ignore SIGPIPE in the app and restore it for children. Every writer already handles the error |
| `readabilityHandler` | Supported through `DuplicateHandle`, `_open_osfhandle` and a Dispatch read source (confirmed: [`FileHandle.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/FileHandle.swift)) | No change needed |
| `process.environment` | Windows environment variable names are case-insensitive | Normalize the keys so that `PATH` and `Path` do not both appear |
| `.posixPermissions` 0o600 and 0o700 (private files such as provider connections, drafts and the vault: `ProviderConnections`, `ComposerDraftRepository`, `VaultCenter` and others) | There are no POSIX modes, so access by the user alone is not guaranteed | Store under the user profile with an ACL. How Foundation applies this attribute on Windows is not confirmed |

## External dependencies

| Dependency | Engine use | Windows | Evidence | Recommended handling |
| --- | --- | --- | --- | --- |
| swift-markdown 0.8.0 (swift-cmark 0.8.0) | `Transcript/TranscriptInlineContent`, `Transcript/TranscriptMarkdownDocument`, `Diff/MarkdownReviewDiff`, `Domain/TaskAttention` off Apple's platforms | The manifest has Windows-specific settings. Builds on Linux (confirmed); Windows not confirmed | `CMARK_GFM_STATIC_DEFINE` `.when(platforms: [.windows])` in swift-markdown's `Package.swift`, `#if os(Windows)` in swift-cmark's `Package.swift` | Keep it in the engine |
| swift-crypto 5.0.3 (in place of CryptoKit) | `CodexEnvironmentManager`, `ClaudeSubagentTranscriptReader`, `YardletRemote` | Windows builds in its own CI; its README names ARM64 Windows. Not confirmed with Yardlet's build | Builds on Linux (confirmed) | Keep |
| SwiftTerm 1.18.0 | None; the macOS layer and screens only | Only the terminal parser builds. No PTY or view (confirmed) | The manifest's `os(Windows)` branch leaves out the `Apple`, `Mac` and `iOS` sources, and `LocalProcess.swift`, `Pty.swift` and `HeadlessTerminal.swift` are under `#if !os(iOS) && !os(Windows)` | The Windows terminal uses ConPTY and a Windows view |
| Sparkle 2.10.1 | None; only the macOS layer imports it (`Platform/macOS/YardletSparkle.swift`), and it is linked only on macOS (`.when(platforms: [.macOS])`) | Not used | `Package.swift` | Windows needs its own update mechanism |
| CSQLite (`systemLibrary`, `pkgConfig: "sqlite3"`, `link "sqlite3"`) | `Store/SessionRepository`, `Domain/ProviderSessionTitleResolver` | Relies on the system's libsqlite3 (the macOS SDK; the Linux image has it). Windows has no default header or pkg-config | `Package.swift`, `Sources/CSQLite/module.modulemap` | Replace: the conventional way, adding the SQLite amalgamation as a C target |
| Observation | Many `@Observable` models | A Swift toolchain module, imported explicitly outside Apple's platforms. Builds on Linux (confirmed) | The Linux build | Keep as is |
