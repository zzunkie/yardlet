# Yardlet development

Yardlet is a native macOS app for running coding agents. Each agent keeps its own agent loop, sign-in,
capabilities and session history; Yardlet starts the agent's own CLI and stays close to the agent's
own app.

Maintainers keep working notes outside this repository, in the ignored folder `docs/internal/`. If
`docs/internal/AGENTS.md` exists, read it first and follow it.

## Product rules

- Yardlet must not be harder to use than the agent's own app, and should feel close to it.
- Add only features that turn on and off easily and leave nothing behind once turned off or removed.
- A feature that one provider's API offers is not, on its own, a reason to add a control, a shortcut
  or explanatory text.
- For session storage, import, resume, titles or the Account Center, read
  [native session storage](docs/NATIVE_SESSION_STORAGE.md).

## Code and verification

- App and agent adapters: `Sources/NativeHarnessClient/`; tests: `Tests/NativeHarnessClientTests/`;
  package targets: [Package.swift](Package.swift).
- Building needs Xcode 27.1 or later. Build with `swift build --build-system native`: the default
  build system also compiles SwiftTerm's Metal shaders and stops when the Metal toolchain is missing.
- Fix a cause where it lives, in the shared rule or path, rather than patching the one case that
  showed it. Add a test only when it pins a contract that could otherwise break unnoticed; prefer
  extending an existing test.
- Main-thread code that runs for every provider event, publication or timer tick does work in
  proportion to what changed, not to the whole history: a conversation can hold thousands of items
  and an agent run thousands of events. When such a path changes, check it with a long history and
  count the publications and redraws, not only the result.
- A test that checks something happened in its own time waits for it with `waitUntil`
  (`Tests/NativeHarnessClientTests/Support/WaitUntil.swift`), not a fixed sleep: CI runs slower than
  a Mac. A sleep is only for checking that something did not happen.
- Run `swift test --build-system native --filter <test>` for the contract you changed and
  `scripts/test-fast.sh` before a pull request. CI runs the build and `scripts/test-fast.sh` on every
  pull request.
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
