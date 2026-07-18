#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'fixture-worker 1.0\n'
  exit 0
fi

packet="$(cat)"
native_adapter=false
if [[ "${1:-}" == "exec" ]]; then
  native_adapter=true
  run_dir="$(sed -n 's#.*- `\(/.*\)/result.json`.*#\1#p' <<<"$packet" | head -n 1)"
else
  run_dir="${1:?run directory is required}"
fi
if [[ -z "$run_dir" && -d "$PWD/.agents/runs" ]]; then
  run_yaml="$(find "$PWD/.agents/runs" -mindepth 2 -maxdepth 2 -name run.yaml -print -quit)"
  if [[ -n "$run_yaml" ]]; then
    run_dir="${run_yaml%/run.yaml}"
  fi
fi
if [[ -z "$run_dir" ]]; then
  printf 'fixture could not resolve run directory\n' >&2
  exit 65
fi
task_id="$(sed -n 's/^# Yardlet task packet: //p' <<<"$packet" | head -n 1)"
if [[ -z "$task_id" && -f "$run_dir/run.yaml" ]]; then
  task_id="$(sed -n 's/^task_id: //p' "$run_dir/run.yaml" | head -n 1)"
fi
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

assert_exact_receipts() {
  for receipt in "$run_dir/run.yaml" "$run_dir/worker-process.yaml"; do
    test -f "$receipt"
    grep -Eq '^worker(_id)?: codex$' "$receipt"
    grep -q '^model: gpt-5.6-sol$' "$receipt"
    grep -q '^fallback_enabled: false$' "$receipt"
    grep -q '^routing_provenance:$' "$receipt"
  done
}

if grep -q 'propose exact lineage follow-ups' <<<"$packet"; then
  printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "compact_summary": "exact lineage follow-ups proposed",\n  "follow_up_tasks": [\n    {"title": "exact lineage remediation", "reason": "fixture remediation", "kind": "implementation", "acceptance": ["receipt parity"]},\n    {"title": "exact lineage review", "reason": "fixture review", "kind": "review", "acceptance": ["receipt parity"]}\n  ]\n}\n' \
    "$run_id" "$task_id" >"$run_dir/result.json"
  write_handoff "exact lineage 후속 작업을 제안했습니다."
  exit 0
fi

if grep -Eq 'exact lineage (remediation|review)' <<<"$packet"; then
  assert_exact_receipts
  if grep -q 'exact lineage review' <<<"$packet"; then
    control_root="${PWD%%/.agents/worktrees/*}"
    review_marker="$control_root/.agents/exact-review-ran"
    if [[ ! -f "$review_marker" ]]; then
      : >"$review_marker"
      printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "validation": {"commands_run": ["pre-dispatch receipt inspection"], "passed": true, "failures": []},\n  "verdict": [{"criterion_id": "AC-RECEIPT", "pass": false, "evidence": "fixture requests one remediation"}],\n  "follow_up_tasks": [{"title": "exact lineage remediation after review", "reason": "exercise review-rerun", "kind": "implementation", "acceptance": ["receipt parity"]}],\n  "compact_summary": "pre-dispatch receipt parity observed before remediation"\n}\n' \
        "$run_id" "$task_id" >"$run_dir/result.json"
    else
      printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "validation": {"commands_run": ["pre-dispatch receipt inspection"], "passed": true, "failures": []},\n  "verdict": [{"criterion_id": "AC-RECEIPT", "pass": true, "evidence": "worker read both receipts before body"}],\n  "compact_summary": "pre-dispatch receipt parity observed"\n}\n' \
        "$run_id" "$task_id" >"$run_dir/result.json"
    fi
  else
    write_done "pre-dispatch receipt parity observed"
  fi
  write_handoff "worker 본문에서 dispatch receipt parity를 확인했습니다."
  exit 0
fi

case "$task_id" in
  YARD-TRANSIENT)
    assert_exact_receipts
    if [[ " $* " == *" resume "* ]]; then
      write_done "transient retry receipt parity observed"
    else
      printf '{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}\n'
      exit 75
    fi
    ;;
  YARD-EXACT-REDIRECT)
    assert_exact_receipts
    if grep -q 'Explicit continuation packet' <<<"$packet"; then
      write_done "redirect receipt parity observed"
    else
      write_handoff "checkpoint before exact redirect"
      child_pid=''
      trap '[[ -z "$child_pid" ]] || kill "$child_pid" 2>/dev/null || true; exit 143' TERM INT
      while true; do
        sleep 30 &
        child_pid=$!
        wait "$child_pid"
      done
    fi
    ;;
  YARD-ASK)
    printf 'ask worker public context before question\n'
    printf 'ask worker diagnostic stream\n' >&2
    write_question "A 또는 B를 선택해 주세요."
    ;;
  YARD-EMPTY-QUESTION)
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "needs_user",\n  "question_for_user": "   ",\n  "compact_summary": "empty question regression"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    write_handoff "빈 질문 회귀 fixture"
    ;;
  YARD-FEEDBACK-EXHAUSTED)
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "validation": {"commands_run": ["fixture"], "passed": false, "failures": ["fixture failed"]},\n  "compact_summary": "feedback exhausted regression"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    write_handoff "feedback 소진 회귀 fixture"
    ;;
  YARD-REVIEW-FAIL)
    printf 'failed review change\n' >review-change.txt
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "validation": {"commands_run": ["fixture"], "passed": true, "failures": []},\n  "verdict": [{"criterion_id": "AC-001", "pass": false, "evidence": "fixture criterion failed"}],\n  "compact_summary": "review failure regression"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    write_handoff "review 실패 회귀 fixture"
    ;;
  YARD-REVIEW-PASS-MANUAL)
    printf 'passing review change\n' >review-change.txt
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "validation": {"commands_run": ["fixture"], "passed": true, "failures": []},\n  "verdict": [{"criterion_id": "AC-001", "pass": true, "evidence": "fixture criterion passed"}],\n  "follow_up_tasks": [{"title": "optional review documentation", "reason": "non-blocking fixture follow-up", "kind": "implementation"}],\n  "compact_summary": "passing review awaiting manual integration"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    write_handoff "WORKER-HANDOFF-MARKER-ISSUE-31-7E3C 통과한 review의 수동 통합 대기 fixture"
    ;;
  YARD-REVIEW-PASS)
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "validation": {"commands_run": ["fixture"], "passed": true, "failures": []},\n  "verdict": [{"criterion_id": "AC-001", "pass": true, "evidence": "foundation passes while runtime remains unresolved"}],\n  "domain_artifact": {"runtime_conformity": {"status": "not_pass"}, "free_text": "status fail blocked not_pass"},\n  "compact_summary": "structured review contract regression"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    write_handoff "구조화 review 계약 회귀 fixture"
    ;;
  YARD-DRAIN)
    sleep 1
    printf 'drain worker public progress\n'
    printf 'drain worker diagnostic stream\n' >&2
    printf 'validated fixture artifact\n' >drain-artifact.txt
    write_done "독립 task worker 완료"
    ;;
  YARD-CWD-TAMPER)
    if grep -q 'Output-contract feedback' <<<"$packet"; then
      # A failover spawn reached a worker. For the parallel run this must be
      # unreachable (the tampered receipt fails attestation first), so leave
      # a marker the test asserts absent.
      if grep -q '^serial_isolated: false' "$run_dir/run.yaml"; then
        control_root="${PWD%%/.agents/worktrees/*}"
        : >"$control_root/.agents/parallel-cwd-failover-ran"
      fi
      write_done "failover worker completed after missing result"
    elif grep -q '^serial_isolated: false' "$run_dir/run.yaml"; then
      # Parallel first attempt: tamper this run's own receipt, then exit
      # without result.json so the parallel path tries a failover worker.
      awk '/^worktree: / { print "worktree: ."; next } { print }' "$run_dir/run.yaml" >"$run_dir/run.yaml.tmp"
      mv "$run_dir/run.yaml.tmp" "$run_dir/run.yaml"
      exit 0
    else
      # Sequential retry after the parallel run failed closed: finish cleanly
      # so the auto drain terminates.
      write_done "serial retry completed without tampering"
    fi
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
  YARD-NATIVE)
    assert_exact_receipts
    if [[ "$native_adapter" != true ]]; then
      printf 'native fixture requires the codex adapter\n' >&2
      exit 66
    fi
    printf '%s\n' "$*" >"$run_dir/native-args.txt"
    if [[ " $* " == *" resume "* ]]; then
      printf '{"type":"item.completed","item":{"type":"agent_message","text":"native resumed stdout"}}\n'
      printf 'native resumed stderr\n' >&2
      write_done "native session resume 완료"
    else
      printf '{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}\n'
      printf '{"type":"item.completed","item":{"type":"agent_message","text":"native first stdout"}}\n'
      printf 'native first stderr\n' >&2
      write_question "native session으로 이어갈까요?"
    fi
    ;;
  YARD-FULL-ACCESS-CWD)
    if [[ "$native_adapter" != true ]]; then
      printf 'full-access cwd fixture requires the codex adapter\n' >&2
      exit 66
    fi
    agent_cwd=''
    args=("$@")
    index=0
    while (( index < ${#args[@]} )); do
      case "${args[$index]}" in
        -C|--cd)
          ((index += 1))
          agent_cwd="${args[$index]:-}"
          ;;
      esac
      ((index += 1))
    done
    if [[ -z "$agent_cwd" ]]; then
      agent_cwd="${YARD_TEST_DECOY_CWD:?missing decoy cwd}"
    fi
    cd "$agent_cwd"
    cat "${YARD_TEST_ABSOLUTE_SOURCE:?missing absolute source}" >relative-worker.txt
    printf '%s\n' "$PWD" >"$run_dir/effective-cwd.txt"
    write_done "full-access relative operation completed"
    ;;
  YARD-CWD-ATTEST)
    write_done "cwd attestation fixture worker ran"
    ;;
  YARD-CODEX-BACKPRESSURE)
    if [[ "$native_adapter" != true ]]; then
      printf 'codex backpressure fixture requires the codex adapter\n' >&2
      exit 66
    fi
    if [[ " $* " == *" resume "* ]]; then
      write_done "Codex resume backpressure fixture 완료"
      printf '{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}\n'
      printf '{"type":"turn.started"}\n'
      changes=''
      for index in $(seq 1 160); do
        path="/workspace/.agents/skills/issue-20/$(printf '%080d' "$index")/fixture-$index.md"
        if [[ -n "$changes" ]]; then
          changes+=','
        fi
        changes+="{\"path\":\"$path\",\"kind\":\"update\"}"
        printf '{"type":"item.started","item":{"id":"item_%s","type":"file_change","changes":[%s],"status":"in_progress"}}\n' "$index" "$changes"
        printf '{"type":"item.completed","item":{"id":"item_%s","type":"file_change","changes":[%s],"status":"completed"}}\n' "$index" "$changes"
      done
      printf '{"type":"item.completed","item":{"id":"item_final","type":"agent_message","text":"resume complete"}}\n'
      printf '{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":10,"output_tokens":8}}\n'
    else
      printf '{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}\n'
      printf '{"type":"turn.started"}\n'
      printf '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"fresh backpressure fixture"}}\n'
      printf '{"type":"item.started","item":{"id":"item_1","type":"file_change","changes":[{"path":"/workspace/sample.txt","kind":"add"}],"status":"in_progress"}}\n'
      printf '{"type":"item.completed","item":{"id":"item_1","type":"file_change","changes":[{"path":"/workspace/sample.txt","kind":"add"}],"status":"completed"}}\n'
      write_question "native resume backpressure를 재현할까요?"
    fi
    ;;
  YARD-CODEX-TAIL)
    if [[ "$native_adapter" != true ]]; then
      printf 'codex tail fixture requires the codex adapter\n' >&2
      exit 66
    fi
    write_done "Codex unsaturated tail fixture 완료"
    printf '{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}\n'
    for index in $(seq 1 64); do
      printf '{"type":"item.completed","item":{"id":"tail_%s","type":"agent_message","text":"canonical tail %s"}}\n' "$index" "$index"
    done
    ;;
  YARD-REDIRECT)
    if grep -q 'Explicit continuation packet' <<<"$packet"; then
      printf 'redirected worker public completion\n'
      printf 'redirected worker diagnostic completion\n' >&2
      write_done "redirect guidance 완료"
    else
      printf 'running worker public progress\n'
      printf 'running worker diagnostic progress\n' >&2
      write_handoff "checkpoint before redirect"
      child_pid=''
      trap '[[ -z "$child_pid" ]] || kill "$child_pid" 2>/dev/null || true; exit 143' TERM INT
      while true; do
        sleep 30 &
        child_pid=$!
        wait "$child_pid"
      done
    fi
    ;;
  YARD-INDEX)
    if grep -q '> \[user\] A' <<<"$packet"; then
      printf 'index continuation stdout\n'
      printf 'index continuation stderr\n' >&2
      write_done "bounded index rebuild 완료"
    else
      for index in $(seq 1 140); do
        printf 'index public progress %03d\n' "$index"
      done
      printf 'index diagnostic stream\n' >&2
      write_question "index rebuild를 계속할까요?"
    fi
    ;;
  YARD-LIVE)
    printf '{"type":"item.started","item":{"type":"command_execution","command":"printf live"}}\n'
    printf '{"type":"item.completed","item":{"type":"reasoning","text":"private fixture reasoning"}}\n'
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"live public message"}}\n'
    printf '{"type":"item.completed","item":{"type":"command_execution","command":"printf live","exit_code":0}}\n'
    sleep 3
    printf 'live worker artifact\n' >live-worker-artifact.txt
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "changes": {"files_created": ["live-worker-artifact.txt"]},\n  "compact_summary": "live event and artifact fixture complete"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    write_handoff "live event and artifact fixture complete"
    ;;
  YARD-AUTH-FALLBACK)
    # Writes result.json but intentionally no handoff.md, so the evaluator
    # fallback authors the handoff and the artifact must record that.
    printf 'fallback authorship fixture stdout\n'
    printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "%s",\n  "status": "done",\n  "compact_summary": "handoff 없이 완료된 fallback authorship fixture"\n}\n' \
      "$run_id" "$task_id" >"$run_dir/result.json"
    ;;
  YARD-REDIRECT-QUESTION)
    if grep -q '> \[user\] resolve current question' <<<"$packet"; then
      printf 'current question resolved\n'
      write_done "redirected current question resolved"
    elif grep -q '> \[user\] ask a current question' <<<"$packet"; then
      printf 'redirected question context\n'
      write_question "current question after redirect"
    elif grep -q '> \[user\] stale answer' <<<"$packet"; then
      printf 'stale question was incorrectly resumed\n'
      write_done "stale question incorrectly resumed"
    else
      printf 'superseded question context\n'
      write_question "question that redirect will supersede"
    fi
    ;;
  YARD-FALLBACK)
    if grep -q 'Explicit continuation packet' <<<"$packet"; then
      printf 'fallback worker explicit continuation\n'
      write_done "fallback worker completed explicit continuation"
    else
      printf 'producer worker question context\n'
      write_question "continue with a fallback worker?"
    fi
    ;;
  *)
    printf 'unexpected fixture task: %s\n' "$task_id" >&2
    exit 64
    ;;
esac
