#!/bin/sh
set -eu

if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'fixture-worker 1.0'
  exit 0
fi

run_dir="$1"
scenario="$2"
task_id="$3"
count_file="$run_dir/fixture-attempt-count"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
cat > "$run_dir/packet-attempt-$count.txt"

if [ "$scenario" = alternate_success ]; then
  run_id="$(basename "$run_dir")"
  cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "unclassified 누락 뒤 기존 failover 완료",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
  printf '# Alternate worker handoff\n' > "$run_dir/handoff.md"
  exit 0
fi

if [ "$count" -eq 1 ]; then
  if [ "$scenario" = unclassified ]; then
    printf '%s\n' 'ordinary resultless worker output'
  else
    printf '%s\n' 'PROVIDER DECLINED response before output contract'
  fi
  exit 0
fi

grep -Fq 'result.json first' "$run_dir/packet-attempt-$count.txt"
grep -Fq 'Do not repeat' "$run_dir/packet-attempt-$count.txt"

if [ "$scenario" = success ]; then
  run_id="$(basename "$run_dir")"
  cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "중립적 output-contract 복구 뒤 완료",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
  printf '# Worker handoff\n\n복구 시도에서 result.json을 먼저 기록했다.\n' > "$run_dir/handoff.md"
else
  printf '%s\n' 'PROVIDER DECLINED response during output contract recovery'
fi
