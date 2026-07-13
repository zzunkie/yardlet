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

mkdir -p "$EVIDENCE_DIR"
ROOT="$(mktemp -d "$EVIDENCE_DIR/fixture.XXXXXX")"
WRAPPER_DIR="$ROOT/wrapper-bin"
mkdir -p "$WRAPPER_DIR"
cp "$SCRIPT_DIR/git-wrapper.sh" "$WRAPPER_DIR/git"
cp "$SCRIPT_DIR/worker-sentinel.sh" "$WRAPPER_DIR/worker-sentinel"
chmod +x "$WRAPPER_DIR/git" "$WRAPPER_DIR/worker-sentinel"

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
  for i in $(seq 1 300); do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  fail "timed out waiting for $label ($path)"
}

remote_oid() {
  "$REAL_GIT" ls-remote --refs "$1" refs/heads/main | awk 'NR == 1 { print $1 }'
}

head_oid() {
  "$REAL_GIT" -C "$1" rev-parse HEAD
}

write_config() {
  local ws="$1"
  local remote="$2"
  cat >"$ws/.agents/yardlet.yaml" <<EOF
schema_version: 1
product: yardlet-fixture
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
  remote: $remote
  target_ref: refs/heads/main
  pre_push_checks:
    - name: fixture-gate
      command: 'test "\${YARDLET_FIXTURE_CHECK:-fail}" = pass'
EOF
}

write_queue() {
  local ws="$1"
  local first_state="$2"
  local second_state="$3"
  cat >"$ws/.agents/work-queue.yaml" <<EOF
schema_version: 1
queue_id: queue-fixture
intent_id: intent-fixture
selection_policy:
  default_order: priority_then_created_at
  require_planning_gate: true
  skip_if_blocked: true
  skip_if_approval_required: true
tasks:
  - id: YARD-001
    title: first accumulated integration
    state: $first_state
    priority: 10
    risk: high
    kind: implementation
  - id: YARD-002
    title: second accumulated integration
    state: $second_state
    priority: 20
    risk: high
    kind: implementation
EOF
  cat >"$ws/.agents/intent-contract.yaml" <<'EOF'
schema_version: 1
id: intent-fixture
source: fixture
summary: accumulated Git finish process recovery
acceptance:
  - exact OID recovery converges
status: accepted
EOF
}

write_workers() {
  local ws="$1"
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

write_result() {
  local run_dir="$1"
  local run_id="$2"
  local task_id="$3"
  mkdir -p "$run_dir"
  cat >"$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
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
}

write_run() {
  local ws="$1"
  local index="$2"
  local task_id="$3"
  local baseline="$4"
  local expected="$5"
  local run_id="run-20990101-00000${index}-${task_id}"
  local run_dir="$ws/.agents/runs/$run_id"
  local worker_oid branch worktree task_slug
  worker_oid="$("$REAL_GIT" -C "$ws" rev-parse "$expected^2")"
  task_slug="$(printf '%s' "$task_id" | tr '[:upper:]' '[:lower:]')"
  branch="yard/$task_slug/$run_id"
  worktree="$(cd "$ws" && pwd -P)/.agents/worktrees/$run_id"
  write_result "$run_dir" "$run_id" "$task_id"
  cat >"$run_dir/run.yaml" <<EOF
schema_version: 1
run_id: $run_id
task_id: $task_id
intent_id: intent-fixture
worker: fixture-worker
state: partial
started_at: 2099-01-01T00:00:0${index}Z
completed_at: 2099-01-01T00:00:1${index}Z
worktree: .
integration_oid: $expected
integration_base_oid: $baseline
integration_worker_oid: $worker_oid
integration_provenance: parallel_worker_direct
owned_oids:
  - $worker_oid
  - $expected
EOF
  mkdir -p "$ws/.agents/checkpoints/integrated-cleanup"
  cat >"$ws/.agents/checkpoints/integrated-cleanup/$run_id.yaml" <<EOF
schema_version: 1
run_id: $run_id
task_id: $task_id
intent_id: intent-fixture
worker: fixture-worker
worktree: $worktree
branch: $branch
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

new_workspace() {
  local name="$1"
  local scenario="$ROOT/$name"
  local seed="$scenario/seed"
  local remote="$scenario/remote.git"
  local ws="$scenario/clone"
  mkdir -p "$seed"
  "$REAL_GIT" -C "$seed" init -q -b main
  "$REAL_GIT" -C "$seed" config user.name "Yardlet Fixture"
  "$REAL_GIT" -C "$seed" config user.email "fixture@example.test"
  printf 'baseline\n' >"$seed/owned.txt"
  "$REAL_GIT" -C "$seed" add owned.txt
  "$REAL_GIT" -C "$seed" commit -q -m baseline
  "$REAL_GIT" init -q --bare "$remote"
  "$REAL_GIT" -C "$seed" remote add local-fixture "$remote"
  "$REAL_GIT" -C "$seed" push -q local-fixture HEAD:refs/heads/main
  "$REAL_GIT" clone -q -b main "$remote" "$ws"
  "$REAL_GIT" -C "$ws" config user.name "Yardlet Fixture"
  "$REAL_GIT" -C "$ws" config user.email "fixture@example.test"
  (
    cd "$ws"
    PATH="$WRAPPER_DIR:$PATH" \
      YARDLET_FIXTURE_REAL_GIT="$REAL_GIT" \
      YARDLET_FIXTURE_GIT_LOG="$scenario/init-wrapper.log" \
      YARDLET_FIXTURE_WORKER_LOG="$scenario/worker.log" \
      "$YARDLET_BIN" init >/dev/null
  )
  write_config "$ws" origin
  write_queue "$ws" partial partial
  write_workers "$ws"
  : >"$scenario/wrapper.log"
  : >"$scenario/worker.log"
  printf '%s\n' "$scenario"
}

commit_owned() {
  local ws="$1"
  local text="$2"
  local baseline tree worker_oid merge_oid
  baseline="$(head_oid "$ws")"
  printf '%s\n' "$text" >"$ws/owned.txt"
  "$REAL_GIT" -C "$ws" add owned.txt
  tree="$("$REAL_GIT" -C "$ws" write-tree)"
  worker_oid="$(printf '%s worker\n' "$text" | "$REAL_GIT" -C "$ws" commit-tree "$tree" -p "$baseline")"
  merge_oid="$(printf '%s integration\n' "$text" | "$REAL_GIT" -C "$ws" commit-tree "$tree" -p "$baseline" -p "$worker_oid")"
  "$REAL_GIT" -C "$ws" update-ref refs/heads/main "$merge_oid" "$baseline"
  "$REAL_GIT" -C "$ws" reset -q --hard "$merge_oid"
  printf '%s\n' "$merge_oid"
}

run_yardlet() {
  local scenario="$1"
  local ws="$2"
  local check="$3"
  local mode="${4:-normal}"
  local event="${5:-$scenario/no-event}"
  (
    cd "$ws"
    PATH="$WRAPPER_DIR:$PATH" \
      YARDLET_FIXTURE_REAL_GIT="$REAL_GIT" \
      YARDLET_FIXTURE_GIT_LOG="$scenario/wrapper.log" \
      YARDLET_FIXTURE_WORKER_LOG="$scenario/worker.log" \
      YARDLET_FIXTURE_CHECK="$check" \
      YARDLET_FIXTURE_CRASH_MODE="$mode" \
      YARDLET_FIXTURE_EVENT="$event" \
      "$YARDLET_BIN" recover
  )
}

launch_grouped_recover() {
  local scenario="$1"
  local ws="$2"
  local check="$3"
  local mode="$4"
  local event="$5"
  local stdout="$6"
  "$PYTHON" - "$YARDLET_BIN" "$ws" "$WRAPPER_DIR" "$REAL_GIT" \
    "$scenario/wrapper.log" "$scenario/worker.log" "$check" "$mode" "$event" "$stdout" <<'PY' &
import os
import sys

yardlet, workspace, wrapper, real_git, git_log, worker_log, check, mode, event, stdout = sys.argv[1:]
os.setsid()
os.chdir(workspace)
env = os.environ.copy()
env["PATH"] = wrapper + os.pathsep + env.get("PATH", "")
env["YARDLET_FIXTURE_REAL_GIT"] = real_git
env["YARDLET_FIXTURE_GIT_LOG"] = git_log
env["YARDLET_FIXTURE_WORKER_LOG"] = worker_log
env["YARDLET_FIXTURE_CHECK"] = check
env["YARDLET_FIXTURE_CRASH_MODE"] = mode
env["YARDLET_FIXTURE_EVENT"] = event
fd = os.open(stdout, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.dup2(fd, 1)
os.dup2(fd, 2)
os.close(fd)
os.execve(yardlet, [yardlet, "recover"], env)
PY
  GROUP_PID=$!
}

kill_process_group() {
  local pgid="$1"
  kill -TERM -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
  local i
  for i in $(seq 1 100); do
    if ! kill -0 -- "-$pgid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
  sleep 0.1
  ! kill -0 -- "-$pgid" 2>/dev/null || fail "process group $pgid still has live children"
}

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

yaml_task_states() {
  "$PYTHON" - "$1" <<'PY'
import sys
states = []
in_tasks = False
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("tasks:"):
        in_tasks = True
    elif in_tasks and line.lstrip().startswith("state: "):
        states.append(line.split(":", 1)[1].strip())
print(" ".join(states))
PY
}

rebind_core_receipt_worktrees() {
  local ws="$1"
  local canonical
  canonical="$(cd "$ws" && pwd -P)"
  "$PYTHON" - "$ws/.agents/checkpoints/integrated-cleanup" "$canonical" <<'PY'
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
root = sys.argv[2]
for path in directory.glob("*.yaml"):
    run_id = path.stem
    lines = path.read_text(encoding="utf-8").splitlines()
    lines = [
        f"worktree: {root}/.agents/worktrees/{run_id}"
        if line.startswith("worktree: ") else line
        for line in lines
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

assert_terminal_projection() {
  local scenario="$1"
  local ws="$2"
  local first_oid="$3"
  local second_oid="$4"
  local first_record="$ws/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
  local second_record="$ws/.agents/runs/run-20990101-000002-YARD-002/git-finish.json"
  local first_status second_status
  first_status="$(json_field "$first_record" status)"
  second_status="$(json_field "$second_record" status)"
  [[ "$first_status" == "pushed" || "$first_status" == "already_applied" ]] || fail "first status is $first_status"
  [[ "$second_status" == "pushed" || "$second_status" == "already_applied" ]] || fail "second status is $second_status"
  assert_eq "$(json_field "$first_record" expected_oid)" "$first_oid" "first expected OID"
  assert_eq "$(json_field "$first_record" baseline_oid)" "$("$REAL_GIT" -C "$ws" rev-parse "$first_oid^")" "first baseline OID"
  assert_eq "$(json_field "$second_record" expected_oid)" "$second_oid" "second expected OID"
  assert_eq "$(json_field "$second_record" baseline_oid)" "$first_oid" "second baseline OID"
  assert_eq "$(yaml_task_states "$ws/.agents/work-queue.yaml")" "done done" "queue terminal projection"
  grep -q '^state: done$' "$ws/.agents/runs/run-20990101-000001-YARD-001/run.yaml" || fail "first run not sealed done"
  grep -q '^state: done$' "$ws/.agents/runs/run-20990101-000002-YARD-002/run.yaml" || fail "second run not sealed done"
  "$PYTHON" - "$ws/.agents/telemetry/runs.jsonl" <<'PY'
import json
import sys
latest = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        record = json.loads(line)
        latest[record.get("run_id", "")] = record
assert len(latest) == 2, latest
for record in latest.values():
    assert record["eval_state"] == "Done", record
    assert record["git_finish_status"] in {"pushed", "already_applied"}, record
PY
  (
    cd "$ws"
    "$YARDLET_BIN" report >"$scenario/final-report.md"
  )
  grep -q '2/2 tasks done' "$scenario/final-report.md" || fail "final report progress did not converge"
  [[ "$(grep -c 'pushed and verified\|already applied and verified' "$scenario/final-report.md")" -eq 2 ]] || fail "final report missing two verified finishes"
}

run_concurrent_recovery() {
  local scenario="$1"
  local snapshot="$2"
  (
    run_yardlet "$scenario" "$snapshot" pass normal >"$scenario/recover-a.log" 2>&1
  ) &
  local a=$!
  (
    run_yardlet "$scenario" "$snapshot" pass normal >"$scenario/recover-b.log" 2>&1
  ) &
  local b=$!
  wait "$a"
  wait "$b"
}

run_crash_scenario() {
  local name="$1"
  local crash_mode="$2"
  local scenario ws remote baseline first_oid second_oid event first_record snapshot
  scenario="$(new_workspace "$name")"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"
  first_oid="$(commit_owned "$ws" first)"
  write_run "$ws" 1 YARD-001 "$baseline" "$first_oid"

  run_yardlet "$scenario" "$ws" fail normal >"$scenario/pre-push-failure.log" 2>&1
  first_record="$ws/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
  assert_eq "$(json_field "$first_record" status)" check_blocked "leading pre-push check"
  assert_eq "$(remote_oid "$remote")" "$baseline" "remote after leading check failure"

  second_oid="$(commit_owned "$ws" second)"
  write_run "$ws" 2 YARD-002 "$first_oid" "$second_oid"
  event="$scenario/$crash_mode.event"
  launch_grouped_recover "$scenario" "$ws" pass "$crash_mode" "$event" "$scenario/crashed-recover.log"
  local pgid="$GROUP_PID"
  wait_for_file "$event" "$crash_mode wrapper stop"
  assert_eq "$(json_field "$first_record" status)" prepared "$crash_mode durable prepared record"
  if [[ "$crash_mode" == "before_push" ]]; then
    assert_eq "$(remote_oid "$remote")" "$baseline" "prepared crash remote"
  else
    assert_eq "$(remote_oid "$remote")" "$first_oid" "post-update crash remote"
  fi
  local wrapper_pid wrapper_pgid
  wrapper_pid="$(cat "$event.pid")"
  wrapper_pgid="$(ps -o pgid= -p "$wrapper_pid" | tr -d ' ')"
  assert_eq "$wrapper_pgid" "$pgid" "wrapper belongs to dedicated recovery process group"
  kill_process_group "$pgid"

  snapshot="$scenario/snapshot"
  cp -R "$ws" "$snapshot"
  rebind_core_receipt_worktrees "$snapshot"
  local worker_before push_before push_after
  worker_before="$(wc -l <"$scenario/worker.log" | tr -d ' ')"
  run_concurrent_recovery "$scenario" "$snapshot"
  assert_terminal_projection "$scenario" "$snapshot" "$first_oid" "$second_oid"
  assert_eq "$(remote_oid "$remote")" "$second_oid" "independent final remote OID"

  push_before="$(grep -c '^PUSH_SUCCESS' "$scenario/wrapper.log" || true)"
  run_yardlet "$scenario" "$snapshot" pass normal >"$scenario/repeated-recover-1.log" 2>&1
  run_yardlet "$scenario" "$snapshot" pass normal >"$scenario/repeated-recover-2.log" 2>&1
  push_after="$(grep -c '^PUSH_SUCCESS' "$scenario/wrapper.log" || true)"
  assert_eq "$push_after" "$push_before" "repeated recovery adds no push"
  assert_eq "$(grep -c "PUSH_SUCCESS.*${first_oid}:refs/heads/main" "$scenario/wrapper.log" || true)" 1 "first exact OID successful push count"
  assert_eq "$(grep -c "PUSH_SUCCESS.*${second_oid}:refs/heads/main" "$scenario/wrapper.log" || true)" 1 "second exact OID successful push count"
  assert_eq "$(wc -l <"$scenario/worker.log" | tr -d ' ')" "$worker_before" "worker invocation count"
  [[ "$("$REAL_GIT" -C "$snapshot" remote get-url origin)" == "$remote" ]] || fail "origin escaped local fixture"
  ! grep -Eiq 'https?://|ssh://|git@' "$scenario/wrapper.log" || fail "public/network remote appeared in wrapper log"

  cat >"$scenario/proof.json" <<EOF
{
  "crash_mode": "$crash_mode",
  "baseline_oid": "$baseline",
  "first_oid": "$first_oid",
  "second_oid": "$second_oid",
  "remote_oid": "$(remote_oid "$remote")",
  "successful_pushes": $push_after,
  "worker_invocations": "$(wc -l <"$scenario/worker.log" | tr -d ' ')"
}
EOF
}

run_block_case() {
  local kind="$1"
  local scenario ws remote baseline oid record other
  scenario="$(new_workspace "block-$kind")"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"
  oid="$(commit_owned "$ws" "$kind-forward")"
  write_run "$ws" 1 YARD-001 "$baseline" "$oid"

  case "$kind" in
    forbidden)
      printf 'fixture-only\n' >"$ws/.env.fixture"
      ;;
    dirty)
      printf 'dirty\n' >"$ws/dirty.txt"
      ;;
    retarget)
      run_yardlet "$scenario" "$ws" fail normal >"$scenario/seed-record.log" 2>&1
      record="$ws/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
      assert_eq "$(json_field "$record" status)" check_blocked "retarget seed record"
      other="$scenario/other.git"
      "$REAL_GIT" init -q --bare "$other"
      "$REAL_GIT" -C "$ws" remote add other "$other"
      write_config "$ws" other
      ;;
    *) fail "unknown block case $kind" ;;
  esac

  run_yardlet "$scenario" "$ws" pass normal >"$scenario/recover.log" 2>&1
  record="$ws/.agents/runs/run-20990101-000001-YARD-001/git-finish.json"
  assert_eq "$(head_oid "$ws")" "$oid" "$kind clone HEAD advanced"
  assert_eq "$(remote_oid "$remote")" "$baseline" "$kind remote unchanged"
  assert_eq "$(json_field "$record" push_invoked)" false "$kind push not invoked"
  if [[ "$kind" == "retarget" ]]; then
    assert_eq "$(json_field "$record" reason)" git_finish_target_changed "retarget block reason"
    assert_eq "$(remote_oid "$other")" "" "retarget destination unchanged"
  elif [[ "$kind" == "dirty" ]]; then
    assert_eq "$(json_field "$record" reason)" worktree_not_clean "dirty block reason"
  else
    assert_eq "$(json_field "$record" reason)" task_not_done "forbidden-path prevents Done before Git finish"
    "$PYTHON" - "$ws/.agents/telemetry/runs.jsonl" <<'PY'
import json
import sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert records[-1]["eval_state"] != "Done", records[-1]
PY
  fi
}

run_crash_scenario prepared-crash before_push
run_crash_scenario remote-update-crash after_push
run_block_case forbidden
run_block_case dirty
run_block_case retarget

public_remote_commands="$(
  (grep -R -Eih 'https?://|ssh://|git@' "$ROOT" --include='wrapper.log' || true) \
    | wc -l | tr -d ' '
)"
worker_invocations="$(find "$ROOT" -name worker.log -type f -exec cat {} + | wc -l | tr -d ' ')"
assert_eq "$public_remote_commands" 0 "public remote commands"
assert_eq "$worker_invocations" 0 "worker invocation count across fixtures"

cat >"$EVIDENCE_DIR/summary.json" <<EOF
{
  "status": "passed",
  "fixture_root": "$ROOT",
  "public_remote_commands": $public_remote_commands,
  "worker_invocations": $worker_invocations,
  "scenarios": [
    "prepared-crash",
    "remote-update-crash",
    "forbidden-path-block",
    "dirty-tree-block",
    "remote-retargeting-block"
  ]
}
EOF

printf 'process recovery fixture passed: %s\n' "$EVIDENCE_DIR/summary.json"
