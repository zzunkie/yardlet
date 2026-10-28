# Contributing to Yardlet

Thanks for taking the time. Yardlet is a personal open-source project. Reports from people who use it and pull
requests are both welcome.

## Issues

- **Bugs:** open a [bug report](../../issues/new?template=bug_report.yml). Include the Yardlet version
  (Yardlet > About Yardlet), your macOS version, the agent and its CLI version, and the steps that lead to the problem.
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
3. CI runs the same build and tests on every pull request, and they must pass before it is merged.
4. Keep one change per pull request. Say what changed, why, and how you checked it; for a change you
   can see, add a screenshot or a short recording.
5. Write code comments, documentation, commit messages and the pull request in English.

[AGENTS.md](AGENTS.md) has the same rules for coding agents working in this repository.

## What fits Yardlet

Yardlet runs each agent's own CLI with its own sign-in and session history, and tries to stay as close as possible to
the agent's own app. A proposal fits best when it works for every agent, can be turned on and off, and leaves nothing
behind once it is turned off or removed. A feature that only one provider's API offers is not, on its own, a reason
to add a control.

## Building from source

See [Development](README.md#development) in the README.

## Code of conduct

Everyone taking part in this project's issues and discussions is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE), like the rest of the
project.
