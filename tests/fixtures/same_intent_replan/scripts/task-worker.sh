#!/usr/bin/env bash
set -euo pipefail

run_dir="${1:?task fixture requires run directory}"
packet="$(cat)"
mkdir -p "$run_dir"
run_id="$(basename "$run_dir")"
task_id="$(sed -n 's/^# Yardlet task packet: \(.*\)$/\1/p' <<<"$packet" | head -1)"

# A question-scenario task parks NeedsUser as a genuine worker-authored
# conversation: status needs_user with an actionable question and passing
# validation, so finalize types the hold worker_question (answer-only).
if grep -q 'question replan fixture task' <<<"$packet"; then
  cat >"$run_dir/result.json" <<JSON
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "needs_user",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": ["fixture-validation"], "passed": true, "failures": []},
  "question_for_user": "fixture worker question: 어느 방향으로 진행할까요?",
  "compact_summary": "고정된 worker 질문을 남기는 fixture 실행",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
JSON
  printf '# Replan fixture handoff\n\n의도된 fixture worker 질문.\n' >"$run_dir/handoff.md"
  printf 'replan fixture task %s paused with a worker question\n' "$task_id"
  exit 0
fi

# Always report a typed validation failure: the run seals failed with a fatal
# failed evaluator check, which is exactly the record the replan projection
# counts.
cat >"$run_dir/result.json" <<JSON
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "failed",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": ["fixture-validation"], "passed": false, "failures": ["fixture validation failed"]},
  "question_for_user": null,
  "compact_summary": "고정된 실패를 재현하는 fixture 실행",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
JSON
printf '# Replan fixture handoff\n\n의도된 fixture 실패.\n' >"$run_dir/handoff.md"
printf 'replan fixture task %s failed deterministically\n' "$task_id"
