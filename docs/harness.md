# Shared Worker Harness & Learning Loop — Design

> Status: H1 implemented (+A1 discovery of existing repo assets), H2 implemented
> (partial continuation), H3 implemented (workspace hooks), H4 implemented
> (learning loop: skill auto-learn + S4 score/prune, rule auto-learn, `yard
> harness review`). Remaining within H4: deterministic-observation candidate
> mining (failure themes → candidates). H5 deferred.
> Companion docs: [parallel-queue.md](parallel-queue.md),
> [routing-and-telemetry.md](routing-and-telemetry.md).

## Problem

Yard drives interchangeable workers (Codex, Claude Code, any CLI via the
generic adapter), but the *harness* around them — repo rules, reusable
procedures, deterministic guards, accumulated lessons — barely exists and is
not shared:

- `.agents/rules/` is only read by Claude Code, by accident (via CLAUDE.md);
  Codex and custom workers never see it.
- There is no skill library, no catalog, no per-task skill loading.
- Deterministic guards exist only as built-ins (billing env scrub, packet
  danger list, evaluator forbidden paths); a workspace cannot add its own.
- Nothing learned in one run ever improves the next run. The handoffs and
  evaluations pile up as history, not as harness.

This absorbs the remaining patterns the spec calls for (§13.2 Hermes skill
lifecycle, §13.4 oh-my/OMC hooks and permission matrix), in Yard's shape.

## Principles (inherited, non-negotiable)

1. **The packet is the only shared injection point.** Anything that must
   reach *every* adapter-connected worker goes through the compiled packet
   (inline or as a read anchor) — never through a CLI-specific mechanism
   like `.claude/skills/`. One harness, all workers.
2. **Policy vs mechanism.** Mechanisms collect and suggest on every cycle;
   only a human promotes a suggestion into the harness. Same discipline as
   routing/telemetry: lessons never enter packets without explicit
   promotion.
3. **`.agents/` stays canonical.** All harness assets live under `.agents/`
   in the workspace; Yard writes promoted assets through `src/state.rs`.
4. **Token economy.** Inline only what is small and always relevant; anchor
   the rest and let the worker read on demand (progressive loading).

## Asset model

```
.agents/
  rules/        always-on constraints, small .md files   → inlined in every packet
  skills/<name>/SKILL.md   reusable procedures           → catalog line in packet;
                (frontmatter: name, description)            body read on demand
  agents/<role>.md   role extensions (exists today)      → appended to that role's packets
  hooks/
    pre-run.d/*       executable guards, run BEFORE spawn  (non-zero exit = abort run)
    post-run.d/*      executable checks, run at evaluation (non-zero exit = fail check)
  telemetry/harness.jsonl   suggestion candidates (mechanism-owned)
```

## Phase H1 — shared injection (rules + skill catalog) — implemented

Execution packets gain two sections, compiled identically for every worker:

- **Workspace rules**: the concatenated contents of `.agents/rules/*.md`,
  inlined, capped at ~4 KB total (over the cap: inline the newest, anchor
  the rest with a note). Rules are constraints, so they must not depend on
  the worker choosing to read them.
- **Skills**: one catalog line per skill (`name — description` from SKILL.md
  frontmatter) plus the instruction *"read `.agents/skills/<name>/SKILL.md`
  before work it applies to"*. Bodies are never inlined (progressive
  loading). The planner may set `task.skills: [name]` to mark a skill as
  required for a task; required skills become explicit read anchors.

Planning packets get the same rules section (planning must respect repo
rules too) and the catalog, so the planner can assign `task.skills`.

## Phase H2 — Partial handling (continuation, not redo)

`Partial` today halts the auto-drain and waits for a human. That wastes the
work already done. Partial has three distinct causes and gets three
behaviors:

| cause | behavior |
|---|---|
| worker self-reported incomplete (`status: partial`) | **auto-continue**: next run of the task is a *continuation packet* — it injects the previous run's `checkpoint.md`, the worker's `compact_summary`, and the unmet acceptance criteria, with the instruction "continue from this checkpoint; do not redo finished work". Bounded by the existing per-drain attempts cap (2), then halt to NeedsUser. |
| parallel merge conflict | human-gated, unchanged: worktree kept, conflict in the handoff. (A future option is a dedicated "integrate" task; not in this phase.) |
| recovery/integration error | same as merge conflict — surfaced, human decides. |

Mechanically: `run_next` gains continuation inputs (like the existing
answer-resume path) sourced from the latest Partial run of the task;
`run_auto` routes Partial retries through it instead of halting on first
sight. A `partial_reason` recorded at evaluation time distinguishes
self-reported from conflict so the drain knows which to auto-continue.

## Phase H3 — hooks (workspace-owned deterministic guards) — implemented

- `pre-run.d/*`: executed by Yard before spawning a worker, in the
  workspace root, with `YARD_TASK_ID`, `YARD_RUN_DIR`, `YARD_WORKER` env.
  Non-zero exit aborts the run with the hook's reason in the report — the
  task fails (drain stops on it; fix the cause and re-run) instead of
  spawning a worker (e.g. detect-secrets, lint gates, "don't run while CI is
  red").
- `post-run.d/*`: executed during evaluation with the same env. Non-zero
  exit folds a failed fatal check into the evaluation (the task cannot be
  Done past it).
- Hooks are the workspace's own code; Yard never ships enabled hooks, only a
  documented `.agents/hooks/README.md` (+ empty `pre-run.d`/`post-run.d`).
  Only executable files run, in sorted filename order. A 30s wall-clock
  timeout (longer = killed + failed) and captured stdout/stderr go to
  `<run_dir>/hooks/<phase>/`. `hooks: false` in yard.yaml turns them off.

This gives internal-tool's `hooks/` a home where they bind *all* workers, not
just one CLI. Implementation: `src/hooks.rs`, wired into `src/run.rs`.

## Phase H4 — the learning loop (every cycle strengthens the harness) — implemented

Lifecycle (spec §13.2): observation → candidate → review → promotion →
deprecation.

> Implemented: a run's `harness_suggestions` of kind "skill" auto-record as
> `.agents/skills/<slug>/SKILL.md` (S3) and of kind "rule" as
> `.agents/rules/learned-<slug>.md` (`src/skills.rs`
> `record_run_suggestions`/`record_run_rules`, gated by `auto_skill`/
> `auto_rule`). Learned skills are scored and auto-pruned (S4); learned rules
> are always-on (no per-task attribution to score) so they are kept until
> removed — reversible via git, visible via `yard harness review`. Still TODO
> within H4: deterministic-observation candidate mining (turning repeated
> validation failures / NeedsUser themes into candidates).

**Observe (mechanism, every run, no extra tokens).**
- The result contract gains an optional field:
  `harness_suggestions: [{kind: "rule"|"skill", title, content}]`. The
  execution packet instructs the worker: *"if you learned something
  reusable about this repo (a convention, a pitfall, a procedure), propose
  it here — short and imperative."* The worker that just did the work is the
  cheapest possible observer.
- Yard adds deterministic observations from the evaluation itself: repeated
  validation failures, drift notes, forbidden-path attempts, merge
  conflicts, NeedsUser questions — each becomes a candidate with its
  evidence run id.

**Collect + apply (mechanism, auto by default).** Candidates append to
`.agents/telemetry/harness.jsonl`, deduplicated by normalized title, and
Yard writes them automatically as `.agents/rules/learned-<slug>.md` or
`.agents/skills/<slug>/SKILL.md` through `state.rs` (the worker proposed; the
deterministic core writes — I1/I3). From the next packet on, every worker
shares the asset. What keeps this from poisoning itself is **not** a human
gate but the eval feedback loop (skill/rule scores) plus reversibility (git):
an asset that doesn't earn its place is auto-pruned.

**Self-correct (eval, the safety mechanism).** Each learned asset carries a
`source: learned` marker and accrues a score from the runs that used it
(review-task pass-through, first-try Done, retry tax — see docs/skills.md).
A learned asset that scores poorly across N intents is auto-deprecated
(unequipped, kept in git). The H1 inline cap bounds packet growth.

**Human override (always available, never required).** `yard harness review`
shows pending candidates, scores, and what was auto-applied/pruned; a human
can promote, reject, or restore. With `auto_skill: false` / `auto_prune:
false`, apply and prune become review actions instead of automatic — the
opt-out for cautious workspaces (I4: minimize intervention, don't mandate it).

## Phase H5 (deferred) — central core & presets

internal-tool's remaining role: one shared library wired into many repos
(`init-tool`, presets, catalog.tsv). Yard equivalent would be
`yard init --core <path>` symlinking shared rules/skills into `.agents/`.
Deferred until H1–H4 prove the in-repo loop; a central core multiplies
whatever the loop produces, including its mistakes.

## Order & sizing

| phase | size | depends on |
|---|---|---|
| H1 rules+skills injection | S | — |
| H2 partial continuation | M | — (independent) |
| H3 hooks | M | — |
| H4 learning loop | L | H1 (promotion target), result schema change |
| H5 central core | L | H1–H4 proven |

H1 and H2 first (H2 fixes a real daily pain; H1 is the foundation H4 needs).

## Open questions (do not block H1/H2)

- Should `task.skills` be planner-assigned only, or user-editable in the TUI
  task view? (start: planner-assigned, hand-edit the yaml if needed)
- Suggestion spam control: per-run cap (start: 3) and a minimum-evidence
  threshold for deterministic candidates (start: 2 occurrences).
- Whether promoted skills should auto-attach to matching task kinds (start:
  no — catalog + planner assignment only).
