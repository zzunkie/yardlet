# Project Memory, Trust Report, and Outcome Mining

Yardlet v0.8 adds three loop-level surfaces that sit above the worker CLI:
Project Memory, Trust Report, and Outcome Mining. They share one boundary:
workers can use the context and propose improvements, but Yardlet keeps the
canonical state and policy changes deterministic and auditable.

## Project Memory

Project Memory is repo-local durable context. A workspace can keep facts and
decisions as Markdown files under `.agents/memory/`, one fact per file. Each
file may use optional frontmatter such as:

```yaml
---
name: Payment webhook decision
description: Reservation finalization must be idempotent.
look_at:
  - src/webhooks.rs
  - docs/payments.md
---
```

Yardlet discovers `.agents/memory/*.md` during the same harness discovery pass
that finds rules and skills. It skips the scaffold README and non-Markdown
files. For every memory doc, Yardlet extracts only an index line:

- title, from `name:` / `title:` or the first `#` heading
- one-line summary, from `description:` / `summary:` or the first prose line
- anchor path, such as `.agents/memory/payment-webhook.md`
- optional `look_at` landmarks

That index is injected into the planner and every worker packet. The body is
not inlined. The packet tells the worker to read the entry only when it bears on
the task. This is the index-and-anchor model: always load a small map, then
open the few bodies needed for the current work.

`yardlet memory` renders the same index for the human. If a memory file declares
`look_at:` landmarks, the command checks git state for those paths. A memory is
marked `possibly stale` when a landmark has an uncommitted change or a newer git
commit time than the memory doc. The packet hot path stays git-free; staleness
is a diagnostic view in the command.

`yardlet memory init` and `yardlet memory refresh` maintain the docs through a
worker without hand-editing. `init` asks a worker to draft memory documents from
the repo into an isolated run directory (`memory-result.json`); Yardlet's core is
the single writer that turns those drafts into canonical `.agents/memory/*.md`.
`refresh` re-drafts the existing docs the same way, and `refresh --stale-only`
limits the worker to the docs currently flagged possibly stale. The worker only
proposes content; the deterministic core owns every write.

## Trust Report

The Trust Report is a deterministic read over your own history. It answers a
local question: how much should this workspace trust the loop's `Done` outcomes?
`yardlet trust` folds two sources, run telemetry (`.agents/telemetry/runs.jsonl`)
and the state-transition audit log (`.agents/transitions/<task>.yaml`), into two
layers, and only reports.

### Attempt view (from run telemetry)

- first-pass Done, for tasks whose first recorded attempt reached `Done`
- Done after retry, for tasks that reached `Done` only after more than one
  attempt
- no Done in record, for tasks that have no `Done` telemetry row
- per-worker reliability, including done rate, partial count, failed count,
  no-result count, wall time, and user override count
- tasks that needed multiple attempts, sorted by most attempts first

Telemetry records carry `intent_id`. When the active intent has matching
telemetry, the attempt view scopes to that intent so reused task ids do not fold
together across unrelated intents. If there is no intent-scoped telemetry yet,
it falls back to the cumulative view and labels that caveat.

### Autonomy view (from the transition audit log)

The transition log is the only record where a `Done` that was later reopened, or
a human intervention, is visible. Yardlet folds it, keyed per (intent, task)
instance, into:

- **Can I trust a Done?** Each Done is graded as evidence-backed (a clean Done,
  never reopened), recovered (Done only after a Failed/Partial/Blocked detour),
  false-done caught (marked Done, then transitioned back out of Done), or
  unresolved (no Done yet). The trustworthy-Done rate is the evidence-backed
  share of all Dones.
- **Human interventions, decision vs chore.** A counted human touch is either a
  decision the loop legitimately owed you (a deliberate defer, or a seeded
  question routed to you) or a chore the self-healing loop should have absorbed
  (un-parking a revived task, recovering an abandoned run). The chore share, per
  intent, is the number the autonomy goal drives toward zero.
- **Unnecessary loop stops.** Every halt into `NeedsUser` is counted; the ones
  that were approval or pause friction rather than a real seeded question are
  reported as reducible waste.

Every number traces to a specific transition or run, never a hand-tally.
`yardlet trust --json` emits the autonomy metrics (nested under `done_trust`,
`human_touches`, `loop_stops`, and `sources`) as machine-readable JSON. The
terminal UI shows the same numbers in a Trust panel (the `T` key on the Home
screen).

The Trust Report is read-only across both layers. It reports, but it does not
edit `.agents/workers.yaml`, rewrite routing policy, mark tasks done, or promote
harness assets.

## Outcome Mining

Outcome Mining uses the same telemetry, but looks for threshold-crossing
patterns that are better treated as harness work than as one-off failures.
`yardlet harness review` surfaces mined observations next to learned rules and
skills.

Current v0.8 thresholds are:

| Signal | Threshold | Why it matters |
| --- | --- | --- |
| Worker no-result hotspot | at least 6 runs for the worker, with no-result rate at least 10% | The worker often finished without a parseable result, which points to a packet or output-contract problem. |
| High-retry task kind | at least 3 tasks of the kind reached Done, averaging at least 2.5 attempts | The kind rarely lands first-pass, which suggests a skill or sharper acceptance criteria may help. |

The first signal is per worker. The second is per task kind and only averages
tasks that eventually reached `Done`, so it measures retry effort rather than
unresolved failure.

Outcome Mining is suggestions-only. It can name the recurring deterministic
outcome and suggest checking a worker contract, writing a rule, creating a
skill, or sharpening acceptance criteria. It never changes routing, never edits
policy, and never promotes a rule or skill without the normal harness path.
Telemetry observes; humans decide which suggestions become durable harness
assets.

## Source Trail

The public feature claims above are grounded in the v0.8 entries in
[CHANGELOG.md](../CHANGELOG.md) and the build record in
[docs/v0.8-decisions.md](v0.8-decisions.md). The policy boundary matches the
existing routing and telemetry design: telemetry suggests, but it never binds
runtime policy.
