#!/usr/bin/env bash
set -euo pipefail

run_dir="${1:?planner fixture requires run directory}"
packet="$(cat)"
mkdir -p "$run_dir"

scenario="seed"
if grep -q 'fixture:replan_retry' <<<"$packet"; then
  scenario="retry"
fi

# max_feedback_cycles 2: each failing run inside the cap seals a `partial` run
# record backed by a fatal failed evaluator check and settles the task Partial,
# which is exactly the typed-failure history the replan projection counts.
cat >"$run_dir/planning-result.json" <<JSON
{
  "summary": "$scenario provider-free replan fixture plan",
  "rationale": "deterministic same-intent replan fixture",
  "allowed_scope": ["src"],
  "out_of_scope": ["external mutation"],
  "acceptance": [{"id": "AC-001", "statement": "replan evidence is visible"}],
  "ambiguity": {"score": "low", "open_questions": []},
  "tasks": [
    {
      "id": "YARD-001",
      "title": "$scenario replan fixture task",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "allowed_scope": ["src"],
      "acceptance": ["replan evidence is visible"],
      "goal": {
        "condition": "replan evidence is visible",
        "max_feedback_cycles": 2,
        "feedback_policy": "inject_failed_checks"
      },
      "worker_rationale": "provider-free replan fixture"
    }
  ],
  "questions_for_user": []
}
JSON
printf 'planned replan fixture scenario %s\n' "$scenario"
