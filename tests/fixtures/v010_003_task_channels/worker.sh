#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'fixture-worker 1.0\n'
  exit 0
fi

run_dir="${1:?run directory is required}"
packet="$(cat)"
task_id="$(sed -n 's/^# Yardlet task packet: //p' <<<"$packet" | head -n 1)"
run_id="${run_dir##*/}"
mkdir -p "$run_dir"

write_handoff() {
  printf '# Handoff\n\n%s\n' "$1" >"$run_dir/handoff.md"
}

write_done() {
  local summary="$1"
  printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "compact_summary": "%s"\n}\n' \
    "$run_id" "$task_id" "$summary" >"$run_dir/result.json"
  write_handoff "$summary"
}

write_question() {
  local question="$1"
  printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "needs_user",\n  "question_for_user": "%s",\n  "compact_summary": "사용자 선택 대기"\n}\n' \
    "$run_id" "$task_id" "$question" >"$run_dir/result.json"
  write_handoff "사용자 선택을 기다립니다."
}

case "$task_id" in
  YARD-ASK)
    printf 'ask worker public context before question\n'
    printf 'ask worker diagnostic stream\n' >&2
    write_question "A 또는 B를 선택해 주세요."
    ;;
  YARD-DRAIN)
    sleep 1
    printf 'drain worker public progress\n'
    printf 'drain worker diagnostic stream\n' >&2
    printf 'validated fixture artifact\n' >drain-artifact.txt
    write_done "독립 task worker 완료"
    ;;
  YARD-001)
    if grep -q '> \[user\] A' <<<"$packet"; then
      printf 'fixture second stdout\n'
      printf 'fixture second stderr\n' >&2
      write_done "질문 답변 뒤 explicit continuation 완료"
    else
      printf 'fixture first stdout\n'
      printf 'fixture first stderr\n' >&2
      write_question "A 또는 B를 선택해 주세요."
    fi
    ;;
  *)
    printf 'unexpected fixture task: %s\n' "$task_id" >&2
    exit 64
    ;;
esac
