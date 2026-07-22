#!/usr/bin/env bash
set -euo pipefail

run_dir="${1:?planner fixture requires run directory}"
packet="$(cat)"
mkdir -p "$run_dir"

scenario="seed"
max_cycles=2
task_title=""
extra_task=""
if grep -q 'fixture:mixed_question_failure_seed' <<<"$packet"; then
  scenario="mixed"
  max_cycles=1
  task_title="question replan fixture task"
  extra_task=',
    {
      "id": "YARD-002",
      "title": "failure replan fixture task",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "allowed_scope": ["src"],
      "acceptance": ["replan evidence is visible"],
      "goal": {
        "condition": "replan evidence is visible",
        "max_feedback_cycles": 1,
        "feedback_policy": "inject_failed_checks"
      },
      "worker_rationale": "provider-free replan fixture"
    }'
elif grep -q 'fixture:replan_retry' <<<"$packet"; then
  scenario="retry"
elif grep -q 'fixture:feedback_seed' <<<"$packet"; then
  # max_feedback_cycles 1: attempt 1 stays a Partial retry hold, attempt 2
  # exhausts the cap and parks the task NeedsUser typed goal_feedback_exhausted.
  scenario="feedback"
  max_cycles=1
elif grep -q 'fixture:question_seed' <<<"$packet"; then
  scenario="question"
  max_cycles=1
fi
if [[ -z "$task_title" ]]; then
  task_title="$scenario replan fixture task"
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
      "title": "$task_title",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "allowed_scope": ["src"],
      "acceptance": ["replan evidence is visible"],
      "goal": {
        "condition": "replan evidence is visible",
        "max_feedback_cycles": $max_cycles,
        "feedback_policy": "inject_failed_checks"
      },
      "worker_rationale": "provider-free replan fixture"
    }$extra_task
  ],
  "questions_for_user": []
}
JSON
printf 'planned replan fixture scenario %s\n' "$scenario"
