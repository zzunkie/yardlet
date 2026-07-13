# Yardlet

[![crates.io](https://img.shields.io/crates/v/yardlet.svg)](https://crates.io/crates/yardlet)
[![CI](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml/badge.svg)](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml)
[![downloads](https://img.shields.io/crates/d/yardlet.svg)](https://crates.io/crates/yardlet)
[![license: MIT](https://img.shields.io/crates/l/yardlet.svg)](LICENSE)

**English** | [한국어](README.ko.md)

> **Rent the intelligence. Own the loop.**
> Yardlet owns the loop around the coding agents you already run. Describe
> intent in a few sentences; Yardlet plans it into tasks, drives Claude Code or
> Codex as interchangeable workers, verifies every result deterministically, and
> keeps the plan, memory, trust record, and handoffs in your repo. You rent the
> model; you own the loop.

![Yardlet terminal UI demo](docs/assets/yardlet-demo.gif)

Yardlet is not a thin wrapper over a coding CLI. The worker CLI is one swappable
part inside a loop Yardlet owns end to end: a planning gate, per-task routing, a
deterministic verifier that is never the doer, durable repo-local state, crash
recovery, project memory, a trust report built from your own run history, and a
learning loop that compounds in your repo. Swap the worker out and the loop, the
records, and everything you have taught it stay yours.

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
yardlet planning show              # review the proposal and semantic diff
yardlet planning accept <proposal> --expected-head none
yardlet planning confirm --expected-head <draft-revision>
yardlet queue                      # review the confirmed tasks
yardlet run --auto                 # drain the queue, stopping only at human gates
yardlet handoff                    # read the teammate-readable summary
yardlet                            # or do it all from the terminal UI
```

Like the worker CLIs, `yardlet` just works in any directory: the first command
creates `.agents/` state on demand. `yardlet init` exists for scripting or to
re-scaffold, but you do not need to run it first.

A one-sentence request opens a planning channel. Each worker proposal is an
immutable draft revision with an inspectable semantic diff. `accept`, `reject`,
`undo`, and `answer` require the expected visible head, and only explicit
`confirm` promotes that exact draft to the active intent and bounded queue. No
active state changes before confirmation, and confirmation does not call the
worker or hide a re-plan. `yardlet goal` remains the express path: it skips the
planning worker but records the generated draft and confirmation provenance.

After confirmation, each task runs through a hidden worker, is checked by a
deterministic evaluator, and leaves a checkpoint and handoff under
`.agents/runs/`.

Tasks can carry an explicit goal condition and feedback-cycle limit. When a
deterministic validation or acceptance check fails, Yardlet records the exact
failure and injects it into the next attempt. If the persisted limit is
exhausted, the task stops at NeedsUser with context instead of being reported
as Done.

## Project Memory

A loop that forgets is a wrapper. Yardlet keeps durable workspace knowledge in
your repo and feeds it to every worker without bloating the prompt.

Drop facts and decisions as plain Markdown under `.agents/memory/`: one fact per
file, git-tracked, with optional `name` / `description` frontmatter. Yardlet
discovers them and injects only a short **index** into every worker packet and
the planner: each doc's title, one-line summary, and path anchor. Bodies are
read **on demand** by the worker that needs them, so the always-loaded cost
stays tiny no matter how much you record. This is index-and-anchor, not
prompt-stuffing: the index points, and the worker opens the few memories that
bear on its task.

A memory doc can also declare `look_at:` landmark paths. `yardlet memory` lists
the index and flags a doc **possibly stale** when one of its landmarks changed
in git after the doc was last updated, so a memory that has drifted from the
code it describes is surfaced rather than trusted silently. `yardlet init`
scaffolds the folder with a convention README.

You can also seed and maintain memory through a worker instead of hand-writing
the files. `yardlet memory init` asks a worker to draft memory documents from
the repo, then Yardlet's core writes the canonical `.agents/memory/*.md` (the
worker drafts, Yardlet is the sole writer). `yardlet memory refresh` re-drafts
existing docs the same way, and `yardlet memory refresh --stale-only` touches
only the docs flagged possibly stale.

For a wider read-only pass, `yardlet memory scout` fans topic scouts out over
isolated workspace copies and merges their reports into unapplied candidates.
Review the run artifacts, then use `yardlet memory apply --run <run-id>` to let
the core write candidates into canonical memory. Scouts never receive the live
workspace path and never write its canonical state.

Mechanics: [docs/memory-trust-mining.md](docs/memory-trust-mining.md).

## Trust Report

Because "Done" is checked by a deterministic gate, every run logs its outcome,
and every task state change is recorded, Yardlet can tell you how far to trust
the loop, from your own history. `yardlet trust` reads your run telemetry and
the state-transition audit log under `.agents/transitions/`, then prints two
layers.

The attempt view, from run telemetry, scoped to the active intent:

- **First-pass Done vs Done-after-retry vs never-Done**, so you can see how
  often work lands on the first attempt instead of after rework.
- **Per-worker reliability**: done-rate, partial / failed / no-result counts,
  wall time, and how often you overrode the result.
- The tasks that needed the **most attempts** to reach Done.

The autonomy view, folded from the transition audit log:

- **Can I trust a Done?** Every Done is graded from its recorded history as
  evidence-backed (a clean Done, never reopened), recovered (Done after a wrong
  turn), false-done caught (marked Done, then reopened), or unresolved, with a
  trustworthy-Done rate over the Dones.
- **Human interventions, decision vs chore.** A hand step is split into a
  decision the loop legitimately owed you and a chore it should absorb itself
  (un-parking, recovery). The chore share is the number the autonomy goal drives
  toward zero, broken down per intent.
- **Unnecessary loop stops.** Halts for approval or pause friction that were not
  a real question, counted as reducible waste.

Every number traces to a specific recorded transition or run, keyed per
(intent, task) instance so a task id reused across intents never folds together.
`yardlet trust --json` emits the autonomy metrics as machine-readable JSON, and
the terminal UI shows the same numbers in a **Trust panel** (press `T`). The
whole report is read-only: it reports, it never changes routing or policy on its
own.

Computation details: [docs/memory-trust-mining.md](docs/memory-trust-mining.md).

## Outcome Mining

The same telemetry feeds the learning loop. `yardlet harness review` shows the
auto-learned rules and skills with their eval scores, and next to them surfaces
**mined observations** that cross a threshold: a worker with a high no-result
rate (an output-contract problem worth a rule), or a task kind that averages
many attempts to reach Done (it wants a skill or sharper acceptance criteria).

These are **suggestions only**. Mining points at a recurring deterministic
outcome and proposes a harness improvement; you apply the rule, skill, or scope
change. Telemetry never rewrites the harness on its own. This is the loop
compounding: a deterministic result from one run becomes guidance that sharpens
the next.

Thresholds: [docs/memory-trust-mining.md](docs/memory-trust-mining.md).

## Terminal UI shortcuts

The terminal UI (`yardlet` with no subcommand) is the main way to drive a
session. From the Home screen:

| Key | Action |
| --- | --- |
| `n` | New work: describe a request (when idle). |
| `r` | Run the next task. |
| `A` | Auto-drain the queue. |
| `t` | Tidy: self-heal workspace state (migrate stale gates, defer non-runnable work, wrap drained intents). |
| `p` | Approve the next task; while a drain runs, request a graceful pause. |
| `a` | Open Answer for a task waiting on you (NeedsUser), with its worker output and conversation. |
| `d` | Defer the selected task by decision. |
| `v` | Revive the selected Deferred task. |
| `Esc` | Stop the running worker. |
| `↑` / `↓` | Browse the queue, then the workers panel past its end. |
| `Enter` | Run the selected task's next action (run / answer / approval hint / monitor / handoff), or toggle a worker past the queue. |
| `Space` / `Enter` | Toggle the selected worker on/off (in the workers panel). |
| `i` | View the intent contract. |
| `h` | View the latest handoff. |
| `T` | Trust and autonomy panel (same numbers as `yardlet trust`). |
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
| `yardlet new "<request>" [--worker <id>]` | Start or resume conversational planning and record a replacement proposal without changing active state. |
| `yardlet planning show [--json]` / `accept` / `reject` / `undo` / `answer` / `confirm` | Review the channel and semantic diff, then act against an expected draft head; only `confirm` promotes the visible draft. |
| `yardlet goal "<goal>" [--verify "..."]` | Express lane: skip the planning worker, record an exact draft and confirmation, then run one goal to a verify condition. |
| `yardlet new "..." --image <path>` | Attach a local image to the goal (also auto-detected from the request). |
| `yardlet add "<title>" [--depends-on <id>]` | Append a user-authored task to the current queue without replanning. |
| `yardlet queue` | List the work queue. |
| `yardlet tidy` | Self-heal workspace state: migrate stale gates, defer non-runnable work, archive drained intents. |
| `yardlet status [--json]` | Workspace, intent, queue, and worker summary. |
| `yardlet worker status` | Worker readiness and billing-env safety. |
| `yardlet inspect repo [--json]` | Cheap deterministic local evidence. |
| `yardlet packet --task <id> --worker <id> [--dry-run]` | Compile a worker packet. |
| `yardlet run --next [--execute] [--worker <id>]` | Prepare (default) or run the next task. |
| `yardlet run --auto [--parallel N]` | Drain the queue autonomously; optionally N tasks at once. |
| `yardlet answer "<reply>"` | Answer a task waiting on you (NeedsUser) and resume it. |
| `yardlet approve <id>` | Grant single-use approval to a gated task. |
| `yardlet defer <id> [reason]` | Set one task aside by decision (Deferred, not pending and not done). |
| `yardlet defer <id> --cascade [reason]` | Also defer queued tasks stranded behind it, transitively, as one revive group. |
| `yardlet revive <id> [--group]` | Return a Deferred task to Queued; `--group` revives the cascade group recorded with it. |
| `yardlet access <sandboxed\|full>` | Set the default worker permission level. |
| `yardlet handoff` | Print the latest run's handoff. |
| `yardlet report` | Print the intent's final report (aggregate of every task). |
| `yardlet memory [init \| refresh [--stale-only]]` | List the project-memory index (flags possibly stale docs); `init`/`refresh` draft docs via a worker that Yardlet's core then writes. |
| `yardlet memory scout` / `yardlet memory apply --run <run-id>` | Inspect isolated copies in parallel, produce unapplied memory candidates, then apply them through the core writer. |
| `yardlet watch [--interval N] [--until CONDITION] [--max-runs N] [--max-seconds N] [-- <command>]` | Observe a local command or path in the foreground until a bounded condition is met. |
| `yardlet eval fixtures [--json] [--fixture <id>]` | Run isolated deterministic mechanism fixtures; any failed fixture returns a non-zero exit. |
| `yardlet trust [--json]` | Trust + autonomy report from run telemetry and the transition audit log (read-only); `--json` emits the metrics. |
| `yardlet recover` | Recover state from an interrupted session (orphaned runs, unread plans). |
| `yardlet skill list / suggest / equip <preset> / unequip / research / create / apply / review` | Classify repos; use the managed 11-skill catalog; equip, author, and score skills. Core skills install without an external library; overlays stay task-scoped. |
| `yardlet harness review` | Show auto-learned rules and skills with their eval scores, plus mined improvement candidates. |
| `yardlet rubric drift / sync [--adopt-text]` | Diagnose how the workspace rubric lags the template and merge improvements in (non-destructive). |
| `yardlet routing review` | Per-kind worker success stats + suggested preferences. |
| `yardlet routing apply --kind K --worker W` | Pin a worker for a task kind (human-approved). |

When a worker needs input it leaves the task in **NeedsUser** with a question.
`yardlet status` (and the TUI) shows the question; reply with `yardlet answer "..."`
(or press `a` in the TUI) and Yardlet re-runs the task with your answer. The TUI
Answer view includes the current intent's worker output and relevant
conversation, with scrolling and a compact fallback when the output is absent.

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

## Serial isolation and owned integration

Every eligible task selected through the serial execution path runs in a
run-owned git worktree, including when dependency scheduling leaves only one
eligible task. That serial worker writes its result files to a staging run
directory inside the worktree. The main Yardlet process imports those artifacts
and remains the only writer of the canonical queue, conversation, telemetry,
and `.agents/runs/` state. This staging/import boundary is specific to the
serial path; parallel workers use their canonical run directories directly, as
described below.

Automatic serial commit and merge remain off by default:

```yaml
auto_commit: false
```

With the default, a changed run creates no commit or merge; it stays Partial
with the owned worktree retained for inspection. With `auto_commit: true`,
Yardlet commits only the isolated non-`.agents/` diff and merges tasks back in
dependency order. Dirty or concurrent main-checkout edits are never staged or
attributed. An unsafe merge stays Partial and retains its worktree and ownership
record. A no-change run needs no commit and its worktree is cleaned up.

For core-staged serial runs only, Yardlet creates the isolated commit with
native `git commit` on a durable internal `yardlet-txn/...` branch, so
repository commit hooks and `commit.gpgSign` still apply. It validates the
commit's exact parent and frozen evaluated tree, then publishes only that commit
to the run-owned branch with a compare-and-swap. A hook or signing failure
leaves the target branch unchanged and preserves the worktree; a concurrent ref
change also fails closed. Parallel workers cannot supply or resume this
transaction record and stay on the marker-free immutable-commit path. After a
merge, restart cleanup removes the worktree and refs only while they still match
the recorded worker commit. Commit hooks that inspect the current branch see
the internal transaction branch during serial completion.

Serial-path provenance plus integration, cleanup, no-change, and Git-finish
authority is stored as core-owned receipts outside the worker-writable run
directory. Recovery rebuilds a malformed or retargeted run projection from
those receipts, and treats a remotely verified finish as terminal only after
the queue and sealed run projection also agree. This closes each cleanup and
push crash window without rerunning a completed worker or repeating an
already-applied push.

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

## Git finish

Automatic push is a separate, user-owned completion policy and is off by
default. `yardlet init` writes an explicit disabled block; older workspaces
without the block also stay disabled. Configure a named remote, a fully
qualified branch ref, and checks in the order they must pass:

```yaml
git_finish:
  auto_push: false
  remote: safe-remote
  target_ref: refs/heads/main
  pre_push_checks:
    - name: format
      command: cargo fmt --check
    - name: tests
      command: cargo test
```

After reviewing this policy, set `auto_push: true` to opt in. This does not
make arbitrary commits pushable. Yardlet records the worktree baseline and the
exact commits created by the run, then accepts the integrated OID only when the
commits newly reachable from the baseline are exactly that owned set. The
remote target must still equal the baseline. A hook, another session, or local
automation that inserts an unowned commit therefore fails closed before push.

Finishers for the same Git common directory, remote, and target ref are
serialized with a bounded local lock. While holding it, Yardlet requires the
current branch and `HEAD` to match the target and owned OID, one push
destination, and no changes outside `.agents/`. Ordered checks run next. After
the checks, Yardlet rechecks `HEAD`, the worktree, fetch and push destinations,
and the remote target ref; any concurrent change stops with zero push.

The push is always an explicit `<expected_oid>:<target_ref>` refspec. There is
no force, force-with-lease, ref deletion, or history rewrite path. Yardlet then
uses a separate `git ls-remote --refs` lookup and reports success only when the
remote OID equals the frozen expected OID. Repeating the same finish converges
to `already_applied` without another push.

When `auto_push: true`, only `pushed`, independently verified
`already_applied`, and core-verified no-change `not_needed` complete the task.
Every other finish status projects the task, sealed `run.yaml`, telemetry,
final report, and Trust accounting as unfinished `Partial`. With the
default-off policy, `disabled` is not a required finish and normal task
completion is unchanged.

| Recorded status | User-visible meaning |
|---|---|
| `pushed` | The exact OID was pushed and independently verified. |
| `already_applied` | The remote already had the exact OID; no push ran. |
| `not_needed` | The core verified that this run produced no Git changes; no push ran. |
| `prepared` | The durable pre-push record exists, but the remote result is not yet known; `recover` reconciles it. |
| `check_blocked` / `safety_blocked` | A configured check, ownership proof, lock, or concurrent-state gate blocked; the task remains Partial for explicit resolution. |
| `git_failed` | A Git lookup or push command failed; the task remains Partial and no remote success is claimed. |
| `remote_mismatch` | Push returned success, but independent verification did not match; inspect the remote before resolving the Partial task. |
| `disabled` | The workspace did not opt in, so Git finish does not gate normal completion. |

Every outcome is written authoritatively to
`.agents/checkpoints/git-finish/<run-id>.json`; the matching
`.agents/runs/<run-id>/git-finish.json` is a user-facing projection. The result
is also projected into run telemetry and the final report. The record includes
the remote name, target ref, baseline, run-owned and expected OIDs, before/after
remote OIDs, check results, push flags, reason, and timestamp. It does not store
a remote URL, check command text or output, credentials, or environment values.

Yardlet writes `prepared` before invoking push. After an interruption,
`yardlet recover` reloads that ownership record under the same target lock and
checks the remote. If the remote already equals the expected OID, recovery
converges to `already_applied` without another push. If it still equals the
baseline, Yardlet can retry the same exact-OID push. Any other remote or local
state fails closed. If remote verification finished but sealing the queue,
`run.yaml`, or telemetry was interrupted, recovery reprojects the verified
result idempotently. Other blocked or failed statuses are not silently retried
or promoted; they remain Partial for explicit user resolution. Use a local bare
remote for project dogfooding and tests; this contract does not claim that
Yardlet pushes its own public `origin`.

## Crash safety

Yardlet state survives restarts. On startup (and via `yardlet recover`) it recovers
interrupted sessions: a planning result the previous session paid for but never
read becomes a proposal in its exact planning session, finished orphaned runs are
evaluated and merged (worktree runs included), and unfinished ones are requeued. A durable
`prepared` Git finish is reconciled from its ownership record and current
remote OID; verified results are projected once, while ambiguous state stays
Partial. PlanMeta schema version 2 binds every conversational planner run to its
session id, expected draft head, request event id, and canonical request-event
digest. Result application rechecks all four under the planning lock. A stale
head, a superseding user event, a closed or missing exact session, malformed
result, or corrupt activation is returned as an error without changing active
bytes or writing the consumed marker. Recovery never finds a session by matching
request text and never writes active intent or queue as a fallback. It creates
only the exact proposal, and accept plus confirm remain explicit user actions.
The consumed marker is written atomically only after canonical proposal and
journal writes succeed. An interrupted planning confirmation replays the same stable action,
deduplicates its effect events, and remains non-runnable if any snapshot,
activation, or completed action receipt does not match the current active
confirmation exactly. Before an accepted revision is stored, its prepared
receipt reserves the stable result id and exact typed effect event id, payload,
and digest. A schema-version 2 terminal receipt requires all four effect fields,
and its canonical payload bytes and digest must equal the one immutable journal
event. Schema version 1 compatibility is an explicit separate branch: realistic
legacy events may omit the request digest, and replay never appends a synthetic
duplicate or mutates the old journal. The event
journal fails closed unless sequence numbers are contiguous from 1, filename and
embedded identities match, event ids and payloads are unique, action/type
cardinality is valid, and `next_seq` is not ahead. A persisted session also
rejects a missing journal directory or a session/latest-pointer identity
mismatch; only an empty, artifact-free `next_seq: 1` initial journal is valid.

Planning confirmation and runtime queue mutations (`add`, run transitions,
finalization, and orphan recovery) share one permanent workspace kernel lock and
compare-and-swap boundary. Lock acquisition is non-blocking with a bounded
timeout, retrying interrupt and contention errors, and the descriptor is closed
across worker execution. Immutable revisions and events use atomic no-clobber
create, while session and action transitions use compare-and-swap. The activated
queue retains an immutable materialized base plan for confirmation parity.
Confirmed task identity, relative order, worker, scope, dependencies, and
acceptance stay exact while typed scheduler metadata evolves. Explicit user
adds and ingested worker follow-ups are append-only runtime tasks with an empty
confirmation-materialization marker and a separate core-owned immutable origin
receipt; their execution contract must keep matching that receipt. A committed
ordinal marker makes their presence and order append-only. Hard `runs_before`
edges and stale decision-capability clears are accepted only when their exact
typed runtime receipt replays onto the immutable base. Receipt preparation is
provisional until that marker exists: if queue CAS never exposes the effect, a
well-formed uncommitted receipt can be safely superseded by a later retry. Once
the effect is in the queue, only its exact after-queue digest may repair the
missing commit marker. Skill projection after confirmation touches only newly
ingested tasks. Snapshot,
status, TUI startup, packet, approval, queue, run, add, finalization, and
recovery reject an altered envelope or missing receipt before exposing trusted
work or changing canonical bytes. Each express goal holds the same outer
workspace transaction across session creation, proposal, accept, and confirm,
so concurrent express processes cannot interleave planning sessions. A new confirmation refuses to replace an active
queue that still contains Queued, Running, NeedsUser, Partial, or Blocked work,
and a corrupt activation guard is returned as an error instead of being treated
as an inactive workspace.

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
  intent-contract.yaml      current goal / scope / acceptance
  work-queue.yaml           tasks
  planning.lock             kernel-held workspace mutation transaction lock
  planning-sessions/        sessions, immutable proposals/drafts, ordered events, action receipts
  activations/              committed exact-promotion receipts
  runtime-task-receipts/    immutable origins for post-confirm user/follow-up tasks
  runtime-capability-receipts/ typed stale-decision capability migrations
  activation-required.yaml durable V010-origin discriminator for fail-closed scheduling
  *-policy.yaml             tool / approval / interaction / research / billing policy
  workers.yaml              worker profiles + routing
  memory/                   durable workspace facts (one fact per .md, git-tracked)
  rules/ skills/ agents/    harness assets (rules, skill catalog, role notes)
  runs/<run-id>/            per-run artifacts (result, validation, checkpoint, handoff, git-finish projection)
  conversations/<id>.yaml   needs-user transcripts threaded back to the worker
  checkpoints/              authoritative recovery receipts + compact resume points
  handoffs/                 teammate-readable summaries
  telemetry/                runs.jsonl: per-run outcomes (the trust + mining source)
  transitions/<task>.yaml   per-task state-change audit log (the autonomy source)
  intents/                  archived drained intents (task history preserved)
```

User-level, non-secret config lives under `~/.yardlet/`.

## License

MIT
