# Changelog

## Unreleased

### Added

- **Worker management from the TUI.** The Home arrow keys now continue past
  the queue into the workers panel; Enter/Space toggles a worker on/off
  (persisted as `enabled:` in workers.yaml — routing and planning skip a
  disabled worker).
- **Model/effort presets sync from the CLIs.** codex models and reasoning
  efforts come from the CLI's own `~/.codex/models_cache.json` (the models
  available to this account); claude effort levels are parsed from
  `claude --help`, and its model aliases are the documented stable set. No
  hand-maintained id lists; typing an exact id still works.
- **Custom workers via config alone.** Any subscription-backed CLI can be
  added as a third worker in workers.yaml with an invocation template
  (`args`, `sandbox_args`/`full_access_args`, `model_args`, `effort_args`,
  `image_args`; placeholders `{run_dir}` `{model}` `{effort}` `{image}`).
  Codex and Claude Code keep their first-class adapters; see README
  "Adding a worker".

- **Role profiles** (plan §13.4). Tasks run under a prompt-mode role derived
  from their kind — builder / reviewer / researcher / security — with
  role-specific working rules in the packet, replacing the old worker-keyed
  guidance. A workspace extends a role by writing `.agents/agents/<role>.md`
  (appended to that role's packets as "Workspace role notes").

### Fixed

- TUI responsiveness: the mid-run refresh no longer spawns worker `--version`
  probes every second (which froze the event loop ~100ms and ate keystrokes),
  and the Run Monitor renders from a cache instead of rescanning the runs
  directory and re-parsing the whole worker log every frame.
- Keyboard shortcuts work with the Korean IME on: 2-beolsik jamo map back to
  their QWERTY keys on shortcut screens (ㅡ→m, ㅗ→h, Shift+ㅁ→A).
- Single-press shortcuts under a CJK IME (macOS): on shortcut screens Yard
  auto-selects an ASCII input source (the im-select pattern), so the first
  keypress is no longer swallowed by IME composition; the IME is restored on
  text-input screens and on exit. Toggle via Settings ("Auto IME switch") or
  `auto_ime` in `.agents/yard.yaml`.
- Quitting mid-run no longer duplicates work: the worker survives a quit, and
  on restart Yard now ADOPTS a still-alive worker (task stays Running, the
  Monitor tails its live log, the idle loop evaluates and merges its result
  when it lands) instead of requeueing the task into a second worker. The
  auto-drain waits for an adopted worker rather than starting overlapping
  work; only a dead worker with no result is requeued.
- Worker-loss audit fixes: a stale plan finished late by an orphaned planning
  worker can no longer clobber a newer intent/queue (supersession guard); a
  still-running planning worker from a previous session is reported instead
  of being silently duplicated; Esc now also stops an adopted worker; a dead
  background job thread fails the job instead of leaving the UI busy forever;
  and integration only ever aborts its OWN in-progress merge — a merge the
  user has in progress is reported and left untouched.

## v0.2.0 — 2026-06-11

### Added

- **Parallel queue.** The auto-drain can run up to `max_parallel` independent
  tasks at once, each in its own git worktree on branch `yard/<task-id>`
  (`yard run --auto --parallel N`, the Settings screen, or
  `max_parallel` in `.agents/yard.yaml`). Workers run in parallel; queue state
  keeps a single writer; results merge back sequentially, and a conflict drops
  the task to Partial with its worktree kept for inspection. Design:
  `docs/parallel-queue.md`.
- **Task dependencies.** Tasks carry `depends_on`; the planner is asked to cut
  tasks coarse along scope boundaries and mark only genuine output
  dependencies. Yard sanitizes plans to backward references (no self/forward/
  unknown ids, no cycles) and scheduling skips tasks with unmet dependencies.
- **Crash recovery for planning.** Plan runs record their mode + request up
  front and a consumed marker once derived; a restart (TUI startup, auto-drain,
  or the new `yard recover`) consumes a planning result the previous session
  paid for but never read — including run dirs created by older versions.
- **`yard recover`.** One command to recover an interrupted session: unread
  plans, finished orphaned runs (worktree runs get merged back), and
  interrupted tasks requeued.
- **TUI.** Run Monitor follows every running task (tab row + Tab/←→ switching
  when parallel), Settings exposes "Parallel tasks", and the auto-drain
  reports gated-vs-drained queues accurately.
- **CI.** GitHub Actions: `cargo fmt --check` + `clippy -D warnings` gate and
  build/test on Ubuntu and macOS.

### Fixed

- Orphan recovery is worktree-aware: a finished parallel run found on startup
  is merged into the workspace instead of leaving its changes stranded.
- Planning results are no longer lost when Yard exits mid-plan.

## v0.1.0

Initial release: planning gate (intent contract + bounded queue), hidden
subscription-backed workers (Codex CLI, Claude Code CLI) behind one packet
contract, zero-AI-API-key guard, deterministic evaluator, checkpoints and
handoffs, worker routing with telemetry-suggested (human-applied) preferences,
per-task model/effort, live run monitor, reports/history browser, and the
Ratatui terminal UI.
