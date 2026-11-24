# Architecture

A map of the code and the documents: which target owns what, where a kind of change starts, and which
document and tests to read first. The rules for contributing are in [CONTRIBUTING.md](../CONTRIBUTING.md);
the rules for coding agents are in [AGENTS.md](../AGENTS.md). Each document below owns the details of its
area; this page only points to them.

## Targets and layers

All Swift targets are declared in [Package.swift](../Package.swift). Which of them a build includes depends on
the platform and on three environment variables: `YARDLET_ENGINE_ONLY=1` and `YARDLET_CEF_DIR` for the product
targets, and `YARDLET_WINDOWS_TESTS=1` for the Windows tests.

| Target or folder | What it is | Boundary |
| --- | --- | --- |
| `NativeHarnessClient` (`Sources/NativeHarnessClient/`) | The app: its model (`AppModel*.swift`), the harness adapters (`Adapters/`), runtime and process handling (`Runtime/`), domain types (`Domain/`), projections the screens read (`Presentation/`), storage (`Store/`), connectors, the vault, the remote bridge, and the screen and platform layers | On macOS an executable, on Windows the Windows app, on Linux the headless host `yardlet` |
| Engine | Every folder of `NativeHarnessClient` outside the screen and platform layers, plus `YardletAgentTools` outside its `Platform/` | Cross-platform Foundation Swift: no SwiftUI, AppKit, WebKit, SwiftTerm, Darwin, Security, CryptoKit or other macOS-only imports and APIs. `EnginePortabilityTests` scans for them and `YARDLET_ENGINE_ONLY=1` builds the engine alone ([PLATFORM_PORTABILITY](PLATFORM_PORTABILITY.md)) |
| macOS layers | `Views/`, `Browser/` (the WebKit preview), `Development/` (visual fixtures and QA), `Platform/macOS/`, `NativeHarnessClientApp.swift` and `Resources/Mermaid` (`macOSLayers` in `Package.swift`) | Mac only; `Platform/POSIX/` is shared by the Mac app and the Linux host |
| Windows layers | `WinUI/` (WinUI 3 screens) and `Platform/Windows/`, on the bindings in [Windows/](../Windows/README.md) | Built only on Windows |
| Linux layer | `Platform/Linux/` | The headless host ([LINUX_HOST](LINUX_HOST.md)) |
| `Platform/Portable/` | Foundation versions of what each platform layer provides under the same names | Used by the engine-only build and for what the Windows and Linux layers do not provide yet |
| `YardletAgentTools` | The MCP protocol, the tool catalogs and schemas, and the local connection shared by the app and `yardlet-mcp` | Engine code (Foundation only) outside `Platform/` |
| `YardletMCP` | The `yardlet-mcp` executable that harnesses start as an MCP server | Thin wrapper over `YardletAgentTools` |
| `YardletRemote` | The remote protocol, pairing, the Noise channel and the server, with no UI; the WebSocket listeners per platform | Shared with the iPhone app ([REMOTE_PROTOCOL](REMOTE_PROTOCOL.md)) |
| `YardletRemoteFixture`, `YardletRemoteFixtureSupport` | A fixture host behind the remote protocol for the phone client and the remote tests | Not linked by the app |
| `YardletBrowserHost`, `YardletCEFBridge`, `YardletCEFHelper` | The Chromium (CEF) browser host process and its helper | Built only when `YARDLET_CEF_DIR` names a CEF distribution (`scripts/build-app.sh` sets it); Yardlet itself never loads CEF ([BROWSER_HOST](BROWSER_HOST.md)) |
| `YardletSurfacePort`, `YardletCEFAccessibility` | IOSurface hand-off between the browser host and the app; CEF accessibility output in the host contract's shape | Mac only; `YardletCEFAccessibility` is Foundation only so tests run without CEF |
| `YardletSimulatorHost`, `YardletSimulatorHostProtocol` | The helper that shows and drives iOS simulators, and the typed protocol Yardlet speaks to it | Mac only ([SIMULATOR](SIMULATOR.md)) |
| `YardletLidSleep`, `YardletLidHelper` | The lid helper's state, its XPC interface and the privileged helper | Mac only ([SLEEP_PREVENTION](SLEEP_PREVENTION.md)) |
| `CSQLite` | SQLite: the system library on macOS and Linux, `winsqlite3` on Windows (`Sources/CSQLiteWindows`) | |
| `Apps/iOS/` | The iPhone remote, a SwiftUI app built with Xcode on `YardletRemote` | [Apps/iOS/README.md](../Apps/iOS/README.md) |
| `relay/` | The relay that connects devices when the direct path fails, and the push and account endpoints: a Cloudflare Worker in TypeScript | [relay/README.md](../relay/README.md), REMOTE_PROTOCOL §14 |
| `scripts/` | Build, bundle, signing, release, test, localization and QA scripts | See [Checks](#checks) |

Test targets: `Tests/NativeHarnessClientTests/` builds against the Mac app and holds almost every test;
`Tests/YardletHostTests/` builds against the Linux host and `Tests/YardletWindowsTests/` against the Windows app
(`YARDLET_WINDOWS_TESTS=1`).

### Harness adapters

Each harness is described by a `HarnessDescriptor` in `HarnessCatalog.builtIns`
(`Sources/NativeHarnessClient/Domain/HarnessKind.swift`): its executable, launch arguments, install paths and
transport. `HarnessRegistry` (`Runtime/HarnessRegistry.swift`) chooses the adapter for the transport:

| Transport | Adapter folder | Harnesses |
| --- | --- | --- |
| `codexAppServer` | `Adapters/Codex/` | Codex |
| `claudeStreamJSON` | `Adapters/Claude/` | Claude Code |
| `acp` (Agent Client Protocol) | `Adapters/ACP/` | OpenCode, Antigravity CLI, Kimi Code, Grok Build, Hermes Agent, Kiro CLI |
| `cursorStreamJSON` | `Adapters/Headless/` | Cursor Agent |
| `msp` | `Adapters/Muse/` | Muse Code |
| `piRPC` | `Adapters/PiRPC/` | Pi |

The adapters speak to the app through the Yardlet Harness Protocol ([YARDLET_HARNESS_PROTOCOL_V1](YARDLET_HARNESS_PROTOCOL_V1.md)).
Each harness keeps its own sign-in and history; [NATIVE_SESSION_STORAGE](NATIVE_SESSION_STORAGE.md) says what
Yardlet reads and stores beside it.

## Where to start

### UI or design change

- Read [DESIGN_SYSTEM](DESIGN_SYSTEM.md) first; shared tokens are in `Views/ParityDesignSystem.swift`.
- Screens are in `Views/` (macOS) and `WinUI/` (Windows). What a screen shows is usually computed in
  `Presentation/` or `Domain/` as a projection; change the projection there, not only the view, so the Windows
  app and the remote get the same result.
- User-visible strings go in `Sources/NativeHarnessClient/Resources/en.lproj/Localizable.strings` only.
- Render the view in light and dark with `WindowlessRender` (see `Tests/NativeHarnessClientTests/WindowlessRenderTests.swift`;
  images go to `.build/windowless-render-qa`) or check it in the running app, and attach both screenshots.

### New ACP harness

- Add a `HarnessKind` and a `HarnessDescriptor` with `transport: .acp` in `Domain/HarnessKind.swift`. The shared
  ACP adapter (`Adapters/ACP/ACPAdapter.swift`) then runs it; avoid harness-specific branches unless the harness
  really differs from ACP.
- Add its logo to `Resources/HarnessLogos/` (with its source in `SOURCES.md`) and its case in
  `Domain/HarnessLogoAsset.swift`.
- If it has a home folder or environment variable for separate accounts, follow
  `Account/ProviderConnections.swift` and [PROVIDER_CONNECTIONS](PROVIDER_CONNECTIONS.md).
- Tests to extend: `HarnessCatalogTests`, `ACPAdapterTests`, `ACPProtocolTests`, `ACPSessionHistoryTests`.

### Existing harness adapter or session storage

- Read [NATIVE_SESSION_STORAGE](NATIVE_SESSION_STORAGE.md) before touching storage, import, resume, titles or
  the Account Center, and [ACCOUNT_SELECTION_UX](ACCOUNT_SELECTION_UX.md) for account choice.
- The adapter is in `Adapters/<Harness>/`; process launch and environment are in `Runtime/`; Yardlet's own
  index is in `Store/`.
- Keep a session ID with the storage it was saved in, and never rewrite provider-owned history.
- Tests to extend: the adapter's and protocol's own tests (`CodexAdapterTests`, `CodexProtocolTests`,
  `ClaudeAdapterTests`, `ClaudeProtocolTests`, `ACPAdapterTests` and the like), with the shared transcripts in
  `Tests/NativeHarnessClientTests/Support/ConversationFixtures.swift` and `TranscriptProjectionFixtures.swift`.

### MCP tool or connector

- Read [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) (tools, injection per harness, code locations, security)
  and [CONNECTORS](CONNECTORS.md).
- Tool definitions are catalogs in `Sources/YardletAgentTools/`; their answers are in
  `Sources/NativeHarnessClient/AgentTools/` and `AppModel+*Tool*.swift`; connectors are in
  `Sources/NativeHarnessClient/Connectors/`.
- Every tool schema costs prompt budget in every harness: extend an existing tool before adding one, and keep
  descriptions short without dropping safety rules.
- Tests to extend: `YardletMCPServerTests`, `AgentToolInjectionTests`, `BrowserAgentToolsTests`.

### Remote protocol, iPhone or Windows

- Read [REMOTE_PROTOCOL](REMOTE_PROTOCOL.md); it is the contract both sides implement. The design record is
  [design/REMOTE_V2_DESIGN](design/REMOTE_V2_DESIGN.md).
- The protocol and server are in `Sources/YardletRemote/`; the app's side is in
  `Sources/NativeHarnessClient/Remote/` (`AppModelRemoteBridge*.swift`); the phone client is in `Apps/iOS/`;
  the relay is in `relay/`.
- Change the protocol document in the same pull request, and keep older clients working or say why not.
- For Windows, read [PLATFORM_PORTABILITY](PLATFORM_PORTABILITY.md), "The Windows app", and
  [Windows/README.md](../Windows/README.md).
- Tests to extend: `RemoteProtocolTests`, `RemoteServerTests`, and `relay/test/` for the relay.

### Performance or main-thread work

- Read [PERFORMANCE_BENCH](PERFORMANCE_BENCH.md); the bench is in `scripts/perf-bench/`.
- Work done on the main thread for every provider event, publication or timer tick must scale with what changed,
  not with the whole history. `AppModelPublicationCounts.swift` counts publications; check a change with a long
  history and count publications and redraws, not only the result.
- Tests to extend: `StreamingPublicationTests` and the in-process benchmarks the bench document lists.

## Checks

| Check | Command |
| --- | --- |
| Build | `swift build --build-system native` |
| No warnings in product targets | `swift build --build-system native 2>&1 \| tee build.log; scripts/product-warnings.sh build.log` |
| Tests for the contract you changed | `swift test --build-system native --filter <TestClass>` |
| Quick suite, as CI runs it | `./scripts/test-fast.sh` |
| Engine without screens | `YARDLET_ENGINE_ONLY=1 swift build --build-system native --target NativeHarnessClient --force-resolved-versions` |
| Light and dark renders | `swift test --build-system native --filter WindowlessRenderTests` (renders are left out of `test-fast.sh`) |
| Localization catalogs | `python3 -B scripts/l10n.py check` (`--strict` for full parity) |
| Relay | `cd relay && npm ci && npm run typecheck && npm test` |

CI workflows are in `.github/workflows/`: `ci.yml` (build, warnings, quick suite), `linux-engine.yml` (engine-only build),
`windows-engine.yml` (engine-only build, the Windows app build and `YardletWindowsTests`), `linux-host.yml`, `windows-app.yml`, `ios.yml`, `relay.yml` and the
nightly `full-tests.yml`.

## Documents

Documents in `docs/` describe how Yardlet works now. `docs/design/` holds design records, which are not kept
current.

| Document | What it covers |
| --- | --- |
| [ACCOUNT_SELECTION_UX](ACCOUNT_SELECTION_UX.md) | How the person sees signed-in accounts and picks one for a task |
| [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) | The Yardlet MCP server, its tools, injection per harness, IPC, code locations and security |
| [BROWSER_HOST](BROWSER_HOST.md) | The in-window browser on macOS: the CEF host process, the panel, input, accessibility, build and signing |
| [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) | Browser profiles per task, cookie copying and import from other browsers |
| [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md) | The vault (Passwords): sign-ins, codes, passkeys and cards, filled without showing values to the model |
| [CALENDAR](CALENDAR.md) | The calendar view over connected Google, Outlook and Apple calendars |
| [CONNECTORS](CONNECTORS.md) | The connector contract: connection types, directory, what harnesses see, storage and each service |
| [CONVERSATION_MEDIA](CONVERSATION_MEDIA.md) | Pictures, video, sound, Mermaid diagrams and widgets shown in a conversation |
| [DESIGN_SYSTEM](DESIGN_SYSTEM.md) | Tokens, semantic colors, component contracts, reference measurements and Mac shortcuts |
| [LINUX_HOST](LINUX_HOST.md) | The headless Linux host, `yardlet host` |
| [MAILBOX](MAILBOX.md) | The mailbox over connected Gmail, Outlook and IMAP accounts |
| [NATIVE_SESSION_STORAGE](NATIVE_SESSION_STORAGE.md) | Task identity, storage scope, what Yardlet reads from each harness and what it stores |
| [PERFORMANCE_BENCH](PERFORMANCE_BENCH.md) | The performance bench: scenes, numbers, budgets and in-process benchmarks |
| [PERSONAL_AGENTS](PERSONAL_AGENTS.md) | The Personal agents list of existing cloud agents in the sidebar |
| [PLATFORM_PORTABILITY](PLATFORM_PORTABILITY.md) | Engine and platform layers, the engine-only build, the Windows app and the portability check |
| [PROVIDER_CONNECTIONS](PROVIDER_CONNECTIONS.md) | Harness, model provider and account connections, and usage per account |
| [REMOTE_PROTOCOL](REMOTE_PROTOCOL.md) | The remote protocol between hosts, the phone and Windows clients, and the relay |
| [SIMULATOR](SIMULATOR.md) | iOS simulators, Android emulators and devices in the side panel |
| [SLEEP_PREVENTION](SLEEP_PREVENTION.md) | Keeping the Mac awake while tasks work, including with the lid closed |
| [TOKEN_USAGE](TOKEN_USAGE.md) | Token counts read from Claude Code and Codex transcripts, with plan limits |
| [YARDLET_HARNESS_PROTOCOL_V1](YARDLET_HARNESS_PROTOCOL_V1.md) | The request, response and event contract between Yardlet and a harness adapter |
