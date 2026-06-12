# AGENTS

Authoritative guidance for AI agents working in the `yard` repository.

> **Claude mirror:** `CLAUDE.md` is a symlink to this file.
> **Codex adapter:** see `.codex/README.md`.
> **Shared agent assets:** `.agents/` is the source of truth for reusable rules, skills, and agent prompts.
>
> ⚠️ **`.agents/` is dual-purpose here.** It is *also* Yard's own canonical runtime state. Treat `rules/`, `skills/`, `agents/` as **harness assets** (edit freely). Treat `yard.yaml`, `*-policy.yaml`, `workers.yaml`, `work-queue.yaml`, `intent-contract.yaml`, and `runs/ checkpoints/ handoffs/ telemetry/` as **Yard-owned operational state** — Yard writes them through `src/state.rs`; do not hand-edit casually.

---

## What Yard is

A local terminal AI workbench (Rust + Ratatui). You describe work in a few sentences; Yard plans it into an intent + task queue, runs each task through a hidden, subscription-backed worker CLI (**Codex** or **Claude Code**), validates with a deterministic evaluator, and leaves checkpoints/handoffs under `.agents/`.

Full spec: [`docs/yard-final-plan.md`](docs/yard-final-plan.md). Routing/telemetry design: [`docs/routing-and-telemetry.md`](docs/routing-and-telemetry.md). Parallel queue / queue-vs-subagent boundary: [`docs/parallel-queue.md`](docs/parallel-queue.md). Shared harness & learning loop: [`docs/harness.md`](docs/harness.md).

## Tech Stack

Rust 2021 (rustc ≥ 1.82) | Ratatui (TUI) | clap (CLI) | serde / serde_json / serde_yaml_ng | anyhow | chrono

## Core Principles

1. **Zero AI API keys (default, not identity).** Yard core never requires, requests, or stores an AI provider API key, and never *silently* falls back to a provider API. Subscription-backed CLIs are the default workers (the initial audience is cost-sensitive individuals); if no safe worker is ready, Yard stops with a clear readiness message. API-backed workers are a per-worker opt-in via `invocation.pass_env` — the named env vars reach that worker only, everything else stays scrubbed, and Yard never reads the values. See `src/guard.rs` + `.agents/billing-policy.yaml`.
2. **Policy vs mechanism.** Routing resolution is deterministic and auditable (`src/routing.rs`); telemetry only *suggests* policy changes a human applies (`src/review.rs`). Telemetry never binds at run-time.
3. **Yard owns canonical state.** Workers author content; Yard writes the canonical `.agents/` files (`src/state.rs` is the only place that touches them). LLMs never edit the system-of-record directly.
4. **Layered safety.** Zero-key (hard) + a packet danger-list the worker self-gates against (soft) + an evaluator forbidden-path check that fails a run post-hoc.
5. **Simple over clever.** Match the surrounding code; small typed structs; no over-abstraction.

## Key Rules

| Rule | Details |
|------|---------|
| Worker contract | Workers are interchangeable CLIs behind one contract: packet in → subprocess → result **files** out. CLI flags live only in `src/workers/mod.rs::build_command`. |
| Structured output | Yard uses **no** provider JSON mode. It prompts the worker to write a JSON file, then parses it. Be tolerant on parse, validate after (see `src/planner.rs`). |
| Access levels | Two only: `sandboxed` (default) / `full` (opt-in via `yard access full`). No true read-only — workers must write their result artifacts. |
| `.agents/` writes | Only through `src/state.rs`. Do not hand-edit Yard-owned operational files. |
| Don't expand scope | Keep `out_of_scope` strict. An adjacent idea becomes a queue candidate, never a silent expansion of the current task. |

## Build / Test

```bash
cargo build && cargo test     # keep the whole suite green
cargo install --path .        # installs `yard` to ~/.cargo/bin
```

## Operational rules

See [`.agents/rules/`](.agents/rules/) (symlinked into `.claude/` and `.codex/`):
- `multi-session-safety.md` — git/commit hygiene across parallel sessions.
- `worktree-tooling.md` — working-directory discipline for worktree work.
