#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'v010-004-resource-fixture 1.0\n'
  exit 0
fi

run_dir="${1:?run directory is required}"
packet="$(cat)"
task_id="$(sed -n 's/^# Yardlet task packet: //p' <<<"$packet" | head -n 1)"
run_id="${run_dir##*/}"

fnv_digest() {
  local file="$1" byte
  local hash=$((0xcbf29ce484222325))
  for byte in $(od -An -tu1 "$file"); do
    hash=$(((hash ^ byte) * 1099511628211))
  done
  printf 'fnv1a64:%016x' "$hash"
}

write_handoff() {
  printf '# Fixture handoff\n' >"$run_dir/handoff.md"
}

case "$task_id" in
  YARD-OPS)
    start_child() {
      /bin/sleep 90 </dev/null >/dev/null 2>&1 &
      local pid=$!
      local identity
      identity="$(ps -o lstart= -p "$pid" | xargs)"
      printf '%s|%s\n' "$pid" "$identity"
    }
    stop_child="$(start_child)"
    restart_child="$(start_child)"
    cleanup_child="$(start_child)"
    detach_child="$(start_child)"
    external_child="$(start_child)"
    dead_child="$(start_child)"
    stop_pid="${stop_child%%|*}"; stop_identity="${stop_child#*|}"
    restart_pid="${restart_child%%|*}"; restart_identity="${restart_child#*|}"
    cleanup_pid="${cleanup_child%%|*}"; cleanup_identity="${cleanup_child#*|}"
    detach_pid="${detach_child%%|*}"; detach_identity="${detach_child#*|}"
    external_pid="${external_child%%|*}"; external_identity="${external_child#*|}"
    dead_pid="${dead_child%%|*}"; dead_identity="${dead_child#*|}"
    kill "$dead_pid"
    wait "$dead_pid" 2>/dev/null || true
    printf '%s\n' "$stop_pid" "$restart_pid" "$cleanup_pid" "$detach_pid" "$external_pid" >ops-pids.txt
    printf 'open me\n' >ops-file.txt
    file_digest="$(fnv_digest ops-file.txt)"
    write_handoff
    cat >"$run_dir/result.json" <<EOF
{
  "schema_version":1,"run_id":"$run_id","task_id":"$task_id","status":"done",
  "changes":{"files_created":["ops-pids.txt","ops-file.txt"]},
  "validation":{"commands_run":[],"passed":true,"failures":[]},
  "compact_summary":"resource operation fixture",
  "artifacts":[
    {"proposal_id":"ops-file","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"ops-file.txt","digest":"$file_digest","media_type":"text/plain","role":"file"}
  ],
  "resources":[
    {"proposal_id":"ops-stop","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"process","pid":$stop_pid,"start_identity":"$stop_identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-restart","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"yardlet","target":{"kind":"process","pid":$restart_pid,"start_identity":"$restart_identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-cleanup","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"yardlet","target":{"kind":"process","pid":$cleanup_pid,"start_identity":"$cleanup_identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-detach","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"terminal","terminal_id":"ops-terminal","pid":$detach_pid,"start_identity":"$detach_identity","attach_hint":"fixture attach"}},
    {"proposal_id":"ops-external","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"external","target":{"kind":"process","pid":$external_pid,"start_identity":"$external_identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-unknown","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"unknown","target":{"kind":"process","pid":$external_pid,"start_identity":"$external_identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-mismatch","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"process","pid":$external_pid,"start_identity":"forged-start-identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-dead","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"process","pid":$dead_pid,"start_identity":"$dead_identity","command":["/bin/sleep","90"]}},
    {"proposal_id":"ops-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"service","url":"http://127.0.0.1:9/health"}},
    {"proposal_id":"ops-unrecoverable","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"service","url":"not-a-url"}},
    {"proposal_id":"ops-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"browser","url":"http://127.0.0.1:9/","session_id":"expired-browser"}}
  ]
}
EOF
    ;;
  YARD-001)
    printf 'file artifact\n' >artifact-file.txt
    printf 'screenshot bytes\n' >artifact-screenshot.png
    printf 'diff --git a/a b/a\n' >artifact.diff
    printf 'validation passed\n' >artifact-validation.log
    printf '{"verdict":"pass"}\n' >artifact-review.json
    printf '# durable handoff\n' >artifact-handoff.md

    terminal_identity="$(ps -o lstart= -p $$ | xargs)"
    file_digest="$(fnv_digest artifact-file.txt)"
    screenshot_digest="$(fnv_digest artifact-screenshot.png)"
    diff_digest="$(fnv_digest artifact.diff)"
    validation_digest="$(fnv_digest artifact-validation.log)"
    review_digest="$(fnv_digest artifact-review.json)"
    handoff_digest="$(fnv_digest artifact-handoff.md)"

    write_handoff
    cat >"$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "changes": {"files_created": ["artifact-file.txt", "artifact-screenshot.png", "artifact.diff", "artifact-validation.log", "artifact-review.json", "artifact-handoff.md"]},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "compact_summary": "typed resource publication fixture",
  "artifacts": [
    {"proposal_id":"proposal-file","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact-file.txt","digest":"$file_digest","media_type":"text/plain","role":"file"},
    {"proposal_id":"proposal-file","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact-file.txt","digest":"$file_digest","media_type":"text/plain","role":"file"},
    {"proposal_id":"proposal-screenshot","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact-screenshot.png","digest":"$screenshot_digest","media_type":"image/png","role":"screenshot"},
    {"proposal_id":"proposal-diff","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact.diff","digest":"$diff_digest","media_type":"text/x-diff","role":"git_diff"},
    {"proposal_id":"proposal-validation","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact-validation.log","digest":"$validation_digest","media_type":"text/plain","role":"validation_output"},
    {"proposal_id":"proposal-review","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact-review.json","digest":"$review_digest","media_type":"application/json","role":"review_report"},
    {"proposal_id":"proposal-handoff","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"artifact-handoff.md","digest":"$handoff_digest","media_type":"text/markdown","role":"handoff"}
  ],
  "resources": [
    {"proposal_id":"proposal-terminal","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"terminal","terminal_id":"fixture-terminal","pid":$$,"start_identity":"$terminal_identity"}},
    {"proposal_id":"proposal-process","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"process","pid":$$,"start_identity":"$terminal_identity","command":["fixture-worker"]}},
    {"proposal_id":"proposal-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"service","url":"http://127.0.0.1:9/health"}},
    {"proposal_id":"proposal-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"browser","url":"http://127.0.0.1:9/","session_id":"fixture-browser"}}
  ]
}
EOF
    ;;
  YARD-CAP)
    mkdir -p cap-artifacts
    artifacts=''
    changes=''
    for index in $(seq -w 1 140); do
      path="cap-artifacts/$index.txt"
      printf 'artifact %s\n' "$index" >"$path"
      digest="$(fnv_digest "$path")"
      [[ -z "$artifacts" ]] || artifacts+=','
      [[ -z "$changes" ]] || changes+=','
      artifacts+="{\"proposal_id\":\"cap-$index\",\"task_id\":\"$task_id\",\"attempt_id\":\"$run_id\",\"producer\":{\"worker_id\":\"fixture\"},\"causation_id\":\"$run_id\",\"path\":\"$path\",\"digest\":\"$digest\",\"media_type\":\"text/plain\",\"role\":\"file\"}"
      changes+="\"$path\""
    done
    write_handoff
    cat >"$run_dir/result.json" <<EOF
{"schema_version":1,"run_id":"$run_id","task_id":"$task_id","status":"done","changes":{"files_created":[$changes]},"validation":{"commands_run":[],"passed":true,"failures":[]},"compact_summary":"bounded artifact fixture","artifacts":[$artifacts]}
EOF
    ;;
  YARD-CAUSE)
    printf 'forged causation\n' >forged-causation.txt
    digest="$(fnv_digest forged-causation.txt)"
    write_handoff
    cat >"$run_dir/result.json" <<EOF
{"schema_version":1,"run_id":"$run_id","task_id":"$task_id","status":"done","changes":{"files_created":["forged-causation.txt"]},"validation":{"commands_run":[],"passed":true,"failures":[]},"compact_summary":"must reject forged causation","artifacts":[{"proposal_id":"forged-cause","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"fixture"},"causation_id":"evt-from-another-attempt","path":"forged-causation.txt","digest":"$digest","media_type":"text/plain","role":"file"}]}
EOF
    ;;
  YARD-BAD)
    printf 'unowned evidence\n' >unowned.txt
    digest="$(fnv_digest unowned.txt)"
    write_handoff
    cat >"$run_dir/result.json" <<EOF
{"schema_version":1,"run_id":"$run_id","task_id":"$task_id","status":"done","changes":{"files_created":["unowned.txt"]},"validation":{"commands_run":[],"passed":true,"failures":[]},"compact_summary":"must not complete","artifacts":[{"proposal_id":"bad","task_id":"$task_id","attempt_id":"","producer":{"worker_id":"fixture"},"causation_id":"$run_id","path":"unowned.txt","digest":"$digest","media_type":"text/plain","role":"file"}]}
EOF
    ;;
  *)
    printf 'unexpected task %s\n' "$task_id" >&2
    exit 64
    ;;
esac
