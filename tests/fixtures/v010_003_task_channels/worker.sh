#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'fixture-worker 1.0\n'
  exit 0
fi

run_dir="$1"
packet="$(cat)"
mkdir -p "$run_dir"

if grep -q '> \[user\] A' <<<"$packet"; then
  printf 'fixture second stdout\n'
  printf 'fixture second stderr\n' >&2
  cat >"$run_dir/result.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "fixture-result",
  "task_id": "YARD-001",
  "status": "done",
  "compact_summary": "질문 답변 뒤 explicit continuation 완료"
}
JSON
  printf '# Handoff\n\n답변 뒤 완료했습니다.\n' >"$run_dir/handoff.md"
else
  printf 'fixture first stdout\n'
  printf 'fixture first stderr\n' >&2
  cat >"$run_dir/result.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "fixture-result",
  "task_id": "YARD-001",
  "status": "needs_user",
  "question_for_user": "A 또는 B를 선택해 주세요.",
  "compact_summary": "사용자 선택 대기"
}
JSON
  printf '# Handoff\n\n사용자 선택을 기다립니다.\n' >"$run_dir/handoff.md"
fi
