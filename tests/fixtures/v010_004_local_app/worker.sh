#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'v010-004-local-app-fixture 1.0\n'
  exit 0
fi

run_dir="${1:?run directory is required}"
app_script="${2:?local app script is required}"
capture_script="${3:?browser capture script is required}"
restart_script="$(dirname "$0")/restart_app.sh"
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
unhealthy_url="http://127.0.0.1:${port}/unhealthy"
browser_session_url="http://127.0.0.1:${port}/browser/session"
external_meta="$(cat external-sentinel.meta)"
external_pid="${external_meta%%|*}"
external_identity="${external_meta#*|}"
external_identity="${external_identity%$'\n'}"
app_pid=''
app_identity=''
restart_healthy_pid=''
restart_healthy_identity=''
restart_unhealthy_pid=''
restart_unhealthy_identity=''
published=0

cleanup_failed_publication() {
  if [[ "$published" -eq 0 ]]; then
    local pair pid identity
    for pair in \
      "$app_pid|$app_identity" \
      "$restart_healthy_pid|$restart_healthy_identity" \
      "$restart_unhealthy_pid|$restart_unhealthy_identity"
    do
      pid="${pair%%|*}"
      identity="${pair#*|}"
      if [[ -n "$pid" && "$(process_identity "$pid" 2>/dev/null || true)" == "$identity" ]]; then
        kill "$pid" 2>/dev/null || true
      fi
    done
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

restart_healthy_port="$(tr -d '[:space:]' <fixture-restart-healthy-port.txt)"
restart_unhealthy_port="$(tr -d '[:space:]' <fixture-restart-unhealthy-port.txt)"
restart_healthy_url="http://127.0.0.1:${restart_healthy_port}/health"
restart_unhealthy_url="http://127.0.0.1:${restart_unhealthy_port}/unhealthy"

nohup "$python_bin" "$app_script" --port "$restart_healthy_port" \
  </dev/null >"$run_dir/restart-healthy.stdout.log" 2>"$run_dir/restart-healthy.stderr.log" &
restart_healthy_pid=$!
nohup "$python_bin" "$app_script" --port "$restart_unhealthy_port" \
  </dev/null >"$run_dir/restart-unhealthy.stdout.log" 2>"$run_dir/restart-unhealthy.stderr.log" &
restart_unhealthy_pid=$!

for _ in $(seq 1 100); do
  restart_healthy_identity="$(process_identity "$restart_healthy_pid" 2>/dev/null || true)"
  restart_unhealthy_identity="$(process_identity "$restart_unhealthy_pid" 2>/dev/null || true)"
  healthy_ready=0
  unhealthy_ready=0
  if [[ -n "$restart_healthy_identity" ]] && "$python_bin" - "http://127.0.0.1:${restart_healthy_port}/health" <<'PY' >/dev/null 2>&1
import sys
from urllib.request import urlopen
with urlopen(sys.argv[1], timeout=0.2) as response:
    assert response.status == 200
PY
  then healthy_ready=1; fi
  if [[ -n "$restart_unhealthy_identity" ]] && "$python_bin" - "http://127.0.0.1:${restart_unhealthy_port}/health" <<'PY' >/dev/null 2>&1
import sys
from urllib.request import urlopen
with urlopen(sys.argv[1], timeout=0.2) as response:
    assert response.status == 200
PY
  then unhealthy_ready=1; fi
  if [[ "$healthy_ready" -eq 1 && "$unhealthy_ready" -eq 1 ]]; then break; fi
  sleep 0.02
done
if [[ "${healthy_ready:-0}" -ne 1 || "${unhealthy_ready:-0}" -ne 1 ]]; then
  printf 'restart service fixtures did not become probeable\n' >&2
  exit 1
fi

printf 'state=after\n' >app-state.txt
git diff -- app-state.txt >local-app.diff

browser_meta="$run_dir/local-browser.json"
if ! "$python_bin" "$capture_script" "$url" local-app-screenshot.png "$browser_meta"; then
  printf 'browser capture failed\n' >&2
  printf 'executable: ' >&2
  command -v chromium chromium-browser google-chrome google-chrome-stable 2>/dev/null >&2 || true
  printf 'versions:\n' >&2
  for browser in chromium chromium-browser google-chrome google-chrome-stable; do
    if command -v "$browser" >/dev/null 2>&1; then
      "$browser" --version >&2 || true
    fi
  done
  if [[ -f "${browser_meta%.json}.stderr.log" ]]; then
    printf 'browser stderr:\n' >&2
    tail -n 100 "${browser_meta%.json}.stderr.log" >&2
  fi
  exit 1
fi
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
    {"proposal_id":"local-terminal","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","attach","detach","reconcile"],"target":{"kind":"terminal","terminal_id":"local-app-worker-terminal","pid":$$,"start_identity":"$terminal_identity","attach_hint":"worker process terminal"}},
    {"proposal_id":"local-process","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","attach","stop","restart","cleanup","reconcile"],"target":{"kind":"process","pid":$app_pid,"start_identity":"$app_identity","command":["$python_bin","$app_script","--port","$port"]}},
    {"proposal_id":"local-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","reconcile"],"target":{"kind":"service","url":"$url","health_url":"$health_url"}},
    {"proposal_id":"local-unhealthy-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","reconcile"],"target":{"kind":"service","url":"$url","health_url":"$unhealthy_url"}},
    {"proposal_id":"local-restart-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"yardlet","capabilities":["open","restart","cleanup","reconcile"],"target":{"kind":"service","url":"$restart_healthy_url","health_url":"$restart_healthy_url","pid":$restart_healthy_pid,"start_identity":"$restart_healthy_identity","restart_command":["$restart_script","$python_bin","$app_script","$restart_healthy_port","${app_script}.restart-healthy"]}},
    {"proposal_id":"local-unhealthy-restart-service","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"yardlet","capabilities":["open","restart","cleanup","reconcile"],"target":{"kind":"service","url":"http://127.0.0.1:${restart_unhealthy_port}/","health_url":"$restart_unhealthy_url","pid":$restart_unhealthy_pid,"start_identity":"$restart_unhealthy_identity","restart_command":["$restart_script","$python_bin","$app_script","$restart_unhealthy_port","${app_script}.restart-unhealthy"]}},
    {"proposal_id":"local-open-only-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open"],"target":{"kind":"browser","url":"$url","session_id":"local-open-only-browser"}},
    {"proposal_id":"local-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","reconcile"],"target":{"kind":"browser","url":"$url","session_id":"local-browser-$browser_pid","pid":$browser_pid,"start_identity":"$browser_identity"}},
    {"proposal_id":"local-live-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","reconcile"],"target":{"kind":"browser","url":"$url","session_id":"local-active-browser-session","session_probe_url":"$browser_session_url","pid":$app_pid,"start_identity":"$app_identity"}},
    {"proposal_id":"local-stale-browser","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"worker","capabilities":["open","reconcile"],"target":{"kind":"browser","url":"$url","session_id":"local-stale-browser-session","session_probe_url":"$browser_session_url","pid":$app_pid,"start_identity":"$app_identity"}},
    {"proposal_id":"local-external","task_id":"$task_id","attempt_id":"$run_id","producer":{"worker_id":"local-app-fixture"},"causation_id":"$run_id","ownership":"external","capabilities":["open","attach","stop","cleanup","reconcile"],"target":{"kind":"process","pid":$external_pid,"start_identity":"$external_identity","command":["/bin/sleep","120"]}}
  ],
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF

published=1
