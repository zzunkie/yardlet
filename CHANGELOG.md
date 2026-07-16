# Changelog

## Unreleased

### Added

- **Crash-safe serial Git completion.** Opted-in serial runs execute in owned
  worktrees, commit only their evaluated non-`.agents/` changes, merge in
  dependency order, and can finish through the existing exact-OID push policy.
  Durable ownership records recover interruptions across commit, merge, checks,
  push, and verification without rerunning a completed worker.

### Fixed

- **Receipted preferred-worker failover survives confirmation validation.**
  Confirmed `model: auto` tasks now resolve a fallback worker's own model from
  the immutable task contract, while matching run and terminal process receipts
  authorize the runtime overlay. Manual selection mutations still fail closed,
  and `yardlet recover` can finalize a completed failover attempt.

- **Serial integration stays bound to trusted evidence.** Worker staging cannot
  replace core-owned cancellation, failover, evaluation, validation, evidence,
  hook, or Git transaction records. Core-staged serial runs use native
  `git commit` on a durable internal transaction branch, validate its exact
  parent and frozen tree, then atomically claim the run-owned ref. Parallel runs
  cannot load that transaction state and retain the marker-free immutable
  commit plus exact-tip CAS path. Concurrent ref changes fail closed, repository
  commit hooks and configured signing remain enforced for serial completion,
  and restart reconciliation deletes only refs that still match the integrated
  worker OID. Core-owned receipts outside the worker-writable run directory
  authenticate the serial transaction path, integration, no-change, cleanup,
  and Git-finish recovery. The authoritative Git-finish record now lives under
  `.agents/checkpoints/git-finish/`; queue and run projections are rebuilt and
  must converge with remote truth before a finish is terminal, without
  duplicate worker runs or pushes.

## 0.9.2 - 2026-07-13

### Fixed

- **Codex worker sessions stay bound to the child that created them.** Fresh
  Codex runs now capture `thread.started.thread_id` directly from that child's
  JSONL stdout and use that exact ID for transient resume and dependent-task
  hot chaining. Yardlet no longer guesses from the most recently modified file
  under the global `~/.codex/sessions` directory, which could attach a
  concurrently active Codex Desktop conversation to an unrelated Yardlet run.
  Missing or malformed child session events now fail closed by disabling retry
  and hot chaining for that run instead of selecting another session.

## 0.9.1 - 2026-07-12

### Added

- **Managed built-in skill library.** Yardlet now ships 11 pinned and
  license-tracked skills: five core skills installed through the canonical
  no-clobber writer and six task-scoped overlays exposed through the existing
  `task.skills` and packet catalog path. Fresh workspaces need no external
  `skill_library`; existing user-owned skills always win on name conflicts.
  The bundle records immutable upstream commits, per-file blobs, included and
  excluded inventory, adaptations, and redistributed license copies.

### Fixed

- **Repository classification remains bounded without letting generated output
  hide source signals.** The deterministic scanner now ignores hidden and
  common generated directories before applying its directory budget. This
  keeps large web repositories with `.output`, build, coverage, or distribution
  trees classifiable from their tracked manifest and source paths, while
  preserving sorted traversal, depth, directory, and per-directory bounds.

## 0.9.0 - 2026-07-12

### Changed

- **Worker routing now follows the dominant acceptance surface, not task breadth
  alone.** Terminal- and tool-heavy work with executable checks can stay on the
  execution specialist even when broad, while synthesis-, vision-, or
  judgment-heavy work routes to the reasoning specialist. When a separate final
  verifier exists, planning prefers a different worker from the builder when
  available. The default worker profiles and planning gate template reflect the
  current Codex/Claude capability boundary without hard-coding model names into
  the reusable rubric.

### Added

- **User-owned, default-off Git finish policy.** `.agents/yardlet.yaml` can now
  name a remote, a full `refs/heads/...` target, and ordered pre-push checks
  under `git_finish`. Yardlet proves the exact commit set owned by the run from
  a recorded worktree baseline, requires the remote to remain at that baseline,
  and serializes finishers for the same repository/remote/ref. It rechecks local
  and remote state after ordered checks, pushes only the explicit non-force
  `<expected_oid>:<target_ref>` refspec, independently verifies it with
  `git ls-remote --refs`, and converges repeated attempts to `already_applied`.
  With auto-push enabled, every status except verified `pushed` or
  `already_applied` keeps the task Partial across queue, run, telemetry, report,
  and Trust projections. A durable `prepared` record lets `yardlet recover`
  reconcile interruptions before push, after push, or after verification
  without duplicate remote mutation. Records omit remote URLs, command output,
  credentials, and environment values. This does not add force push or
  public-`origin` dogfooding support.

- **Explicit goal feedback is bounded and durable.** Tasks can carry a goal
  condition, feedback policy, and maximum feedback cycles. Failed deterministic
  validation and acceptance evidence is recorded under the run, injected into
  the next attempt, and counted in a persisted ledger. Exhausting the limit
  stops at NeedsUser with the failure context instead of reporting Done.
- **Read-only memory scout fanout.** `yardlet memory scout` runs topic scouts
  against isolated workspace copies and merges their reports into unapplied
  candidates. `yardlet memory apply --run <run-id>` is a separate core-owned
  write step. `look_at` stale detection now also covers uncommitted and non-git
  filesystem changes.
- **Bounded foreground observation with `yardlet watch`.** A local command or
  path can be observed until success, failure, matching output, path creation,
  or path change, with interval, run-count, duration, and Ctrl-C bounds. Every
  invocation writes a stable `watch-result.json` run artifact.
- **Deterministic mechanism fixtures.** `yardlet eval fixtures` runs the seven
  baseline evaluator and recovery fixtures plus bounded goal feedback,
  read-only scout isolation, and watch-until behavior. Human and `--json`
  output share one verdict report, and any fixture failure returns a non-zero
  exit.
- **Question context in the TUI Answer view.** A NeedsUser stop now opens with
  the current intent's scrollable worker output and relevant conversation above
  the question, with compact-summary fallback when output is unavailable.
- **v0.9 mechanism documentation.** Comparison documents state the agent-CLI
  boundary, task versus worker yielding, and the mechanism-only benchmark
  posture. A durable ledger records every v0.9 disposition, deferral rationale,
  and measurable restart condition. Launch copy remains an unpublished draft.

- **`yardlet resolve <id>` finalizes a hand-merged Partial.** When a
  parallel run's merge-back conflicts, the task drops to `Partial` with its
  worktree kept. After you resolve and integrate the conflict by hand, a single
  `yardlet resolve <id> [reason]` marks it `Done` through the sole state writer:
  it appends a transition record to `.agents/transitions/` (so the Trust report
  sees the Done-transition, actor=you), clears the `partial-reason` marker,
  removes the merged worktree, and unblocks any dependents. No worker is
  re-invoked, since the work is already integrated. It refuses a task that is not
  `Partial`. Previously the only routes were a wasteful worker re-run or a raw
  hand-edit of `work-queue.yaml` that bypassed the audit log.
- **Defer and revive from the TUI.** On the Home queue, `d` defers the selected
  task and `v` revives a deferred one, each recording the state transition, so
  you no longer have to drop to the CLI to set a task aside or bring it back.
- **Approve a pending task mid-drain.** `p` is now context-aware on Home: it
  approves the selected approval-pending task even while an auto-drain is
  running, and only falls back to pausing the drain when nothing is awaiting
  approval. Previously `p` during a drain could only pause, so an approval-gated
  task could not be cleared without stopping the loop first.

### Fixed

- **Fast consecutive runs no longer overwrite one another's artifacts.** Every
  task, planning, memory, skill, and parallel attempt now atomically claims its
  run directory. When timestamp-based ids collide, Yardlet appends a numeric
  suffix instead of reusing the existing directory, preserving one auditable
  artifact set per attempt during fast auto-drains.
- **Final verification no longer races worker-proposed follow-up work.** Review
  and safety tasks now run as an exclusive serial phase after other runnable
  queue work. A newly ingested implementation or research task therefore lands
  before final verification instead of sharing the verifier's stale worktree
  snapshot. The barrier is scheduler-only rather than a hard dependency, so
  failed, deferred, or gated work cannot strand the verifier indefinitely.
- **Korean status labels no longer leak English tokens.** The terminal UI task
  state labels (running, done, failed, blocked, needs-you, partial, deferred,
  queued) now render from the localized label table for the detected language
  instead of hardcoded English, so a Korean session shows Korean state labels
  end to end.
- **`yardlet answer` shows the current plan's question, not a stale one.** The
  pending-question lookup is now scoped to the live intent. A past plan can reuse
  a task id (e.g. `YARD-001`) and its `result.json`/conversation stays on disk;
  the lookup now compares each candidate run's `intent_id` to the current queue's
  and ignores runs from a different intent, so a superseded question can no
  longer resurface. When the intent is unknown (unattributed legacy run) it
  falls back to the prior behavior rather than hide a real question.
- **Documentation and other non-code tasks are not failed by whole-app
  validation.** Configured validation commands now gate builder-role
  (implementation) tasks only; a research, review, or safety task is no longer
  flipped to `Failed` by an unrelated whole-app command that is not its
  acceptance.
- **An open question gates intent completion.** The completion judgment now
  distinguishes a `NeedsUser` task (an open question) from a `Deferred` one (a
  settled decision): the drain, terminal UI final-report transition, final
  report, and intent wrap no longer read as complete while a `NeedsUser`
  question is still pending.

## 0.8.1 - 2026-07-10

### Added

- **Trust Report v2: autonomy from the transition audit log.** `yardlet trust`
  now prints a second layer above the attempt view. A "can I trust a Done?"
  grade per (intent, task) instance (evidence-backed, recovered, false-done
  caught, unresolved, with a trustworthy-Done rate), a decision-vs-chore split
  of human interventions with a per-intent chore share, and a count of
  unnecessary loop stops. It folds the per-task transition records under
  `.agents/transitions/` and cross-checks run telemetry, so a Done that was
  later reopened is visible where telemetry attempts alone cannot show it. Every
  number traces to a recorded transition or run. `yardlet trust --json` emits
  the metrics as machine-readable JSON (nested under `done_trust`,
  `human_touches`, `loop_stops`, `sources`), and the terminal UI shows the same
  numbers in a Trust panel (the `T` key). Read-only, like v1.
- **Transition records carry `intent_id`.** System-driven task state changes now
  record the intent that owned the task, so the autonomy report attributes
  decisions and chores to the right intent instead of folding a reused task id
  across unrelated intents.
- **Worker-drafted project memory: `yardlet memory init` / `refresh`.** `init`
  asks a worker to draft memory documents from the repo into an isolated run
  directory; Yardlet's core is the sole writer that turns the drafts into
  canonical `.agents/memory/*.md`. `refresh` re-drafts existing docs the same
  way, and `refresh --stale-only` limits the worker to the docs currently
  flagged possibly stale. The worker proposes content; the deterministic core
  owns every write.
- **Self-healing workspace state.** `yardlet status`, `yardlet queue`, reports,
  and the TUI now distinguish runnable-now work from waiting decisions,
  approvals, dependencies, worker capability gaps, held tasks, deferred tasks,
  and done work. New `yardlet tidy` migrates legacy human-decision capability
  gates to `NeedsUser`, sets non-runnable tool gaps aside as `Deferred`, and
  archives drained intents without hard-deleting task history. System-driven
  task state changes now append per-task transition records under
  `.agents/transitions/` and surface the latest reason in status/queue/report.
- **One-shot worker failover.** A run that dies leaving no result artifacts is
  retried once on the next capable worker in `fallback_order` (readiness-checked,
  recorded in telemetry with the failover attribution), on both the serial and
  parallel paths.
- **State-aware Enter in the TUI.** Enter on the selected task runs its next
  action: queued/failed/partial = run, needs-user = answer, running = follow in
  monitor, done = view handoff, deferred = revive hint. An approval-required
  task without a grant is never run from Enter; it points at the approval flow
  instead. Stop messages now say why nothing ran and which key to press next,
  in both the English and Korean label tables.
- **Cascade defer and revive.** `yardlet defer <id> --cascade [reason]`
  now sets the target task and every queued task stranded behind it,
  transitively, to `Deferred` as one recorded group. `yardlet revive <id>`
  returns a Deferred task to `Queued`, and `yardlet revive <id> --group`
  revives every Deferred task recorded in the same cascade group, warning when
  revived tasks still depend on Deferred, Failed, Blocked, NeedsUser, or Partial
  work.

### Changed

- **Breaking: `yardlet status --json` queue counts were split.** The
  `queue.queued` field has been removed instead of kept as a compatibility
  alias. Consumers should read `queue.runnable` for work that can run now, or
  add `queue.runnable` and the `queue.waiting_*` fields when they need the old
  broad "not done yet" bucket.
- **The work queue is runtime state.** `yardlet` now treats a missing
  `.agents/work-queue.yaml` as an empty queue instead of erroring, so the queue
  file can be gitignored where it is operational rather than shared state. A
  present but malformed queue still fails loudly.

### Fixed

- **The approval gate holds on every spawn path.** `run_next` is the single
  choke-point: an approval-required task spawns a worker only with a valid
  grant, the grant is consumed on execution, and retry, failover, checkpoint
  auto-continue, and recover all re-enter through the gate. The auto drain now
  routes an unapproved retry to needs-user and continues runnable work instead
  of stalling.
- **Worktree commits carry your git identity.** Parallel-batch auto-commits and
  merges no longer use a hardcoded `yardlet <yardlet@localhost>` identity; they
  inherit the repository's configured `user.name`/`user.email`, and the commit
  message includes the task title, not just its id. Stale worktrees and branches
  from an earlier failed run are pruned before a task's worktree is recreated.
- **Viewer scroll is clamped to content.** Monitor/handoff viewers no longer
  scroll past the end of wrapped content.
- **Done-first completion for non-blocking leftovers.** Worker packets now
  reserve `needs_user` for questions or gates that actually block acceptance.
  When acceptance is met, minor cleanup or adjacent work should finish as
  `done`, with leftovers preserved in handoff/checkpoint notes and, when useful,
  proposed through `follow_up_tasks` so the auto loop can continue.
- **Preserve contradictory done questions.** If a worker reports `status=done`
  while also filling `question_for_user`, the evaluator now records the mismatch
  as an advisory check and the question remains visible in the run handoff and
  checkpoint instead of being silently lost.
- **Preserve user-owned config files.** TUI settings saves and `yardlet access`
  now update only the targeted `yardlet.yaml` / legacy `yard.yaml` /
  `workers.yaml` keys, preserving comments, key order, and untouched values
  instead of round-tripping the whole file through YAML serialization.
- **Recover abandoned runs.** `yardlet recover` now salvages a task stranded by
  an abandoned run: a run left stuck `running` (no live worker, no result) whose
  task is not itself flagged `Running`, e.g. a `NeedsUser` task whose
  `yardlet answer` run died before finalize. Previously recover keyed only off
  task state and reported "nothing to recover" while the task sat stuck. It now
  seals the stranded run record and requeues the task so it can re-run.
- **Human decisions are questions, not capabilities.** A worker can now mark a
  proposed follow-up that is really a human choice/approval with a
  `decision_question`; Yardlet ingests it as `needs_user` (seeding the question
  so `yardlet status` shows it and `yardlet answer` resolves it) and drops any
  `required_capabilities` on it. Previously such a decision could only be
  expressed as an off-vocab capability, which parked the task `Blocked` with no
  clean resolver. `required_capabilities` now means strictly a tool/skill/license
  a worker needs; the planner/worker prompts no longer conflate the two.
- **Scope-gated follow-ups.** A worker-proposed follow-up task whose
  `allowed_scope` reaches outside the parent intent's `allowed_scope` is now
  ingested as approval-required: the drain skips it until `yardlet approve`
  rather than auto-running it. An adjacent idea stays a queue candidate, not a
  silent expansion of the current intent.

## 0.8.0 - 2026-06-24

### Added

- **Project memory.** Drop durable facts and decisions about a workspace as
  Markdown under `.agents/memory/` (git-tracked, one fact per file, optional
  `name`/`description` frontmatter). Yardlet discovers them and injects a short
  **index** (title, one-line summary, anchor) into every worker packet and the
  planner, with bodies read on demand, so the always-loaded cost stays tiny.
  `yardlet memory` lists the index; `yardlet init` scaffolds the folder with a
  convention README. A doc can declare `look_at:` landmark paths, and
  `yardlet memory` flags it **possibly stale** when a landmark changed in git
  after the doc did.
- **Trust report.** `yardlet trust` summarizes run telemetry into a trust view:
  first-pass Done vs Done-after-retry vs never-Done, per-worker reliability
  (done-rate, partial/failed/no-result counts, wall time, user overrides), and
  the tasks that needed the most attempts. Scoped to the active intent so a task
  id reused across intents does not fold its attempts together. Read-only: it
  reports, it never changes policy.
- **Outcome mining.** `yardlet harness review` now surfaces telemetry-mined,
  threshold-crossing observations next to learned rules and skills: a worker
  with a high no-result rate (an output-contract problem), and a task kind that
  averages many attempts to reach Done (wants a skill or sharper acceptance).
  Suggestions only; you apply the rule/skill/scope change.
- **Capability grounding.** The planner validates each task's
  `required_capabilities` against the workers that actually declare them at queue
  creation, and a run-time backstop parks an unmet task as blocked instead of
  hard-erroring, so a capability gap is a clean human gate, never a crash.
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
  fix re-queues to re-verify AFTER that fix, sequenced by priority, not a
  blocking `depends_on` edge, so a fix that fails, is deferred, or is title-
  deduped can never deadlock the review, instead of blindly re-reviewing
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
