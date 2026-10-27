# Engine portability review (2026-09-27)

Status: checklist written, three pieces of macOS code that could be moved mechanically moved to `Platform/macOS/`, and
a check that blocks new violations added. macOS behavior did not change.
Basis: the code and product decisions as of 2026-09-27 (macOS and Windows support, the engine in cross-platform
Swift, the screens per platform). Nothing was actually built on Windows. For dependencies and Foundation behavior, only
what was checked in the official source is written as "confirmed"; the rest is left as "not confirmed".

## Scope

- **Engine:** `Account`, `Adapters`, `Diff`, `Domain`, `Files`, `Presentation`, `Runtime`, `Store`,
  `Transcript`, and at the root `AppModel.swift`, `Localization.swift` and `ProductIdentity.swift`: 127 files.
  New folders count as engine by default.
- **Screen and platform layer (excluded from the check):** `Views/` (40), `Browser/` (1, the WebKit preview, which the
  product decision replaces with CEF and WebView2), `Development/` (6, visual fixtures), `Platform/macOS/` (3, created
  in this pass), `NativeHarnessClientApp.swift`.

## Summary

| Category | Files at review | After the move | Files |
| --- | --- | --- | --- |
| UI framework imports (SwiftUI, AppKit, WebKit, SwiftTerm) | 3 | 1 | `AccountLoginController` (before the move also: `HarnessLogoCatalog`, `SystemNotificationCenter`) |
| Darwin and POSIX APIs (signals, process groups, `proc_*`, `waitpid`, PTY, `copyfile`) | 3 | 3 | `NativeProcessTree`, `AccountLoginController`, `CodexEnvironmentManager` |
| macOS-only frameworks (Security, UserNotifications, NSWorkspace, CryptoKit, NSDataDetector) | 5 | 2 | `AccountLoginController`, `CodexEnvironmentManager` (before the move also: `HarnessAccountBroker`, `SystemNotificationCenter`, `HarnessLogoCatalog`) |
| Path assumptions and executable lookup | 15 | 15 | Section 3 below |
| Windows differences in Foundation `Process`, `FileHandle` and file permissions | 19 | 19 | Section 4 below |
| External dependencies (swift-markdown, SwiftTerm, SQLite) | 3 dependencies, 5 engine files | Same | Section 5 below |

The three biggest obstacles:

1. **Process lifetime management.** Every harness transport, Git and the account commands leave termination to
   `NativeProcessTree`. This code collects descendants with `proc_listchildpids` and sends signals with `kill`, up to
   the process group. On Windows, Foundation's `Process` creates no job object, and `terminate()` ends only the root
   process with `TerminateProcess`, so grandchild processes such as node and MCP servers stay behind. On Windows
   `interrupt()` is also `TerminateProcess(handle, SIGINT)`, not a graceful stop (confirmed:
   [swift-corelibs-foundation `Process.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/Process.swift)).
2. **Executable lookup and run environment.** The code assumes a `PATH` joined with `:`, Homebrew, `/usr/local` and
   `.app/Contents` paths, `HOME`, and executable names without extensions. It does not handle Windows's `;` separator,
   `PATHEXT` and `.exe`, npm's `.cmd` shims or `USERPROFILE`. Foundation `Process` does not send `.cmd` and `.bat` to
   `cmd.exe` (confirmed: same source).
3. **Account sign-in terminal.** `AccountLoginController` is a controller attached to SwiftTerm's
   `LocalProcessTerminalView` (a PTY and an AppKit view), yet the engine's `AccountCenterModel` owns it directly, and
   `HarnessAccountBroker` parses output with its static functions. SwiftTerm builds on Windows without the PTY layer,
   and `NSDataDetector`, which URL detection uses, does not exist in Foundation outside Apple platforms.

## What moved in this pass

Behavior is the same. The moved code is unchanged, and on the engine side only name references changed. Moved files
are not added to the check's allow list.

| Before | New location (macOS layer) | What stays in the engine |
| --- | --- | --- |
| All of `Domain/HarnessLogoCatalog.swift` (NSImage loading and cache, SwiftUI icon view) | `Platform/macOS/HarnessLogoCatalog.swift` | `Domain/HarnessLogoAsset.swift`: the asset name and subfolder name per harness |
| `LocalSystemNotificationCenter` (UserNotifications), `systemSettingsURL` and `openSystemSettings()` (NSWorkspace) from `Domain/SystemNotificationCenter.swift` | `Platform/macOS/LocalSystemNotificationCenter.swift` | The `SystemNotificationCenter` protocol, `SystemNotificationAuthorization`, `SystemNotificationSettingsModel` (an unused default argument removed) |
| `HarnessAccountBroker.antigravityCredentialState` (Keychain `SecItemCopyMatching`) | `Platform/macOS/AntigravityKeychainProbe.swift` (an extension with the same name) | The call site `Self.antigravityCredentialState()`. The Windows layer must provide the same function |

## Checklist and recommended handling

There are three kinds of recommended handling. **Move:** move the code to the platform layer. **Abstract:** keep only a
small protocol or values in the engine and let the platform layer provide the implementation. **Replace:** the means to
use on Windows.

### 1. UI frameworks and macOS-only frameworks

| File | Item | Recommended handling |
| --- | --- | --- |
| `Account/AccountLoginController.swift` | `import AppKit`, `SwiftTerm`, `Darwin`; `NSWorkspace.open`, `NSPasteboard`; `LocalProcessTerminalView` (PTY); `pid_t`; `NSDataDetector` (`firstHTTPSURL`) | Abstract: put a sign-in session protocol (state, phase, sending input) and pure text parsing (`stripANSI`, `firstDeviceCode`, `outputRequiresInput`, finding URLs) in the engine. Find URLs with a regular expression instead of `NSDataDetector`. Move the SwiftTerm host. Replace: a ConPTY host on Windows. **Why it was not moved:** it is tied to the PTY and to process termination, and `AccountCenterModel`, `HarnessAccountBroker` and several tests refer to its types directly, so it is not a mechanical move. |
| `Runtime/CodexEnvironmentManager.swift` | `import CryptoKit` (`SHA256` fingerprint); `import Darwin` and `copyfile(COPYFILE_ALL | COPYFILE_CLONE)` | Replace: CryptoKit with `Crypto` from swift-crypto, which has the same API (this needs a package added, so it was not done this time). `copyfile` already has a `FileManager.copyItem` fallback, so either abstract only the clone function into the platform layer or wrap it in `#if canImport(Darwin)`. |
| `Account/HarnessAccountBroker.swift` | 4 user-facing strings that name Keychain as the Antigravity credential location; `Self.antigravityCredentialState()` is in a macOS-layer extension | Abstract: the platform provides the credential location text and the detection. Where the Antigravity CLI stores credentials on Windows is not confirmed. |
| `Domain/HarnessKind.swift` | SF Symbols names in `symbolName` (macOS icon names inside engine data) | Abstract: the screen layer picks the icon by harness ID. Windows uses the logo assets first. They are strings, so the check does not cover them. |
| `AppModel.swift` | The default argument `LocalSystemNotificationCenter()` names the macOS implementation | Move: the app injects it when the targets split. For now it stays, because there are many call sites. |

### 2. Darwin and POSIX process APIs

| File | Item | Recommended handling |
| --- | --- | --- |
| `Runtime/NativeProcessTree.swift` | Collecting descendants with `proc_listchildpids`, `kill(pid, SIGHUP/SIGKILL)`, `kill(-pgid, …)`, `waitpid`, `usleep`, `pid_t` | Abstract: put a protocol with `terminate(process:) -> Int32` and `terminate(rootPID:)` in the engine, and move the current code unchanged into the macOS implementation. Replace: on Windows, put the process in a job object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) right after it starts and end it with `TerminateJobObject`. Adding it after Foundation `Process` has started it leaves a short gap, so also consider creating the process directly with `CREATE_SUSPENDED`. **Why it was not moved:** it is the termination path of every transport, so moving it risks changing behavior. |
| `NativeProcessTree` call sites (9 in the engine): `AccountCommandRunner`, `AccountLoginController`, `ACPProcessTransport`, `ClaudeProcessTransport`, `CodexProcessTransport`, `PiRPCProcessTransport`, `StructuredHeadlessAdapter`, `GitDiffService`, `HarnessProtocolProcessHost` | Leave termination to the functions above | With the protocol above, only the names change at the call sites. |
| `Adapters/Headless/StructuredHeadlessAdapter.swift` | `process.interrupt()` (SIGINT on macOS) | Replace: on Windows this becomes an immediate kill, so use the harness protocol's cancel first, and if there is none, consider `CREATE_NEW_PROCESS_GROUP` with `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)`. Whether each CLI treats this as a stop is not confirmed. |
| PTY | In the engine, only `AccountLoginController` (through SwiftTerm `LocalProcess`). The screen layer's `Views/TerminalPane` also uses a PTY | Replace: Windows ConPTY (`CreatePseudoConsole`). |

### 3. Path assumptions and executable lookup

| File | Item | Recommended handling |
| --- | --- | --- |
| `Runtime/RuntimeProcessEnvironment.swift` | Splits and joins `PATH` with `:`. Fixed `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `~/.local/bin`, `~/.bun/bin`; `HOME`. `searchDirectories` adds the package managers' folders (`~/.volta/bin`, `~/.cargo/bin`, `~/.deno/bin`, `~/.npm-global/bin`, `~/Library/pnpm`), nvm's `~/.nvm/versions/node/*/bin` and Docker Desktop's `bin` | Abstract: the platform provides the separator and the default path list. On Windows: `;`, a case-insensitive `Path` key, `USERPROFILE`, `%APPDATA%\npm` and so on. |
| `Runtime/RuntimeSelectionStore.swift` | Candidates in `RuntimeProcessEnvironment.searchDirectories`, `/Applications/ChatGPT.app/Contents/Resources/codex`, `~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude`, splitting `PATH` at `:`, breaking relative paths apart at `/` | Abstract: the platform provides the install candidates per harness. The Windows candidates (each CLI's install location) are not confirmed. |
| `Diff/GitExecutableLocator.swift` | `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/opt/local/bin/git`, fallback `/usr/bin/git` | Abstract: the platform provides the candidate list. On Windows: `git.exe` in `PATH` and the Git for Windows install path. |
| `Diff/GitDiffService.swift` | `/dev/null` as a Git argument (`hash-object`, `diff --no-index`) | Whether Git for Windows accepts this path is not confirmed. For the empty tree, consider a way without a path, such as `git hash-object -t tree --stdin`. The `/dev/null` in `UnifiedDiffParser` is Git's output format, so it stays. |
| `Domain/HarnessKind.swift` | `relativeExecutablePaths` are POSIX paths without extensions (`.local/bin/codex`, `.hermes/hermes-agent/venv/bin/hermes` and others) | Abstract: candidates per platform. A Windows venv uses `Scripts\*.exe`. |
| `Account/ProviderConnections.swift`, `Account/ProviderConnectionService.swift`, `Domain/ProviderSessionTitleResolver.swift`, `Domain/WorkspaceGitOrigin.swift` | Decide absolute paths with `hasPrefix("/")` | Replace: gather them into one shared check that accepts `C:\` and UNC paths. |
| `Domain/CodexWorkSurfaceProjection.swift`, `Files/WorkspaceFileService.swift`, `Domain/Project.swift` | Decide whether a path is inside the workspace folder with a `root + "/"` string prefix, and split at `/` | Replace: compare path components instead, and account for the case-insensitive file system on Windows. The containment check is a security boundary, so add tests with it during the Windows work. |
| `Runtime/CodexEnvironmentManager.swift` | `~/` expansion | Usable on Windows too, but it should also accept `\` as a separator. |
| `Account/HarnessAccountBroker.swift` | Finds the Grok home from the `HOME` environment variable (usually missing on Windows) | Use `homeDirectoryForCurrentUser` throughout. |
| `Store/SessionRepository.swift`, `Domain/ProviderSessionTitleResolver.swift` | Pass the `URL.path(percentEncoded: false)` string to SQLite | Replace: `withUnsafeFileSystemRepresentation`. Whether `path()` becomes `/C:/…` on Windows is not confirmed. |

Foundation also provides `~/.yardlet`, `applicationSupportDirectory` and `UserDefaults` from `ProductIdentity.swift` and
`AppModel.swift` on Windows. The actual storage location (AppData, the registry and so on) is not confirmed.

### 4. Foundation `Process`, `FileHandle` and file permissions

The 19 files: `AccountCommandRunner`, `AccountLoginController`, `ProviderConnections`, `ACPAdapter`,
`ACPProcessTransport`, `ClaudeAdapter`, `ClaudeProcessTransport`, `CodexAdapter`, `CodexProcessTransport`,
`StructuredHeadlessAdapter`, `MuseAdapter`, `PiRPCAdapter`, `PiRPCProcessTransport`, `GitDiffService`,
`GitExecutableLocator`, `HarnessProtocolProcessHost`, `HarnessRuntimeCompatibility`, `RuntimeSelectionStore` and
`ComposerDraftRepository`.

| Item | Windows behavior | Recommended handling |
| --- | --- | --- |
| `Process.run()` (12 files) | Quotes the arguments by Windows rules, passes them to `CreateProcessW`, and does not handle `.cmd` and `.bat` separately (confirmed) | Find the real `.exe` in the lookup step. If there is only a shim, wrap it in `cmd.exe /d /s /c`, but take care with argument escaping (the BatBadBut family). |
| `isExecutableFile(atPath:)` (8 files) | swift-foundation decides with `SHGetFileInfoW(SHGFI_EXETYPE)` | Whether it treats a `.cmd` shim as executable is not confirmed. Put the check in the lookup abstraction. |
| `terminate()` / `interrupt()` | Both are `TerminateProcess` and end only the root (confirmed) | The job object from section 2. |
| `readabilityHandler` | Supported through `DuplicateHandle`, `_open_osfhandle` and a Dispatch read source (confirmed: [`FileHandle.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/FileHandle.swift)) | No change needed. |
| `process.environment` | Windows environment variable names are case-insensitive | Normalize the keys so that `PATH` and `Path` do not both appear. |
| `.posixPermissions` 0o600 and 0o700 (`ProviderConnections`, `ComposerDraftRepository`) | There are no POSIX modes, so access by the user alone is not guaranteed | Replace: store under the user profile + ACL. How Foundation applies this attribute is not confirmed. |

### 5. External dependencies

CryptoKit, Observation and `NSDataDetector` are not package dependencies, but they need the same judgment, so they are
listed here too.

| Dependency | Engine use | Windows | Evidence | Recommended handling |
| --- | --- | --- | --- | --- |
| swift-markdown 0.8.0 (swift-cmark 0.8.0) | `TranscriptInlineContent`, `TranscriptMarkdownDocument` | The manifest has Windows-specific settings. An actual build is not confirmed | `CMARK_GFM_STATIC_DEFINE` `.when(platforms: [.windows])` in swift-markdown's `Package.swift`, `#if os(Windows)` in swift-cmark's `Package.swift` | Keep it in the engine. Confirm with a build in the Windows preview. |
| SwiftTerm 1.18.0 | `AccountLoginController` | Only the terminal parser builds. No PTY or view (confirmed) | The manifest's `os(Windows)` branch leaves out the `Apple`, `Mac` and `iOS` sources, and `LocalProcess.swift`, `Pty.swift` and `HeadlessTerminal.swift` are under `#if !os(iOS) && !os(Windows)` | Take it out of the engine (section 1). The Windows terminal uses ConPTY and a Windows view. |
| CSQLite (`systemLibrary`, `pkgConfig: "sqlite3"`, brew provider, `link "sqlite3"`) | `Store/SessionRepository`, `Domain/ProviderSessionTitleResolver` | Relies on the macOS SDK's libsqlite3. Windows has no default header or pkg-config | `Package.swift`, `Sources/CSQLite/module.modulemap` | Replace: the conventional way, adding the SQLite amalgamation as a C target. Decide the approach at the Windows preview. |
| CryptoKit | `CodexEnvironmentManager` | Apple only | None | `Crypto` from swift-crypto (adding the package needs approval). |
| Observation | Many `@Observable` models | A Swift toolchain module. Not confirmed with a Windows build | None | Keep as is. |
| Foundation `NSDataDetector` | `AccountLoginController` | Missing (confirmed) | [swift-corelibs-foundation #4305](https://github.com/swiftlang/swift-corelibs-foundation/issues/4305), closed with no plans | Replace with a regular expression. |

## Checks that block new violations

`Tests/NativeHarnessClientTests/EnginePortabilityTests.swift`.

- In engine files (the scope above, new folders included), it looks for forbidden imports (SwiftUI, AppKit, UIKit, Cocoa,
  WebKit, SwiftTerm, Darwin, Security, UserNotifications, CryptoKit and others) and macOS-only API rules (names qualified
  with `Darwin.`, signals, `waitpid` and `pid_t`, `proc_*` and `sysctl`, PTY functions, `posix_spawn`, `copyfile`,
  Keychain, `UN*` notification types, AppKit types, FSEvents and kqueue, APIs missing from Foundation outside Apple
  platforms, `x-apple.` URLs). Line comments are skipped.
- The allow list is a set of rule names per file. Right now it has 3 files and 13 entries:
  `AccountLoginController` (6), `CodexEnvironmentManager` (3), `NativeProcessTree` (4).
- A violation in a file that is not on the allow list, or a new kind of violation in an allowed file, fails. When an
  allowed entry no longer applies, the test fails and asks for it to be removed from the list. The cap of 13 entries can
  only go down.
- Path assumptions (section 3) and `Process` semantics (section 4) are string and behavior problems, so they are not in
  the check.

## Suggested next steps

1. Split the text parsing of `AccountLoginController` into engine types (no behavior change, small).
2. Abstract the executable candidates and `PATH` composition into lists that the platform provides, keeping the macOS
   values as they are.
3. Move `NativeProcessTree` behind a protocol, keeping the macOS implementation as it is. Build the Windows job object
   implementation in the Windows preview.
4. Decide on adopting swift-crypto and on how to include SQLite (adding packages needs separate approval).

## To do when splitting SwiftPM targets

Right now there is a single executable target, so every declaration is `internal`, and tests reach them with
`@testable import`. This is what splitting into an engine library target and a macOS app target needs.

- **Visibility:** the engine types and members that the screens use (`AppModel`, stores, projections and so on) must be
  opened outside the target. Using the `package` access level, which is visible only inside the same package, instead
  of `public` allows the split without creating an external API. There are many of them, so change them mechanically
  by following the compile errors.
- **Removing circular dependencies:** turn the places where the engine calls platform code into injection. The engine
  cannot call an extension in another module, so calls that rely on macOS-layer extensions belong here too.
  - `AppModel`'s default argument `LocalSystemNotificationCenter()` → the app injects it.
  - `AccountLoginController`, owned by `AccountCenterModel` → injected through an engine protocol.
  - `HarnessAccountBroker` → `AccountLoginController.stripANSI` → move to an engine text utility.
  - `HarnessAccountBroker` → `antigravityCredentialState()` (macOS-layer extension) → an injected credential detection
    protocol.
  - The transports → `NativeProcessTree` → a protocol, or per-platform implementations inside the engine.
  - The opposite direction (`Platform/macOS` → `HarnessLogoAsset`, the `SystemNotificationSettingsModel` extension) is
    not a problem.
- **Resources:** both the engine and the screens use `Localizable.strings` through `L10n`, so the engine target owns it;
  check that `L10n`'s rule of trying `Bundle.main` first still works in the app bundle. The `HarnessLogos` PNGs go to
  the macOS target.
- **Dependency placement:** `CSQLite` and `Markdown` go to the engine. `SwiftTerm` goes only to the macOS target, after
  `AccountLoginController` is split. The fixtures in `Development/` (SwiftUI) go to the macOS target or a separate
  fixture target.
- **Test targets:** of 114 test files, 12 import AppKit, SwiftUI, SwiftTerm, WebKit, Darwin or Security. Split them
  into engine tests (`@testable import` of the engine, also run on Windows) and macOS tests. After the split, building
  the engine target on Windows becomes the strongest check, so `EnginePortabilityTests` is reduced or removed then.
