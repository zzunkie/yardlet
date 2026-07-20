#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "${1:-}" == "--version" ]]; then
  printf 'yardlet-capability-fixture-worker 1.0\n'
  exit 0
fi

run_dir="${1:?worker requires run directory}"
access="${!#}"
packet="$(cat)"
if grep -q '^# Yardlet queue-isolated capability scout' <<<"$packet"; then
  printf 'worker-executable=%s worker-cwd=%s worker-args=%s\n' "$0" "$(pwd)" "$*"
  printf '%s\n' "$packet" | "$SCRIPT_DIR/scout-worker.sh" "$run_dir" "$access"
else
  printf '%s\n' "$packet" | "$SCRIPT_DIR/planner-worker.sh" "$run_dir"
fi
