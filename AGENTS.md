# Yardlet development

Yardlet is a native macOS app for running coding agents. Each agent keeps its own agent loop, sign-in,
capabilities and session history; Yardlet starts the agent's own CLI and stays close to the agent's
own app.

Maintainers keep working notes outside this repository, in the ignored folder `docs/internal/`. If
`docs/internal/AGENTS.md` exists, read it first and follow it.

## Product rules

- Yardlet must not be harder to use than the agent's own app, and should feel close to it.
- Prefer shared paths across agents; add only features that turn on and off easily and leave nothing
  behind once turned off or removed.
- A feature that one provider's API offers is not, on its own, a reason to add a control, a shortcut
  or explanatory text. Follow [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md) and keep the UI native and
  uncluttered.
- Respect the user's workspace: never silently archive, move or reorganize a person's tasks, drafts or
  files without explicit request or approval, and keep credentials and trust boundaries host-local.
- Protect MCP tool budgets across harnesses: prefer extending an existing tool over adding a new one,
  and keep schemas concise without weakening safety rules.
- Add or change user-visible strings in `Sources/NativeHarnessClient/Resources/en.lproj/Localizable.strings`
  only. Other `.lproj` catalogs fall back to English at run time and are synced separately with
  `scripts/l10n.py` ([CONTRIBUTING.md](CONTRIBUTING.md#localization)).
- For session storage, import, resume, titles or the Account Center, read
  [native session storage](docs/NATIVE_SESSION_STORAGE.md). See [CONTRIBUTING.md](CONTRIBUTING.md#what-fits-yardlet)
  for the full contributor principles.

## Code and verification

- App and agent adapters: `Sources/NativeHarnessClient/`; tests: `Tests/NativeHarnessClientTests/`;
  package targets: [Package.swift](Package.swift).
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) maps the targets, layers and documents, and says where each kind
  of change starts.
- Building needs Xcode 27.1 or later. Build with `swift build --build-system native`: the default
  build system also compiles SwiftTerm's Metal shaders and stops when the Metal toolchain is missing.
- The product targets build without compiler warnings, and CI fails on one
  (`scripts/product-warnings.sh`). The test target's warnings are not counted.
- Fix a cause where it lives, in the shared rule or path, rather than patching the one case that
  showed it. Add a test only when it pins a contract that could otherwise break unnoticed; prefer
  extending an existing test.
- When a defect comes back after a fix, or the same kind of defect turns up in a second place, the
  second fix also adds the check that would have caught both: a source rule test (see
  [the checks that only tighten](docs/ARCHITECTURE.md#checks-that-only-tighten)) or a contract test on
  the shared path that CI runs. Remove the narrower tests it covers.
- Main-thread code that runs for every provider event, publication or timer tick does work in
  proportion to what changed, not to the whole history: a conversation can hold thousands of items
  and an agent run thousands of events. When such a path changes, check it with a long history and
  count the publications and redraws, not only the result.
- A test that checks something happened in its own time waits for it with `waitUntil`
  (`Tests/NativeHarnessClientTests/Support/WaitUntil.swift`), not a fixed sleep: CI runs slower than
  a Mac. A sleep is only for checking that something did not happen.
- Before a pull request, build (`swift build --build-system native`) and run
  `swift test --build-system native --filter <test>` for the contract you changed. CI runs the build
  and `scripts/test-fast.sh` on every pull request that changes more than documents, so leave the
  whole run to it; run `scripts/test-fast.sh` yourself to reproduce a failure CI found, or when a
  change has to reach `main` without a pull request.
- Launch and bundle commands are in the [README](README.md#development). Building, opening a
  development bundle and replacing the installed app are different actions; use only the ones the
  task needs.
- UI changes need evidence from the running app or a rendered view. A mocked provider response, a
  local test, a real provider turn and the installed app establish different facts.

## Boundaries

- Keep a provider's session ID and the storage it was saved in together. Existing isolated sessions
  keep their storage; a new session is no reason to move old history or copy credentials between
  folders.
- Preserve drafts, reading state, the local index, provider-owned history and existing backups. Do not
  start a model turn or change authentication merely to inspect saved state.
- Reuse the sign-ins and permissions already there and leave unrelated work alone. Installing builds,
  changing accounts, sending anything to outside services and deleting data need the person's
  explicit go-ahead.

## Writing in this repository

- Write documentation, code comments, commit messages and pull request text in English. Translations
  in `*.lproj` folders are the exception.
- Keep personal names, private repository names, internal task IDs and paths outside this repository
  out of tracked files and commit messages.
- The documents in `docs/` describe how Yardlet works now. When a fact changes, update the document
  that owns it rather than adding a dated note.
- `docs/design/` holds design records: a design for something not built yet, or one kept for the
  reasons behind what was built. Each says so in its first lines and names the document that
  describes the behavior. A design record is not kept current; behavior goes in that document.
- A test file's top doc comment does not list its individual test cases or rendered images: the test
  names already say what each covers, and a list there makes unrelated pull requests conflict.
