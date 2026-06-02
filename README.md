# Yard

> Yard is the local operating console where AI coding workers plan, build, verify, and hand off long-running work inside your workspace.

Yard is a local AI workbench. You describe work in a few natural-language sentences, and Yard manages planning, a queued execution model, worker routing, validation, compacting, handoff, and safety inside your local workspace. It uses **Codex CLI** and **Claude Code CLI** as hidden, subscription-backed workers.

You normally open **Yard**, not Codex or Claude Code directly.

```
User
  -> Yard UI (terminal)
    -> planning gate
    -> intent / scope / acceptance contract
    -> queue / state / ledger
    -> worker packet compiler
      -> Codex CLI or Claude Code CLI as a hidden worker
    -> validation / evaluation
    -> checkpoint / handoff
```

## Hard rule: zero AI API keys

Yard core does **not** require, request, store, or call AI provider API keys. It drives already-installed, subscription-backed worker CLIs. If no safe local worker is ready, Yard stops with a clear readiness message. It never asks for an API key and never silently falls back to a provider API.

## Status

Early scaffold. The deterministic surfaces run today:

- `yard init` creates canonical `.agents/` state from templates.
- `yard status [--json]` reports workspace, intent, and queue state.
- `yard worker status` probes worker readiness and zero-key billing safety.
- `yard inspect repo [--json]` gathers cheap deterministic local evidence.
- `yard packet --task <id> --worker <codex|claude-code> [--dry-run]` compiles a worker-specific task packet.
- `yard` (no args) opens the terminal UI (read-only Home for now).

Worker invocation, the planning gate, the evaluator, and compact/handoff are wired as modules and grow from here.

## Build

```bash
cargo build
cargo run -- init
cargo run -- status
```

## Canonical state

Yard owns state; workers do not. Canonical state lives under `.agents/` in the target repo:

```
.agents/
  yard.yaml              workspace config
  intent-contract.yaml   current goal / scope / acceptance
  work-queue.yaml         tasks
  *-policy.yaml           tool / approval / interaction / research / billing policy
  workers.yaml            worker profiles + routing
  runs/<run-id>/          per-run artifacts (result, validation, checkpoint, handoff)
  checkpoints/            latest compact resume points
  handoffs/               teammate-readable summaries
```

User-level, non-secret config lives under `~/.yard/`.

## License

MIT
