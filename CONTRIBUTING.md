# Contributing to Yardlet

Thanks for your interest in Yardlet. This guide covers building, testing, and
sending changes. For the deeper design rationale, see [AGENTS.md](AGENTS.md) and
[docs/identity.md](docs/identity.md).

## Build and test

```bash
cargo build
cargo test
```

Keep the whole suite green. Yardlet targets Rust 2021 (rustc >= 1.82). To try
your build against a project:

```bash
cargo run -- status      # run from source
cargo install --path .   # or install the `yardlet` binary
```

## What Yardlet is (the parts you will touch)

Yardlet is a local terminal workbench (Rust + Ratatui). It turns a few sentences
of intent into an intent contract plus a task queue, runs each task through a
hidden worker CLI (Codex, Claude Code, or any CLI via the generic adapter),
validates the result with a deterministic evaluator, and writes checkpoints and
handoffs under `.agents/`.

A few invariants shape almost every change:

- **The core is deterministic; anything generative goes through the worker
  contract.** Packet in -> subprocess -> result files out. A worker's CLI flags
  live only in `src/workers/mod.rs::build_command`.
- **Yardlet owns canonical state.** Only `src/state.rs` writes the `.agents/`
  files (`work-queue.yaml`, `*-policy.yaml`, runs, checkpoints, handoffs). Do
  not write them from anywhere else.
- **The core drives the user's installed CLIs.** It does not require, store, or
  call an AI provider API; the worker subprocess env is sanitized by default
  (`src/guard.rs`).
- **Routing is policy vs mechanism.** Resolution is deterministic
  (`src/routing.rs`); telemetry only *suggests* changes a human applies
  (`src/review.rs`).

## Sending a change

1. Branch off `main` (use a `git worktree` for parallel work).
2. Run `git status` before staging; stage only the files you changed (avoid
   `git add -A`).
3. `cargo build && cargo test` must pass.
4. Match the surrounding code: small typed structs, no over-abstraction, the
   same comment density and naming as the file you are editing.
5. Keep scope strict: an adjacent idea becomes a queue candidate, not a silent
   expansion of the current change.
6. Open a PR describing the user-facing effect.

## Reporting issues

Open a GitHub issue with the Yardlet version (`yardlet status`), your OS, the
worker CLIs involved, and steps to reproduce. Never paste secret values.
