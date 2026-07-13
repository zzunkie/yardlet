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
STERILE_HOME="$ROOT/sterile-home"
mkdir -p "$STERILE_HOME/.config"
: >"$STERILE_HOME/global.gitconfig"
: >"$STERILE_HOME/system.gitconfig"
chmod 600 "$STERILE_HOME/global.gitconfig" "$STERILE_HOME/system.gitconfig"
export HOME="$STERILE_HOME"
export XDG_CONFIG_HOME="$STERILE_HOME/.config"
export GIT_CONFIG_GLOBAL="$STERILE_HOME/global.gitconfig"
export GIT_CONFIG_SYSTEM="$STERILE_HOME/system.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export YARDLET_FIXTURE_ROOT="$ROOT"
export YARDLET_FIXTURE_PYTHON="$PYTHON"
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
while IFS='=' read -r name _; do
  case "$name" in
    GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_*) unset "$name" ;;
  esac
done < <(env)
WRAPPER_DIR="$ROOT/wrapper-bin"
mkdir -p "$WRAPPER_DIR"
cp "$SCRIPT_DIR/git-wrapper.sh" "$WRAPPER_DIR/git"
cp "$SCRIPT_DIR/worker.sh" "$WRAPPER_DIR/worker.sh"
chmod +x "$WRAPPER_DIR/git" "$WRAPPER_DIR/worker.sh"

fail() {
  printf 'fixture failure: %s\n' "$*" >&2
  exit 1
}

ACTIVE_GROUP_PID=""
EXIT_TRAP_PROOF=""

terminate_active_process_group() {
  local pgid="${ACTIVE_GROUP_PID:-}"
  local i
  ACTIVE_GROUP_PID=""
  [[ -n "$pgid" ]] || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
  for i in $(seq 1 100); do
    if ! kill -0 -- "-$pgid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
}

cleanup_on_exit() {
  local status=$?
  local pgid="${ACTIVE_GROUP_PID:-}"
  local process_group_absent=false
  terminate_active_process_group
  if [[ -n "$EXIT_TRAP_PROOF" && -n "$pgid" ]]; then
    if ! kill -0 -- "-$pgid" 2>/dev/null; then
      process_group_absent=true
    fi
    cat >"$EXIT_TRAP_PROOF" <<EOF
{
  "pgid": $pgid,
  "process_group_absent": $process_group_absent,
  "exit_status": $status
}
EOF
  fi
  return "$status"
}

trap cleanup_on_exit EXIT

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

run_exit_trap_probe() {
  local ready="$EVIDENCE_DIR/exit-trap-probe.ready"
  EXIT_TRAP_PROOF="$EVIDENCE_DIR/exit-trap-cleanup.json"
  rm -f "$ready" "$EXIT_TRAP_PROOF"
  "$PYTHON" - "$ready" <<'PY' &
import os
import sys
import time

os.setsid()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpgrp()}\n")
while True:
    time.sleep(1)
PY
  ACTIVE_GROUP_PID=$!
  wait_for_file "$ready" "EXIT trap probe process group"
  assert_eq "$(cat "$ready")" "$ACTIVE_GROUP_PID" "EXIT trap probe PGID"
  fail "intentional EXIT trap cleanup probe"
}

if [[ "${YARDLET_FIXTURE_EXIT_TRAP_PROBE:-0}" == "1" ]]; then
  run_exit_trap_probe
fi

remote_oid() {
  "$REAL_GIT" ls-remote --refs "$1" refs/heads/main | awk 'NR == 1 { print $1 }'
}

head_oid() {
  "$REAL_GIT" -C "$1" rev-parse HEAD
}

json_field() {
  "$PYTHON" - "$1" "$2" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print(str(value).lower() if isinstance(value, bool) else value)
PY
}

yaml_value() {
  local path="$1"
  local key="$2"
  awk -F': ' -v key="$key" '$1 == key { print substr($0, index($0, ": ") + 2); exit }' "$path"
}

yaml_list() {
  local path="$1"
  local key="$2"
  awk -v key="$key" '
    $0 == key ":" { found=1; next }
    found && /^[[:space:]]*- / { sub(/^[[:space:]]*- /, ""); print; next }
    found { exit }
  ' "$path"
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

write_config() {
  local ws="$1"
  cat >"$ws/.agents/yardlet.yaml" <<'EOF'
schema_version: 1
product: yardlet-fixture
workspace_id: fixture
created_at: 2099-01-01T00:00:00Z
state_dir: .agents
default_interface: tui
canonical_queue: work-queue.yaml
current_intent: intent-contract.yaml
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
auto_commit: true
git_finish:
  auto_push: true
  remote: origin
  target_ref: refs/heads/main
  pre_push_checks:
    - name: fixture-check
      command: 'printf "check\n" >> "$YARDLET_FIXTURE_CHECK_LOG"'
EOF
}

write_intent_and_queue() {
  local ws="$1"
  local scenario="$2"
  cat >"$ws/.agents/intent-contract.yaml" <<'EOF'
schema_version: 1
id: intent-v010-001a-fixture
source: fixture
summary: serial dependency Git finish process proof
acceptance:
  - reviewer remediation and independent re-review converge
status: accepted
EOF
  cat >"$ws/.agents/work-queue.yaml" <<EOF
schema_version: 1
queue_id: queue-v010-001a-fixture
intent_id: intent-v010-001a-fixture
selection_policy:
  default_order: priority_then_created_at
  require_planning_gate: true
  skip_if_blocked: true
  skip_if_approval_required: true
tasks:
  - id: YARD-001
    title: fixture builder
    state: queued
    priority: 10
    risk: low
    kind: implementation
    preferred_worker: builder
    acceptance:
      - builder artifact exists
  - id: YARD-002
    title: fixture reviewer remediation
    state: queued
    priority: 20
    risk: high
    kind: safety
    preferred_worker: reviewer
    depends_on: [YARD-001]
    acceptance:
      - reviewer failed check is remediated exactly once
    goal:
      condition: reviewer validation passes after one injected failed check
      max_feedback_cycles: 1
      feedback_policy: inject_failed_checks
  - id: YARD-003
    title: fixture independent re-review
    state: queued
    priority: 30
    risk: high
    kind: review
    preferred_worker: rereviewer
    depends_on: [YARD-002]
    acceptance:
      - independent re-review passes
EOF
}

write_workers() {
  local ws="$1"
  local scenario="$2"
  cat >"$ws/.agents/workers.yaml" <<EOF
schema_version: 1
routing:
  default_worker: builder
  fallback_order: [builder, reviewer, remediator, rereviewer]
workers:
  - id: builder
    invocation:
      command: bash
      args: [$WRAPPER_DIR/worker.sh, "{run_dir}", YARD-001, builder, $scenario/attempts, $scenario/packets, $STERILE_HOME]
    limits: {max_wall_minutes: 1, max_retries: 0}
  - id: reviewer
    invocation:
      command: bash
      args: [$WRAPPER_DIR/worker.sh, "{run_dir}", YARD-002, reviewer, $scenario/attempts, $scenario/packets, $STERILE_HOME]
    limits: {max_wall_minutes: 1, max_retries: 0}
  - id: remediator
    invocation:
      command: bash
      args: [$WRAPPER_DIR/worker.sh, "{run_dir}", YARD-004, remediator, $scenario/attempts, $scenario/packets, $STERILE_HOME]
    limits: {max_wall_minutes: 1, max_retries: 0}
  - id: rereviewer
    invocation:
      command: bash
      args: [$WRAPPER_DIR/worker.sh, "{run_dir}", YARD-003, rereviewer, $scenario/attempts, $scenario/packets, $STERILE_HOME]
    limits: {max_wall_minutes: 1, max_retries: 0}
EOF
}

new_workspace() {
  local name="$1"
  local scenario="$ROOT/$name"
  local seed="$scenario/seed"
  local remote="$scenario/remote.git"
  local ws="$scenario/clone"
  mkdir -p "$seed" "$scenario/attempts" "$scenario/packets"
  "$REAL_GIT" -C "$seed" init -q -b main
  "$REAL_GIT" -C "$seed" config user.name "Yardlet Fixture"
  "$REAL_GIT" -C "$seed" config user.email "fixture@example.test"
  printf 'baseline\n' >"$seed/baseline.txt"
  "$REAL_GIT" -C "$seed" add baseline.txt
  "$REAL_GIT" -C "$seed" commit -q -m baseline
  "$REAL_GIT" clone -q --bare "$seed" "$remote"
  "$REAL_GIT" clone -q -b main "$remote" "$ws"
  "$REAL_GIT" -C "$ws" config user.name "Yardlet Fixture"
  "$REAL_GIT" -C "$ws" config user.email "fixture@example.test"
  "$YARDLET_BIN" init --path "$ws" >/dev/null 2>&1 || (
    cd "$ws"
    "$YARDLET_BIN" init >/dev/null
  )
  write_config "$ws"
  write_intent_and_queue "$ws" "$scenario"
  write_workers "$ws" "$scenario"
  : >"$scenario/wrapper.log"
  : >"$scenario/checks.log"
  printf '%s\n' "$scenario"
}

run_env() {
  local scenario="$1"
  local ws="$2"
  local mode="$3"
  local event="$4"
  shift 4
  (
    cd "$ws"
    PATH="$WRAPPER_DIR:$PATH" \
      YARDLET_FIXTURE_REAL_GIT="$REAL_GIT" \
      YARDLET_FIXTURE_GIT_LOG="$scenario/wrapper.log" \
      YARDLET_FIXTURE_CHECK_LOG="$scenario/checks.log" \
      YARDLET_FIXTURE_CRASH_MODE="$mode" \
      YARDLET_FIXTURE_EVENT="$event" \
      "$YARDLET_BIN" "$@"
  )
}

assert_wrapper_rejects_escape() {
  local scenario="$1"
  local ws="$2"
  local remote="$3"
  local escaped_root="$EVIDENCE_DIR/wrapper-escape"
  local literal_remote="$escaped_root/literal.git"
  local pushurl_remote="$escaped_root/pushurl.git"
  local rewrite_remote="$escaped_root/remote.git"
  local refspec status rejection_count
  mkdir -p "$escaped_root"
  "$REAL_GIT" init -q --bare "$literal_remote"
  "$REAL_GIT" init -q --bare "$pushurl_remote"
  "$REAL_GIT" init -q --bare "$rewrite_remote"
  refspec="$(head_oid "$ws"):refs/heads/main"

  run_rejected_push() {
    local label="$1"
    shift
    set +e
    (
      cd "$ws"
      PATH="$WRAPPER_DIR:$PATH" \
        YARDLET_FIXTURE_REAL_GIT="$REAL_GIT" \
        YARDLET_FIXTURE_GIT_LOG="$scenario/wrapper.log" \
        YARDLET_FIXTURE_ROOT="$ROOT" \
        YARDLET_FIXTURE_PYTHON="$PYTHON" \
        git "$@"
    ) >"$scenario/wrapper-escape-$label.log" 2>&1
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "git wrapper allowed $label to escape the fixture root"
  }

  run_rejected_push literal -C "$ws" push --porcelain -- "$literal_remote" "$refspec"
  run_rejected_push pushurl -C "$ws" -c "remote.origin.pushurl=$pushurl_remote" \
    push --porcelain -- origin "$refspec"
  run_rejected_push rewrite -C "$ws" \
    -c "url.file://$escaped_root/.pushInsteadOf=$scenario/" \
    push --porcelain -- origin "$refspec"

  [[ ! -e "$literal_remote/refs/heads/main" ]] || fail "literal escaped remote was mutated"
  [[ ! -e "$pushurl_remote/refs/heads/main" ]] || fail "pushurl escaped remote was mutated"
  [[ ! -e "$rewrite_remote/refs/heads/main" ]] || fail "rewrite escaped remote was mutated"
  assert_eq "$(remote_oid "$remote")" "$(head_oid "$ws")" "rejected pushes left fixture remote unchanged"
  rejection_count="$(grep -c $'^PUSH_REJECTED\treason=' "$scenario/wrapper.log" || true)"
  assert_eq "$rejection_count" 3 "literal, remote.pushurl, and pushInsteadOf rejection count"
}

launch_grouped_run() {
  local scenario="$1"
  local ws="$2"
  local mode="$3"
  local event="$4"
  local stdout="$5"
  "$PYTHON" - "$YARDLET_BIN" "$ws" "$WRAPPER_DIR" "$REAL_GIT" \
    "$scenario/wrapper.log" "$scenario/checks.log" "$mode" "$event" "$stdout" <<'PY' &
import os
import sys

yardlet, workspace, wrapper, real_git, git_log, check_log, mode, event, stdout = sys.argv[1:]
os.setsid()
os.chdir(workspace)
env = os.environ.copy()
env["PATH"] = wrapper + os.pathsep + env.get("PATH", "")
env["YARDLET_FIXTURE_REAL_GIT"] = real_git
env["YARDLET_FIXTURE_GIT_LOG"] = git_log
env["YARDLET_FIXTURE_CHECK_LOG"] = check_log
env["YARDLET_FIXTURE_CRASH_MODE"] = mode
env["YARDLET_FIXTURE_EVENT"] = event
fd = os.open(stdout, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.dup2(fd, 1)
os.dup2(fd, 2)
os.close(fd)
os.execve(yardlet, [yardlet, "run", "--auto", "--execute", "--headless"], env)
PY
  GROUP_PID=$!
  ACTIVE_GROUP_PID="$GROUP_PID"
}

kill_process_group() {
  local pgid="$1"
  ACTIVE_GROUP_PID="$pgid"
  terminate_active_process_group
  ! kill -0 -- "-$pgid" 2>/dev/null || fail "process group $pgid still has live children"
}

done_run_for() {
  local ws="$1"
  local task_id="$2"
  local path
  for path in "$ws"/.agents/runs/*/run.yaml; do
    [[ "$(yaml_value "$path" task_id)" == "$task_id" ]] || continue
    [[ "$(yaml_value "$path" state)" == "done" ]] || continue
    printf '%s\n' "$(dirname "$path")"
  done
}

assert_run_projection() {
  local scenario="$1"
  local ws="$2"
  local remote="$3"
  local baseline="$4"
  local previous="$baseline"
  local task_id run_dir run_yaml finish expected base parents parent1 parent2 owned worker_oid

  for task_id in YARD-001 YARD-004 YARD-002 YARD-003; do
    run_dir="$(done_run_for "$ws" "$task_id")"
    [[ -n "$run_dir" ]] || fail "missing done run for $task_id"
    run_yaml="$run_dir/run.yaml"
    finish="$run_dir/git-finish.json"
    expected="$(yaml_value "$run_yaml" integration_oid)"
    base="$(yaml_value "$run_yaml" integration_base_oid)"
    assert_eq "$base" "$previous" "$task_id dependency-ordered integration base"
    assert_eq "$(json_field "$finish" expected_oid)" "$expected" "$task_id finish expected OID"
    assert_eq "$(json_field "$finish" baseline_oid)" "$base" "$task_id finish baseline OID"
    assert_eq "$(json_field "$finish" remote_oid)" "$expected" "$task_id remote read-back"
    if [[ "$task_id" == "$ALREADY_APPLIED_TASK" ]]; then
      # A crash after the push subprocess succeeded but before Yardlet saw the
      # result must recover by reading the remote back, not by pushing again.
      assert_eq "$(json_field "$finish" status)" already_applied \
        "$task_id idempotent post-push recovery"
      assert_eq "$(json_field "$finish" push_invoked)" false \
        "$task_id recovery must not push a second time"
    else
      assert_eq "$(json_field "$finish" remote_before_oid)" "$base" "$task_id remote-baseline guard"
      assert_eq "$(json_field "$finish" checks.0.passed)" true "$task_id configured check"
      assert_eq "$(json_field "$finish" push_invoked)" true "$task_id push invocation"
      assert_eq "$(json_field "$finish" push_succeeded)" true "$task_id push success"
    fi
    parents="$("$REAL_GIT" -C "$ws" show -s --format=%P "$expected")"
    parent1="${parents%% *}"
    parent2="${parents#* }"
    assert_eq "$parent1" "$base" "$task_id first-parent dependency order"
    owned="$(yaml_list "$run_yaml" owned_oids)"
    worker_oid="$(printf '%s\n' "$owned" | head -1)"
    assert_eq "$parent2" "$worker_oid" "$task_id merge second parent is isolated commit"
    assert_eq "$(printf '%s\n' "$owned" | tail -1)" "$expected" "$task_id merge OID ownership"
    assert_eq "$(grep -c "PUSH_SUCCESS.*${expected}:refs/heads/main" "$scenario/wrapper.log" || true)" 1 "$task_id exact refspec once"
    [[ ! -e "$(yaml_value "$run_yaml" worktree)" ]] || fail "$task_id successful worktree was retained"
    previous="$expected"
  done

  assert_eq "$(head_oid "$ws")" "$previous" "local final OID"
  assert_eq "$(remote_oid "$remote")" "$previous" "independent bare-remote final OID"
  assert_eq "$("$REAL_GIT" -C "$ws" rev-list --count "${baseline}..HEAD")" 8 "four isolated commits and four merge commits"
  assert_eq "$(wc -l <"$scenario/checks.log" | tr -d ' ')" "$EXPECTED_CHECK_LINES" "configured checks run count"
}

assert_feedback_and_cleanup() {
  local scenario="$1"
  local ws="$2"
  assert_eq "$(cat "$scenario/attempts/YARD-001")" 1 "builder worker invocation count"
  assert_eq "$(cat "$scenario/attempts/YARD-002")" 2 "reviewer remediation invocation count"
  assert_eq "$(cat "$scenario/attempts/YARD-004")" 1 "remediation worker invocation count"
  assert_eq "$(cat "$scenario/attempts/YARD-003")" 1 "independent re-review invocation count"
  assert_eq "$(find "$ws/.agents/runs" -name feedback.json -type f | wc -l | tr -d ' ')" 1 "exactly one feedback cycle"
  local feedback
  feedback="$(find "$ws/.agents/runs" -name feedback.json -type f)"
  assert_eq "$(json_field "$feedback" cycle)" 1 "feedback cycle number"
  grep -q 'failed check evidence: review_criteria_pass: criteria failed: AC-001' "$scenario/packets/YARD-004-1.md" || fail "remediation packet lacks injected failed check evidence"
  grep -q 'AC-001: reviewer attempt 1' "$scenario/packets/YARD-004-1.md" || fail "remediation packet lacks reviewer evidence"
  grep -q '^remediated$' "$ws/review.txt" || fail "review remediation did not merge"
  grep -q '^independent-pass$' "$ws/rereview.txt" || fail "independent re-review did not merge"
  assert_eq "$(yaml_task_states "$ws/.agents/work-queue.yaml")" "done done done done" "terminal queue projection"

  local partial_run partial_worktree
  partial_run="$(dirname "$feedback")"
  assert_eq "$(yaml_value "$partial_run/run.yaml" task_id)" YARD-002 "feedback run task"
  assert_eq "$(yaml_value "$partial_run/run.yaml" state)" queued "failed review re-queued behind remediation"
  partial_worktree="$(yaml_value "$partial_run/run.yaml" worktree)"
  [[ -d "$partial_worktree" ]] || fail "evaluated-Partial worktree was not retained"
  assert_eq "$("$REAL_GIT" -C "$ws" worktree list --porcelain | grep -c '^worktree ')" 2 "main plus retained Partial worktree"

  "$PYTHON" - "$ws/.agents/telemetry/runs.jsonl" <<'PY'
import json
import sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert len(records) == 5, records
review = [record for record in records if record["task_id"] == "YARD-002"]
assert len(review) == 2, review
assert review[0]["feedback_cycle"] == 1 and review[0]["eval_state"] == "Partial", review
assert review[1]["eval_state"] == "Done", review
assert sum(record["task_id"] == "YARD-004" and record["eval_state"] == "Done" for record in records) == 1, records
assert records[-1]["task_id"] == "YARD-003" and records[-1]["eval_state"] == "Done", records[-1]
PY
}

assert_no_unsafe_finish() {
  local scenario="$1"
  ! grep -Eiq 'https?://|ssh://|git@' "$scenario/wrapper.log" || fail "network/public remote appeared"
  local forced_push forced_other escaped_removal
  forced_push="$( (grep -E '(^|[[:space:]])push([[:space:]]|$)' "$scenario/wrapper.log" || true) \
    | grep -Ec '(^|[[:space:]])--force(-with-lease)?([[:space:]]|$)' || true)"
  assert_eq "$forced_push" 0 "force push must never appear"
  forced_other="$( (grep -E '(^|[[:space:]])--force(-with-lease)?([[:space:]]|$)' "$scenario/wrapper.log" || true) \
    | grep -Evc '(^|[[:space:]])worktree[[:space:]]' || true)"
  assert_eq "$forced_other" 0 "--force outside owned-worktree cleanup must never appear"
  escaped_removal="$( (grep -E '(^|[[:space:]])worktree[[:space:]]+remove([[:space:]]|$)' "$scenario/wrapper.log" || true) \
    | grep -Fvc '/.agents/worktrees/' || true)"
  assert_eq "$escaped_removal" 0 "worktree removal must stay inside the Yardlet-owned directory"
  assert_eq "$(grep -c '^PUSH_SUCCESS' "$scenario/wrapper.log" || true)" 4 "one Yardlet-owned push per successful task"
}

run_scenario() {
  local name="$1"
  local crash_mode="$2"
  local scenario ws remote baseline event pgid worker_before
  # Crash-window-specific expectations. A crash between the Prepared record
  # and the push is recovered by re-running the pre-push checks before the
  # retried push (one extra check line); a crash after the push subprocess
  # succeeded is recovered idempotently by reading the remote back (no second
  # push, no re-run checks for that task).
  EXPECTED_CHECK_LINES=4
  ALREADY_APPLIED_TASK=""
  case "$crash_mode" in
    before_push) EXPECTED_CHECK_LINES=5 ;;
    after_push) ALREADY_APPLIED_TASK="YARD-001" ;;
  esac
  scenario="$(new_workspace "$name")"
  ws="$scenario/clone"
  remote="$scenario/remote.git"
  baseline="$(head_oid "$ws")"

  if [[ "$name" == "serial-chain" ]]; then
    assert_wrapper_rejects_escape "$scenario" "$ws" "$remote"
  fi

  if [[ "$crash_mode" == "normal" ]]; then
    run_env "$scenario" "$ws" normal "$scenario/no-event" run --auto --execute --headless >"$scenario/run.log" 2>&1
  else
    event="$scenario/$crash_mode.event"
    launch_grouped_run "$scenario" "$ws" "$crash_mode" "$event" "$scenario/crashed-run.log"
    pgid="$GROUP_PID"
    wait_for_file "$event" "$crash_mode stop"
    assert_eq "$(cat "$event")" "$crash_mode" "$crash_mode event"
    assert_eq "$(ps -o pgid= -p "$(cat "$event.pid")" | tr -d ' ')" "$pgid" "$crash_mode wrapper process group"
    worker_before="$(cat "$scenario/attempts/YARD-001")"
    kill_process_group "$pgid"
    run_env "$scenario" "$ws" normal "$scenario/no-event" recover >"$scenario/recover.log" 2>&1
    assert_eq "$(cat "$scenario/attempts/YARD-001")" "$worker_before" "$crash_mode recovery worker count"
    run_env "$scenario" "$ws" normal "$scenario/no-event" run --auto --execute --headless >"$scenario/resume.log" 2>&1
  fi

  assert_run_projection "$scenario" "$ws" "$remote" "$baseline"
  assert_feedback_and_cleanup "$scenario" "$ws"
  assert_no_unsafe_finish "$scenario"

  cat >"$scenario/proof.json" <<EOF
{
  "scenario": "$name",
  "crash_mode": "$crash_mode",
  "baseline_oid": "$baseline",
  "local_oid": "$(head_oid "$ws")",
  "remote_oid": "$(remote_oid "$remote")",
  "worker_invocations": {"YARD-001": 1, "YARD-002": 2, "YARD-004": 1, "YARD-003": 1},
  "feedback_cycles": 1,
  "pushes": 4
}
EOF
}

run_scenario serial-chain normal
run_scenario crash-before-commit before_commit
run_scenario crash-after-commit after_commit
run_scenario crash-after-merge after_merge
run_scenario crash-before-push before_push
run_scenario crash-after-push after_push

public_remote_commands="$(
  (grep -R -Eih 'https?://|ssh://|git@' "$ROOT" --include='wrapper.log' || true) \
    | wc -l | tr -d ' '
)"
manual_finish_commands="$(
  (grep -R -Eh 'MANUAL_(COMMIT|MERGE|PUSH)' "$ROOT" || true) | wc -l | tr -d ' '
)"
wrapper_escape_rejections="$(
  (grep -R -Eh '^PUSH_REJECTED[[:space:]]+reason=' "$ROOT" \
    --include='wrapper.log' || true) | wc -l | tr -d ' '
)"
exit_trap_process_groups="$($PYTHON - "$EVIDENCE_DIR/exit-trap-cleanup.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    print(0)
else:
    proof = json.load(open(path, encoding="utf-8"))
    print(1 if proof.get("process_group_absent") is True else 0)
PY
)"
assert_eq "$public_remote_commands" 0 "public remote commands"
assert_eq "$manual_finish_commands" 0 "manual completion commands"
assert_eq "$wrapper_escape_rejections" 3 "wrapper escape rejection count"
assert_eq "$exit_trap_process_groups" 1 "EXIT trap process group cleanup proof"

cat >"$EVIDENCE_DIR/summary.json" <<EOF
{
  "status": "passed",
  "fixture_root": "$ROOT",
  "scenarios_passed": 6,
  "crash_windows_passed": 5,
  "public_remote_commands": $public_remote_commands,
  "manual_finish_commands": $manual_finish_commands,
  "ambient_git_config_ignored": true,
  "wrapper_escape_rejections": $wrapper_escape_rejections,
  "exit_trap_process_groups": $exit_trap_process_groups
}
EOF

printf 'V010-001A serial Git finish fixture passed: %s\n' "$EVIDENCE_DIR/summary.json"
