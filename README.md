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

## The loop

```bash
cd your-project
yard new "add admin order search with status, email, and date filters"
yard queue                      # review the planned tasks
yard run --next --execute       # run the next task through a hidden worker
yard handoff                    # read the teammate-readable summary
yard                            # or do it all from the terminal UI
```

Like the worker CLIs, `yard` just works in any directory: the first command
creates `.agents/` state on demand. `yard init` exists for scripting or to
re-scaffold, but you do not need to run it first.

A one-sentence request becomes an intent contract plus a bounded task queue;
each task runs through a hidden worker, is checked by a deterministic
evaluator, and leaves a checkpoint and handoff under `.agents/runs/`.

## Commands

| Command | Purpose |
| --- | --- |
| `yard` | Open the terminal UI (auto-inits on first use). |
| `yard init [--force]` | Explicitly scaffold `.agents/` state (optional). |
| `yard new "<request>" [--worker <id>]` | Plan a request into an intent contract + queue. |
| `yard queue` | List the work queue. |
| `yard status [--json]` | Workspace, intent, queue, and worker summary. |
| `yard worker status` | Worker readiness and zero-key billing safety. |
| `yard inspect repo [--json]` | Cheap deterministic local evidence. |
| `yard packet --task <id> --worker <id> [--dry-run]` | Compile a worker packet. |
| `yard run --next [--execute] [--worker <id>]` | Prepare (default) or run the next task. |
| `yard answer "<reply>"` | Answer a task waiting on you (NeedsUser) and resume it. |
| `yard handoff` | Print the latest run's handoff. |

When a worker needs input it leaves the task in **NeedsUser** with a question.
`yard status` (and the TUI) shows the question; reply with `yard answer "..."`
(or press `a` in the TUI) and Yard re-runs the task with your answer.

## Language

Worker-authored content (plan summary, task titles, handoff, questions) follows
your language. By default Yard auto-detects it from your request, so a Korean
request gets a Korean plan and handoff while code and identifiers stay English.
Set `language:` in `.agents/yard.yaml` to `ko`/`en`/etc. to force one.

## Permissions

Workers run in a bounded sandbox by default (local files and tests, no network).
This is layered:

1. **Safe by default** — codex `workspace-write`, claude `acceptEdits`.
2. **Report, don't bypass** — if a worker needs network, an install, production,
   or a destructive action, it stops and asks via **NeedsUser** instead of
   failing silently. You grant access and resume.
3. **Explicit escalation** — `yard run --next --execute --full-access` (or
   `yard answer --full-access`) drops the sandbox for that run only. Off by
   default; it is a human-granted permission, never automatic.

`run --next` prepares a run and stops *before* invoking a worker by default,
because spawning a subscription-backed worker consumes usage. Pass `--execute`
to actually run it.

## Build

```bash
cargo build
cargo test
cargo run -- init
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
