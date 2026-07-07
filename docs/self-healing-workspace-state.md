# Self-Healing Workspace State — Design Spec

> Status: design of record for intent `intent-20260707-153247` (YARD-001).
> Scope: `src/schemas.rs`, `src/state.rs`, `src/cli.rs`, `src/snapshot.rs`,
> `src/report.rs`, `src/parallel.rs`, `src/run.rs`, `src/routing.rs`, `src/ui/**`,
> `docs/**`, `CHANGELOG.md`. No product/auth/DB/deploy, no README rewrite, no full
> Trust Report v2, no planner re-design. Evaluator's Done semantics stay untouched.
> This document is a spec only; YARD-002 implements it, YARD-003 verifies it.

North star (intent): **the human decides; the system cleans.** After long
dogfooding the workspace must not silt up with false-pending signals, dead gates,
and decided-but-unactable tasks. Five outcome pillars map to acceptance
AC-001..AC-006 (§7).

---

## 0. Where we are today (evidence baseline)

The existing model already carries most of the primitives; the gaps are (a) an
honest **runnable-now** predicate at the count/label layer, (b) a structured
**transition-reason** record, (c) **stale-gate migration**, and (d) a
**one-action tidy**. Concretely, from the code:

- `TaskState` = `Queued | Running | Done | Blocked | Failed | NeedsUser | Partial
  | Deferred` (`schemas.rs:205`). `is_terminal()` = everything except
  `Queued`/`Running` (`schemas.rs:231`). `drained()` = all terminal
  (`schemas.rs:430`). `deps_met()` = every dep is `Done`, a missing dep counts as
  met (`schemas.rs:437`).
- **Counts are raw per-state today.** `Snapshot::count(state)` filters by exact
  state (`snapshot.rs:171`); `status` prints `"{queued} queued, … {total} total"`
  straight from those raw counts (`cli.rs:1277`). A `Queued` task with unmet deps
  or `approval_required` still counts as "queued" — this is the dishonesty
  AC-001 targets.
- **The true serial runnable predicate already exists but only inside the
  scheduler**: `select_next` runs a task iff `Queued && !(skip_if_approval_required
  && approval_required) && deps_met` (`run.rs:1153`). Nothing at the *count/label*
  layer reuses it. `parallel::ready_independent` is a stricter, parallel-only
  cousin (`Queued && !approval && !requires_validation && deps_met`,
  `parallel.rs:34`) and `assess_parallelism` already emits structured
  `SequentialReason`s (`parallel.rs:106`).
- **Capability grounding exists** in three agreeing spots: planner park at
  queue-creation (`Queued → Blocked`, `planner.rs:767`), a run-time backstop for a
  forced `--task` (`run.rs:151`), and the `status` split of cap-gated Blocked vs
  real Blocked (`cli.rs:1306`). Shared predicate:
  `routing::unsatisfiable_capabilities` (`routing.rs:279`).
- **The decision→artifact path largely works for NEW follow-ups**:
  `decision_question` ingests as `NeedsUser` with capabilities dropped and the
  question seeded as a conversation turn (`planner.rs:885`); `yardlet answer`
  runs `run_next` with `target=<id>`, which bypasses `select_next` and runs the
  task at any queue position (`cli.rs:935`, `run.rs:145`). Gaps: (i) a *stale*
  task carrying a fake `required_capabilities` is parked `Blocked`, never
  migrated (finding-19); (ii) reason for the pause is ad-hoc.
- **No structured transition-reason record.** Today the only "reason" is free
  text appended onto `Task.worker_rationale` — by defer (`schemas.rs:504`) and by
  capability-park (`planner.rs:787`). `finalize_on_latest_queue` flips state with
  **no** reason (`run.rs:1782`). AC-005 needs a real record.
- **No `yardlet tidy`/`wrap` command.** The pieces exist —
  `report::archive_intent` (preserves follow-ups + writes `final-report.md`,
  `report.rs:20`), `state::clear_intent_and_queue` (`state.rs:234`),
  `WorkQueue::defer_task`/`revive_task` — and the "new plan" path already
  archives+clears (`planner.rs:286`, `ui/mod.rs:1325`). Nothing composes them
  into one self-heal move.

---

## 1. Mechanism (1): the `runnable-now` predicate & where counts/labels change

### 1.1 Definition — one predicate, one home

Add a single canonical classifier in `schemas.rs` so counts, labels, the CLI,
and the TUI all agree (the same discipline `unsatisfiable_capabilities` already
enforces for capabilities). A task's **runnability** answers "can the auto-drain
advance this *right now* with no human input?" It is a function of the task *and*
the queue (deps) *and* the workspace (approval grants, worker capability vocab):

```rust
// schemas.rs — new
pub enum RunnableClass {
    Runnable,             // Queued, deps met, no approval pending, caps satisfiable
    WaitingDecision,      // NeedsUser (a decision/answer is owed)
    WaitingApproval,      // Queued + approval_required + not granted
    WaitingDependency,    // Queued + !deps_met
    WaitingCapability,    // Blocked by unsatisfiable required_capabilities
    Held,                 // Blocked (non-capability) | Failed | Partial
    SetAside,             // Deferred
    Running,              // Running
    Done,                 // Done
}
```

Because grant-checking (`approvals::is_granted`) and capability vocab
(`declared_capabilities`) live outside `schemas.rs`, the classifier takes them as
inputs rather than reaching for I/O:

```rust
// schemas.rs
impl WorkQueue {
    pub fn runnable_class(
        &self,
        task: &Task,
        approved: bool,                 // approvals::is_granted(ws, &task.id)
        cap_vocab: &BTreeSet<String>,   // routing::declared_capabilities(workers)
    ) -> RunnableClass { /* order: Running, Done, Deferred, then the waiting
        buckets in the same precedence select_next uses, then Runnable */ }
}
```

`RunnableClass::Runnable` MUST be exactly the set `select_next`/`ready_independent`
would pick (minus the parallel-only `requires_validation` carve-out, which is
still runnable *serially*). To guarantee that, `select_next` and
`ready_independent` are refactored to *consume* `runnable_class` (or a thin
`is_runnable_now` derived from it) so there is one source of truth and drift is
impossible (test AC-001-b).

Precedence when several conditions apply to one `Queued` task (deps unmet AND
approval pending): report the **most-blocking, least-human-first** reason, matching
`select_next`'s skip order — approval, then dependency. (A task is only `Runnable`
when *no* waiting bucket applies.)

### 1.2 What counts change, and where

Introduce a small typed rollup on `Snapshot` computed once from `runnable_class`:

```rust
// snapshot.rs — new, replaces ad-hoc per-state counts in the honest views
pub struct QueueHealth {
    pub runnable: usize,          // the honest "to-do now" number
    pub running: usize,
    pub waiting_decision: usize,
    pub waiting_approval: usize,
    pub waiting_dependency: usize,
    pub waiting_capability: usize,
    pub held: usize,              // blocked(non-cap)+failed+partial
    pub set_aside: usize,         // deferred
    pub done: usize,
    pub total: usize,
}
impl Snapshot { pub fn health(&self) -> QueueHealth { … } }
```

| Surface | File / line today | Change |
|---|---|---|
| `yardlet status` headline | `cli.rs:1277` | Lead with **`{runnable} ready to run`**, then a waiting breakdown: `{waiting_decision} awaiting you, {waiting_approval} need approval, {waiting_dependency} blocked on deps, {waiting_capability} need a worker/decision, {held} held, {set_aside} set aside, {done} done, {total} total`. The bare word "queued" is retired from the headline — it was the lie. |
| `status --json` `queue` block | `snapshot.rs:202` | Replace the raw per-state map with the `QueueHealth` fields (keep `total`). Add `runnable` as the primary integer. Back-compat: keep `done`/`running` keys; drop `queued` in favor of `runnable` + the `waiting_*` split (documented in CHANGELOG as a JSON-shape change). |
| `yardlet queue` list | `cli.rs:861` | Each row gains a right-aligned class tag from `runnable_class` (`ready` / `awaiting you` / `needs approval` / `blocked: deps` / `needs worker` / `held` / `set aside` / `done`). Sort already floats active work up (`sort_for_display`, `schemas.rs:597`). |
| Final report progress line | `report.rs:137` | The `unfinished:` list is recomputed as **non-terminal AND runnable-or-waiting**, and the "complete (held: …)" branch already exists (`report.rs:140`) — extend the held list to name *why* each is held (decision/approval/dep/capability) from `runnable_class`. |
| Parallel assessment | `parallel.rs:106` | `assess_parallelism` keeps its structured reasons but sources its "runnable" set from `runnable_class == Runnable` (minus validation carve-out) so it can never disagree with the headline count. |
| TUI Home queue counts | `ui/**` (renders `Snapshot`) | Bind the header/badges to `QueueHealth` instead of raw `count(state)`; a decision-waiting or dep-gated task shows in its own bucket, never under "to run". |

**Invariant (falsifiable):** `runnable + running + waiting_decision +
waiting_approval + waiting_dependency + waiting_capability + held + set_aside +
done == total`. Every task lands in exactly one bucket (test AC-001-a).

---

## 2. Mechanism (2): the transition-reason record

### 2.1 Shape

Every *system-driven* state change gets a structured, human-readable record.
Keep it a small typed struct (Core Principle 5: simple over clever), append-only,
written **only** through `src/state.rs` (Key Rule: `.agents/` writes go through
`state.rs`). This is the AC-005 slice of finding-9's audit log — *not* the full
Trust v2 metrics (explicitly out of scope), just the reason trail.

```rust
// schemas.rs — new
pub struct TransitionRecord {
    pub task_id: String,
    pub from: TaskState,
    pub to: TaskState,
    pub cause: TransitionCause, // typed enum, not free text
    pub detail: String,         // one human sentence, e.g. "no worker declares [video]"
    pub actor: Actor,           // System | User | Worker(run_id)
    pub ts: String,             // RFC3339
}
pub enum TransitionCause {
    RunOutcome,        // worker finished: evaluator set Done/Partial/Failed/NeedsUser
    CapabilityPark,    // Queued->Blocked, unsatisfiable required_capabilities
    StaleMigration,    // fake-cap gate -> NeedsUser (finding-19, §3)
    Defer,             // user set aside
    Revive,            // user brought back
    TidyDefer,         // tidy set aside an un-runnable task
    Wrap,              // intent archived/cleared
    DecisionSeed,      // decision_question ingested as NeedsUser
    Recover,           // abandoned-run salvage
}
pub enum Actor { System, User, Worker(String) }
```

### 2.2 Storage

`.agents/transitions/<task_id>.log.yaml` — append-only per task (mirrors the
per-task `conversations/<task_id>.yaml` convention, `state.rs:113`). Rationale:
per-task keeps files small, is trivially greppable, survives queue archival
alongside the task, and needs no global lock (each writer touches one file). One
new writer in `state.rs`:

```rust
// state.rs — the ONLY entry point (Key Rule)
pub fn append_transition(ws: &Workspace, rec: TransitionRecord) -> Result<()>;
```

`Task.worker_rationale` stays as the *last-reason* convenience string shown inline
(defer/park already write it), but the durable, ordered trail is the transition
log. `worker_rationale`'s current writers (`schemas.rs:504`, `planner.rs:787`)
additionally call `append_transition`.

### 2.3 Recording points (every system transition writes exactly one record)

| Transition | Site today | Record with cause |
|---|---|---|
| worker run result → Done/Partial/Failed/NeedsUser | `finalize_on_latest_queue` (`run.rs:1782`) sets `t.state = state` | `RunOutcome`, `actor = Worker(run_id)`, detail from evaluator |
| Queued → Blocked (capability) | `planner.rs:786`, backstop `run.rs:161` | `CapabilityPark`, detail = the unsatisfiable list |
| stale fake-cap gate → NeedsUser | §3 migration | `StaleMigration` |
| defer / revive | `schemas.rs:defer_task/revive_task` | `Defer` / `Revive`, `actor = User` |
| tidy actions | §4 | `TidyDefer` / `Wrap` |
| decision_question ingest → NeedsUser | `planner.rs:890` | `DecisionSeed` |
| recover salvage | existing `yardlet recover` | `Recover` |

To make this uniform and un-bypassable, route state writes through a helper
`finalize_on_latest_queue(..., cause: TransitionCause, detail)` that both saves the
queue and appends the transition — so a future state change can't silently skip
the record.

### 2.4 Surfacing

- `yardlet status`: for any held/waiting/set-aside task, print the **last**
  transition's `detail` inline (so "why is this here?" needs no second command).
- `yardlet handoff` / final report: include the ordered transition trail per task.
- `status --json`: add `last_transition` to each task line.
- TUI: the selected-task detail pane shows the last reason (ties to finding-14
  "opaque causation").

---

## 3. Mechanism (3): stale gate / `required_capabilities` detection & migration

### 3.1 The finding-19 case (confirmed live)

A dogfooded workspace's decision task requires `user_creative_direction_approval`;
the only worker vocab is `{image_generation}`. `reconcile_queue_capabilities` parks it `Blocked`
(`planner.rs:786`); reviving it and re-running hits the run-time backstop
(`run.rs:161`) and re-parks `Blocked`. Dead end: it is *really* a human decision
(the modern path would make it `NeedsUser` with a `decision_question`), but it was
authored under the pre-2026-07-01 "fake capability" convention and never migrated.

### 3.2 Classifier: decision-shaped vs tool-shaped capability

We cannot enumerate every capability string, so the rule is **structural**, same
philosophy as `reconcile_queue_capabilities` (`planner.rs:762`). A `Blocked` task
whose `required_capabilities` are unsatisfiable is classified:

```rust
// routing.rs — new, pure + unit-tested
pub enum GateShape { Decision, ToolGap }
pub fn classify_stale_gate(caps_unsatisfiable: &[String]) -> GateShape;
```

**Decision-shaped** (→ migrate, §3.3) when the capability name reads like a human
sign-off rather than a machine affordance. Heuristic, tunable, and *conservative*
(unsure ⇒ ToolGap ⇒ surface, never silently rewrite):
- contains a decision/approval token: `approval`, `approve`, `sign_off`,
  `signoff`, `decision`, `direction`, `review_approval`, `creative`, `product`,
  `choice`, `confirm`, `okay`/`ok`, `go_ahead`; **and**
- is not a known tool/asset affordance token: `generation`, `search`, `browse`,
  `image`, `video`, `audio`, `execute`, `deploy`, `render`, `vision`, `web`.

**Tool-shaped** otherwise (`image_generation`, `video`, `web_search`, …) → a
genuine worker/tool/license gap → **surface** for one-action cleanup, do NOT
invent a decision.

> `user_creative_direction_approval` → matches `approval`+`creative`+`direction`,
> no tool token ⇒ `Decision` ⇒ migrates. Falsifiable (test AC-003-a).

The token lists live next to `norm_cap` in `routing.rs` so both the planner and
the migration path share one vocabulary, and adding a token needs no schema change.

### 3.3 Migration rule (Decision-shaped)

When a `Decision`-shaped stale gate is *encountered* — on revive, on a forced
`--task` run, and during `tidy` (§4) — auto-migrate to the modern path instead of
re-Blocking:

1. `state = NeedsUser`; **clear** `required_capabilities` (they were the fake
   gate). Same shape the follow-up ingest already produces (`planner.rs:903`).
2. Seed a decision turn into `conversations/<id>.yaml`: reuse `worker_rationale`
   or a default "This task needs your decision: {title}. Reply with `yardlet
   answer`." via `append_conversation_turn` (`state.rs:670`).
3. `append_transition(StaleMigration, "migrated legacy capability gate
   [{caps}] to a decision (answerable with `yardlet answer`)")`.
4. Now the existing decision→artifact path (`answer` → `run_next(target)`) carries
   it to output at any queue position — AC-002/AC-003 close together.

**Where the migration is triggered (no re-Block):**

| Path | Today | Change |
|---|---|---|
| `WorkQueue::revive_task` | `schemas.rs:519` restores to `Queued` | after restore, run `migrate_stale_gates` on the revived set; a Decision-shaped one lands `NeedsUser`, not `Queued`→(re-park). |
| forced `--task` backstop | `run.rs:151` re-parks `Blocked` | classify first; if `Decision`, migrate to `NeedsUser` and return a "answer it" report instead of a Blocked report. |
| capability park at plan time | `planner.rs:786` | for a *Decision*-shaped required cap, park as `NeedsUser` (seeded) rather than `Blocked`, so new decision-vocab gates never enter the Blocked trap in the first place. Tool-shaped stays `Blocked`. |

### 3.4 Surface rule (Tool-shaped)

A `ToolGap`-shaped unsatisfiable gate is a real "no worker can do this yet." It
STAYS `Blocked` until cleanup, and is surfaced honestly (already partly done at
`cli.rs:1341` "awaiting you (no worker can do these yet)"). `tidy` (§4) does not
strip or rewrite the capability gate. It moves the task to `Deferred` with the
missing capability preserved and records `TidyDefer`, so the task is out of the
runnable count but can be revived later.

---

## 4. Mechanism (4): one-action `tidy` (wrap / defer / migrate) semantics

### 4.1 The command

`yardlet tidy` (CLI) + a TUI key on Home. There are currently no `--dry-run` or
`--yes` flags. The command composes the existing primitives into **one move**
that returns the workspace to a clean baseline. It is the inverse of "the human
hand-defers/revives to keep dogfooding usable" (the motivating chore).

`tidy` performs, in order, only safe and reversible actions:

| Step | Action | Auto? | Reversible via |
|---|---|---|---|
| **wrap** | If the queue is `drained()` (`schemas.rs:430`) and an intent is live, `archive_intent` + `clear_intent_and_queue`. | **auto** (safe: archive is a copy, not a delete) | the archived `.agents/intents/<id>/` (git-tracked record) + `promote_follow_up` |
| **defer** | Set aside every task that is *stuck with no runnable path*: `Held` (non-cap Blocked / Failed / Partial) with no retry pending, and `WaitingCapability` ToolGap gates. ToolGap capabilities are preserved. `Deferred`, not deleted. | **auto** (safe: `Deferred` is reversible by `revive`) | `yardlet revive <id>` (`schemas.rs:519`) |
| **migrate** | Decision-shaped stale gates → `NeedsUser` (§3.3). | **auto** (safe: adds a resolvable question, removes a dead end) | `defer`, or answering |

Boundary rule (resolves intent open-question #1/#3): **safe, reversible, additive**
moves (wrap-when-drained, defer-the-stuck, migrate-the-decision) run automatically
— including at the start of a new plan, generalizing the existing "new plan
archives previous" behavior (`planner.rs:286`). There is no strip path in the
current implementation: `ToolGap` cleanup is modeled as `Deferred` with the gate
still present. Nothing is ever hard-deleted: defer and archive are the strongest
auto moves, and both are recoverable.

### 4.2 Auto vs explicit — the exact line

- **Automatic (no prompt), on `yardlet tidy` AND on new-plan start:**
  wrap a drained intent, defer un-runnable `Held`/ToolGap tasks, migrate
  decision-shaped stale gates. Each writes a `Tidy*`/`Wrap`/`StaleMigration`
  transition record (§2). Rationale: every one of these is reversible and none
  destroys user output or a `Done` task.
- There is no explicit strip tier and no dry-run tier yet. If a future release
  adds `--dry-run` or `--yes`, the code and tests should introduce a matching
  transition cause at that time rather than keeping an unused enum variant.

### 4.3 Safety invariants (AC-006, enforced + tested)

1. `tidy` NEVER touches a `Done` task and NEVER deletes a run artifact / user
   deliverable. It only changes `Queued/Blocked/Failed/Partial/NeedsUser` task
   *states* and archives (copies) intent records. (test AC-006-a)
2. Every `tidy` mutation is reversible: `Deferred → revive`, archived intent →
   `promote_follow_up`. No `std::fs::remove_*` of deliverables. (test AC-006-b)
3. All `.agents/` writes go through `state.rs` (`save_queue`, `append_transition`,
   `archive_intent`, `clear_intent_and_queue`). `tidy` adds no new write path
   outside `state.rs`. (test AC-006-c — grep/architecture assertion)
4. `cargo test` stays green (existing 130+ tests unaffected; new tests added).

### 4.4 Idempotence

`tidy` is idempotent: running it twice with no intervening work is a no-op that
records no new transitions (a drained-and-cleared workspace has nothing to wrap;
already-deferred stuck tasks are skipped). Mirrors
`reconcile_queue_capabilities`'s idempotence (`planner.rs:765`). (test AC-004-b)

---

## 5. Decision → artifact path (AC-002), consolidated

Most of this already works; the spec makes it whole:

- **Surface:** a human decision reaches the queue as `NeedsUser` with a seeded
  question — via `decision_question` on a follow-up (`planner.rs:885`), via
  stale-gate migration (§3.3), or via a `Decision`-shaped plan-time park (§3.3).
- **Answerable at any position:** `yardlet answer [--task <id>] "<reply>"` →
  `run_next(target=<id>, answer=…)` bypasses `select_next` and runs the task
  regardless of queue order (`cli.rs:935`, `run.rs:145`). A TUI answer key does
  the same (finding-17 surfacing).
- **No dead-end:** the fake-`required_capabilities`→`Blocked` trap is removed by
  §3 (decision-shaped caps never park `Blocked`; existing ones migrate on
  contact). AC-002's "decided but the system can't act" state cannot occur for a
  decision-shaped gate.
- **Honesty tie-in:** a `NeedsUser` task counts as `WaitingDecision`, not
  `Runnable` (§1), so it never inflates "ready to run."

---

## 6. Files touched by YARD-002 (implementation map)

| File | Change |
|---|---|
| `schemas.rs` | `RunnableClass`, `WorkQueue::runnable_class`, `TransitionRecord`/`TransitionCause`/`Actor`; defer/revive also emit transitions. |
| `routing.rs` | `GateShape` + `classify_stale_gate` + shared decision/tool token lists next to `norm_cap`. |
| `state.rs` | `append_transition`, `transition_path`; route state writes through a reason-carrying finalize; `tidy` helpers compose archive/clear/defer. |
| `snapshot.rs` | `QueueHealth` + `Snapshot::health()`; `to_json` queue block reshaped. |
| `run.rs` | `finalize_on_latest_queue` carries a `TransitionCause`; `--task` backstop classifies+migrates; `select_next` consumes `runnable_class`. |
| `parallel.rs` | `ready_independent`/`assess_parallelism` source "runnable" from `runnable_class`. |
| `planner.rs` (read-only for logic re-use; **park classification** is the only edit, allowed by scope: "stale 상태의 이관·표면화만") | Decision-shaped caps park `NeedsUser`, not `Blocked`. |
| `cli.rs` | `status` headline + breakdown; `queue` row tags; new `tidy` command; `revive` triggers migration. |
| `report.rs` | progress line reasons; tidy's `wrap` reuse. |
| `ui/**` | Home counts from `QueueHealth`; class tags; defer/revive/answer/tidy keys; selected-task last-reason pane. |
| `CHANGELOG.md` | Unreleased entry (JSON shape change for `status --json`). |

Planner note: intent scope permits only *migration/surfacing of already-created
stale state*, not new planning logic. The single planner edit (park classification)
is migration-of-a-gate, not re-planning — it changes only how an off-vocab
capability is *parked*, reusing existing `reconcile_queue_capabilities`.

---

## 7. Falsifiable tests, 1:1 with AC-001..AC-006

Intent acceptance ids (`intent-contract.yaml:42`): AC-001 honest counts, AC-002
decision→artifact, AC-003 stale gates don't re-Block, AC-004 one-action tidy,
AC-005 transition reasons, AC-006 regression/safety.

**AC-001 — honest queue counts**
- `AC-001-a runnable_class_partitions_every_task`: a queue mixing every state +
  a dep-gated + an approval-gated + a cap-gated task → the eight `QueueHealth`
  buckets sum to `total`, each task in exactly one bucket.
- `AC-001-b runnable_matches_scheduler`: for a random-ish queue,
  `{t : runnable_class(t)==Runnable}` == `{t : select_next-eligible}` (serial),
  proving the count can't drift from what actually runs.
- `AC-001-c status_headline_excludes_waiting`: a queue with 1 truly-Queued +
  1 dep-gated + 1 NeedsUser + 1 approval-gated reports `runnable == 1`, not 4.
  (was the lie.)

**AC-002 — a decision reaches an artifact**
- `AC-002-a decision_follow_up_needs_user_not_blocked`: ingesting a follow-up
  with `decision_question` yields `NeedsUser`, empty `required_capabilities`, a
  seeded conversation turn (guards `planner.rs:885`).
- `AC-002-b answer_runs_task_at_any_position`: a `NeedsUser` task sitting *behind*
  queued work is run by `run_next(target=id)` without `select_next` picking it —
  i.e. queue position is irrelevant.
- `AC-002-c no_fake_capability_dead_end`: a decision-shaped required capability
  never lands `Blocked` (plan-time park routes it to `NeedsUser`).

**AC-003 — stale state doesn't re-Block**
- `AC-003-a classify_stale_gate_finding19`:
  `classify_stale_gate(["user_creative_direction_approval"]) == Decision`; a
  tool-shaped `["video"]` / `["image_generation"]` == `ToolGap`.
- `AC-003-b revive_migrates_decision_gate`: a `Blocked` task carrying the fake
  cap, revived, becomes `NeedsUser` (migrated) — not `Queued`-then-re-`Blocked`.
- `AC-003-c forced_task_migrates_not_reparks`: `run_next(target)` on the same
  stale task returns an "answer it" outcome, not a `Blocked` report
  (guards the `run.rs:161` re-park regression).
- `AC-003-d tool_gap_stays_blocked_and_surfaced`: a real `image_generation` gap
  with no worker stays `Blocked` and appears under "awaiting you (no worker)".

**AC-004 — one-action tidy**
- `AC-004-a tidy_wraps_drained_defers_stuck_migrates_decision`: on a workspace
  with a drained-except-held queue, one `tidy` archives+clears the intent, defers
  the `Held`/ToolGap tasks, migrates the decision gate — in a single call.
- `AC-004-b tidy_idempotent`: a second `tidy` with no work between is a no-op
  (no new transitions, no state changes).
- `AC-004-c tidy_defers_tool_gap_without_stripping`: `tidy` moves a ToolGap task
  to `Deferred`, preserves its `required_capabilities`, and records `TidyDefer`.

**AC-005 — every transition carries a reason**
- `AC-005-a defer_records_transition`: `defer_task` appends a `TransitionRecord`
  with `cause=Defer, actor=User, from, to=Deferred, detail`.
- `AC-005-b capability_park_records_reason`: plan-time park writes
  `cause=CapabilityPark` with the unsatisfiable list in `detail`.
- `AC-005-c run_outcome_records_reason`: a finalize to Done/Partial/NeedsUser
  writes `cause=RunOutcome, actor=Worker(run_id)`.
- `AC-005-d status_shows_last_reason`: `status` prints the last transition detail
  for a held/waiting task (no second command needed).
- `AC-005-e transitions_written_only_via_state_rs`: the append path is the sole
  writer (architecture/grep test), upholding the `.agents/`-through-`state.rs`
  rule.

**AC-006 — regression & safety**
- `AC-006-a tidy_never_touches_done_or_deliverables`: a `Done` task and its run
  artifacts are unchanged after `tidy`; no deliverable file is deleted.
- `AC-006-b every_tidy_move_reversible`: after `tidy`, deferred tasks
  `revive` back to `Queued`; archived intent is present under
  `.agents/intents/<id>/` and `promote_follow_up`-able.
- `AC-006-c no_agents_write_outside_state_rs`: grep assertion that new code adds
  no `std::fs::write`/`remove` to `.agents/` outside `state.rs`.
- `AC-006-d cargo_test_green`: the full existing suite still passes with the new
  code (the whole-suite gate).

---

## 8. Open questions carried to the user (non-blocking for this design)

Answered here with defaults (from the intent's own `open_questions`,
`intent-contract.yaml:51`); flagged for confirmation, not blocking YARD-002:

1. **Auto-tidy at new-plan start?** Default: *yes* for the safe/reversible tier
   (wrap+defer+migrate), generalizing today's new-plan archive. (§4.2)
2. **Migrate old decision gates automatically?** Default: *yes when
   decision-shaped* (conservative classifier), *surface only when tool-shaped*.
   (§3.2–3.4)
3. **`status --json` shape change** (drop `queued`, add `runnable` +
   `waiting_*`): acceptable? This is the one backward-incompatible surface; called
   out in CHANGELOG. If a consumer depends on `queued`, we can keep it as an alias
   for `runnable + waiting_*` for one release.
