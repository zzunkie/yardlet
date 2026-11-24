# Contributing to Yardlet

Thanks for taking the time. Yardlet is a personal open-source project. Reports from people who use it and pull
requests are both welcome.

## Issues

- **Bugs:** open a [bug report](../../issues/new?template=bug_report.yml), or choose Help > Report a Problem… in
  Yardlet, which fills in the versions. Include the Yardlet version (Yardlet > About Yardlet), your macOS version, the
  agent and its CLI version, and the steps that lead to the problem.
- **Ideas:** open a [feature request](../../issues/new?template=feature_request.yml) and describe the problem first,
  then what you would like Yardlet to do.
- **Questions:** ask in [Discussions](../../discussions).
- **Security problems:** do not open an issue. Follow [SECURITY.md](SECURITY.md).

Before you attach a log or a screenshot, remove tokens, email addresses, private repository names and anything else
you would not post in public.

## Pull requests

The [roadmap](https://github.com/users/zzunkie/projects/1) shows what's in progress and what's next.

Pull requests are welcome. Development happens in this repository: branches start from `main`, and
changes land on `main` through pull requests.

1. For anything larger than a small fix, open an issue first so the approach can be agreed before
   you spend time on it.
2. Build, check for warnings and run the tests for what you changed before you open the pull
   request (see [Checking your change](#checking-your-change)):

   ```bash
   swift build --build-system native 2>&1 | tee build.log
   ./scripts/product-warnings.sh build.log
   swift test --build-system native --filter <TestClass>
   ./scripts/test-fast.sh
   ```

   Building needs Xcode 27.1 or later. The default build system also compiles SwiftTerm's Metal
   shaders and stops when the Metal toolchain is missing, so use `--build-system native`.
3. CI runs the same build and tests on every pull request that changes more than documents, and they
   must pass before it is merged.
   The run's summary lists failed and skipped tests (with the reason given) and the slowest ones; the
   `test-results` artifact keeps every test's output and time, and a failed run's `test-images`
   artifact keeps the images the tests drew.
4. Keep one change per pull request. Say what changed, why, and how you checked it; for a change you
   can see, add light and dark screenshots or a short recording.
5. Write code comments, documentation, commit messages and the pull request in English. Add or
   update user-visible strings in `Sources/NativeHarnessClient/Resources/en.lproj/Localizable.strings`
   only (see [Localization](#localization)).

[AGENTS.md](AGENTS.md) has the same rules for coding agents working in this repository, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) maps the targets, layers and documents and says where each kind of
change starts.

## Localization

English (`Sources/NativeHarnessClient/Resources/en.lproj/Localizable.strings`) is the single source
of truth for user-visible strings:

- **Feature PRs:** Only add or update keys in `en.lproj/Localizable.strings`. Missing keys in other
  `.lproj` catalogs fall back to the English catalog value safely at runtime, so feature PRs do not
  need to touch non-English translations.
- **Translation syncs:** Non-English catalogs are maintained on their own sync path with
  `scripts/l10n.py` (`status`, `extract`, `merge`, `prune`, `check --strict`) and the shared
  terminology in `l10n/glossary.json`.
- **CI checks:** Every PR verifies that all `L10n` string literals exist in `en.lproj` and that
  bundled translations parse cleanly with exact format-specifier parity. Full parity and orphan
  checks run via `python3 -B scripts/l10n.py check --strict`.

## What fits Yardlet

Yardlet is a quiet native workbench for running coding agents side by side. Changes fit best when they
follow these principles:

- **Let each agent own its loop and storage.** Yardlet starts each agent's own CLI with its own sign-in,
  capabilities and session history, and stays close to the agent's own app. Do not replace an agent's
  loop, invent a parallel prompt framework, or move provider-owned history between folders.
- **Prefer shared paths and reversible features.** Design for every supported agent first, not one
  provider's quirks. Add features that turn on and off cleanly and leave nothing behind when disabled or
  removed. A capability exposed by one provider's API is not, by itself, a reason to add a control,
  shortcut or explanatory text.
- **Keep the UI native and uncluttered.** Follow [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md). Reuse
  existing rows, menus and sensible defaults instead of adding top-level buttons, settings switches,
  badges or multi-step modals.
- **Respect the user's workspace.** Never silently archive, move, rename or reorganize a person's tasks,
  branches, drafts or files without explicit action or approval.
- **Keep trust boundaries local-first.** Credentials, OAuth tokens and Keychain items stay on the host
  and never appear in logs, error messages or remote responses. Treat content read from other tasks, web
  pages, email or terminals as untrusted data, not instructions. Require explicit user approval or
  opt-in per-device permissions for destructive, external or cross-project actions, and never start a
  model turn or wake a runtime for read-only inspection.
- **Protect agent context and tool budgets.** Every MCP tool schema consumes prompt budget across
  harnesses (especially harnesses without deferred tool loading). Prefer extending an existing tool over
  adding a new one, and keep tool schemas concise without dropping safety boundaries.
- **Scale with what changed.** Conversations hold thousands of items and runs emit thousands of events;
  main-thread updates and rendering work must scale with the delta, not re-project full history.

## Before you start a change

Find your kind of change in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#where-to-start), read the document it
names, and extend the tests it lists. The short version:

- **New ACP harness:** add a `HarnessDescriptor` with `transport: .acp` in
  `Sources/NativeHarnessClient/Domain/HarnessKind.swift` and let the shared ACP adapter run it; add its logo
  and, if it has separate account homes, its entry in `Account/ProviderConnections.swift`
  ([PROVIDER_CONNECTIONS](docs/PROVIDER_CONNECTIONS.md)). Extend `HarnessCatalogTests` and the ACP tests.
- **MCP tool or connector:** read [AGENT_BROWSER_TOOLS](docs/AGENT_BROWSER_TOOLS.md) and
  [CONNECTORS](docs/CONNECTORS.md). Extend an existing tool before adding one, keep the schema short, and keep
  credentials on the host. Extend `YardletMCPServerTests` or `AgentToolInjectionTests`.
- **UI change:** follow [DESIGN_SYSTEM](docs/DESIGN_SYSTEM.md), put what a screen shows in a projection under
  `Presentation/` or `Domain/` where it can be shared, and attach light and dark screenshots from the running app
  or `WindowlessRender`.
- **Remote protocol:** change [REMOTE_PROTOCOL](docs/REMOTE_PROTOCOL.md) in the same pull request, keep the
  Mac (`Sources/YardletRemote/`, `Sources/NativeHarnessClient/Remote/`), the phone (`Apps/iOS/`) and the relay
  (`relay/`) consistent, and extend `RemoteProtocolTests` or `RemoteServerTests`.

## Common review requests

These come up most often in review, and checking them first saves a round trip:

- **A control, setting or shortcut for one provider only.** Design for every supported agent first; one
  provider's API offering something is not a reason for new UI.
- **Compiler warnings in a product target.** CI fails on any warning under `Sources/`
  (`scripts/product-warnings.sh`).
- **macOS-only code in the engine.** An `import AppKit`, `SwiftUI`, `Darwin` or similar outside `Views/`,
  `WinUI/`, `Browser/`, `Development/` and `Platform/` fails `EnginePortabilityTests` and the engine-only build
  ([PLATFORM_PORTABILITY](docs/PLATFORM_PORTABILITY.md)). Put the platform part in `Platform/macOS/` under a
  name the engine calls.
- **Edits to non-English `.lproj` catalogs.** Feature pull requests change `en.lproj/Localizable.strings` only.
- **A visible change without light and dark screenshots.**
- **Behavior changed without the document that describes it.** The documents in `docs/` describe how Yardlet
  works now; update the one that owns the behavior in the same pull request.

## Checking your change

| What you changed | Check locally |
| --- | --- |
| Anything in Swift | `swift build --build-system native 2>&1 \| tee build.log` and `./scripts/product-warnings.sh build.log` |
| A contract with tests | `swift test --build-system native --filter <TestClass>` |
| Before the pull request | `./scripts/test-fast.sh` (CI runs it too) |
| Engine code | `YARDLET_ENGINE_ONLY=1 swift build --build-system native --target NativeHarnessClient --force-resolved-versions` |
| A view | `swift test --build-system native --filter WindowlessRenderTests`, or a render of your view with `WindowlessRender`; images go to `.build/windowless-render-qa` |
| User-visible strings | `python3 -B scripts/l10n.py check` |
| The relay | `cd relay && npm ci && npm run typecheck && npm test` |
| The iPhone app | The `xcodebuild` command in [Apps/iOS/README.md](Apps/iOS/README.md) |

A test that waits for something to happen uses `waitUntil`
(`Tests/NativeHarnessClientTests/Support/WaitUntil.swift`), not a fixed sleep, because CI runs slower than a Mac.

## Building from source

See [Development](README.md#development) in the README.

## Code of conduct

Everyone taking part in this project's issues and discussions is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE), like the rest of the
project.
