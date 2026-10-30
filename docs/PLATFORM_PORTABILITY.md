# Engine portability

Yardlet runs on macOS. Windows is planned: the engine is kept in cross-platform Swift, and each platform gets its own
screens. Nothing has been built or run on Windows. For dependencies and Foundation behavior on Windows, what was checked
in the official source is marked "confirmed"; the rest is "not confirmed".

## Engine and platform layers

- **Engine:** every Swift file of the `NativeHarnessClient` target and of `YardletAgentTools` (the library the app
  shares with the Yardlet MCP server, `yardlet-mcp`), except the screen and platform layers below. New folders count as
  engine by default.
- **Screen and platform layers (outside the check):** `Views/`, `Browser/` (the WebKit preview), `Development/` (visual
  fixtures and QA), `Platform/` and `NativeHarnessClientApp.swift`.
- `Platform/macOS/` holds the macOS implementations the engine reaches through a small protocol, an injected value or
  an extension with the same name. For example, `LocalSystemNotificationCenter` (UserNotifications) implements the
  engine's `SystemNotificationCenter`; `HarnessLogoCatalog` loads the logos, while the engine keeps only the asset names
  (`Domain/HarnessLogoAsset.swift`); and `AntigravityKeychainProbe` gives `HarnessAccountBroker` its
  `antigravityCredentialState()`. A Windows layer has to provide the same pieces.

## The check that blocks new violations

`Tests/NativeHarnessClientTests/EnginePortabilityTests.swift` scans every engine file.

- It looks for forbidden imports (SwiftUI, AppKit, UIKit, Cocoa, WebKit, SwiftTerm, Darwin, Security,
  UserNotifications, CryptoKit, CoreServices, Carbon, ServiceManagement, IOKit, CoreGraphics, QuartzCore, Combine,
  OSLog and os) and macOS-only API rules: names qualified with `Darwin.`, POSIX process control (signals, `waitpid`,
  `pid_t` and the like), `proc_*` and `sysctl`, PTY functions, `posix_spawn`, `copyfile` and cloning, Keychain, `UN*`
  notification types, AppKit types, FSEvents and kqueue, Foundation APIs missing outside Apple platforms
  (`NSDataDetector` and others) and `x-apple.` URLs. Line comments are skipped.
- The allow list is a set of rule names per file. It has 3 files and 13 entries: `Account/AccountLoginController.swift`
  (6), `Runtime/CodexEnvironmentManager.swift` (3) and `Runtime/NativeProcessTree.swift` (4).
- A violation in a file that is not on the allow list, or a new kind of violation in an allowed file, fails. When an
  allowed entry no longer applies, the test fails and asks for it to be removed. The ceiling of 13 entries can only go
  down.
- Path assumptions and `Process` semantics (below) are string and behavior problems, so they are not in the check.

## macOS-only code left in the engine

These are the three allow-listed files. Each is a blocker for Windows.

| File | macOS-only part | What Windows needs |
| --- | --- | --- |
| `Runtime/NativeProcessTree.swift` | Collects descendants with `proc_listchildpids` and ends the tree with `kill` (also on the process group), `waitpid` and `usleep`. Every harness transport, Git, the account commands and the protocol process host leave termination to it (`terminate(process:)`, `terminate(rootPID:)`) | Abstract: keep a protocol with these two functions in the engine and move the current code unchanged into the macOS implementation. Replace: on Windows, put the process in a job object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) right after it starts and end it with `TerminateJobObject`. Adding it after Foundation `Process` has started leaves a short gap, so also consider creating the process with `CREATE_SUSPENDED`. Foundation's `Process` creates no job object on Windows, and `terminate()` ends only the root with `TerminateProcess`, so grandchildren such as node and MCP servers would stay behind (confirmed: [swift-corelibs-foundation `Process.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/Process.swift)) |
| `Account/AccountLoginController.swift` | `import AppKit`, `Darwin` and `SwiftTerm`; a `LocalProcessTerminalViewDelegate` driving a PTY; `pid_t`; `NSWorkspace.open`; URL detection with `NSDataDetector` (`firstHTTPSURL`). `AccountCenterModel` owns it, and `HarnessAccountBroker` parses output with its `stripANSI` | Abstract: an engine sign-in session protocol (state, phase, sending input) and pure text parsing (`stripANSI`, device codes, input prompts, finding URLs) in the engine; find URLs with a regular expression, because `NSDataDetector` does not exist in Foundation outside Apple platforms (confirmed: [swift-corelibs-foundation #4305](https://github.com/swiftlang/swift-corelibs-foundation/issues/4305)). Move the SwiftTerm host to the macOS layer. Replace: a ConPTY (`CreatePseudoConsole`) host on Windows |
| `Runtime/CodexEnvironmentManager.swift` | `import CryptoKit` (a `SHA256` fingerprint); `import Darwin` and `copyfile(COPYFILE_ALL \| COPYFILE_CLONE)`, with a `FileManager.copyItem` fallback | Replace CryptoKit with `Crypto` from swift-crypto, which has the same API (adding a package needs approval). Put the clone behind the platform layer or `#if canImport(Darwin)`; the fallback already works without it. `Transcript/NameBasedUUID.swift` computes its SHA-1 itself so as not to add another CryptoKit use |

Other macOS-specific values that the check does not catch:

- `Domain/HarnessKind.swift`: `symbolName` holds SF Symbols names. The screen layer should pick the icon by harness ID;
  Windows uses the logo assets.
- `Account/HarnessAccountBroker.swift`: the user-facing text names macOS Keychain as the Antigravity CLI credential
  location. Where Antigravity CLI keeps credentials on Windows is not confirmed.
- `AppModel.swift`: the default argument `LocalSystemNotificationCenter()` names the macOS implementation. The app
  should inject it once the targets split.
- PTY: besides `AccountLoginController`, the screen layer's `Views/TerminalPane.swift` and the macOS layer's task shell
  (`Platform/macOS/ShellCommandProcess.swift`, SwiftTerm `LocalProcess`) use a PTY. Windows needs ConPTY.

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

CryptoKit, Observation and `NSDataDetector` are not package dependencies, but they need the same judgment, so they are
listed here too.

| Dependency | Engine use | Windows | Evidence | Recommended handling |
| --- | --- | --- | --- | --- |
| swift-markdown 0.8.0 (swift-cmark 0.8.0) | `Transcript/TranscriptInlineContent`, `Transcript/TranscriptMarkdownDocument`, `Diff/MarkdownReviewDiff` | The manifest has Windows-specific settings. An actual build is not confirmed | `CMARK_GFM_STATIC_DEFINE` `.when(platforms: [.windows])` in swift-markdown's `Package.swift`, `#if os(Windows)` in swift-cmark's `Package.swift` | Keep it in the engine. Confirm with a Windows build |
| SwiftTerm 1.18.0 | `AccountLoginController` | Only the terminal parser builds. No PTY or view (confirmed) | The manifest's `os(Windows)` branch leaves out the `Apple`, `Mac` and `iOS` sources, and `LocalProcess.swift`, `Pty.swift` and `HeadlessTerminal.swift` are under `#if !os(iOS) && !os(Windows)` | Take it out of the engine. The Windows terminal uses ConPTY and a Windows view |
| Sparkle 2.10.1 | None; only the macOS layer imports it (`Platform/macOS/YardletSparkle.swift`), and it is linked only on macOS (`.when(platforms: [.macOS])`) | Not used | `Package.swift` | Windows needs its own update mechanism |
| CSQLite (`systemLibrary`, `pkgConfig: "sqlite3"`, `link "sqlite3"`) | `Store/SessionRepository`, `Domain/ProviderSessionTitleResolver` | Relies on the macOS SDK's libsqlite3. Windows has no default header or pkg-config | `Package.swift`, `Sources/CSQLite/module.modulemap` | Replace: the conventional way, adding the SQLite amalgamation as a C target |
| CryptoKit | `CodexEnvironmentManager` | Apple only | None | `Crypto` from swift-crypto (adding the package needs approval) |
| Observation | Many `@Observable` models | A Swift toolchain module. Not confirmed with a Windows build | None | Keep as is |
| Foundation `NSDataDetector` | `AccountLoginController` | Missing (confirmed) | [swift-corelibs-foundation #4305](https://github.com/swiftlang/swift-corelibs-foundation/issues/4305), closed with no plans | Replace with a regular expression |

## Splitting SwiftPM targets

`NativeHarnessClient` is one executable target holding the engine and the macOS screens, so its declarations are
`internal` and tests reach them with `@testable import`. Splitting it into an engine library and a macOS app target
needs the following.

- **Visibility:** the engine types and members the screens use (`AppModel`, stores, projections and so on) must be
  visible outside the target. The `package` access level, visible only inside the same package, allows the split
  without creating an external API. There are many, so change them mechanically by following the compile errors.
- **Removing circular dependencies:** turn the places where the engine calls platform code into injection. The engine
  cannot call an extension in another module, so calls that rely on macOS-layer extensions belong here too.
  - `AppModel`'s default argument `LocalSystemNotificationCenter()` → the app injects it.
  - `AccountLoginController`, owned by `AccountCenterModel` → injected through an engine protocol.
  - `HarnessAccountBroker` → `AccountLoginController.stripANSI` → an engine text utility.
  - `HarnessAccountBroker` → `antigravityCredentialState()` (a macOS-layer extension) → an injected credential
    detection protocol.
  - The transports → `NativeProcessTree` → a protocol, or per-platform implementations inside the engine.
  - The opposite direction (`Platform/macOS` → `HarnessLogoAsset`, `SystemNotificationCenter`) is not a problem.
- **Resources:** both the engine and the screens use `Localizable.strings` through `L10n`, so the engine target owns
  it; check that `L10n`'s rule of trying `Bundle.main` first still works in the app bundle. The `HarnessLogos` images
  go to the macOS target.
- **Dependency placement:** `CSQLite` and `Markdown` go to the engine. `SwiftTerm` goes only to the macOS target, after
  `AccountLoginController` is split. The code in `Development/` goes to the macOS target or a separate fixture target.
- **Test targets:** split the tests into engine tests (`@testable import` of the engine, also run on Windows) and macOS
  tests (the ones that import AppKit, SwiftUI, SwiftTerm, WebKit, Darwin or Security). Once the engine target builds on
  Windows, that build is the strongest check, and `EnginePortabilityTests` can be reduced or removed.
