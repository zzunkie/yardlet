# Yardlet

[![crates.io](https://img.shields.io/crates/v/yardlet.svg)](https://crates.io/crates/yardlet)
[![CI](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml/badge.svg)](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml)
[![downloads](https://img.shields.io/crates/d/yardlet.svg)](https://crates.io/crates/yardlet)
[![license: MIT](https://img.shields.io/crates/l/yardlet.svg)](LICENSE)

**English** | [한국어](README.ko.md)

> **Rent the intelligence. Own the work.**
> Yardlet is a local console for engineering the loop that turns a few sentences
> of intent into verified, durable work, using your already-installed coding
> agents as interchangeable workers.

![Yardlet terminal UI demo](docs/assets/yardlet-demo.gif)

*"I don't prompt Claude anymore. I have loops running that prompt Claude…
my job is to write loops."* That is how Anthropic's Claude Code lead
describes his own workflow now, and **loop engineering** is the name the
practice picked up. Yardlet is that practice as a product, for everyone:

- **Prompts are compiled, not written.** You state intent once; every worker
  prompt is built from contracts, rules, skills, role discipline, and
  checkpoints you own. Improve those inputs and every future prompt improves.
- **The loop is yours, not a vendor's.** Worker-neutral (Claude Code, Codex,
  or any CLI behind one contract), local (state lives in your repo), and it
  survives crashes, restarts, and worker swaps.
- **The verifier is never the doer.** A deterministic evaluator checks every
  run against the contract; risky plans get reviewer-role verification tasks.
  "Done" is earned, not self-reported. Mechanical checks are deterministic
  (schema, IDs, scope drift, forbidden paths from the actual git diff, and the
  validation commands Yardlet runs itself); semantic quality is judged by
  separate reviewer-role tasks, not by pretending a checker judges everything.

Full identity: [docs/identity.md](docs/identity.md).

```
User intent (a few sentences)
  -> planning gate            intent / scope / acceptance contract
  -> work queue               bounded tasks, dependencies, parallel-ready
  -> packet compiler          prompts built from state you own
      -> hidden workers       claude / codex / any CLI, sandboxed, routable
  -> deterministic evaluator  done is checked, not declared
  -> checkpoint / handoff     durable artifacts, resumable forever
```

## Install

```bash
cargo install yardlet
```

Prebuilt binaries for macOS and Linux are attached to each
[GitHub release](https://github.com/zzunkie/yardlet/releases); with
[`cargo-binstall`](https://github.com/cargo-bins/cargo-binstall) installed,
`cargo binstall yardlet` fetches one instead of compiling.

## Your Claude Code and Codex, as they are

If `claude` or `codex` runs on your machine, Yardlet can drive it, with no new
accounts, no extra configuration, no setup step. Yardlet discovers the installed
CLIs, probes readiness, and puts them to work exactly as you already pay for
them. Any other agent CLI can be added in config alone (see
"Adding a worker"), including API-backed tools via a per-worker
`invocation.pass_env` opt-in.

Because the worker runs in your project, your existing setup keeps working inside
each task: your `CLAUDE.md`, skills, hooks, MCP servers, and subagents all still
apply. Yardlet layers orchestration and verification on top rather than replacing
your harness. It does not try to be clever at the LLM layer; it runs the
harnesses that are already good there as interchangeable workers and spends its
own effort on the parts you can solve deterministically: routing, evaluation,
state, merges, recovery, handoffs.

It is built to run within the subscriptions you already pay for, not to rack up
per-token API costs. Billing keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and the
like) are scrubbed from the worker environment before spawn, so an unattended
auto-drain cannot silently bill against an API key instead of your subscription;
a worker opts a specific var back in only via `pass_env`.

## The loop

```bash
cd your-project
yardlet new "add admin order search with status, email, and date filters"
yardlet queue                      # review the planned tasks
yardlet run --auto                 # drain the queue, stopping only at human gates
yardlet handoff                    # read the teammate-readable summary
yardlet                            # or do it all from the terminal UI
```

Like the worker CLIs, `yardlet` just works in any directory: the first command
creates `.agents/` state on demand. `yardlet init` exists for scripting or to
re-scaffold, but you do not need to run it first.

A one-sentence request becomes an intent contract plus a bounded task queue
with explicit dependencies; each task runs through a hidden worker, is checked
by a deterministic evaluator, and leaves a checkpoint and handoff under
`.agents/runs/`.

## Terminal UI shortcuts

The terminal UI (`yardlet` with no subcommand) is the main way to drive a
session. From the Home screen:

| Key | Action |
| --- | --- |
| `n` | New work: describe a request (when idle). |
| `r` | Run the next task. |
| `A` | Auto-drain the queue. |
| `p` | Approve the next task; while a drain runs, request a graceful pause. |
| `a` | Answer a task waiting on you (NeedsUser). |
| `Esc` | Stop the running worker. |
| `↑` / `↓` | Browse the queue, then the workers panel past its end. |
| `Enter` | Open the selected task's handoff. |
| `Space` / `Enter` | Toggle the selected worker on/off (in the workers panel). |
| `i` | View the intent contract. |
| `h` | View the latest handoff. |
| `R` | Reports and history browser. |
| `m` | Monitor the worker's live output. |
| `s` | Settings (can be opened mid-run). |
| `g` | Refresh, re-probing worker readiness. |
| `l` | Toggle language. |
| `f` | Toggle access level (sandboxed / full). |
| `u` | Restart into a freshly installed update (when available). |
| `q` / `Ctrl+C` | Quit. |

Korean keyboard layouts work without switching back to English: the Hangul jamo
are mapped to the same shortcuts.

## Commands

| Command | Purpose |
| --- | --- |
| `yardlet` | Open the terminal UI (auto-inits on first use). |
| `yardlet init [--force]` | Explicitly scaffold `.agents/` state (optional). |
| `yardlet new "<request>" [--worker <id>]` | Plan a request into an intent contract + queue. |
| `yardlet goal "<goal>" [--verify "..."]` | Express lane: skip planning, run one goal to a verify condition. |
| `yardlet new "..." --image <path>` | Attach a local image to the goal (also auto-detected from the request). |
| `yardlet queue` | List the work queue. |
| `yardlet status [--json]` | Workspace, intent, queue, and worker summary. |
| `yardlet worker status` | Worker readiness and billing-env safety. |
| `yardlet inspect repo [--json]` | Cheap deterministic local evidence. |
| `yardlet packet --task <id> --worker <id> [--dry-run]` | Compile a worker packet. |
| `yardlet run --next [--execute] [--worker <id>]` | Prepare (default) or run the next task. |
| `yardlet run --auto [--parallel N]` | Drain the queue autonomously; optionally N tasks at once. |
| `yardlet answer "<reply>"` | Answer a task waiting on you (NeedsUser) and resume it. |
| `yardlet handoff` | Print the latest run's handoff. |
| `yardlet report` | Print the intent's final report (aggregate of every task). |
| `yardlet recover` | Recover state from an interrupted session (orphaned runs, unread plans). |
| `yardlet skill list / suggest / equip <preset> / unequip / research / create / apply / review` | Classify, equip, author, and score skills. |
| `yardlet harness review` | Show auto-learned rules and skills with their eval scores. |
| `yardlet routing review` | Per-kind worker success stats + suggested preferences. |
| `yardlet routing apply --kind K --worker W` | Pin a worker for a task kind (human-approved). |

When a worker needs input it leaves the task in **NeedsUser** with a question.
`yardlet status` (and the TUI) shows the question; reply with `yardlet answer "..."`
(or press `a` in the TUI) and Yardlet re-runs the task with your answer.

## Language

Worker-authored content (plan summary, task titles, handoff, questions) follows
your language. By default Yardlet auto-detects it from your request, so a Korean
request gets a Korean plan and handoff while code and identifiers stay English.
Set `language:` in `.agents/yardlet.yaml` to `ko`/`en`/etc. to force one.

## Permissions

Workers run in a bounded sandbox by default (local files and tests, no network).
This is layered:

1. **Safe by default**: codex `workspace-write`, claude `acceptEdits`.
2. **Report, don't bypass**: if a worker needs network, an install, production,
   or a destructive action, it stops and asks via **NeedsUser** instead of
   failing silently. You grant access and resume.
3. **Explicit escalation**: `yardlet run --next --execute --full-access` (or
   `yardlet answer --full-access`) drops the sandbox for that run only. Off by
   default; it is a human-granted permission, never automatic.

## Worker routing

The planner picks a worker per task from an editable rubric in
`.agents/workers.yaml` (each worker's `best_for` + a `cost_bias` dial). At run
time the choice is deterministic: preferred worker → readiness check → fall back
to the next ready worker. Every run logs its outcome to
`.agents/telemetry/runs.jsonl`; `yardlet routing review` aggregates that and
*suggests* profile changes (e.g. "claude-code wins refactors"), which you apply
with `yardlet routing apply`. Telemetry never changes routing on its own. Design:
[docs/routing-and-telemetry.md](docs/routing-and-telemetry.md).

`run --next` prepares a run and stops *before* invoking a worker by default,
because spawning a subscription-backed worker consumes usage. Pass `--execute`
to actually run it.

Workers can be toggled on/off from the Home workers panel (arrow keys past
the queue, then Enter/Space); a disabled worker is skipped by routing and
planning.

### Adding a worker

Codex and Claude Code have built-in adapters. Any other subscription-backed
CLI can be added in `.agents/workers.yaml` alone: give it an invocation
template and Yardlet drives it through the same contract (packet on stdin →
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

The ecosystem's agents are Yardlet's supply side: terminal agents like
[oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`), OpenCode, Gemini
CLI, or an API-backed CLI of your own all fit the same template. Register
the winners, swap them per task, keep the records.

## Role profiles

Each task runs under a role, a prompt mode over the worker, derived from the
task kind: `implementation` → **builder**, `review` → **reviewer**,
`research` → **researcher**, `safety` → **security**. The same Codex/Claude
session gets role-specific working rules (a reviewer cites file:line evidence
and doesn't rewrite code; a researcher makes no code changes; security audits
adversarially and never prints secret values). Extend a role per workspace by
writing `.agents/agents/<role>.md`; it is appended to that role's packets.

## Parallel execution

The planner marks which tasks genuinely depend on each other (`depends_on`);
everything else is independent. With parallelism on, the auto-drain runs up to
N independent tasks at once, each in its own git worktree on branch
`yard/<task-id>`, possibly on different workers. Workers run in parallel, but
queue state keeps a single writer and results merge back sequentially; a merge
conflict is never auto-resolved (the task drops to Partial and its worktree is
kept for inspection). Off by default; opt in via Settings ("Parallel tasks"),
`max_parallel` in `.agents/yardlet.yaml`, or `yardlet run --auto --parallel 3`.
Requires a clean git tree, otherwise Yardlet falls back to sequential.

Inside a task, workers are free to use their own subagents. Yardlet's queue
parallelism is for work that must survive sessions, cross workers, or pass
human gates. Design: [docs/parallel-queue.md](docs/parallel-queue.md).

## Crash safety

Yardlet state survives restarts. On startup (and via `yardlet recover`) it recovers
interrupted sessions: a planning result the previous session paid for but never
read is consumed into the queue, finished orphaned runs are evaluated and
merged (worktree runs included), and unfinished ones are requeued.

## Build

```bash
cargo build
cargo test
cargo run -- init
```

Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md) for build/test, the core
invariants, and the PR process. Adding another worker is config-only (see
"Adding a worker"); PRs to wire up new workers are welcome.

## Canonical state

Yardlet owns state; workers do not. Canonical state lives under `.agents/` in the target repo:

```
.agents/
  yardlet.yaml              workspace config
  intent-contract.yaml   current goal / scope / acceptance
  work-queue.yaml         tasks
  *-policy.yaml           tool / approval / interaction / research / billing policy
  workers.yaml            worker profiles + routing
  runs/<run-id>/          per-run artifacts (result, validation, checkpoint, handoff)
  checkpoints/            latest compact resume points
  handoffs/               teammate-readable summaries
```

User-level, non-secret config lives under `~/.yardlet/`.

## License

MIT
