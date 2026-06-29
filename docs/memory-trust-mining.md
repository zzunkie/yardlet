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

## Trust Report

The Trust Report is a deterministic read over run telemetry. It answers a local
question: how much should this workspace trust the loop's `Done` outcomes based
on its own history?

`yardlet trust` reads `.agents/telemetry/runs.jsonl` and folds run attempts into
a trust view:

- first-pass Done, for tasks whose first recorded attempt reached `Done`
- Done after retry, for tasks that reached `Done` only after more than one
  attempt
- no Done in record, for tasks that have no `Done` telemetry row
- per-worker reliability, including done rate, partial count, failed count,
  no-result count, wall time, and user override count
- tasks that needed multiple attempts, sorted by most attempts first

Telemetry records now carry `intent_id`. When the active intent has matching
telemetry, the report scopes to that intent so reused task ids do not fold
together across unrelated intents. If there is no intent-scoped telemetry yet,
it falls back to the cumulative view and labels that caveat.

The Trust Report is read-only. It reports from telemetry, but it does not edit
`.agents/workers.yaml`, rewrite routing policy, mark tasks done, or promote
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
