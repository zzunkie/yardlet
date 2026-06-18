# Worker Routing + Telemetry Loop — Design

> Status: implemented (all four phases)
> Decides: which worker (Codex CLI / Claude Code CLI) runs each task, and how
> that decision stays correct as models, costs, and task mixes change.

## Problem

Yardlet routes work between two subscription-backed CLIs. The "right" worker
varies three ways, so any fixed rule rots:

- by **task** (a tight diff edit vs a multi-file refactor want different engines),
- over **time** (relative strength flips as the CLIs/models evolve),
- by **cost** (the user's tolerance for the pricier engine).

Today's gaps: the planner gets no guidance so it picks one worker for
everything; `routing.implementation` is dead config; there is no run-time
readiness fallback.

## Principles (from a survey of modern routers)

1. **Two-layer binding.** Plan-time picks the *intended* worker per task
   (capability/role). Run-time validates readiness and falls back. This is the
   production consensus (OpenRouter, Claude Code, LiteLLM).
2. **No learned router.** With two workers there is nothing to train. The
   planner LLM *is* the router; it only needs a rubric.
3. **Policy in config, mechanism in code.** Which worker suits which task and
   the cost dial are policy (editable; the planner reads them). Readiness
   checks, the fallback walk, telemetry, and the execution gate are mechanism
   (code).
4. **Express guidance in model-independent terms.** Route on task
   characteristics + a cost dial, never on "Claude > Codex" constants, so the
   rubric survives model changes.
5. **Hard capability rules beat rubric preferences.** If one worker has a
   concrete capability the other lacks, make that a deterministic mechanism,
   not a planner preference. Current rule: image/asset generation routes to
   Codex; if Codex is not ready, do not fall back to Claude Code.
6. **Telemetry never binds at run-time.** Run-time stays deterministic and
   auditable. Telemetry only produces *suggestions* to update the policy, which
   a human approves.

## What rots, and who maintains it

Not everything rots at the same rate — split it:

| Fact | Maintained by | Cadence |
| --- | --- | --- |
| Concrete model version a CLI uses | the CLI itself | automatic; Yardlet never tracks it |
| Relative strength per task type | **Yardlet telemetry → human-approved suggestion** | occasional |
| `cost_bias` (cheap vs quality) | the human (a preference) | rarely; never automated |

Only the middle row needs a loop.

## Policy surface: worker profiles (editable config)

Extend `.agents/workers.yaml` (the worker SOT). New, human-editable fields:

```yaml
workers:
  - id: codex
    # ...existing invocation/limits...
    best_for: "image/asset generation, issue-to-patch implementation, test-driven bugfixes, shell-heavy build/test/debug loops, visual UI implementation, mechanical transforms, schema/format constrained output"
    cost_weight: low
  - id: claude-code
    # ...existing...
    best_for: "ambiguity reduction, acceptance criteria, PRDs/strategy briefs, evidence synthesis, long-form writing/editing, broad exploration, architecture planning, policy-bound reasoning"
    cost_weight: high

routing:
  cost_bias: balanced          # cheap | balanced | quality   (human dial)
  default_worker: codex
  fallback_order: [codex, claude-code]
  planning_gate: { primary: claude-code, fallback: codex }
```

`best_for` is written as task characteristics, not model names. Updating it when
trends shift is a one-line edit — no code change, no retrain.

## Layer 1 — Plan-time selection (guided planner)

The planning packet gains a **Worker selection** section listing each worker's
`best_for` + the current `cost_bias`, instructing the planner: for each task,
emit `preferred_worker` *and* a one-line `worker_rationale`, weighing the task's
characteristics against `best_for` and the cost dial.

`planning-result.json` task shape gains:

```json
{ "preferred_worker": "codex", "worker_rationale": "tight single-file edit; cheap worker per profile" }
```

Yardlet stores `preferred_worker` on the task (already does) and keeps
`worker_rationale` for the audit log. This fixes the "picks codex for
everything" bug: the judge now has a rubric and its choice is explainable.

## Layer 2 — Run-time resolution (deterministic, code)

```
resolve_worker(task, routing) -> (worker_id, reason):
  candidate = run_override ?? hard_capability_rule ?? task.preferred_worker ?? routing.default_worker
  if probe(candidate).ready:        return (candidate, "preferred")
  if hard_capability_rule:          error "required worker not ready"
  for w in routing.fallback_order:
      if w != candidate and probe(w).ready:
          return (w, "fallback: {candidate} not ready")
  error "no ready worker"           # surfaced as a hard stop / NeedsUser
```

Run-time does **not** consult telemetry (keeps it predictable). The chosen
worker + reason + the planner's rationale are recorded on the run.

## The telemetry loop

### Collect (mechanism)

On every completed run, append one line to `.agents/telemetry/runs.jsonl`
(append-only):

```json
{
  "ts": "...", "task_id": "YARD-002", "kind": "implementation", "risk": "medium",
  "worker": "codex", "chosen_reason": "preferred",
  "result_status": "done", "eval_state": "done",
  "wall_seconds": 95, "retries": 0,
  "user_override": null            // e.g. "codex->claude" when the user forced the other
}
```

All of these already exist in `run.yaml` / `evaluation.json`; this is a compact
projection for analysis.

### Aggregate + suggest (mechanism; output is advice, not action)

`yardlet routing review` reads the telemetry and aggregates per `(kind, worker)`:
success rate (`eval_state == done` / total), avg wall time, override count.
Thresholds (config-tunable) turn deltas into suggestions:

- non-preferred worker's success rate beats the default by margin `M` over `>= K`
  samples for a kind → suggest flipping that kind's preference,
- override rate for a kind exceeds a threshold → suggest aligning the profile
  with what the user keeps choosing,
- a worker's success drops sharply after its CLI version changed → flag it.

Output: human-readable findings **plus a proposed diff to `workers.yaml`**. It
never edits config itself.

### Human gate (policy change)

Applying a suggestion edits `best_for` / `default_worker` / `fallback_order` —
that is a policy change, so a human approves it (`yardlet routing apply` stages the
diff for confirmation, or you edit the file). This matches Yardlet's "human
approval for shared-state changes" rule and the observe → candidate → review →
promote learning lifecycle.

### Triggers (event-based, not calendar)

- `yardlet status` shows a one-line nudge when suggestions are pending
  (`routing: 2 suggestions — run \`yardlet routing review\``).
- a worker's CLI version change (Yardlet stores last-seen versions) flags a
  re-evaluation,
- an override spike for a kind.

### Cold start

Early on there is little data, so suggestions stay silent until `>= K` samples
per kind accrue. The profile is human-seeded (the `best_for` defaults above);
the loop refines it once real runs exist. `cost_bias` is always manual.

## Loop

```
profile (seeded)
   -> planner reads rubric -> task.preferred_worker + rationale
   -> run-time resolve: preferred -> ready? -> fallback        (deterministic)
   -> execute -> evaluate
   -> append telemetry (kind, worker, outcome, override)
   -> aggregate -> thresholds -> suggestion (proposed profile diff)
   -> human reviews/approves -> profile updated
   ^________________________________________________________|
```

## Policy vs mechanism (explicit)

- **Mechanism (code):** readiness probe, hard capability rules, fallback walk,
  telemetry collection, aggregation + thresholds, suggestion computation,
  version-change detection, the worker execution gate.
- **Policy (editable config / human):** `best_for`, `cost_bias`,
  `default_worker`, `fallback_order`, the thresholds, and the planner's per-task
  choice derived from the rubric. Applying a suggestion is a human-gated policy
  edit.

## Implementation phases

1. **Run-time fallback + telemetry collection** (mechanism). `resolve_worker`
   with readiness + `fallback_order`; append `runs.jsonl`. Fixes the missing
   fallback immediately and starts gathering data. Low risk.
2. **Guided planner.** `best_for` + `cost_bias` into the planning packet;
   `worker_rationale` in the result. Fixes the codex-default bug.
3. **Aggregate + `yardlet routing review`.** Suggestions, the status nudge,
   version-change flag.
4. **`yardlet routing apply` + override detection.** Assisted, human-confirmed
   profile edits.

Phase 1 is shippable on its own and is the highest-value first slice.
