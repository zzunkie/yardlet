#!/bin/sh
# Fake generic worker for the prompt-transport fixture matrix.
#
# Every mode writes its evidence INTO the run directory it was handed, because
# the worker environment is sanitized: nothing the test exports would survive to
# this process. Modes:
#
#   probe                 offline readiness probe (version_args)
#   stdin | file          fresh attempt that asks a question and emits a session
#                         ref; the packet arrives on stdin or in a file
#   stdin-resume |
#   file-resume           native resume that completes the task
#   ignored-stdin         declares stdin transport but closes stdin unread
#   broken-result         exits 0 after writing an unparseable result.json
set -eu

mode="${1:-}"

if [ "$mode" = probe ]; then
  printf 'transport-matrix-worker 1.0\n'
  exit 0
fi

run_dir="${2:-}"
run_id="$(basename "$run_dir")"
session_ref=''

case "$mode" in
  stdin)
    cat > "$run_dir/seen-packet-body"
    ;;
  file)
    packet_file="${3:-}"
    printf '%s' "$packet_file" > "$run_dir/seen-packet-path"
    cp "$packet_file" "$run_dir/seen-packet-body"
    cat > "$run_dir/seen-stdin"
    ;;
  stdin-resume)
    session_ref="${3:-}"
    cat > "$run_dir/seen-resume-packet-body"
    ;;
  file-resume)
    packet_file="${3:-}"
    session_ref="${4:-}"
    printf '%s' "$packet_file" > "$run_dir/seen-resume-packet-path"
    cp "$packet_file" "$run_dir/seen-resume-packet-body"
    cat > "$run_dir/seen-resume-stdin"
    ;;
  ignored-stdin)
    # Close the inherited read end without draining it, so the orchestrator's
    # best-effort packet write fails with EPIPE instead of being consumed.
    exec 0<&-
    ;;
  broken-result)
    ;;
  *)
    printf 'unknown fixture mode: %s\n' "$mode" >&2
    exit 64
    ;;
esac

case "$mode" in
  stdin | file)
    printf 'SESSION_REF=transport-matrix session\n'
    cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "needs_user",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": "Continue in the same transport-matrix session?",
  "compact_summary": "transport matrix fixture needs an answer",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
    printf '# Transport matrix question\n' > "$run_dir/handoff.md"
    ;;
  stdin-resume | file-resume)
    if [ "$session_ref" != 'transport-matrix session' ]; then
      printf 'wrong session ref: %s\n' "$session_ref" >&2
      exit 64
    fi
    cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "transport matrix native resume complete",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
    printf '# Transport matrix resumed\n' > "$run_dir/handoff.md"
    ;;
  ignored-stdin)
    cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "transport matrix ignored stdin and still delivered files",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
    printf '# Transport matrix ignored stdin\n' > "$run_dir/handoff.md"
    ;;
  broken-result)
    printf 'transport matrix broken-result stdout\n'
    printf 'transport matrix broken-result stderr\n' >&2
    # Exit 0 with a truncated object: a worker claiming success it cannot prove.
    printf '{"schema_version": 1, "run_id": "%s", "status": "done"' "$run_id" \
      > "$run_dir/result.json"
    printf '# Transport matrix broken result\n' > "$run_dir/handoff.md"
    ;;
esac

exit 0
