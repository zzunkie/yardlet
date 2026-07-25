# Contributing to Yardlet

Thank you for helping improve Yardlet. This guide explains where to start, what
the repository expects, and how a change reaches `main`.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md). For project ownership and decision
making, see [GOVERNANCE.md](GOVERNANCE.md).

## Choose the right starting point

- **Bug with a clear reproduction:** a pull request is welcome; link an issue
  when one exists.
- **Documentation, tests, typo, or small cleanup:** a pull request is welcome.
- **New feature or user-visible behavior:** open a feature issue and agree on
  scope first.
- **CLI, file format, policy, security boundary, or architecture:** open an
  issue before implementation.
- **Security vulnerability:** follow [SECURITY.md](SECURITY.md); do not open a
  public issue.
- **Usage question:** use the question issue form.

Issue-first changes need maintainer agreement before implementation. That avoids
asking contributors to spend time on a direction the project will not adopt.
An issue or discussion is not a promise that a proposal will be accepted.

## Development setup

You need:

- Git;
- the latest stable Rust toolchain with `rustfmt` and `clippy`;
- macOS or Linux for the same platforms exercised by CI;
- an installed worker CLI only for end-to-end tests that actually launch one.

After forking the repository:

```bash
git clone https://github.com/YOUR-USER/yardlet.git
cd yardlet
git remote add upstream https://github.com/zzunkie/yardlet.git
git switch -c fix/short-description
rustup update stable
rustup component add rustfmt clippy
rustup toolchain install 1.82.0 --profile minimal
```

Do not put credentials or provider billing variables in repository files. A
normal build and test run does not require an AI provider API key.

## Required checks

Run the same checks CI runs before requesting review:

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo build --all-targets
cargo test
cargo +1.82.0 check --locked
```

Yardlet is a binary crate. Useful focused commands include:

```bash
cargo test --bin yardlet test_name
cargo test --test integration_test_name
cargo run -- --help
cargo run -- status
```

The package declares Rust 1.82 as its minimum supported Rust version. CI checks
that declaration with the committed lockfile, while lint and cross-platform
test jobs run on the current stable toolchain. If stable Clippy disagrees with
an older local toolchain, update stable and run the checks again.

## Architecture boundaries

The deeper rationale lives in [AGENTS.md](AGENTS.md) and
[docs/identity.md](docs/identity.md). Four invariants shape most changes:

- **The core is deterministic.** Anything generative goes through a worker
  contract: packet in, subprocess, result files out.
- **Workers are interchangeable CLIs.** Worker command-line flags belong only
  in `src/workers/mod.rs::build_command`.
- **Yardlet owns canonical state.** `src/state.rs` is the only product module
  that writes canonical `.agents/` state.
- **Routing policy is auditable.** Runtime routing is deterministic; telemetry
  may suggest policy changes but never silently activates them.

### The `.agents/` boundary

This repository uses `.agents/` for two different purposes:

- `.agents/rules/`, `.agents/skills/`, and `.agents/agents/` are reusable
  harness assets. Changes are welcome when they are in the PR scope.
- `templates/agents/` contains source templates used when Yardlet initializes
  state. Edit these when changing generated defaults.
- `.agents/yardlet.yaml`, `*-policy.yaml`, `workers.yaml`, `work-queue.yaml`,
  and `intent-contract.yaml` are Yardlet-owned or machine-specific operational
  state. Do not hand-edit them for a product change.
- `.agents/runs/`, `checkpoints/`, `handoffs/`, `telemetry/`, and
  `transitions/` are generated runtime evidence. Do not include them in a PR.

When a behavior change needs a different generated file, change the typed
mechanism in `src/` and the source template under `templates/`, then test the
generated result. Do not patch a generated instance and call that the fix.

## Make a focused change

1. Update your branch from `upstream/main`.
2. Keep one problem and one coherent solution in each pull request.
3. Match the surrounding Rust style: small typed structs, direct control flow,
   and no speculative abstraction.
4. Add or update tests for behavior changes.
5. Update user documentation when commands, output, configuration, or public
   contracts change.
6. Keep adjacent ideas out of the patch and open a follow-up issue instead.
7. Review `git status` and stage only files that belong to the change. Do not
   use a blind `git add -A` in a mixed worktree.

Do not include secrets, personal paths, generated run artifacts, benchmark
scratch data, or unrelated formatting changes.

## Open the pull request

The pull request template asks for:

- the problem and user-visible effect;
- the related issue when issue-first agreement was required;
- exact validation commands and results;
- screenshots or terminal captures for visible TUI changes;
- confirmation that canonical or generated state was not hand-edited.

Draft pull requests are welcome for early feedback. A pull request becomes
mergeable only after the protected-branch checks pass and review conversations
are resolved. The maintainer may ask to split a patch, revise its scope, or
close it when it conflicts with the project's direction or safety model.

## Reporting bugs

Use the bug issue form and include:

- `yardlet --version` or the commit SHA;
- operating system and installation method;
- worker CLI names involved, if any;
- minimal reproduction steps;
- expected and actual behavior;
- relevant logs with secrets and personal paths removed.

Use [SECURITY.md](SECURITY.md) instead of an issue if the report involves
credential exposure, command injection, sandbox or approval bypass, canonical
state tampering, or another security boundary.

## License

Yardlet is distributed under the [MIT License](LICENSE). By submitting a
contribution, you confirm that you have the right to submit it and agree that it
may be distributed under the same license.
