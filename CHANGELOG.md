# Changelog

## Unreleased

### Added

- **Explicit skill authoring: `yard skill research / create / apply` (S2/S3).**
  On-demand skills without hand-writing a SKILL.md. `yard skill research
  "<topic>"` runs a researcher-role worker that drafts a candidate skill to a
  run dir and installs nothing; `yard skill apply <run-id>` installs that
  draft; `yard skill create <name> [--from "<topic>"]` authors and installs in
  one step. The run is **queue-isolated** — like the planner it spawns one
  worker, but derives no intent/queue, so authoring a skill never disturbs the
  live intent (the gap that deferred this). The worker proposes the content;
  Yard (the deterministic core) is the sole writer. Authored skills are tagged
  `source: created` (not `learned`), so they are user-chosen and never
  auto-pruned — they persist like a library equip until `unequip`.

### Fixed

- **Recover a task wrongly stuck `Failed` by a dead orchestrator.** If Yard
  exited after a worker *finished* but before the result was evaluated, the
  task could end up `Failed` even though its run produced a clean `done`
  result — and neither restart-recovery nor `yard recover` could salvage it
  (recovery only looked at `Running` tasks), forcing a wasteful full re-run.
  Recovery now also re-evaluates such a task's stranded result, detected by an
  **unfinalized orphan run** (`worker.pid` still on disk — a finalized run
  removes it — with the process gone). It routes through the evaluator, so a
  genuinely-bad result stays failed; only real, completed work is reclaimed.
  Surfaced by dogfooding sample-project, where a completed map task sat `Failed`.

## 0.4.0 — 2026-06-16

### Added

- **Shared harness injection (phase H1).** Every packet — execution and
  planning, every worker — now carries the workspace harness: `.agents/rules/*.md`
  inlined (4 KB cap, overflow becomes read anchors) and a skill catalog from
  `.agents/skills/*/SKILL.md` frontmatter with Hermes-style progressive
  loading (catalog line → SKILL.md → deeper reference files). The planner can
  assign `task.skills`, which become required read-anchors in that task's
  packet; parallel worktrees get the harness assets copied in so relative
  anchors resolve. Skill format stays agentskills.io/Claude-Code compatible.

- **Harness asset discovery (A1).** Repos that already carry agent assets
  get them as shared harness the moment Yard runs: root `AGENTS.md` /
  `CLAUDE.md`, `.claude/skills/*`, `.cursor/rules/*.{md,mdc}`, and
  `.github/copilot-instructions.md` are discovered read-only and projected
  into packets **worker-aware** — a worker that reads a source natively
  (claude: CLAUDE.md + .claude/skills; codex: AGENTS.md) never receives it
  twice. Symlinked duplicates (CLAUDE.md -> AGENTS.md) merge into one entry
  native to both. Opt out with `harness_discovery: false` in yard.yaml.

- **Ambiguity gate + planner interview (A2).** The planner's own ambiguity
  self-report now has teeth: while it says "high", queue-selected runs and
  the auto-drain refuse to start and show the planner's open questions.
  Press `a` to answer — each answer runs one interview turn (an in-place
  re-plan that folds all clarifications in and re-scores ambiguity), up to
  10 turns; the gate opens when the score drops, the cap is reached, or you
  override (`--accept-ambiguity`, or `ambiguity_gate: false`). The status
  line shows the questions and the turn counter.

- **Guaranteed acceptance review (A3).** A risky plan (any high-risk task)
  or a sizable one (3+ tasks) now always ends in a review-kind task that
  verifies the intent's acceptance criteria per criterion against the
  actual workspace. The planner is asked to include it; if it forgets,
  Yard appends one deterministically (depends_on = every prior task) — the
  verifier is never the doer.

- **Skill toolbox (S1): repo classification + auto-equip.** Point
  `skill_library` at a local library (internal-tool layout: `presets/*.skills`
  + `skills/<name>/SKILL.md`) and Yard classifies the repo from its file
  signals (`project.godot`→game, `package.json`→web-ui, Dockerfile→infra,
  …) and equips the matching presets' skills automatically on plan/goal
  (`auto_equip`, on by default — I4: minimize intervention). `yard skill
  list / suggest / equip <preset|name> / unequip` manage it by hand.
  Deterministic, no LLM; equip is a reversible symlink into `.agents/skills/`.

- **Auto-learned skills (S3).** When a run's result proposes a reusable
  procedure (`harness_suggestions` of kind "skill"), Yard records it
  automatically as `.agents/skills/<slug>/SKILL.md` marked `source: learned`
  — the worker authored the content, Yard (the deterministic core) does the
  writing, no clobber of existing skills. On by default (`auto_skill`, I4:
  minimize intervention). This is the cycle-strengthening loop: every run
  can leave the harness sharper, and the eval score (next) prunes what
  doesn't earn its place.

- **Skill score + auto-prune (S4) — the self-correction loop closes.** Each
  equipped skill is scored from telemetry by the runs that DECLARED it,
  preferring structured review-verdict pass-through over a plain Done rate
  (a skill injected often whose work keeps failing scores down, not up).
  `yard skill review` shows the table. Learned skills (`source: learned`)
  that score below the floor over enough runs are auto-pruned on plan
  (unequipped, kept in git — reversible), `auto_prune` default on (I4).
  Library skills you equipped are never auto-pruned. This makes auto-writing
  safe: bad learned skills don't accumulate — the eval loop removes them.

- **Structured review verdicts (eval upgrade).** Reviewer/safety tasks and
  `yard goal --verify` now emit `verdict: [{criterion_id, pass, evidence}]`
  in result.json — a machine-readable per-criterion judgment instead of
  trusting prose. The evaluator requires it for review tasks (no verdict, or
  a "done" claim with a failed criterion, blocks Done), and reviewers are
  instructed to report `needs_user` when a criterion fails so a real defect
  routes to you, not into a review retry loop. Verdict pass/total and the
  task's declared skills are recorded in telemetry — the quality signal the
  skill score (S4) reads. This is the gap that let sample-project pass
  as "web-UI quality": "good" is no longer the worker's self-report.

- **Hot session chaining (P1).** During an auto-drain, a task whose
  `depends_on` includes the task that just finished — on the same worker —
  now runs IN that worker's live session (`claude --resume` /
  `codex exec resume`) instead of cold-booting: the worker keeps everything
  it learned about the repo. The chain cuts on anything but a clean Done
  (failure/partial poisons the context), on a worker switch, on parallel
  fan-out, and after 3 consecutive tasks (context-rot cap). The packet says
  so explicitly ("same session, next task — do not re-explore").

- **`yard goal` express lane (P2).** For small work, skip the planning
  worker entirely: `yard goal "fix the login redirect"` lays down a single
  deterministic task and drains it. Add `--verify "..."` and Yard appends a
  separate reviewer task (depends_on the work) that checks the condition
  against the actual workspace with evidence — the verifier is never the
  doer, so for visual goals it picks up the ui-review / browser-evidence
  skills and must cite screenshots. No ambiguity gate (typing the goal is
  the acceptance). `--plan-only` queues without running.

- **`i` opens the full intent.** The Home header now shows the goal as a
  single line with a `(+N)` chip for follow-ups; press `i` to read the whole
  intent contract — goal, scope, out-of-scope, acceptance, and any interview
  clarifications — in a scrollable view. The reclaimed header line goes to
  the queue (header is now 5 lines, not 6).

- **Loud upgrade prompt.** When a newer yard binary is installed while the
  TUI is open, the Home footer turns into a cyan "press u to restart" prompt
  (the old one-line status note got missed for days). Once you've restarted
  into a build that has this, in-place upgrades won't go unnoticed again.

### Fixed

- A fresh plan now clears the queue before the planning worker runs, so the
  Home screen no longer shows the previous intent's tasks for the whole
  planning run. (Interview/amend keep the live queue.)

- **Mid-run model/effort changes apply to the next task.** Settings can be
  edited while a worker runs (it already could); now saving confirms with a
  toast that says the change lands on the next task — the in-flight worker
  keeps the model it was spawned with, but `run_next` re-reads workers.yaml
  every task, so the switch takes effect without stopping the drain.

- Input caret position with Korean text: the cursor drifted one cell per
  wrapped line (width/box-width division ignored word wrap and double-width
  Hangul at the right edge). The caret now simulates the renderer's
  wrapping, including explicit newlines on earlier lines.

## v0.3.0 — 2026-06-12

### Added

- **Per-worker API key pass-through (`invocation.pass_env`).** Zero-key is
  now framed as the default for the subscription-first audience, not an
  identity rule: a custom worker profile can name env vars (e.g.
  `OPENAI_API_KEY`) that reach that worker only, while every other worker
  stays key-scrubbed and Yard never reads or stores the values. README and
  AGENTS.md reworded accordingly; a native API adapter is on the roadmap.

- **Self-restart on upgrade.** yard notices when its own binary is replaced
  (cargo install while running) — the status line announces the new build
  and `u` re-execs into it in place. No more silently-stale TUI sessions;
  `a` now also works on queued tasks (instructions ride into the run).

- **Partial = continue, not redo (harness phase H2).** Re-running a Partial
  task injects the previous run's checkpoint, summary, and unresolved
  validation failures into the packet ("do not redo finished work"). The
  auto-drain now continues self-reported partials automatically
  (attempts-capped) and halts only on merge-conflict partials (marked via a
  partial-reason file). The TUI `a` key now also answers Partial/Blocked
  tasks — the reply becomes rerun instructions threaded into the
  continuation packet; the Answer screen shows what the previous run says is
  still missing.

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
