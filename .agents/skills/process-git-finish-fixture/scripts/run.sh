#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <yardlet-bin> <evidence-dir>\n' "$0" >&2
  exit 2
fi

bin=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
evidence=$2
scripts=$(cd "$(dirname "$0")" && pwd)
root=$(mktemp -d /tmp/yardlet-process-git-finish.XXXXXX)
mkdir -p "$evidence"
printf '%s\n' "$root" > "$evidence/fixture-root.txt"

make_workspace() {
  name="$1"
  check="$2"
  seed="$root/$name-seed"
  remote="$root/$name-remote.git"
  ws="$root/$name-work"
  mkdir -p "$seed"
  /usr/bin/git -C "$seed" init -q -b main
  /usr/bin/git -C "$seed" config user.name 'Yardlet Fixture'
  /usr/bin/git -C "$seed" config user.email 'yardlet-fixture@example.test'
  printf 'seed\n' > "$seed/seed.txt"
  printf 'outside\n' > "$seed/outside.txt"
  /usr/bin/git -C "$seed" add seed.txt outside.txt
  /usr/bin/git -C "$seed" commit -q -m seed
  /usr/bin/git clone -q --bare "$seed" "$remote"
  /usr/bin/git clone -q "$remote" "$ws"
  /usr/bin/git -C "$ws" remote rename origin fixture
  /usr/bin/git -C "$ws" config user.name 'Yardlet Fixture'
  /usr/bin/git -C "$ws" config user.email 'yardlet-fixture@example.test'
  (cd "$ws" && "$bin" init >/dev/null)
  cp "$scripts/workers.yaml" "$ws/.agents/workers.yaml"
  perl -0pi -e "s#__WORKER__#$scripts/worker.sh#g" "$ws/.agents/workers.yaml"
  perl -0pi -e "s/auto_push: false/auto_push: true/; s/remote: ''/remote: fixture/; s#target_ref: ''#target_ref: refs/heads/main#" "$ws/.agents/yardlet.yaml"
  if [ -n "$check" ]; then
    perl -0pi -e "s#pre_push_checks: \[\]#pre_push_checks:\n  - name: fixture\n    command: '$check'#" "$ws/.agents/yardlet.yaml"
  fi
  (cd "$ws" && "$bin" goal '격리 Git finish 실제 프로세스 검증' --worker fixture --plan-only >/dev/null)
  (cd "$ws" && "$bin" add '격리 병렬 보조 작업' --worker fixture >/dev/null)
  : > "$root/$name-worker-count"
  : > "$root/$name-push-invoked"
  : > "$root/$name-push-executed"
  printf '%s\n' "$ws"
}

task_run_dir() {
  ws="$1"
  task_id="$2"
  for run_dir in "$ws"/.agents/runs/run-*; do
    if grep -q "^task_id: $task_id$" "$run_dir/run.yaml" 2>/dev/null; then
      printf '%s\n' "$run_dir"
      return 0
    fi
  done
  return 1
}

wait_for_marker() {
  marker="$1"
  for _ in $(seq 1 200); do
    [ -s "$marker" ] && return 0
    sleep 0.05
  done
  return 1
}

kill_fixture_group() {
  launcher_pid="$1"
  marker="$2"
  wrapper_pid=$(awk '{print $1}' "$marker")
  pgid=$(awk '{print $2}' "$marker")
  test "$pgid" = "$launcher_pid"
  /bin/kill -TERM -"$pgid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    if ! /bin/kill -0 "$wrapper_pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  printf 'wrapper pid survived process-group termination: %s\n' "$wrapper_pid" >&2
  return 1
}

recover_twice() {
  name="$1"
  ws="$2"
  marker="$root/$name-marker"
  common_env="PATH=$scripts:$PATH YARD_FIXTURE_MODE=normal YARD_FIXTURE_PUSH_INVOKED=$root/$name-push-invoked YARD_FIXTURE_PUSH_EXECUTED=$root/$name-push-executed YARD_FIXTURE_MARKER=$marker"
  (cd "$ws" && env $common_env "$bin" recover > "$root/$name-recover-1.log" 2>&1) &
  first=$!
  (cd "$ws" && env $common_env "$bin" recover > "$root/$name-recover-2.log" 2>&1) &
  second=$!
  wait "$first"
  wait "$second"
}

run_crash_case() {
  name="$1"
  ws=$(make_workspace "$name" true)
  marker="$root/$name-marker"
  (cd "$ws" && exec /usr/bin/perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV' \
    env PATH="$scripts:$PATH" \
    YARD_FIXTURE_MODE="$name" \
    YARD_FIXTURE_PUSH_INVOKED="$root/$name-push-invoked" \
    YARD_FIXTURE_PUSH_EXECUTED="$root/$name-push-executed" \
    YARD_FIXTURE_MARKER="$marker" \
    YARD_FIXTURE_WORKER_COUNT="$root/$name-worker-count" \
    "$bin" run --auto --parallel 2 --accept-ambiguity) > "$root/$name-run.log" 2>&1 &
  launcher_pid=$!
  wait_for_marker "$marker"
  kill_fixture_group "$launcher_pid" "$marker"
  run_dir=$(task_run_dir "$ws" YARD-001)
  cp "$run_dir/git-finish.json" "$evidence/$name-prepared.json"
  recover_twice "$name" "$ws"

  run_dir=$(task_run_dir "$ws" YARD-001)
  cp "$run_dir/git-finish.json" "$evidence/$name-git-finish.json"
  cp "$run_dir/run.yaml" "$evidence/$name-run.yaml"
  cp "$ws/.agents/work-queue.yaml" "$evidence/$name-queue.yaml"
  cp "$ws/.agents/telemetry/runs.jsonl" "$evidence/$name-telemetry.jsonl"
  (cd "$ws" && "$bin" report) > "$evidence/$name-final-report.md"
  /usr/bin/git -C "$ws" ls-remote --refs fixture refs/heads/main | awk '{print $1}' > "$evidence/$name-remote-oid.txt"

  test "$(sed -n '1p' "$root/$name-push-executed")" = 1
  test "$(wc -l < "$root/$name-worker-count" | tr -d ' ')" = 2
  status=$(jq -r '.status' "$run_dir/git-finish.json")
  case "$status" in
    pushed|already_applied) ;;
    *) printf 'unverified recovery status: %s\n' "$status" >&2; return 1 ;;
  esac
  test "$(jq -r '.expected_oid' "$run_dir/git-finish.json")" = "$(cat "$evidence/$name-remote-oid.txt")"
  grep -q '^  state: done$' "$ws/.agents/work-queue.yaml"
  grep -q '^state: done$' "$run_dir/run.yaml"
  telemetry_count=$(jq -r --arg run_id "$(basename "$run_dir")" 'select(.run_id == $run_id) | .run_id' "$ws/.agents/telemetry/runs.jsonl" | wc -l | tr -d ' ')
  test "$telemetry_count" = 1
  grep -q '1/2 tasks done' "$evidence/$name-final-report.md"
  grep -q 'YARD-001 .* — Done' "$evidence/$name-final-report.md"
}

run_crash_case before
run_crash_case after

rename_ws=$(make_workspace rename 'git mv outside.txt .agents/inside.txt')
(cd "$rename_ws" && env \
  PATH="$scripts:$PATH" \
  YARD_FIXTURE_MODE=normal \
  YARD_FIXTURE_PUSH_INVOKED="$root/rename-push-invoked" \
  YARD_FIXTURE_PUSH_EXECUTED="$root/rename-push-executed" \
  YARD_FIXTURE_MARKER="$root/rename-marker" \
  YARD_FIXTURE_WORKER_COUNT="$root/rename-worker-count" \
  "$bin" run --auto --parallel 2 --accept-ambiguity) > "$root/rename-run.log" 2>&1 || true
rename_run=$(task_run_dir "$rename_ws" YARD-001)
cp "$rename_run/git-finish.json" "$evidence/rename-git-finish.json"
cp "$rename_ws/.agents/work-queue.yaml" "$evidence/rename-queue.yaml"
/usr/bin/git -C "$rename_ws" ls-remote --refs fixture refs/heads/main | awk '{print $1}' > "$evidence/rename-remote-oid.txt"
test "$(jq -r '.reason' "$rename_run/git-finish.json")" = worktree_changed_during_checks
test "$(jq -r '.push_invoked' "$rename_run/git-finish.json")" = false
test ! -s "$root/rename-push-executed"
grep -q '^  state: partial$' "$rename_ws/.agents/work-queue.yaml"

jq -n \
  --arg root "$root" \
  --arg before_status "$(jq -r '.status' "$evidence/before-git-finish.json")" \
  --arg before_oid "$(cat "$evidence/before-remote-oid.txt")" \
  --arg after_status "$(jq -r '.status' "$evidence/after-git-finish.json")" \
  --arg after_oid "$(cat "$evidence/after-remote-oid.txt")" \
  --arg rename_reason "$(jq -r '.reason' "$evidence/rename-git-finish.json")" \
  '{schema_version:1, fixture_root:$root, interrupt_before:{status:$before_status, remote_oid:$before_oid, worker_runs_before_recover:2, worker_runs_after_recover:2, pushes_executed:1, wrapper_process_group_terminated:true, queue_run_telemetry_report_converged:true}, interrupt_after:{status:$after_status, remote_oid:$after_oid, worker_runs_before_recover:2, worker_runs_after_recover:2, pushes_executed:1, wrapper_process_group_terminated:true, queue_run_telemetry_report_converged:true}, rename:{reason:$rename_reason, push_invoked:false, pushes_executed:0, queue_partial:true}}' \
  > "$evidence/process-proof.json"

printf 'process git-finish fixture passed: %s\n' "$root"
