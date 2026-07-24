# HarnessBench local run notes

Status: repo-local evidence note. This records benchmark research and local
HarnessBench runs that were previously only in temporary directories and Codex
session memory. It is not a public leaderboard claim.

Recorded: 2026-07-24 (Asia/Seoul)

## Why this exists

Yardlet should not be judged by a single pass/fail number. It wraps native
workers, so external benchmarks need to separate at least four axes:

1. functional correctness;
2. heuristic or style deductions;
3. operational overhead, including planning, skill loading, verifier work, and
   wall-clock time;
4. evidence quality, such as durable result files, reports, handoffs, and
   validation logs.

This note preserves the local HarnessBench evidence we have so far and the
benchmark-landscape conclusions that shaped it.

## Benchmark landscape summary

The broader benchmark review from July 2026 found that no single public suite
fully measures Yardlet's shape: native CLI worker, deterministic outer state,
queueing, validation, recovery, and handoff evidence.

The working benchmark portfolio is:

| benchmark | useful signal for Yardlet | caveat |
|---|---|---|
| TUA-Bench | broad terminal-use agent comparison through Harbor | reports whole model-plus-harness configurations, not isolated mechanism causes |
| Harness-Bench | closest diagnostic for harness effects | young suite; treat as diagnostic before launch evidence |
| Terminal-Bench / FeatureBench | technical task and delivery outcomes | task quality and revision pinning matter |
| TeamBench | planner/executor/verifier ablations | shows team structure can add overhead or role collapse |
| STATE-Bench | memory and state compounding | narrower than Yardlet's full lifecycle |
| ClawMark / SentinelBench | durable state, waiting, and external changes | complementary to coding benchmarks |
| Toolathlon / MCPMark / AppWorld | broad tool-use behavior | less focused on repo-local verification |
| AgentDojo / HarnessAudit-Bench | permissions and trajectory safety | safety signal, not product outcome alone |
| Yardlet deterministic fixtures | restart, recovery, false-Done, forbidden paths, handoff invariants | provider-free mechanism tests, not worker coding quality |

Peer evidence is useful mostly as protocol inspiration. Goose has the strongest
published same-model terminal-agent comparison pattern; MiMo Code and Oh My
OpenAgent publish narrower or less reproducible self-evaluations. Yardlet should
copy the discipline of same-model comparisons and mechanism ablations, not the
claim shape.

## Local HarnessBench runs

### Source and artifact status

- HarnessBench repository: `Qihoo360/harness-bench`
- Pinned commit for the recorded four-arm run:
  `1025086a446653702b80cfb48babbeec35db6b2c`
- Main temporary checkout used for the four-arm run:
  `/tmp/harnessbench.3hvjbV`
- Raw result artifacts were left outside this repository under `/tmp`. They
  should be treated as ephemeral unless copied into a future committed archive.
- The current repo had no intentional HarnessBench result file before this
  note. Existing hits were benchmark posture docs or incidental `.agents/`
  operational logs.

### `041-frontend-state-bug`

This is the best-preserved local comparison because the four arms were recorded
with the exact task, scores, durations, and interpretation.

| arm | duration | score | verdict | notes |
|---|---:|---:|---|---|
| `claude-native` | 213.0 s | 1.0000 | pass | all checks passed |
| `codex-native` | 467.5 s | 1.0000 | pass | all checks passed; proxy reported 32,277 tokens |
| `yardlet-codex-single` | 475.5 s | 1.0000 | pass | one Yardlet implementation task; close to `codex-native` wall-clock |
| `yardlet-codex-local` | 647.4 s | 0.9962 | pass | implementation plus `YARD-002` verification task; stronger evidence artifacts |

Interpretation:

- All arms passed the functional checks.
- The `yardlet-codex-local` deduction was not a hidden behavior failure. It was
  an implementation-quality heuristic difference: `state_term_hits` was `5`
  instead of `6`.
- `yardlet-codex-single` is the cleaner wrapped-vs-native comparison for
  overhead on this task because it used one Yardlet implementation task.
- `yardlet-codex-local` is the better evidence-quality comparison because it
  added verification and produced Yardlet artifacts such as `result.json`,
  `report.md`, `handoff.md`, and `validation.log`.
- A concrete overhead source was skill loading: five skills and roughly 900
  lines of skill documentation were loaded for one Yardlet task.

Implementation evidence recorded for the state fix included immutable updates,
deep input copies, quantity validation, undo/redo and redo clearing, schema-v2
persistence, legacy-v1 migration, selector freshness, coupon round trips, and
protected-test integrity.

### Earlier exploratory tasks

The earlier local HarnessBench runs were useful, but their raw temp-clone
artifacts are not currently preserved in this repository. Treat these as
session-derived notes until rerun.

| task | observed result | interpretation |
|---|---|---|
| `001-file` | all compared arms passed | microtask; mainly measures harness startup overhead |
| `002-exec` | all compared arms passed | microtask; mainly measures command execution path |
| `020-archive-checksum` | all compared arms passed | microtask; correctness was easy, Yardlet was slower |
| `016-code-repair-pytest` | all compared arms passed | simple code repair; Yardlet slower |
| `087-cli-parser-bug-tests` | all compared arms passed | Yardlet review noticed a `--where ""` edge outside the oracle |
| `042-api-schema-migration` | all compared arms scored about `0.74` | public pytest passed, but hidden `convert_many_errors` and `audit_written_in_project` failed |

The `042-api-schema-migration` result is especially important as a task-quality
warning. The oracle behavior was tricky because the last `convert_many(bad_batch)`
call overwrote audit state, and different arms failed through slightly different
first-error paths. It should not be reduced to "all agents passed" or "Yardlet
failed" without first revalidating the oracle.

## Current benchmark meaning

So far, the local evidence supports only narrow claims:

1. Yardlet can preserve worker-level functional correctness on at least one
   preserved HarnessBench task.
2. Yardlet adds observable overhead, especially when it plans, loads skills, and
   runs a verifier for a small task.
3. Yardlet can produce stronger durable evidence than a native single-agent run.
4. Microtasks are too small to prove product value; they mostly expose startup
   and orchestration cost.
5. Harder tasks are needed to learn whether the verification and handoff layer
   pays for itself.

The evidence does not yet support these claims:

1. Yardlet improves absolute benchmark pass rate over native Codex or Claude
   Code.
2. Yardlet is faster than native workers.
3. One HarnessBench score generalizes to production agent work.
4. A hidden-oracle pass/fail label is always the right behavioral truth.

## Next benchmark plan

The next run should use a small matrix rather than a broad leaderboard:

| axis | choice |
|---|---|
| benchmark | rerun HarnessBench first, then consider TUA-Bench or Terminal-Bench only after cost and licensing review |
| task mix | one microtask, one normal code-repair task, one stateful frontend task, one harder migration task |
| arms | native Codex, native Claude Code, Yardlet single-task Codex, Yardlet local plan-plus-verify Codex |
| required output | per-task raw result JSON, wall-clock, tokens/cost where available, verifier logs, and a short interpretation |
| archive location | a committed or explicitly ignored `benchmarks/` archive, not `/tmp` |

Report correctness, heuristic deductions, overhead, and evidence quality in
separate columns. Avoid collapsing the result into pass/non-pass unless the task
oracle is simple and already audited.
