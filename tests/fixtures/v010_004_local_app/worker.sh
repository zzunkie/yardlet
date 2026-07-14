#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'v010-004-local-app-fixture 1.0\n'
  exit 0
fi

run_dir="${1:?run directory is required}"
app_script="${2:?local app script is required}"
capture_script="${3:?browser capture script is required}"
packet="$(cat)"
task_id="$(sed -n 's/^# Yardlet task packet: //p' <<<"$packet" | head -n 1)"
run_id="${run_dir##*/}"
python_bin="$(command -v python3)"

if [[ "$task_id" != "YARD-LOCAL-APP" ]]; then
  printf 'unexpected task %s\n' "$task_id" >&2
  exit 64
fi

fnv_digest() {
  local file="$1" byte
  local hash=$((0xcbf29ce484222325))
  for byte in $(od -An -tu1 "$file"); do
    hash=$(((hash ^ byte) * 1099511628211))
  done
  printf 'fnv1a64:%016x' "$hash"
}

process_identity() {
  ps -o lstart= -p "$1" | xargs
}

port="$(tr -d '[:space:]' <fixture-port.txt)"
url="http://127.0.0.1:${port}/"
health_url="http://127.0.0.1:${port}/health"
external_meta="$(cat external-sentinel.meta)"
external_pid="${external_meta%%|*}"
external_identity="${external_meta#*|}"
external_identity="${external_identity%$'\n'}"
app_pid=''
app_identity=''
published=0

cleanup_failed_publication() {
  if [[ "$published" -eq 0 && -n "$app_pid" ]]; then
    if [[ "$(process_identity "$app_pid" 2>/dev/null || true)" == "$app_identity" ]]; then
      kill "$app_pid" 2>/dev/null || true
    fi
  fi
}
trap cleanup_failed_publication EXIT

nohup "$python_bin" "$app_script" --port "$port" \
  </dev/null >"$run_dir/local-app.stdout.log" 2>"$run_dir/local-app.stderr.log" &
app_pid=$!
service_ready=0
for _ in $(seq 1 100); do
  app_identity="$(process_identity "$app_pid" 2>/dev/null || true)"
  if [[ -n "$app_identity" ]] && "$python_bin" - "$health_url" <<'PY' >/dev/null 2>&1
import sys
from urllib.request import urlopen

with urlopen(sys.argv[1], timeout=0.2) as response:
    assert response.status == 200
PY
  then
    service_ready=1
    break
  fi
  sleep 0.02
done
if [[ -z "$app_identity" || "$service_ready" -ne 1 ]]; then
  printf 'local app did not become probeable\n' >&2
  exit 1
fi

printf 'state=after\n' >app-state.txt
git diff -- app-state.txt >local-app.diff

browser_meta="$run_dir/local-browser.json"
"$python_bin" "$capture_script" "$url" local-app-screenshot.png "$browser_meta"
browser_pid="$("$python_bin" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$browser_meta")"
browser_identity="$("$python_bin" -c 'import json,sys; print(json.load(open(sys.argv[1]))["start_identity"])' "$browser_meta")"

"$python_bin" - "$url" "$health_url" >local-app-validation.json <<'PY'
import json
import sys
from urllib.request import urlopen

with urlopen(sys.argv[1], timeout=1) as response:
    page = response.read().decode()
    page_status = response.status
with urlopen(sys.argv[2], timeout=1) as response:
    health = json.loads(response.read())
    health_status = response.status
assert page_status == 200
assert health_status == 200
assert "yardlet-local-app" in page
assert health == {"status": "ok", "marker": "yardlet-local-app"}
print(json.dumps({"page_status": page_status, "health_status": health_status, "marker": health["marker"]}))
PY

terminal_identity="$(process_identity $$)"
screenshot_digest="$(fnv_digest local-app-screenshot.png)"
diff_digest="$(fnv_digest local-app.diff)"
validation_digest="$(fnv_digest local-app-validation.json)"

cat >"$run_dir/handoff.md" <<'EOF'
# Local app fixture handoff

실제 localhost app, headless browser screenshot, diff, validation evidence를 게시했다.
EOF

cat >"$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {
    "files_modified": ["app-state.txt"],
    "files_created": ["local-app-screenshot.png", "local-app.diff", "local-app-validation.json"],
    "files_deleted": []
  },
  "validation": {
    "commands_run": ["headless Chromium screenshot", "localhost page and health probe"],
    "passed": true,
    "failures": []
  },
  "question_for_user": null,
  "compact_summary": "실제 local app resource와 retained browser evidence를 게시했다.",
  "artifacts": [
    {"proposal_id":"local-screenshot","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","path":"local-app-screenshot.png","digest":"$screenshot_digest","media_type":"image/png","role":"screenshot"},
    {"proposal_id":"local-diff","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","path":"local-app.diff","digest":"$diff_digest","media_type":"text/x-diff","role":"git_diff"},
    {"proposal_id":"local-validation","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","path":"local-app-validation.json","digest":"$validation_digest","media_type":"application/json","role":"validation_output"}
  ],
  "resources": [
    {"proposal_id":"local-terminal","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"terminal","terminal_id":"local-app-worker-terminal","pid":$$,"start_identity":"$terminal_identity","attach_hint":"worker process terminal"}},
    {"proposal_id":"local-process","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"process","pid":$app_pid,"start_identity":"$app_identity","command":["$python_bin","$app_script","--port","$port"]}},
    {"proposal_id":"local-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"service","url":"$url","health_url":"$health_url"}},
    {"proposal_id":"local-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","target":{"kind":"browser","url":"$url","session_id":"local-browser-$browser_pid","pid":$browser_pid,"start_identity":"$browser_identity"}},
    {"proposal_id":"local-external","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"external","target":{"kind":"process","pid":$external_pid,"start_identity":"$external_identity","command":["/bin/sleep","120"]}}
  ],
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF

published=1
