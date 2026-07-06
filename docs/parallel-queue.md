# Parallel Queue — Design

> Status: implemented (all three phases).

## Why this exists, and what it is NOT

Worker CLIs (Claude Code, Codex) keep getting better at spawning subagents and
orchestrating workflows *inside one session*. Yardlet must not compete with that.
The queue earns its place only where in-session orchestration structurally
cannot go:

| | Worker subagents (in-session) | Yardlet queue tasks |
|---|---|---|
| Lifetime | dies with the session | survives crashes, restarts, days |
| Worker | locked to one vendor session | routable/retryable across Codex ↔ Claude |
| Gates | LLM-driven control flow | deterministic code: approvals, needs_user, evaluator |
| Record | evaporates with context | system-of-record in `.agents/` |

**The rule:** if a unit of work must survive the session, be human-gated, be
re-routed to another worker, or be audited — it is a queue task. If it is a
tactic inside one bounded run — it belongs to the worker's own subagents, and
Yardlet explicitly allows that (the execution packet says so; the task contract
and danger boundaries bind the whole agent tree).

This sets the planner's granularity rule: **cut tasks coarse, along scope
boundaries.** Tasks that would need to share context to run in parallel should
have been one task. A good split is one where tasks could run in any order —
which is exactly what makes queue-level parallelism safe.

## Layer model

Two layers of parallelism that do not overlap:

- **Task level (Yardlet):** independent tasks (disjoint `allowed_scope`, no
  `depends_on` edges) may run concurrently, each in its own git worktree,
  possibly on different workers.
- **Inside a task (worker):** the worker parallelizes freely with its own
  subagents within the task's scope and sandbox.

## Phase 1 — dependency model (implemented)

- `Task.depends_on: Vec<String>` — ids that must be `Done` first. Empty =
  independent.
- Planner contract: `depends_on` only for tasks whose *output* is genuinely
  needed ("order alone is not a dependency"). Yardlet sanitizes the plan: a task
  may only depend on tasks planned before it (drops self-references, forward
  references, unknown ids, and therefore cycles).
- `select_next` skips tasks with unmet dependencies. A dependency id that no
  longer exists in the queue counts as met, so a typo cannot deadlock a queue.
- Execution stays sequential in this phase.

## Phase 2 — parallel worktree execution

Three invariants keep this simple:

1. **Workers run in parallel; queue state has a single writer.** Only the Yardlet
   orchestrating loop writes `work-queue.yaml` (one process, one thread doing
   state writes). Worker results land in their own run dirs, which are
   per-run-id and conflict-free.
2. **Each parallel task gets its own git worktree** on branch
   `yard/<task-id>`, so workers never see each other's uncommitted edits.
3. **Integration is sequential.** After a worker finishes and its evaluation
   passes, Yardlet merges `yard/<task-id>` back one at a time. A merge conflict
   does not get auto-resolved: the task drops to `Partial` with the conflict
   recorded in the handoff, and its worktree is kept for inspection.

Fallbacks: not a git repo, dirty tracked tree, or a parallelism of 1 → run
sequentially exactly as today.

Implementation notes (src/parallel.rs):

- Off by default: `max_parallel: 1` in `.agents/yardlet.yaml`; opt in by raising
  it or passing `yardlet run --auto --parallel N`.
- Worktrees live at `.agents/worktrees/<task-id>`, kept out of `git status`
  via the repo-local `.git/info/exclude` (the user's .gitignore is never
  touched).
- Run artifacts stay in the main workspace: the run dir is passed to the
  worker as an absolute path plus an extra writable root, while the worker's
  cwd is its worktree. The two contract files (intent, queue) are copied into
  the worktree so the packet's read anchors resolve.
- Resultless worker failover matches the serial path's bounded retry semantics:
  if a parallel task finishes without `result.json`, Yardlet resolves one
  alternate ready worker through the same routing/capability/readiness gates,
  reruns that task once in the same worktree and run dir, records
  `failover.json`, then finalizes the alternate worker's output. If no
  alternate is invocable or the alternate also leaves no result, finalization
  proceeds through the normal evaluator failure path with no further retry.
  Parallel batches do not attempt same-worker session resume first; fan-out runs
  are fresh contexts by design, so the shared guarantee here is the one-shot
  alternate-worker failover, not hot-session continuation.
- Integration commits as `yard <yard@localhost>`, excluding `.agents/` from
  the worker's staged changes; merges are `--no-ff` in completion order; a
  conflict aborts cleanly, drops the task to Partial, appends the conflict to
  the handoff, and keeps the worktree for manual integration.

## Phase 3 — TUI + recovery (implemented)

- Run Monitor: with several tasks running, a tab row lists them; Tab/←→
  switches which run's live output is followed.
- Settings exposes `max_parallel` ("Parallel tasks", Space cycles 1–4).
- Orphan recovery is worktree-aware: a finished orphaned worktree run is
  merged back on recovery (conflict → Partial, worktree kept), and an
  unfinished one is requeued with its abandoned worktree removed.
