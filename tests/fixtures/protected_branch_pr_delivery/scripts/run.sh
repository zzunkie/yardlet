#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <yardlet-bin> <evidence-dir>" >&2
  exit 64
fi

YARDLET_BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EVIDENCE_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_GIT="$(command -v git)"
PYTHON="$(command -v python3)"
SAFE_SYSTEM_PATH="/usr/bin:/bin"

mkdir -p "$EVIDENCE_DIR"
ROOT="$(mktemp -d "$EVIDENCE_DIR/fixture.XXXXXX")"
STERILE_HOME="$ROOT/sterile-home"
mkdir -p "$STERILE_HOME/.config"
: >"$STERILE_HOME/global.gitconfig"
: >"$STERILE_HOME/system.gitconfig"
export HOME="$STERILE_HOME"
export XDG_CONFIG_HOME="$STERILE_HOME/.config"
export GIT_CONFIG_GLOBAL="$STERILE_HOME/global.gitconfig"
export GIT_CONFIG_SYSTEM="$STERILE_HOME/system.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GH_HOST=ambient.invalid
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

WRAPPER_DIR="$ROOT/wrapper-bin"
NO_GH_DIR="$ROOT/no-gh-bin"
mkdir -p "$WRAPPER_DIR" "$NO_GH_DIR"
cp "$SCRIPT_DIR/git-wrapper.sh" "$WRAPPER_DIR/git"
cp "$SCRIPT_DIR/fake-gh.sh" "$WRAPPER_DIR/gh"
cp "$SCRIPT_DIR/worker-sentinel.sh" "$WRAPPER_DIR/worker-sentinel"
cp "$SCRIPT_DIR/git-wrapper.sh" "$NO_GH_DIR/git"
cp "$SCRIPT_DIR/worker-sentinel.sh" "$NO_GH_DIR/worker-sentinel"
chmod +x "$WRAPPER_DIR/git" "$WRAPPER_DIR/gh" "$WRAPPER_DIR/worker-sentinel"
chmod +x "$NO_GH_DIR/git" "$NO_GH_DIR/worker-sentinel"

fail() {
  printf 'fixture failure: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1': $3"
}

wait_for_file() {
  local path="$1"
  local label="$2"
  local i
  for i in $(seq 1 400); do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  fail "timed out waiting for $label ($path)"
}

ACTIVE_GROUP_PID=""
terminate_active_process_group() {
  local pgid="${ACTIVE_GROUP_PID:-}"
  local i
  ACTIVE_GROUP_PID=""
  [[ -n "$pgid" ]] || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
  for i in $(seq 1 100); do
    ! kill -0 -- "-$pgid" 2>/dev/null && return 0
    sleep 0.05
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
  ! kill -0 -- "-$pgid" 2>/dev/null || fail "process group $pgid still alive"
}
trap terminate_active_process_group EXIT

json_field() {
  "$PYTHON" - "$1" "$2" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
print(str(value).lower() if isinstance(value, bool) else value)
PY
}

yaml_task_state() {
  awk '/^[[:space:]]+state: / { print $2; exit }' "$1"
}

yaml_run_state() {
  awk '/^state: / { print $2; exit }' "$1"
}

remote_oid() {
  "$REAL_GIT" ls-remote --refs "$1" "$2" | awk 'NR == 1 { print $1 }'
}

head_oid() {
  "$REAL_GIT" -C "$1" rev-parse HEAD
}

write_config() {
  local ws="$1"
  local remote="${2:-origin}"
  cat >"$ws/.agents/yardlet.yaml" <<EOF
schema_version: 1
product: protected-branch-fixture
workspace_id: fixture
created_at: 2099-01-01T00:00:00Z
state_dir: .agents
default_interface: tui
canonical_queue: .agents/work-queue.yaml
current_intent: .agents/intent-contract.yaml
language: ko
default_access: sandboxed
max_parallel: 1
auto_ime: false
ambiguity_gate: false
harness_discovery: false
skill_library: ""
auto_equip: false
auto_skill: false
auto_rule: false
auto_prune: false
hooks: false
auto_commit: false
git_finish:
  auto_push: true
  delivery: auto
  remote: $remote
  target_ref: refs/heads/main
  pre_push_checks:
    - name: fixture-check
      command: 'printf "check\n" >> "\$YARDLET_FIXTURE_CHECK_LOG"'
EOF
}

write_state() {
  local ws="$1"
  cat >"$ws/.agents/intent-contract.yaml" <<'EOF'
schema_version: 1
id: intent-protected-branch-fixture
source: fixture
summary: protected branch PR delivery process proof
acceptance:
  - exact OID delivery converges
status: accepted
EOF
  cat >"$ws/.agents/work-queue.yaml" <<'EOF'
schema_version: 1
queue_id: queue-protected-branch-fixture
intent_id: intent-protected-branch-fixture
selection_policy:
  default_order: priority_then_created_at
  require_planning_gate: true
  skip_if_blocked: true
  skip_if_approval_required: true
tasks:
  - id: YARD-001
    title: protected branch fixture task
    state: partial
    priority: 10
    risk: high
    kind: implementation
EOF
  cat >"$ws/.agents/workers.yaml" <<EOF
schema_version: 1
workers:
  - id: fixture-worker
    kind: cli_worker
    billing:
      mode: subscription_backed_only
    invocation:
      command: $WRAPPER_DIR/worker-sentinel
      supports_noninteractive: true
      output_contract: files
routing:
  default_worker: fixture-worker
  fallback_order: [fixture-worker]
  planning_gate:
    primary: fixture-worker
    fallback: fixture-worker
EOF
}

write_integrated_run() {
  local ws="$1"
  local baseline="$2"
  local expected="$3"
  local run_id="run-20990101-000001-YARD-001"
  local run_dir="$ws/.agents/runs/$run_id"
  local worker_oid canonical_ws
  canonical_ws="$(cd "$ws" && pwd -P)"
  worker_oid="$("$REAL_GIT" -C "$ws" rev-parse "$expected^2")"
  mkdir -p "$run_dir" "$ws/.agents/checkpoints/integrated-cleanup"
  cat >"$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "fixture integration",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
  printf '# Fixture handoff\n' >"$run_dir/handoff.md"
  cat >"$run_dir/run.yaml" <<EOF
schema_version: 1
run_id: $run_id
task_id: YARD-001
intent_id: intent-protected-branch-fixture
worker: fixture-worker
state: partial
started_at: 2099-01-01T00:00:01Z
completed_at: 2099-01-01T00:00:02Z
worktree: .
integration_oid: $expected
integration_base_oid: $baseline
integration_worker_oid: $worker_oid
integration_provenance: parallel_worker_direct
owned_oids:
  - $worker_oid
  - $expected
EOF
  cat >"$ws/.agents/checkpoints/integrated-cleanup/$run_id.yaml" <<EOF
schema_version: 1
run_id: $run_id
task_id: YARD-001
intent_id: intent-protected-branch-fixture
worker: fixture-worker
worktree: $canonical_ws/.agents/worktrees/$run_id
branch: yard/yard-001/$run_id
baseline_oid: $baseline
integration_base_oid: $baseline
integration_worker_oid: $worker_oid
integration_oid: $expected
provenance: parallel_worker_direct
owned_oids:
  - $worker_oid
  - $expected
EOF
}

commit_owned() {
  local ws="$1"
  local label="$2"
  local baseline tree worker_oid merge_oid
  baseline="$(head_oid "$ws")"
  printf '%s\n' "$label" >"$ws/owned.txt"
  "$REAL_GIT" -C "$ws" add owned.txt
  tree="$("$REAL_GIT" -C "$ws" write-tree)"
  worker_oid="$(printf '%s worker\n' "$label" | "$REAL_GIT" -C "$ws" commit-tree "$tree" -p "$baseline")"
  merge_oid="$(printf '%s integration\n' "$label" | "$REAL_GIT" -C "$ws" commit-tree "$tree" -p "$baseline" -p "$worker_oid")"
  "$REAL_GIT" -C "$ws" update-ref refs/heads/main "$merge_oid" "$baseline"
  "$REAL_GIT" -C "$ws" reset -q --hard "$merge_oid"
  printf '%s\n' "$merge_oid"
}

new_workspace() {
  local name="$1"
  local github_host="${2:-github.com}"
  local scenario="$ROOT/$name"
  local seed="$scenario/seed"
  local remote="$scenario/remote.git"
  local ws="$scenario/clone"
  local raw_url="https://$github_host/fixture-owner/fixture-repo.git"
  mkdir -p "$seed"
  "$REAL_GIT" -C "$seed" init -q -b main
  "$REAL_GIT" -C "$seed" config user.name "Yardlet Fixture"
  "$REAL_GIT" -C "$seed" config user.email "fixture@example.test"
  printf 'baseline\n' >"$seed/owned.txt"
  "$REAL_GIT" -C "$seed" add owned.txt
  "$REAL_GIT" -C "$seed" commit -q -m baseline
  "$REAL_GIT" init -q --bare "$remote"
  "$REAL_GIT" -C "$seed" remote add fixture "$remote"
  "$REAL_GIT" -C "$seed" push -q fixture HEAD:refs/heads/main
  "$REAL_GIT" clone -q -b main "$remote" "$ws"
  "$REAL_GIT" -C "$ws" config user.name "Yardlet Fixture"
  "$REAL_GIT" -C "$ws" config user.email "fixture@example.test"
  "$REAL_GIT" -C "$ws" remote set-url origin "$raw_url"
  "$REAL_GIT" -C "$ws" config "url.$remote.insteadOf" "$raw_url"
  printf '%s\n' "$github_host" >"$scenario/expected-host"
  (
    cd "$ws"
    PATH="$WRAPPER_DIR:$SAFE_SYSTEM_PATH" \
      YARDLET_FIXTURE_REAL_GIT="$REAL_GIT" \
      YARDLET_FIXTURE_GIT_LOG="$scenario/init-git.log" \
      YARDLET_FIXTURE_GH_LOG="$scenario/init-gh.log" \
      YARDLET_FIXTURE_GH_STATE="$scenario/init-pr-state" \
      YARDLET_FIXTURE_EXPECTED_OID="$(head_oid "$ws")" \
      YARDLET_FIXTURE_EXPECTED_HOST="$github_host" \
      "$YARDLET_BIN" init >/dev/null
  )
  write_config "$ws"
  write_state "$ws"
  : >"$scenario/git.log"
  : >"$scenario/gh.log"
  : >"$scenario/worker.log"
  : >"$scenario/check.log"
  printf '%s\n' "$scenario"
}

run_yardlet() {
  local scenario="$1"
  local gh_mode="${2:-normal}"
  local protected="${3:-true}"
  local crash_mode="${4:-normal}"
  local event="${5:-$scenario/no-event}"
  local path_dir="${6:-$WRAPPER_DIR}"
  local expected expected_host
  expected="$(head_oid "$scenario/clone")"
  expected_host="$(cat "$scenario/expected-host")"
  (
    cd "$scenario/clone"
    PATH="$path_dir:$SAFE_SYSTEM_PATH" \
      YARDLET_FIXTURE_REAL_GIT="$REAL_GIT" \
      YARDLET_FIXTURE_GIT_LOG="$scenario/git.log" \
      YARDLET_FIXTURE_GH_LOG="$scenario/gh.log" \
      YARDLET_FIXTURE_GH_STATE="$scenario/pr-state" \
      YARDLET_FIXTURE_EXPECTED_OID="$expected" \
      YARDLET_FIXTURE_EXPECTED_HOST="$expected_host" \
      YARDLET_FIXTURE_GH_MODE="$gh_mode" \
      YARDLET_FIXTURE_PROTECTED="$protected" \
      YARDLET_FIXTURE_CRASH_MODE="$crash_mode" \
      YARDLET_FIXTURE_EVENT="$event" \
      YARDLET_FIXTURE_WORKER_LOG="$scenario/worker.log" \
      YARDLET_FIXTURE_CHECK_LOG="$scenario/check.log" \
      "$YARDLET_BIN" recover
  )
}

launch_grouped_recovery() {
  local scenario="$1"
  local crash_mode="$2"
  local event="$3"
  local expected expected_host
  expected="$(head_oid "$scenario/clone")"
  expected_host="$(cat "$scenario/expected-host")"
  "$PYTHON" - "$YARDLET_BIN" "$scenario/clone" "$WRAPPER_DIR" \
    "$SAFE_SYSTEM_PATH" "$REAL_GIT" "$scenario" "$expected" "$expected_host" \
    "$crash_mode" "$event" <<'PY' &
import os
import sys

yardlet, workspace, wrapper, safe_path, real_git, scenario, expected, host, mode, event = sys.argv[1:]
os.setsid()
os.chdir(workspace)
env = os.environ.copy()
env["PATH"] = wrapper + os.pathsep + safe_path
env["YARDLET_FIXTURE_REAL_GIT"] = real_git
env["YARDLET_FIXTURE_GIT_LOG"] = scenario + "/git.log"
env["YARDLET_FIXTURE_GH_LOG"] = scenario + "/gh.log"
env["YARDLET_FIXTURE_GH_STATE"] = scenario + "/pr-state"
env["YARDLET_FIXTURE_EXPECTED_OID"] = expected
env["YARDLET_FIXTURE_EXPECTED_HOST"] = host
env["YARDLET_FIXTURE_GH_MODE"] = "normal"
env["YARDLET_FIXTURE_PROTECTED"] = "true"
env["YARDLET_FIXTURE_CRASH_MODE"] = mode
env["YARDLET_FIXTURE_EVENT"] = event
env["YARDLET_FIXTURE_WORKER_LOG"] = scenario + "/worker.log"
env["YARDLET_FIXTURE_CHECK_LOG"] = scenario + "/check.log"
fd = os.open(scenario + "/crashed-recover.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.dup2(fd, 1)
os.dup2(fd, 2)
os.close(fd)
os.execve(yardlet, [yardlet, "recover"], env)
PY
  ACTIVE_GROUP_PID=$!
}

run_concurrent_recovery() {
  local scenario="$1"
  (run_yardlet "$scenario" normal true normal >"$scenario/recover-a.log" 2>&1) &
  local first=$!
  (run_yardlet "$scenario" normal true normal >"$scenario/recover-b.log" 2>&1) &
  local second=$!
  wait "$first"
  wait "$second"
}

assert_success_projection() {
  local scenario="$1"
  local expected="$2"
  local finish="$scenario/clone/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
  assert_eq "$(json_field "$finish" status)" pull_request_open "protected finish status"
  assert_eq "$(json_field "$finish" expected_oid)" "$expected" "protected expected OID"
  assert_eq "$(json_field "$finish" remote_oid)" "$expected" "independent head OID"
  assert_eq "$(yaml_task_state "$scenario/clone/.agents/work-queue.yaml")" done "queue projection"
  assert_eq "$(yaml_run_state "$scenario/clone/.agents/runs/run-20990101-000001-YARD-001/run.yaml")" done "sealed run projection"
  "$PYTHON" - "$scenario/clone/.agents/telemetry/runs.jsonl" <<'PY'
import json
import sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert records[-1]["eval_state"] == "Done", records[-1]
assert records[-1]["git_finish_status"] == "pull_request_open", records[-1]
PY
  (
    cd "$scenario/clone"
    "$YARDLET_BIN" report >"$scenario/final-report.md"
  )
  grep -q '1/1 tasks done' "$scenario/final-report.md" || fail "success report progress"
  grep -q 'pull request #17 open and verified' "$scenario/final-report.md" \
    || fail "success report Git finish projection"
}

run_direct_case() {
  local scenario ws remote baseline expected
  scenario="$(new_workspace direct-writable)"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"
  expected="$(commit_owned "$ws" direct)"
  write_integrated_run "$ws" "$baseline" "$expected"
  run_yardlet "$scenario" normal false normal >"$scenario/recover.log" 2>&1
  assert_eq "$(remote_oid "$remote" refs/heads/main)" "$expected" "direct base OID"
  assert_eq "$(grep -c "PUSH_SUCCESS.*${expected}:refs/heads/main" "$scenario/git.log" || true)" 1 "direct base push count"
  assert_eq "$(yaml_task_state "$ws/.agents/work-queue.yaml")" done "direct queue Done"
}

run_protected_case() {
  local name="$1"
  local github_host="$2"
  local scenario ws remote baseline expected head_ref
  scenario="$(new_workspace "$name" "$github_host")"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"
  expected="$(commit_owned "$ws" "$name")"
  write_integrated_run "$ws" "$baseline" "$expected"
  run_yardlet "$scenario" normal true normal >"$scenario/recover.log" 2>&1
  head_ref="refs/heads/yardlet/runs/run-20990101-000001-YARD-001"
  assert_eq "$(remote_oid "$remote" refs/heads/main)" "$baseline" "protected base unchanged"
  assert_eq "$(remote_oid "$remote" "$head_ref")" "$expected" "protected exact head OID"
  assert_eq "$(grep -c 'PUSH_SUCCESS.*:refs/heads/main' "$scenario/git.log" || true)" 0 "protected base push count"
  assert_eq "$(grep -c "PUSH_SUCCESS.*${expected}:${head_ref}" "$scenario/git.log" || true)" 1 "protected head push count"
  [[ "$(grep -c 'PR_CREATE_SUCCESS' "$scenario/gh.log" || true)" -le 1 ]] \
    || fail "protected PR create mutation count"
  [[ "$(grep -c "ls-remote.*${head_ref}" "$scenario/git.log" || true)" -ge 2 ]] \
    || fail "protected independent head lookup count"
  [[ "$(grep -c "^HOST_OK[[:space:]]${github_host}$" "$scenario/gh.log" || true)" -ge 6 ]] \
    || fail "all GitHub calls did not use derived host $github_host"
  ! grep -q '^HOST_MISMATCH' "$scenario/gh.log" || fail "ambient GitHub host changed authority"
  assert_success_projection "$scenario" "$expected"
}

run_crash_case() {
  local crash_mode="$1"
  local scenario ws remote baseline expected event record pgid wrapper_pid wrapper_pgid
  local head_ref worker_before
  scenario="$(new_workspace "crash-$crash_mode")"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"
  expected="$(commit_owned "$ws" "$crash_mode")"
  write_integrated_run "$ws" "$baseline" "$expected"
  event="$scenario/$crash_mode.event"
  launch_grouped_recovery "$scenario" "$crash_mode" "$event"
  pgid="$ACTIVE_GROUP_PID"
  wait_for_file "$event" "$crash_mode event"
  record="$ws/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
  assert_eq "$(json_field "$record" status)" prepared "$crash_mode durable prepared"
  if [[ "$crash_mode" == before_pr_create || "$crash_mode" == after_pr_create ]]; then
    assert_eq "$(json_field "$record" reason)" ready_to_create_or_reuse_pull_request "$crash_mode PR prepared gate"
  else
    assert_eq "$(json_field "$record" reason)" ready_to_push_run_head "$crash_mode push prepared gate"
  fi
  wrapper_pid="$(cat "$event.pid")"
  wrapper_pgid="$(ps -o pgid= -p "$wrapper_pid" | tr -d ' ')"
  assert_eq "$wrapper_pgid" "$pgid" "$crash_mode child process group"
  terminate_active_process_group
  ! kill -0 -- "-$pgid" 2>/dev/null || fail "$crash_mode process group survived"
  worker_before="$(wc -l <"$scenario/worker.log" | tr -d ' ')"
  run_concurrent_recovery "$scenario"
  head_ref="refs/heads/yardlet/runs/run-20990101-000001-YARD-001"
  assert_eq "$(remote_oid "$remote" refs/heads/main)" "$baseline" "$crash_mode base unchanged"
  assert_eq "$(remote_oid "$remote" "$head_ref")" "$expected" "$crash_mode head OID"
  assert_eq "$(grep -c "PUSH_SUCCESS.*${expected}:${head_ref}" "$scenario/git.log" || true)" 1 "$crash_mode head mutation count"
  assert_eq "$(grep -c 'PR_CREATE_SUCCESS' "$scenario/gh.log" || true)" 1 "$crash_mode PR mutation count"
  assert_eq "$(wc -l <"$scenario/worker.log" | tr -d ' ')" "$worker_before" "$crash_mode worker count"
  assert_success_projection "$scenario" "$expected"
}

FAILURE_PROJECTION_TOTAL=0
FAILURE_PROJECTION_CONVERGED=0
assert_failure_projection() {
  local scenario="$1"
  local expected_reason="$2"
  local finish="$scenario/clone/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
  local queue_state run_state telemetry_state
  FAILURE_PROJECTION_TOTAL=$((FAILURE_PROJECTION_TOTAL + 1))
  assert_eq "$(json_field "$finish" reason)" "$expected_reason" "$scenario failure reason"
  queue_state="$(yaml_task_state "$scenario/clone/.agents/work-queue.yaml")"
  run_state="$(yaml_run_state "$scenario/clone/.agents/runs/run-20990101-000001-YARD-001/run.yaml")"
  telemetry_state="$("$PYTHON" - "$scenario/clone/.agents/telemetry/runs.jsonl" <<'PY'
import json
import sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
print(records[-1]["eval_state"])
PY
)"
  (
    cd "$scenario/clone"
    "$YARDLET_BIN" report >"$scenario/final-report.md"
  )
  if [[ "$queue_state" == partial && "$run_state" == partial \
    && "$telemetry_state" == Partial ]] \
    && grep -q '0/1 tasks done' "$scenario/final-report.md"; then
    FAILURE_PROJECTION_CONVERGED=$((FAILURE_PROJECTION_CONVERGED + 1))
  else
    cat >"$scenario/projection-mismatch.json" <<EOF
{
  "queue_state": "$queue_state",
  "run_state": "$run_state",
  "telemetry_eval_state": "$telemetry_state",
  "report_done_progress": "$(grep -o '[0-9]/1 tasks done' "$scenario/final-report.md" | head -1)"
}
EOF
  fi
}

run_failure_case() {
  local name="$1"
  local gh_mode="$2"
  local expected_reason="$3"
  local path_dir="${4:-$WRAPPER_DIR}"
  local policy_remote="${5:-origin}"
  local scenario ws baseline expected
  scenario="$(new_workspace "failure-$name")"
  ws="$scenario/clone"
  baseline="$(head_oid "$ws")"
  expected="$(commit_owned "$ws" "$name")"
  write_integrated_run "$ws" "$baseline" "$expected"
  write_config "$ws" "$policy_remote"
  run_yardlet "$scenario" "$gh_mode" true normal "$scenario/no-event" "$path_dir" \
    >"$scenario/recover.log" 2>&1
  assert_eq "$(grep -c '^PUSH_SUCCESS' "$scenario/git.log" || true)" 0 "$name external Git mutation"
  assert_eq "$(grep -c 'PR_CREATE_SUCCESS' "$scenario/gh.log" || true)" 0 "$name external PR mutation"
  assert_failure_projection "$scenario" "$expected_reason"
}

run_pr_mismatch_case() {
  local mode="$1"
  local scenario ws remote baseline expected head_ref
  scenario="$(new_workspace "failure-$mode")"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"
  expected="$(commit_owned "$ws" "$mode")"
  write_integrated_run "$ws" "$baseline" "$expected"
  head_ref="refs/heads/yardlet/runs/run-20990101-000001-YARD-001"
  "$REAL_GIT" -C "$ws" push -q "$remote" "$expected:$head_ref"
  printf 'open\n' >"$scenario/pr-state"
  run_yardlet "$scenario" "$mode" true normal >"$scenario/recover.log" 2>&1
  assert_eq "$(grep -c '^PUSH_SUCCESS' "$scenario/git.log" || true)" 0 "$mode Yardlet Git mutation"
  assert_eq "$(grep -c 'PR_CREATE_SUCCESS' "$scenario/gh.log" || true)" 0 "$mode PR mutation"
  assert_failure_projection "$scenario" pull_request_verification_mismatch
}

run_direct_case
run_protected_case protected-success github.com
run_protected_case enterprise-protected ghe.example.test
run_crash_case before_head_push
run_crash_case after_head_push
run_crash_case before_pr_create
run_crash_case after_pr_create
run_failure_case gh-missing normal gh_not_installed "$NO_GH_DIR"
run_failure_case gh-unauthenticated unauthenticated gh_not_authenticated
run_failure_case remote-mismatch normal configured_remote_conflicts_with_upstream "$WRAPPER_DIR" other
run_failure_case default-branch-mismatch default_branch_mismatch github_default_branch_mismatch
run_pr_mismatch_case pr_head_mismatch
run_pr_mismatch_case pr_base_mismatch

public_remote_commands="$(
  (grep -R -h '^PUBLIC_REMOTE_REJECTED' "$ROOT" 2>/dev/null || true) \
    | wc -l | tr -d ' '
)"
worker_invocations="$(find "$ROOT" -name worker.log -type f -exec cat {} + | wc -l | tr -d ' ')"
host_mismatches="$(
  (grep -R -h '^HOST_MISMATCH' "$ROOT" --include=gh.log || true) \
    | wc -l | tr -d ' '
)"
assert_eq "$public_remote_commands" 0 "public remote commands"
assert_eq "$worker_invocations" 0 "worker invocations"
assert_eq "$host_mismatches" 0 "ambient host authority mismatches"

failure_projections_converged=false
[[ "$FAILURE_PROJECTION_TOTAL" -eq "$FAILURE_PROJECTION_CONVERGED" ]] \
  && failure_projections_converged=true

cat >"$EVIDENCE_DIR/summary.json" <<EOF
{
  "fixture_completed": true,
  "fixture_root": "$ROOT",
  "public_remote_commands": $public_remote_commands,
  "direct_base_pushes": 1,
  "protected_base_pushes": 0,
  "protected_head_pushes": 1,
  "crash_windows_passed": 4,
  "worker_invocations": $worker_invocations,
  "failure_projection_total": $FAILURE_PROJECTION_TOTAL,
  "failure_projection_converged": $FAILURE_PROJECTION_CONVERGED,
  "failure_projections_converged": $failure_projections_converged,
  "ambient_host_ignored": true,
  "enterprise_host_supported": true,
  "scenarios": [
    "direct-writable",
    "protected-success",
    "enterprise-protected",
    "before-head-push",
    "after-head-push",
    "before-pr-create",
    "after-pr-create",
    "gh-missing",
    "gh-unauthenticated",
    "remote-mismatch",
    "default-branch-mismatch",
    "pr-head-mismatch",
    "pr-base-mismatch"
  ]
}
EOF

printf 'protected branch fixture completed: %s\n' "$EVIDENCE_DIR/summary.json"
