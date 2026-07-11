#!/bin/sh
set -eu

run_dir="$1"
run_id=$(basename "$run_dir")
task_id=$(sed -n 's/^task_id: //p' "$run_dir/run.yaml" | head -n 1)

printf '%s\n' "$task_id" >> "${YARD_FIXTURE_WORKER_COUNT:?}"

if [ "$task_id" = YARD-002 ]; then
  printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    "  \"run_id\": \"$run_id\"," \
    "  \"task_id\": \"$task_id\"," \
    '  "status": "failed",' \
    '  "intent_adherence": {"drift_detected": false, "notes": ""},' \
    '  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},' \
    '  "validation": {"commands_run": [], "passed": false, "failures": ["fixture auxiliary terminal state"]},' \
    '  "question_for_user": null,' \
    '  "compact_summary": "격리 보조 작업 종료",' \
    '  "verdict": [],' \
    '  "harness_suggestions": [],' \
    '  "follow_up_tasks": []' \
    '}' > "$run_dir/result.json"
  printf '# Handoff\n\n격리 보조 작업이 실패 상태로 종료됐습니다.\n' > "$run_dir/handoff.md"
  exit 0
fi

# Let the auxiliary task seal before this task reaches Git finish. This keeps
# the crash fixture focused on exactly one recoverable Prepared record.
sleep 1
printf 'owned by %s\n' "$task_id" > "fixture-$task_id.txt"

printf '%s\n' \
  '{' \
  '  "schema_version": 1,' \
  "  \"run_id\": \"$run_id\"," \
  "  \"task_id\": \"$task_id\"," \
  '  "status": "done",' \
  '  "intent_adherence": {"drift_detected": false, "notes": ""},' \
  "  \"changes\": {\"files_modified\": [], \"files_created\": [\"fixture-$task_id.txt\"], \"files_deleted\": []}," \
  '  "validation": {"commands_run": [], "passed": true, "failures": []},' \
  '  "question_for_user": null,' \
  '  "compact_summary": "격리 process fixture 완료",' \
  '  "verdict": [],' \
  '  "harness_suggestions": [],' \
  '  "follow_up_tasks": []' \
  '}' > "$run_dir/result.json"
printf '# Handoff\n\n격리 process fixture가 %s 변경을 남겼습니다.\n' "$task_id" > "$run_dir/handoff.md"
