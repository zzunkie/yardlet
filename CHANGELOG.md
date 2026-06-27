# Changelog

## 0.8.0 - 2026-06-24

### Added

- **Project memory.** Drop durable facts and decisions about a workspace as
  Markdown under `.agents/memory/` (git-tracked, one fact per file, optional
  `name`/`description` frontmatter). Yardlet discovers them and injects a short
  **index** — title, one-line summary, anchor — into every worker packet and the
  planner, with bodies read on demand, so the always-loaded cost stays tiny.
  `yardlet memory` lists the index; `yardlet init` scaffolds the folder with a
  convention README. A doc can declare `look_at:` landmark paths, and
  `yardlet memory` flags it **possibly stale** when a landmark changed in git
  after the doc did.
- **Trust report.** `yardlet trust` summarizes run telemetry into a trust view:
  first-pass Done vs Done-after-retry vs never-Done, per-worker reliability
  (done-rate, partial/failed/no-result counts, wall time, user overrides), and
  the tasks that needed the most attempts. Scoped to the active intent so a task
  id reused across intents does not fold its attempts together. Read-only — it
  reports, it never changes policy.
- **Outcome mining.** `yardlet harness review` now surfaces telemetry-mined,
  threshold-crossing observations next to learned rules and skills: a worker
  with a high no-result rate (an output-contract problem), and a task kind that
  averages many attempts to reach Done (wants a skill or sharper acceptance).
  Suggestions only — you apply the rule/skill/scope change.
- **Capability grounding.** The planner validates each task's
  `required_capabilities` against the workers that actually declare them at queue
  creation, and a run-time backstop parks an unmet task as blocked instead of
  hard-erroring — so a capability gap is a clean human gate, never a crash.
  `yardlet status` lists such tasks under "awaiting you (no worker can do these
  yet)" rather than as broken/retryable work.
- **Defer a task.** `yardlet defer <id> [reason]` sets a task aside by decision
  (new `Deferred` state): not pending, not done. It is skipped by the scheduler
  but reads as a decision, not a problem, so a P0 ceiling you have chosen to
  postpone (e.g. work needing files you will provide later, or a capability no
  worker has) stops looking like a broken task and lets the intent wrap with the
  deferral on record. Revive it by re-queuing.
- **Auto-commit (opt-in).** The `auto_commit: true` flag in `.agents/yard.yaml`
  governs the serial path, which currently does NOT auto-commit: in the shared
  working tree a serial run's changes can't be told apart from a concurrent edit,
  so it reports that and leaves the commit to you (serial-in-worktree auto-commit
  is the next slice). The worktree/parallel path is independent of the flag and
  always commits as part of integration: each task commits in its own isolated
  worktree and merges back (never Yardlet's own `.agents/` state), so the commit
  is provably the worker's. Push stays manual either way.

### Changed

- **One finalization pipeline.** Serial, parallel, and recovery runs now share a
  single `finalize_run` path, so evaluation, gates, queue updates, and telemetry
  behave consistently across all three. Each run's `run.yaml` is now sealed to
  its real terminal outcome with a `completed_at` (it previously stayed
  `running` forever). Recovery emits telemetry for the salvaged outcome,
  attributed to the original worker, so the trust report no longer undercounts
  recovered tasks, and recovery never mutates the queue graph (it only finalizes
  the stranded run).
- **Review auto-remediation.** A review that fails its criteria and proposes a
  fix re-queues to re-verify AFTER that fix — sequenced by priority, not a
  blocking `depends_on` edge, so a fix that fails, is deferred, or is title-
  deduped can never deadlock the review — instead of blindly re-reviewing
  unchanged code. The drain's per-task attempt cap bounds the fix+re-verify loop
  ("try hard, then ask"); a review with no runnable fix surfaces to you.

## 0.7.0 - 2026-06-21

### Added

- **`yardlet rubric drift` / `yardlet rubric sync`.** Diagnose how a workspace's
  `.agents/workers.yaml` rubric has fallen behind the binary's embedded worker
  template, and merge the improvements back in non-destructively. `sync` is
  additive by default: it unions `capabilities` and `role_strengths`, fills
  empty `best_for`/`not_for`/`cost_weight`, and adds template-only workers,
  while leaving operational config (`invocation`, `model`, `effort`, `limits`,
  `billing`), the `routing` block, and workspace-only workers untouched.
  `--adopt-text` also replaces customized rubric text. This closes the gap where
  template rubric improvements never reached workspaces created earlier.
- **needs_user is now a conversation.** A task paused for the user keeps a
  transcript at `.agents/conversations/<id>.yaml`; resuming threads the whole
  exchange back to the worker, so it remembers the conversation. The worker
  decides whether your message is the decision (proceed) or a question (reply
  and stay paused). A bare `yardlet answer` now prints the worker's pending
  message instead of erroring, and answering surfaces the worker's reply, so the
  back-and-forth is visible.

### Changed

- **The queue renders in attention order.** `yardlet queue` and the TUI now show
  the running and next-to-run tasks on top and completed work at the bottom
  (grouped by state, then priority), and `yardlet queue` marks the task that
  runs next. Display-only; the on-disk queue keeps its order.
- **A needs_user task no longer halts the whole drain.** Autonomous draining
  skips a task that is waiting on you (or blocked) and keeps running independent
  ready work; tasks that depend on the paused one stay gated. The drain stops
  only when nothing is runnable, and then reports what needs you versus what is
  waiting on approval or dependencies.
- A review task that returns `needs_user` defers its verdict/criteria gate
  instead of reporting every acceptance criterion as failed, so a clarifying
  turn reads cleanly.

## 0.6.2 - 2026-06-19

### Added

- **Workers propose follow-up tasks; Yardlet ingests them (propose -> ingest).**
  A worker that finds adjacent work no longer edits `.agents/work-queue.yaml`
  itself. It proposes tasks in `result.json` `follow_up_tasks` (title + reason,
  optional kind/risk/scope/acceptance/skills/depends_on/preferred_worker/
  required_capabilities) and Yardlet ingests them as the sole queue writer:
  assigns ids and priority, sanitizes dependencies, dedups by title, and tags
  each `provenance: worker-proposed` so an enqueued follow-up is a tracked
  candidate, never a silent scope expansion. Runs on the serial and parallel
  paths.
- **Positional insert for proposed tasks.** `insert: "next"` slots a follow-up
  before the tasks already queued (soft ordering); `runs_before: [ids]` injects
  a dependency so each named existing task waits for the new one (a true "insert
  between"), dropping self, unknown, and cycle-forming targets. Lets a worker
  that hits a capability ceiling hand work to the capable worker, placed before
  its dependents.
- TUI: up/down arrows move the caret between lines in the multi-line New Work
  and Answer inputs (column-preserving, CJK-safe).

### Changed

- **A worker writing Yardlet-owned canonical state is now a fatal violation.**
  The evaluator's forbidden-path gate, run on the real diff, rejects a worker
  write to `work-queue.yaml`, `intent-contract.yaml`, `workers.yaml`,
  `*-policy.yaml`, `yardlet.yaml`, or `telemetry/`. The harness assets
  (`runs/`, `rules/`, `skills/`, `agents/`) stay writable.

### Fixed

- A task's `model: auto` / `effort: auto` no longer clobbers the worker
  profile's pinned model/effort. A per-task value overrides the profile only
  when explicit (set and not "auto"); "auto"/empty keeps the profile pin, so
  resolution is a consistent cascade task -> profile -> CLI default. Only
  affects workers that pin a model in workers.yaml; the default (empty pin) is
  unchanged.

## 0.6.1 - 2026-06-18

### Changed

- **Capability-based worker routing replaces the image-keyword router.** A task
  routes by a typed `required_capabilities` (planner-assigned) matched against a
  worker's declared `capabilities` in workers.yaml, instead of a hardcoded
  English/Korean keyword list in the router. Routing restricts both the
  candidate and the fallback set to workers that declare the capability; an
  explicit override to an incapable worker fails with a clear message. The
  "is this image generation?" judgment moves to the planner (the right layer);
  the deterministic core only matches the structured field. `yardlet goal` gains
  `--requires <capability>` for the express path.
- **"Done" is backed by real git evidence, and fails closed without it.** The
  forbidden-path gate runs against the actual diff, attributed by content
  fingerprints (so a worker re-modifying an already-dirty path is still caught),
  and the serial, parallel, and recovery paths all feed real git status rather
  than the worker's self-report. With no git evidence the gate fails closed, so
  a run cannot reach Done on the worker's word alone.
- **Workers are labelled "invocable", not "ready".** Readiness means the binary
  and version probed and the billing-env posture is known, not that the
  subscription login was verified (Yardlet never makes a billed call to check).

### Added

- The Home workers panel shows each worker's billing/auth posture and model;
  `yardlet worker status` and `yardlet status --json` expose the same.

### Fixed

- **A worker-added follow-up task is no longer clobbered.** A run re-reads the
  latest queue before saving its end state, so a task the worker appended during
  the run survives (the user-cancel path too).
- **The configured `routing.default_worker` is reachable** again: the planner no
  longer rewrites a blank `preferred_worker` to `codex`.
- **Validation commands get a timeout, captured output, and a scrubbed env.**
  Each runs in its own process group and is killed (whole tree) on a 300s
  timeout, with stdout/stderr captured; it runs with a billing-scrubbed core
  environment, so a validation command cannot consume provider credentials.

## 0.6.0 - 2026-06-18

### Changed

- **"Done" is now backed by workspace evidence, not the worker's self-report.**
  The evaluator's forbidden-path check runs against the actual git diff a run
  produced (baseline vs after), not the paths the worker claimed to touch, and a
  task's `validation` commands now run deterministically after the worker exits:
  a failing validation (or a required one that never ran) blocks the Done state.
  This closes the gap where a worker could report success while the workspace
  said otherwise.
- **Hard image/asset-generation routing.** Image and asset *generation* tasks
  now route to `codex` through a deterministic capability rule, not just the
  planner rubric, and may opt out of the fallback chain when no other worker has
  the capability. Image *analysis* tasks are unaffected.
- **Learned auto-rules are off by default.** `auto_rule` no longer defaults on;
  always-on rules are promoted by hand via `yardlet harness review`, so the
  deterministic core never silently rewrites its own guidance.

### Added

- **Staged `yardlet worker status`.** Each readiness gate (binary, version,
  billing-env, auth) is shown as a discrete stage with a marker. Auth is
  reported as "not verified offline" (Yardlet never makes a billed call to
  confirm a subscription login), and the per-worker verdict is framed as "safe
  to invoke under current policy", never as "auth verified".

## 0.5.6 - 2026-06-17

### Changed

- **Sharper worker routing.** Each worker's planner rubric is now contrastive and
  carries an explicit `not_for` (avoid-for) signal next to `best_for`, and the
  planning prompt shows each worker as one neutral "best for X. Avoid for Y."
  line. This fixes a class of mis-routing where a surface word (e.g. "refactor"
  on a single-file cleanup) pulled cheap, scoped work onto the more expensive
  worker. Grounded in routing-rubric research plus an A/B routing eval: no
  regression on clear tasks, better calls on ambiguous ones.

## 0.5.5 - 2026-06-17

### Fixed

- **Restored the macOS Intel (`x86_64-apple-darwin`) prebuilt binary.** The
  release workflow's Intel job ran on the `macos-13` runner, which stuck in
  `queued` and never produced a binary, so v0.5.4 shipped only Apple Silicon and
  Linux binaries and `cargo binstall yardlet` fell back to a source build on
  Intel Macs. Both darwin targets now cross-compile on the `macos-14` (Apple
  Silicon) runner.

### Added

- README documents the terminal UI keyboard shortcuts, and the repo now ships a
  CONTRIBUTING guide.

### Changed

- Planner rubric: `codex` `best_for` now also covers image and asset
  generation, so those tasks route to codex without naming a worker.

## 0.5.4 - 2026-06-17

### Changed

- The published crate no longer ships repo-internal material. `Cargo.toml`
  `exclude` drops the repo's own `.agents/` state, seed queues, CI config, and
  local backups from the tarball, leaving only what builds and runs the crate.

## 0.5.3 - 2026-06-17

### Added

- **Prebuilt binaries + `cargo binstall` support.** A release workflow
  (`.github/workflows/release.yml`) builds macOS (Intel and Apple Silicon) and
  Linux x86_64 binaries on each version tag and attaches them to the GitHub
  release, so users can grab a binary or run `cargo binstall yardlet` instead
  of compiling.

### Changed

- Public-landing polish: README gains crates.io/CI/downloads/license badges
  and an Install section, and its prose (plus this changelog) drops em-dashes.

## 0.5.2 - 2026-06-17

### Fixed

- **Pressing `p` during an auto-drain now shows feedback.** The running status
  line replaces the toast area while busy, so the graceful-pause toast was
  invisible exactly when you'd press `p` - it looked like a no-op. The busy
  status line now reflects the pause flag directly: request a pause and it
  switches to "pausing - will stop after the current task" (persistent, since
  the flag is). Completes the 0.5.1 pause/stop fix.

## 0.5.1 - 2026-06-17

### Changed

- **Renamed the project to Yardlet.** The crate, binary, and command are now
  `yardlet` (the `yard` name was taken on crates.io by an unrelated parser).
  The container-yard metaphor and identity are unchanged. Existing workspaces
  keep working: the config file is now `.agents/yardlet.yaml`, but a legacy
  `.agents/yard.yaml` is still read (and written in place) so nothing breaks on
  upgrade. Internal worktree branches stay `yard/<task-id>`.

### Fixed

- **Pause/stop now works from the Monitor screen, and the footer stops lying.**
  `p` (graceful pause) and a new `x` (stop the worker now) work on the Run
  Monitor, not just Home - the monitor was a dead end for both. The Home footer
  no longer advertises `p pause` during a planning or single-task run (nothing
  to pause between tasks); it shows `Esc stop` instead, and pressing `p` there
  now says so explicitly rather than a vague "busy". Esc/`x` stop the worker
  immediately; `p` still only pauses an auto-drain (between tasks).

## 0.5.0 - 2026-06-16

### Added

- **Rule auto-learn + `yardlet harness review` (harness H4 completion).** The
  learning loop already auto-recorded worker-proposed *skills* (S3); now a
  run's `harness_suggestions` of kind `"rule"` are auto-recorded too, as
  `.agents/rules/learned-<slug>.md` - an always-apply constraint H1 inlines
  into every packet (the worker proposes, Yardlet's deterministic core writes; no
  clobber; gated by `auto_rule`, default on). Because a rule is always-on it
  has no per-task attribution to score, so learned rules are kept until removed
  (git-reversible) rather than auto-pruned like skills. New `yardlet harness
  review` shows the learned rules and the learned skills with their eval
  scores in one place. (Deterministic-observation candidate mining - failure
  themes into candidates - remains the open part of H4.)

- **Workspace hooks (harness H3) - deterministic guards that bind every
  worker.** Executables in `.agents/hooks/pre-run.d/*` run before a worker
  spawns; a non-zero exit **blocks the run** (the task fails with the hook's
  reason, so the drain stops on it - fix the cause and re-run). Executables in
  `post-run.d/*` run during evaluation; a non-zero exit is a **fatal check
  that blocks Done**, folded into the evaluation. Each hook runs in the repo
  root with `YARD_TASK_ID` / `YARD_RUN_DIR` / `YARD_WORKER`, a 30s timeout
  (longer is killed and fails), and stdout/stderr captured to
  `<run_dir>/hooks/<phase>/`. Only executable files run, in sorted filename
  order. Unlike a single CLI's hooks, these bind Codex, Claude Code, and any
  generic-adapter worker alike. Yardlet ships no enabled hooks - `yardlet init`
  lays down empty `pre-run.d`/`post-run.d` and a documented `README.md`. Off
  with `hooks: false` in `yardlet.yaml`.

- **Explicit skill authoring: `yardlet skill research / create / apply` (S2/S3).**
  On-demand skills without hand-writing a SKILL.md. `yardlet skill research
  "<topic>"` runs a researcher-role worker that drafts a candidate skill to a
  run dir and installs nothing; `yardlet skill apply <run-id>` installs that
  draft; `yardlet skill create <name> [--from "<topic>"]` authors and installs in
  one step. The run is **queue-isolated** - like the planner it spawns one
  worker, but derives no intent/queue, so authoring a skill never disturbs the
  live intent (the gap that deferred this). The worker proposes the content;
  Yardlet (the deterministic core) is the sole writer. Authored skills are tagged
  `source: created` (not `learned`), so they are user-chosen and never
  auto-pruned - they persist like a library equip until `unequip`.

### Fixed

- **Recover a task wrongly stuck `Failed` by a dead orchestrator.** If Yardlet
  exited after a worker *finished* but before the result was evaluated, the
  task could end up `Failed` even though its run produced a clean `done`
  result - and neither restart-recovery nor `yardlet recover` could salvage it
  (recovery only looked at `Running` tasks), forcing a wasteful full re-run.
  Recovery now also re-evaluates such a task's stranded result, detected by an
  **unfinalized orphan run** (`worker.pid` still on disk - a finalized run
  removes it - with the process gone). It routes through the evaluator, so a
  genuinely-bad result stays failed; only real, completed work is reclaimed.
  Surfaced by dogfooding a real project, where a completed map task sat `Failed`.

## 0.4.0 - 2026-06-16

### Added

- **Shared harness injection (phase H1).** Every packet - execution and
  planning, every worker - now carries the workspace harness: `.agents/rules/*.md`
  inlined (4 KB cap, overflow becomes read anchors) and a skill catalog from
  `.agents/skills/*/SKILL.md` frontmatter with Hermes-style progressive
  loading (catalog line → SKILL.md → deeper reference files). The planner can
  assign `task.skills`, which become required read-anchors in that task's
  packet; parallel worktrees get the harness assets copied in so relative
  anchors resolve. Skill format stays agentskills.io/Claude-Code compatible.

- **Harness asset discovery (A1).** Repos that already carry agent assets
  get them as shared harness the moment Yardlet runs: root `AGENTS.md` /
  `CLAUDE.md`, `.claude/skills/*`, `.cursor/rules/*.{md,mdc}`, and
  `.github/copilot-instructions.md` are discovered read-only and projected
  into packets **worker-aware** - a worker that reads a source natively
  (claude: CLAUDE.md + .claude/skills; codex: AGENTS.md) never receives it
  twice. Symlinked duplicates (CLAUDE.md -> AGENTS.md) merge into one entry
  native to both. Opt out with `harness_discovery: false` in yardlet.yaml.

- **Ambiguity gate + planner interview (A2).** The planner's own ambiguity
  self-report now has teeth: while it says "high", queue-selected runs and
  the auto-drain refuse to start and show the planner's open questions.
  Press `a` to answer - each answer runs one interview turn (an in-place
  re-plan that folds all clarifications in and re-scores ambiguity), up to
  10 turns; the gate opens when the score drops, the cap is reached, or you
  override (`--accept-ambiguity`, or `ambiguity_gate: false`). The status
  line shows the questions and the turn counter.

- **Guaranteed acceptance review (A3).** A risky plan (any high-risk task)
  or a sizable one (3+ tasks) now always ends in a review-kind task that
  verifies the intent's acceptance criteria per criterion against the
  actual workspace. The planner is asked to include it; if it forgets,
  Yardlet appends one deterministically (depends_on = every prior task) - the
  verifier is never the doer.

- **Skill toolbox (S1): repo classification + auto-equip.** Point
  `skill_library` at a local library (presets/skills layout: `presets/*.skills`
  + `skills/<name>/SKILL.md`) and Yardlet classifies the repo from its file
  signals (`project.godot`→game, `package.json`→web-ui, Dockerfile→infra,
  …) and equips the matching presets' skills automatically on plan/goal
  (`auto_equip`, on by default - I4: minimize intervention). `yardlet skill
  list / suggest / equip <preset|name> / unequip` manage it by hand.
  Deterministic, no LLM; equip is a reversible symlink into `.agents/skills/`.

- **Auto-learned skills (S3).** When a run's result proposes a reusable
  procedure (`harness_suggestions` of kind "skill"), Yardlet records it
  automatically as `.agents/skills/<slug>/SKILL.md` marked `source: learned`
  - the worker authored the content, Yardlet (the deterministic core) does the
  writing, no clobber of existing skills. On by default (`auto_skill`, I4:
  minimize intervention). This is the cycle-strengthening loop: every run
  can leave the harness sharper, and the eval score (next) prunes what
  doesn't earn its place.

- **Skill score + auto-prune (S4) - the self-correction loop closes.** Each
  equipped skill is scored from telemetry by the runs that DECLARED it,
  preferring structured review-verdict pass-through over a plain Done rate
  (a skill injected often whose work keeps failing scores down, not up).
  `yardlet skill review` shows the table. Learned skills (`source: learned`)
  that score below the floor over enough runs are auto-pruned on plan
  (unequipped, kept in git - reversible), `auto_prune` default on (I4).
  Library skills you equipped are never auto-pruned. This makes auto-writing
  safe: bad learned skills don't accumulate - the eval loop removes them.

- **Structured review verdicts (eval upgrade).** Reviewer/safety tasks and
  `yardlet goal --verify` now emit `verdict: [{criterion_id, pass, evidence}]`
  in result.json - a machine-readable per-criterion judgment instead of
  trusting prose. The evaluator requires it for review tasks (no verdict, or
  a "done" claim with a failed criterion, blocks Done), and reviewers are
  instructed to report `needs_user` when a criterion fails so a real defect
  routes to you, not into a review retry loop. Verdict pass/total and the
  task's declared skills are recorded in telemetry - the quality signal the
  skill score (S4) reads. This is the gap that let a dogfooded project pass
  as "web-UI quality": "good" is no longer the worker's self-report.

- **Hot session chaining (P1).** During an auto-drain, a task whose
  `depends_on` includes the task that just finished - on the same worker -
  now runs IN that worker's live session (`claude --resume` /
  `codex exec resume`) instead of cold-booting: the worker keeps everything
  it learned about the repo. The chain cuts on anything but a clean Done
  (failure/partial poisons the context), on a worker switch, on parallel
  fan-out, and after 3 consecutive tasks (context-rot cap). The packet says
  so explicitly ("same session, next task - do not re-explore").

- **`yardlet goal` express lane (P2).** For small work, skip the planning
  worker entirely: `yardlet goal "fix the login redirect"` lays down a single
  deterministic task and drains it. Add `--verify "..."` and Yardlet appends a
  separate reviewer task (depends_on the work) that checks the condition
  against the actual workspace with evidence - the verifier is never the
  doer, so for visual goals it picks up the ui-review / browser-evidence
  skills and must cite screenshots. No ambiguity gate (typing the goal is
  the acceptance). `--plan-only` queues without running.

- **`i` opens the full intent.** The Home header now shows the goal as a
  single line with a `(+N)` chip for follow-ups; press `i` to read the whole
  intent contract - goal, scope, out-of-scope, acceptance, and any interview
  clarifications - in a scrollable view. The reclaimed header line goes to
  the queue (header is now 5 lines, not 6).

- **Loud upgrade prompt.** When a newer yardlet binary is installed while the
  TUI is open, the Home footer turns into a cyan "press u to restart" prompt
  (the old one-line status note got missed for days). Once you've restarted
  into a build that has this, in-place upgrades won't go unnoticed again.

### Fixed

- A fresh plan now clears the queue before the planning worker runs, so the
  Home screen no longer shows the previous intent's tasks for the whole
  planning run. (Interview/amend keep the live queue.)

- **Mid-run model/effort changes apply to the next task.** Settings can be
  edited while a worker runs (it already could); now saving confirms with a
  toast that says the change lands on the next task - the in-flight worker
  keeps the model it was spawned with, but `run_next` re-reads workers.yaml
  every task, so the switch takes effect without stopping the drain.

- Input caret position with Korean text: the cursor drifted one cell per
  wrapped line (width/box-width division ignored word wrap and double-width
  Hangul at the right edge). The caret now simulates the renderer's
  wrapping, including explicit newlines on earlier lines.

## v0.3.0 - 2026-06-12

### Added

- **Per-worker API key pass-through (`invocation.pass_env`).** Zero-key is
  now framed as the default for the subscription-first audience, not an
  identity rule: a custom worker profile can name env vars (e.g.
  `OPENAI_API_KEY`) that reach that worker only, while every other worker
  stays key-scrubbed and Yardlet never reads or stores the values. README and
  AGENTS.md reworded accordingly; a native API adapter is on the roadmap.

- **Self-restart on upgrade.** yardlet notices when its own binary is replaced
  (cargo install while running) - the status line announces the new build
  and `u` re-execs into it in place. No more silently-stale TUI sessions;
  `a` now also works on queued tasks (instructions ride into the run).

- **Partial = continue, not redo (harness phase H2).** Re-running a Partial
  task injects the previous run's checkpoint, summary, and unresolved
  validation failures into the packet ("do not redo finished work"). The
  auto-drain now continues self-reported partials automatically
  (attempts-capped) and halts only on merge-conflict partials (marked via a
  partial-reason file). The TUI `a` key now also answers Partial/Blocked
  tasks - the reply becomes rerun instructions threaded into the
  continuation packet; the Answer screen shows what the previous run says is
  still missing.

- **Worker management from the TUI.** The Home arrow keys now continue past
  the queue into the workers panel; Enter/Space toggles a worker on/off
  (persisted as `enabled:` in workers.yaml - routing and planning skip a
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
  from their kind - builder / reviewer / researcher / security - with
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
- Single-press shortcuts under a CJK IME (macOS): on shortcut screens Yardlet
  auto-selects an ASCII input source (the im-select pattern), so the first
  keypress is no longer swallowed by IME composition; the IME is restored on
  text-input screens and on exit. Toggle via Settings ("Auto IME switch") or
  `auto_ime` in `.agents/yardlet.yaml`.
- Quitting mid-run no longer duplicates work: the worker survives a quit, and
  on restart Yardlet now ADOPTS a still-alive worker (task stays Running, the
  Monitor tails its live log, the idle loop evaluates and merges its result
  when it lands) instead of requeueing the task into a second worker. The
  auto-drain waits for an adopted worker rather than starting overlapping
  work; only a dead worker with no result is requeued.
- Worker-loss audit fixes: a stale plan finished late by an orphaned planning
  worker can no longer clobber a newer intent/queue (supersession guard); a
  still-running planning worker from a previous session is reported instead
  of being silently duplicated; Esc now also stops an adopted worker; a dead
  background job thread fails the job instead of leaving the UI busy forever;
  and integration only ever aborts its OWN in-progress merge - a merge the
  user has in progress is reported and left untouched.

## v0.2.0 - 2026-06-11

### Added

- **Parallel queue.** The auto-drain can run up to `max_parallel` independent
  tasks at once, each in its own git worktree on branch `yard/<task-id>`
  (`yardlet run --auto --parallel N`, the Settings screen, or
  `max_parallel` in `.agents/yardlet.yaml`). Workers run in parallel; queue state
  keeps a single writer; results merge back sequentially, and a conflict drops
  the task to Partial with its worktree kept for inspection. Design:
  `docs/parallel-queue.md`.
- **Task dependencies.** Tasks carry `depends_on`; the planner is asked to cut
  tasks coarse along scope boundaries and mark only genuine output
  dependencies. Yardlet sanitizes plans to backward references (no self/forward/
  unknown ids, no cycles) and scheduling skips tasks with unmet dependencies.
- **Crash recovery for planning.** Plan runs record their mode + request up
  front and a consumed marker once derived; a restart (TUI startup, auto-drain,
  or the new `yardlet recover`) consumes a planning result the previous session
  paid for but never read - including run dirs created by older versions.
- **`yardlet recover`.** One command to recover an interrupted session: unread
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
- Planning results are no longer lost when Yardlet exits mid-plan.

## v0.1.0

Initial release: planning gate (intent contract + bounded queue), hidden
subscription-backed workers (Codex CLI, Claude Code CLI) behind one packet
contract, zero-AI-API-key guard, deterministic evaluator, checkpoints and
handoffs, worker routing with telemetry-suggested (human-applied) preferences,
per-task model/effort, live run monitor, reports/history browser, and the
Ratatui terminal UI.
