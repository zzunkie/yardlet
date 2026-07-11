# Benchmark posture

Yardlet v0.9 evaluates mechanisms, not model intelligence.

`yardlet eval fixtures` runs isolated, provider-free fixtures against the same
core mechanisms used by normal execution. The suite reports an `id`, `verdict`,
`evidence`, and `duration_ms` for every fixture. Human and `--json` output are
rendered from the same report, and any failed fixture produces a non-zero exit.

The suite currently covers the seven baseline evaluator and recovery
invariants plus bounded goal feedback, read-only scout isolation, and a watch
until condition. Each fixture uses a temporary workspace and cleans it up, so
repeated runs in one checkout do not share fixture state.

This supports three claims only:

1. A named deterministic mechanism produced the recorded verdict.
2. A regression in one fixture cannot be hidden by passes elsewhere.
3. The same structured verdicts are available to people and automation.

It does not measure worker coding quality, compare providers, rank models,
estimate task success on an external benchmark, or use consensus voting or
best-of-N selection. Worker telemetry is workspace evidence for routing review,
not a general performance leaderboard. Policy changes remain explicit.

Run the complete suite or select fixtures by id:

```bash
yardlet eval fixtures
yardlet eval fixtures --json
yardlet eval fixtures --fixture goal-feedback-is-bounded
```
