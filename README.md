# Yard

> Yard is the local operating console where AI coding workers plan, build, verify, and hand off long-running work inside your workspace.

![Yard terminal UI demo](docs/assets/yard-demo.gif)

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

## Your Claude Code and Codex, as they are

If `claude` or `codex` runs on your machine, Yard can drive it — no new
accounts, no extra configuration, no setup step. Yard discovers the installed
CLIs, probes readiness, and puts them to work exactly as you already pay for
them. Any other agent CLI can be added in config alone (see
"Adding a worker"), including API-backed tools via a per-worker
`invocation.pass_env` opt-in.

## The loop

```bash
cd your-project
yard new "add admin order search with status, email, and date filters"
yard queue                      # review the planned tasks
yard run --auto                 # drain the queue, stopping only at human gates
yard handoff                    # read the teammate-readable summary
yard                            # or do it all from the terminal UI
```

Like the worker CLIs, `yard` just works in any directory: the first command
creates `.agents/` state on demand. `yard init` exists for scripting or to
re-scaffold, but you do not need to run it first.

A one-sentence request becomes an intent contract plus a bounded task queue
with explicit dependencies; each task runs through a hidden worker, is checked
by a deterministic evaluator, and leaves a checkpoint and handoff under
`.agents/runs/`.

## Commands

| Command | Purpose |
| --- | --- |
| `yard` | Open the terminal UI (auto-inits on first use). |
| `yard init [--force]` | Explicitly scaffold `.agents/` state (optional). |
| `yard new "<request>" [--worker <id>]` | Plan a request into an intent contract + queue. |
| `yard new "..." --image <path>` | Attach a local image to the goal (also auto-detected from the request). |
| `yard queue` | List the work queue. |
| `yard status [--json]` | Workspace, intent, queue, and worker summary. |
| `yard worker status` | Worker readiness and billing-env safety. |
| `yard inspect repo [--json]` | Cheap deterministic local evidence. |
| `yard packet --task <id> --worker <id> [--dry-run]` | Compile a worker packet. |
| `yard run --next [--execute] [--worker <id>]` | Prepare (default) or run the next task. |
| `yard run --auto [--parallel N]` | Drain the queue autonomously; optionally N tasks at once. |
| `yard answer "<reply>"` | Answer a task waiting on you (NeedsUser) and resume it. |
| `yard handoff` | Print the latest run's handoff. |
| `yard report` | Print the intent's final report (aggregate of every task). |
| `yard recover` | Recover state from an interrupted session (orphaned runs, unread plans). |
| `yard routing review` | Per-kind worker success stats + suggested preferences. |
| `yard routing apply --kind K --worker W` | Pin a worker for a task kind (human-approved). |

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

## Worker routing

The planner picks a worker per task from an editable rubric in
`.agents/workers.yaml` (each worker's `best_for` + a `cost_bias` dial). At run
time the choice is deterministic: preferred worker → readiness check → fall back
to the next ready worker. Every run logs its outcome to
`.agents/telemetry/runs.jsonl`; `yard routing review` aggregates that and
*suggests* profile changes (e.g. "claude-code wins refactors"), which you apply
with `yard routing apply` — telemetry never changes routing on its own. Design:
[docs/routing-and-telemetry.md](docs/routing-and-telemetry.md).

`run --next` prepares a run and stops *before* invoking a worker by default,
because spawning a subscription-backed worker consumes usage. Pass `--execute`
to actually run it.

Workers can be toggled on/off from the Home workers panel (arrow keys past
the queue, then Enter/Space); a disabled worker is skipped by routing and
planning.

### Adding a worker

Codex and Claude Code have built-in adapters. Any other subscription-backed
CLI can be added in `.agents/workers.yaml` alone — give it an invocation
template and Yard drives it through the same contract (packet on stdin →
result files out). Placeholders: `{run_dir}`, `{model}`, `{effort}`,
`{image}`.

```yaml
- id: mytool
  best_for: "..."            # planner rubric
  invocation:
    command: mytool          # must support --version (readiness probe)
    supports_noninteractive: true
    args: ["run", "--json", "--out", "{run_dir}"]
    sandbox_args: ["--sandbox"]        # default access level
    full_access_args: ["--yolo"]       # only when full access is granted
    model_args: ["--model", "{model}"] # added when a model is set
    effort_args: ["--effort", "{effort}"]
    image_args: ["-i", "{image}"]      # repeated per attached image
```

The worker must be able to write files in the workspace (that is how results
come back); its subprocess env is sanitized unless the profile opts vars
back in with `pass_env`.

## Role profiles

Each task runs under a role — a prompt mode over the worker, derived from the
task kind: `implementation` → **builder**, `review` → **reviewer**,
`research` → **researcher**, `safety` → **security**. The same Codex/Claude
session gets role-specific working rules (a reviewer cites file:line evidence
and doesn't rewrite code; a researcher makes no code changes; security audits
adversarially and never prints secret values). Extend a role per workspace by
writing `.agents/agents/<role>.md` — it is appended to that role's packets.

## Parallel execution

The planner marks which tasks genuinely depend on each other (`depends_on`);
everything else is independent. With parallelism on, the auto-drain runs up to
N independent tasks at once — each in its own git worktree on branch
`yard/<task-id>`, possibly on different workers. Workers run in parallel, but
queue state keeps a single writer and results merge back sequentially; a merge
conflict is never auto-resolved (the task drops to Partial and its worktree is
kept for inspection). Off by default; opt in via Settings ("Parallel tasks"),
`max_parallel` in `.agents/yard.yaml`, or `yard run --auto --parallel 3`.
Requires a clean git tree, otherwise Yard falls back to sequential.

Inside a task, workers are free to use their own subagents — Yard's queue
parallelism is for work that must survive sessions, cross workers, or pass
human gates. Design: [docs/parallel-queue.md](docs/parallel-queue.md).

## Crash safety

Yard state survives restarts. On startup (and via `yard recover`) it recovers
interrupted sessions: a planning result the previous session paid for but never
read is consumed into the queue, finished orphaned runs are evaluated and
merged (worktree runs included), and unfinished ones are requeued.

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
