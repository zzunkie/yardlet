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
2. Build and run the quick tests before you open the pull request:

   ```bash
   swift build --build-system native
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
5. Write code comments, documentation, commit messages and the pull request in English. Add user-visible
   strings to every supported `.lproj` localization catalog.

[AGENTS.md](AGENTS.md) has the same rules for coding agents working in this repository.

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

## Building from source

See [Development](README.md#development) in the README.

## Code of conduct

Everyone taking part in this project's issues and discussions is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE), like the rest of the
project.
