#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <yardlet-bin> <evidence-dir> <scenario>" >&2
  exit 64
fi

YARDLET_BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EVIDENCE_DIR="$2"
SCENARIO="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ROOT="$(mktemp -d "$EVIDENCE_DIR/workspace.XXXXXX")"
PLANNER="$ROOT/planner-worker.sh"
cp "$SCRIPT_DIR/planner-worker.sh" "$PLANNER"
chmod +x "$PLANNER"

if [[ "$SCENARIO" == "confirmed_auto_runtime_envelope" ]]; then
  touch "$ROOT/.fixture-confirmed-auto"
fi

fail() {
  printf 'fixture failure: %s\n' "$*" >&2
  exit 1
}

run_yardlet() {
  (cd "$ROOT" && "$YARDLET_BIN" "$@")
}

run_in() {
  local root="$1"
  shift
  (cd "$root" && "$YARDLET_BIN" "$@")
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
if value is None:
    print("none")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

json_len() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print(len(value))
PY
}

show() {
  run_yardlet planning show --json >"$EVIDENCE_DIR/show.json"
}

proposal() {
  show
  json_get "$EVIDENCE_DIR/show.json" pending_proposals.0.proposal_id
}

visible_head() {
  show
  json_get "$EVIDENCE_DIR/show.json" session.current_head
}

revision_count() {
  find "$ROOT/.agents/planning-sessions" -path '*/drafts/*.yaml' -type f | wc -l | tr -d ' '
}

accept_proposal() {
  local proposal_id="$1"
  local expected="$2"
  local action_id="$3"
  run_yardlet planning accept "$proposal_id" --expected-head "$expected" --action-id "$action_id"
}

answer_turn() {
  local text="$1"
  local expected="$2"
  local action_id="$3"
  run_yardlet planning answer "$text" --expected-head "$expected" --action-id "$action_id" --worker fixture-planner
}

write_summary() {
  local detail="$1"
  cat >"$EVIDENCE_DIR/summary.json" <<EOF
{
  "status": "passed",
  "scenario": "$SCENARIO",
  "detail": "$detail"
}
EOF
}

wait_for_file() {
  local path="$1"
  local pid="${2:-}"
  for _ in $(seq 1 250); do
    [[ -f "$path" ]] && return 0
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.02
  done
  return 1
}

wait_for_worker_exit() {
  local run_dir="$1"
  local pid
  pid="$(cat "$run_dir/worker.pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 0
  for _ in $(seq 1 250); do
    ! kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.02
  done
  return 1
}

state_digest() {
  local root="$1"
  (cd "$root" && find .agents -type f ! -name planning.lock -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')
}

state_manifest() {
  local root="$1"
  (cd "$root" && find .agents -type f ! -name planning.lock -print0 | sort -z | xargs -0 shasum)
}

run_yardlet init >/dev/null
cat >"$ROOT/.agents/workers.yaml" <<EOF
schema_version: 1
workers:
  - id: fixture-planner
    kind: cli_worker
    best_for: deterministic planning fixture
    billing:
      mode: subscription_backed_only
    invocation:
      command: $PLANNER
      supports_noninteractive: true
      output_contract: files
      args: ["{run_dir}"]
    limits:
      max_wall_minutes: 1
      max_retries: 0
routing:
  default_worker: fixture-planner
  fallback_order: [fixture-planner]
  planning_gate:
    primary: fixture-planner
    fallback: ""
EOF

if [[ "$SCENARIO" == "confirmed_auto_runtime_envelope" ]]; then
  python3 - "$ROOT/.agents/yardlet.yaml" "$ROOT/.agents/workers.yaml" <<'PY'
import re
import sys
config_path, workers_path = sys.argv[1:]
config = open(config_path, encoding="utf-8").read()
config, count = re.subn(r"^max_parallel: \d+$", "max_parallel: 2", config, count=1, flags=re.M)
if count != 1:
    raise SystemExit("failed to configure parallel fixture")
open(config_path, "w", encoding="utf-8").write(config)
workers = open(workers_path, encoding="utf-8").read()
workers, count = re.subn(
    r"^(    kind: cli_worker)$",
    r"\1\n    model: fixture-model",
    workers,
    count=1,
    flags=re.M,
)
if count != 1:
    raise SystemExit("failed to configure fixture worker model")
open(workers_path, "w", encoding="utf-8").write(workers)
PY
fi

if [[ "$SCENARIO" == "runtime_transition_provenance" ]]; then
  touch "$ROOT/.fixture-two-task"
fi

run_yardlet new "initial planning request" --worker fixture-planner >/dev/null
p1="$(proposal)"

case "$SCENARIO" in
  accept)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    show
    [[ "$(json_get "$EVIDENCE_DIR/show.json" session.lifecycle)" == "open" ]] || fail "session not open"
    [[ "$(json_get "$EVIDENCE_DIR/show.json" activation)" == "none" ]] || fail "accept activated work"
    [[ ! -f "$ROOT/.agents/intent-contract.yaml" ]] || fail "accept wrote active intent"
    write_summary "proposal accepted without activation"
    ;;
  reject)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "scope correction" "$h1" act-answer-2 >/dev/null
    p2="$(proposal)"
    run_yardlet planning reject "$p2" --expected-head "$h1" --action-id act-reject-2 >/dev/null
    [[ "$(visible_head)" == "$h1" ]] || fail "reject changed head"
    write_summary "proposal rejected and head preserved"
    ;;
  undo)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "scope correction" "$h1" act-answer-2 >/dev/null
    p2="$(proposal)"
    accept_proposal "$p2" "$h1" act-accept-2 >/dev/null
    h2="$(visible_head)"
    run_yardlet planning undo --expected-head "$h2" --action-id act-undo-2 >/dev/null
    [[ "$(visible_head)" == "$h1" ]] || fail "undo did not restore parent"
    write_summary "undo restored parent revision"
    ;;
  stale_head)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "scope correction" "$h1" act-answer-2 >/dev/null
    p2="$(proposal)"
    if accept_proposal "$p2" none act-stale >/dev/null 2>"$EVIDENCE_DIR/stale.err"; then
      fail "stale expected head was accepted"
    fi
    grep -q "stale_head" "$EVIDENCE_DIR/stale.err" || fail "stale error missing"
    [[ "$(visible_head)" == "$h1" ]] || fail "stale action changed head"
    write_summary "stale expected head rejected"
    ;;
  restart_confirm)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    run_yardlet planning show --json >"$EVIDENCE_DIR/restarted.json"
    [[ "$(json_get "$EVIDENCE_DIR/restarted.json" session.current_head)" == "$h1" ]] || fail "restart lost head"
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-1 >/dev/null
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-1 >/dev/null
    show
    [[ "$(json_get "$EVIDENCE_DIR/show.json" session.lifecycle)" == "confirmed" ]] || fail "session not confirmed"
    [[ "$(json_get "$EVIDENCE_DIR/show.json" activation.status)" == "committed" ]] || fail "activation not committed"
    [[ "$(json_get "$EVIDENCE_DIR/show.json" exact_active_parity)" == "true" ]] || fail "active parity false"
    write_summary "restart restored history and confirm provenance"
    ;;
  runtime_transition_provenance)
    accept_proposal "$p1" none act-runtime-transition-accept >/dev/null
    head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$head" --action-id act-runtime-transition-confirm >/dev/null
    queue_before="$EVIDENCE_DIR/runtime-transition-queue-before.yaml"
    cp "$ROOT/.agents/work-queue.yaml" "$queue_before"
    materialized_digest="$(sed -n 's/^materialized_queue_digest: //p' "$queue_before")"
    [[ -n "$materialized_digest" ]] || fail "confirmed queue omitted immutable materialized digest"
    materialized_before="$(sed -n '/^materialized_queue:/,$p' "$queue_before" | shasum | awk '{print $1}')"

    (cd "$ROOT" && git init -q && git config user.name fixture && git config user.email fixture@example.invalid && \
      git add .agents/yardlet.yaml && git commit -qm baseline)
    run_yardlet run --task YARD-001 --execute >"$EVIDENCE_DIR/runtime-transition-run.out" 2>"$EVIDENCE_DIR/runtime-transition-run.err"
    run_yardlet planning show --json >"$EVIDENCE_DIR/runtime-transition-restarted.json"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-transition-restarted.json" activation.status)" == "committed" ]] || fail "fresh process lost committed activation"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-transition-restarted.json" exact_active_parity)" == "true" ]] || fail "first runtime failure broke exact active parity"
    grep -q '^activation_required: true$' "$ROOT/.agents/work-queue.yaml" || fail "runtime transition stripped activation envelope"
    grep -q '^planning_session_id:' "$ROOT/.agents/work-queue.yaml" || fail "runtime transition stripped session provenance"
    [[ "$materialized_digest" == "$(sed -n 's/^materialized_queue_digest: //p' "$ROOT/.agents/work-queue.yaml")" ]] || fail "runtime transition changed immutable materialized digest"
    [[ "$materialized_before" == "$(sed -n '/^materialized_queue:/,$p' "$ROOT/.agents/work-queue.yaml" | shasum | awk '{print $1}')" ]] || fail "runtime transition changed immutable materialized snapshot"
    run_yardlet queue >"$EVIDENCE_DIR/runtime-transition-queue.out"
    grep -q 'evaluation status: failed' "$EVIDENCE_DIR/runtime-transition-run.out" || fail "first task did not execute a failed evaluation"
    sed -n '1,/^materialized_queue:/p' "$ROOT/.agents/work-queue.yaml" | \
      sed -n '/^- id: YARD-001$/,/^- id: YARD-002$/p' | grep -q '^  state: needs_user$' || fail "failed first task did not reach its terminal gate"
    sed -n '1,/^materialized_queue:/p' "$ROOT/.agents/work-queue.yaml" | \
      sed -n '/^- id: YARD-002$/,$p' | grep -q '^  state: queued$' || fail "second task did not remain Queued"
    run_yardlet run --task YARD-002 >"$EVIDENCE_DIR/runtime-transition-next.out"
    grep -q 'selected task YARD-002' "$EVIDENCE_DIR/runtime-transition-next.out" || fail "fresh process could not prepare second task"
    write_summary "2-task confirm 뒤 첫 실제 worker failure가 immutable activation provenance를 보존하고 fresh process에서 두 번째 task가 runnable함"
    ;;
  partial_promotion)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-1 >/dev/null
    activation_path="$(find "$ROOT/.agents/activations" -type f -name '*.yaml' | head -n 1)"
    cp "$activation_path" "$EVIDENCE_DIR/activation.yaml"
    cp "$ROOT/.agents/intent-contract.yaml" "$EVIDENCE_DIR/intent.yaml"
    cp "$ROOT/.agents/work-queue.yaml" "$EVIDENCE_DIR/queue.yaml"
    rm "$activation_path"
    if run_yardlet run --next >"$EVIDENCE_DIR/run.out" 2>"$EVIDENCE_DIR/run.err"; then
      fail "partial promotion became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/run.err" || fail "missing fail-closed reason"
    cp "$EVIDENCE_DIR/activation.yaml" "$activation_path"
    rm "$ROOT/.agents/work-queue.yaml"
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/missing-queue.err"; then
      fail "intent-only partial promotion became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/missing-queue.err" || fail "missing queue reason missing"
    cp "$EVIDENCE_DIR/queue.yaml" "$ROOT/.agents/work-queue.yaml"
    rm "$ROOT/.agents/intent-contract.yaml"
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/missing-intent.err"; then
      fail "queue-only partial promotion became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/missing-intent.err" || fail "missing intent reason missing"
    cp "$EVIDENCE_DIR/intent.yaml" "$ROOT/.agents/intent-contract.yaml"
    python3 - "$ROOT/.agents/intent-contract.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("confirmation_id: cnf_", "confirmation_id: forged_", 1)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/confirmation.err"; then
      fail "confirmation id tamper became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/confirmation.err" || fail "confirmation tamper reason missing"
    cp "$EVIDENCE_DIR/intent.yaml" "$ROOT/.agents/intent-contract.yaml"
    python3 - "$activation_path" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("draft_revision_id: drv_", "draft_revision_id: forged_", 1)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/draft.err"; then
      fail "draft id tamper became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/draft.err" || fail "draft tamper reason missing"
    cp "$EVIDENCE_DIR/activation.yaml" "$activation_path"
    python3 - "$ROOT/.agents/work-queue.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("materialized_by_confirmation_id: cnf_", "materialized_by_confirmation_id: forged_", 1)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/materialized.err"; then
      fail "task materialization tamper became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/materialized.err" || fail "materialization tamper reason missing"
    cp "$EVIDENCE_DIR/queue.yaml" "$ROOT/.agents/work-queue.yaml"
    python3 - "$ROOT/.agents/intent-contract.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace("summary: 초기", "summary: 변조된", 1)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/digest.err"; then
      fail "intent digest tamper became runnable"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/digest.err" || fail "digest tamper reason missing"
    write_summary "missing commit, intent-only, queue-only, and linkage tampering are non-runnable"
    ;;
  running_isolation)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-1 >/dev/null
    if run_yardlet planning answer "mutate confirmed queue" --expected-head "$h1" --action-id act-late --worker fixture-planner >"$EVIDENCE_DIR/late.out" 2>"$EVIDENCE_DIR/late.err"; then
      fail "confirmed session accepted free-form mutation"
    fi
    grep -q "confirmed" "$EVIDENCE_DIR/late.err" || fail "confirmed mutation error missing"
    run_yardlet new "plan while active work is isolated" --worker fixture-planner >/dev/null
    p2="$(proposal)"
    accept_proposal "$p2" none act-accept-next >/dev/null
    h2="$(visible_head)"
    python3 - "$ROOT/.agents/work-queue.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace("state: queued", "state: running", 1)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet planning confirm --expected-head "$h2" --action-id act-confirm-running >"$EVIDENCE_DIR/running.out" 2>"$EVIDENCE_DIR/running.err"; then
      fail "running queue was replaced by planning confirmation"
    fi
    grep -Eq "running_queue_isolated|unconfirmed_or_inconsistent" "$EVIDENCE_DIR/running.err" || fail "running isolation error missing"
    write_summary "confirmed session mutation and running queue replacement are rejected"
    ;;
  goal_regression)
    goal_default="$(mktemp -d "$EVIDENCE_DIR/goal-default.XXXXXX")"
    (cd "$goal_default" && "$YARDLET_BIN" init >/dev/null)
    cp "$ROOT/.agents/workers.yaml" "$goal_default/.agents/workers.yaml"
    (cd "$goal_default" && "$YARDLET_BIN" goal "default express fixture" --plan-only >/dev/null)
    [[ ! -f "$goal_default/.fixture-planning-turn" ]] || fail "default goal invoked planner"
    [[ -n "$(find "$goal_default/.agents/activations" -type f -name '*.yaml' -print -quit)" ]] || fail "default goal activation missing"
    (cd "$goal_default" && "$YARDLET_BIN" planning show --json) >"$EVIDENCE_DIR/goal-default.json"
    [[ "$(json_len "$EVIDENCE_DIR/goal-default.json" current_draft.content.queue.tasks)" == "1" ]] || fail "default goal task count changed"
    [[ "$(json_get "$EVIDENCE_DIR/goal-default.json" exact_active_parity)" == "true" ]] || fail "default goal parity false"
    (cd "$goal_default" && "$YARDLET_BIN" run --next) >"$EVIDENCE_DIR/goal-default-run.out"
    grep -q "prepared" "$EVIDENCE_DIR/goal-default-run.out" || fail "default goal queue not runnable"

    goal_verify="$(mktemp -d "$EVIDENCE_DIR/goal-verify.XXXXXX")"
    (cd "$goal_verify" && "$YARDLET_BIN" init >/dev/null)
    cp "$ROOT/.agents/workers.yaml" "$goal_verify/.agents/workers.yaml"
    (cd "$goal_verify" && "$YARDLET_BIN" goal "verified express fixture" --verify "fixture verified" --plan-only >/dev/null)
    [[ ! -f "$goal_verify/.fixture-planning-turn" ]] || fail "verified goal invoked planner"
    [[ -n "$(find "$goal_verify/.agents/activations" -type f -name '*.yaml' -print -quit)" ]] || fail "verified goal activation missing"
    (cd "$goal_verify" && "$YARDLET_BIN" planning show --json) >"$EVIDENCE_DIR/goal-verify.json"
    [[ "$(json_len "$EVIDENCE_DIR/goal-verify.json" current_draft.content.queue.tasks)" == "2" ]] || fail "verified goal task count changed"
    [[ "$(json_get "$EVIDENCE_DIR/goal-verify.json" exact_active_parity)" == "true" ]] || fail "verified goal parity false"
    (cd "$goal_verify" && "$YARDLET_BIN" run --next) >"$EVIDENCE_DIR/goal-verify-run.out"
    grep -q "prepared" "$EVIDENCE_DIR/goal-verify-run.out" || fail "verified goal queue not runnable"
    write_summary "default and verified goal express paths confirmed without planner"
    ;;
  dogfood)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "scope correction" "$h1" act-answer-2 >/dev/null
    p2="$(proposal)"
    accept_proposal "$p2" "$h1" act-accept-2 >/dev/null
    h2="$(visible_head)"
    answer_turn "acceptance correction to reject" "$h2" act-answer-3 >/dev/null
    p3="$(proposal)"
    run_yardlet planning reject "$p3" --expected-head "$h2" --action-id act-reject-3 >/dev/null
    answer_turn "final acceptance correction" "$h2" act-answer-4 >/dev/null
    p4="$(proposal)"
    accept_proposal "$p4" "$h2" act-accept-4 >/dev/null
    h4="$(visible_head)"
    run_yardlet planning undo --expected-head "$h4" --action-id act-undo-4 >/dev/null
    [[ "$(visible_head)" == "$h2" ]] || fail "dogfood undo did not restore visible head"
    run_yardlet planning show --json >"$EVIDENCE_DIR/pre-confirm.json"
    run_yardlet planning confirm --expected-head "$h2" --action-id act-confirm-final >/dev/null
    show
    [[ "$(json_get "$EVIDENCE_DIR/show.json" exact_active_parity)" == "true" ]] || fail "dogfood exact parity false"
    [[ "$(json_get "$EVIDENCE_DIR/show.json" channel_turn_count)" -ge 4 ]] || fail "dogfood content turns missing"
    [[ "$(json_get "$EVIDENCE_DIR/show.json" rejected_proposal_count)" -ge 1 ]] || fail "dogfood reject provenance missing"
    [[ "$(json_get "$EVIDENCE_DIR/show.json" undo_count)" -ge 1 ]] || fail "dogfood undo provenance missing"
    cp "$EVIDENCE_DIR/show.json" "$EVIDENCE_DIR/dogfood-final.json"
    write_summary "four content turns, accept, reject, undo, restart, confirm, exact parity"
    ;;
  terminal_proposal)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "proposal to reject" "$h1" act-answer-2 >/dev/null
    p2="$(proposal)"
    run_yardlet planning reject "$p2" --expected-head "$h1" --action-id act-reject-2 >/dev/null
    before_count="$(revision_count)"
    if accept_proposal "$p2" "$h1" act-reaccept-rejected >"$EVIDENCE_DIR/reaccept-rejected.out" 2>"$EVIDENCE_DIR/reaccept-rejected.err"; then
      fail "rejected proposal was accepted"
    fi
    [[ "$(visible_head)" == "$h1" ]] || fail "rejected proposal reaccept changed head"
    [[ "$(revision_count)" == "$before_count" ]] || fail "rejected proposal reaccept created revision"
    if run_yardlet planning reject "$p2" --expected-head "$h1" --action-id act-rereject >"$EVIDENCE_DIR/rereject.out" 2>"$EVIDENCE_DIR/rereject.err"; then
      fail "rejected proposal was rejected twice with a new action"
    fi
    [[ "$(visible_head)" == "$h1" ]] || fail "duplicate reject changed head"
    [[ "$(revision_count)" == "$before_count" ]] || fail "duplicate reject created revision"
    run_yardlet planning reject "$p2" --expected-head "$h1" --action-id act-reject-2 >/dev/null
    answer_turn "proposal to accept once" "$h1" act-answer-3 >/dev/null
    p3="$(proposal)"
    accept_proposal "$p3" "$h1" act-accept-3 >/dev/null
    h3="$(visible_head)"
    run_yardlet planning undo --expected-head "$h3" --action-id act-undo-3 >/dev/null
    [[ "$(visible_head)" == "$h1" ]] || fail "setup undo did not restore head"
    before_count="$(revision_count)"
    if accept_proposal "$p3" "$h1" act-reaccept-accepted >"$EVIDENCE_DIR/reaccept-accepted.out" 2>"$EVIDENCE_DIR/reaccept-accepted.err"; then
      fail "accepted proposal was accepted twice"
    fi
    if run_yardlet planning reject "$p3" --expected-head "$h1" --action-id act-reject-accepted >"$EVIDENCE_DIR/reject-accepted.out" 2>"$EVIDENCE_DIR/reject-accepted.err"; then
      fail "accepted proposal was later rejected"
    fi
    [[ "$(visible_head)" == "$h1" ]] || fail "disposed proposal mutation changed head"
    [[ "$(revision_count)" == "$before_count" ]] || fail "disposed proposal mutation created revision"
    write_summary "rejected and accepted proposals are terminal and idempotent replay is stable"
    ;;
  undo_integrity)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "second revision" "$h1" act-answer-2 >/dev/null
    p2="$(proposal)"
    accept_proposal "$p2" "$h1" act-accept-2 >/dev/null
    h2="$(visible_head)"
    session_dir="$(dirname "$(dirname "$(find "$ROOT/.agents/planning-sessions" -path "*/drafts/$h2.yaml" -print -quit)")")"
    current_path="$session_dir/drafts/$h2.yaml"
    parent_path="$session_dir/drafts/$h1.yaml"
    cp "$current_path" "$EVIDENCE_DIR/current.yaml"
    cp "$parent_path" "$EVIDENCE_DIR/parent.yaml"
    before_count="$(revision_count)"

    python3 - "$current_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^content_digest: .*?$", "content_digest: forged", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet planning undo --expected-head "$h2" --action-id act-undo-bad-digest >"$EVIDENCE_DIR/undo-digest.out" 2>"$EVIDENCE_DIR/undo-digest.err"; then
      fail "undo accepted corrupt current digest"
    fi
    [[ "$(sed -n 's/^current_head: //p' "$session_dir/session.yaml")" == "$h2" ]] || fail "corrupt digest undo changed head"
    cp "$EVIDENCE_DIR/current.yaml" "$current_path"

    python3 - "$current_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^parent_revision_id: .*?$", "parent_revision_id: missing-parent", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet planning undo --expected-head "$h2" --action-id act-undo-missing-parent >"$EVIDENCE_DIR/undo-missing.out" 2>"$EVIDENCE_DIR/undo-missing.err"; then
      fail "undo accepted missing parent"
    fi
    [[ "$(sed -n 's/^current_head: //p' "$session_dir/session.yaml")" == "$h2" ]] || fail "missing parent undo changed head"
    cp "$EVIDENCE_DIR/current.yaml" "$current_path"

    python3 - "$parent_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^session_id: .*?$", "session_id: forged-session", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet planning undo --expected-head "$h2" --action-id act-undo-foreign-parent >"$EVIDENCE_DIR/undo-parent.out" 2>"$EVIDENCE_DIR/undo-parent.err"; then
      fail "undo accepted cross-session parent"
    fi
    [[ "$(sed -n 's/^current_head: //p' "$session_dir/session.yaml")" == "$h2" ]] || fail "cross-session parent undo changed head"
    [[ "$(revision_count)" == "$before_count" ]] || fail "invalid undo changed revision count"
    cp "$EVIDENCE_DIR/parent.yaml" "$parent_path"
    show
    [[ "$(json_get "$EVIDENCE_DIR/show.json" current_draft.draft_revision_id)" == "$h2" ]] || fail "projection did not recover after rejected undo"
    write_summary "undo rejects current digest and parent referential-integrity corruption"
    ;;
  stripped_modern)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-strip >/dev/null
    rm -rf "$ROOT/.agents/activations"
    rm -f "$ROOT/.agents/activation-required.yaml"
    python3 - "$ROOT/.agents/intent-contract.yaml" "$ROOT/.agents/work-queue.yaml" <<'PY'
import sys
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8").readlines()
    stripped = []
    for line in lines:
        key = line.strip().split(":", 1)[0]
        if key in {
            "planning_session_id",
            "confirmation_id",
            "draft_revision_id",
            "draft_content_digest",
            "materialized_queue_digest",
            "materialized_by_confirmation_id",
            "activation_required",
        }:
            continue
        if line.startswith("materialized_queue:"):
            break
        stripped.append(line)
    open(path, "w", encoding="utf-8").writelines(stripped)
PY
    if run_yardlet run --next >"$EVIDENCE_DIR/stripped.out" 2>"$EVIDENCE_DIR/stripped.err"; then
      fail "stripped modern activation fell back to Legacy"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/stripped.err" || fail "stripped modern failure reason missing"
    write_summary "modern activation marker survives stripped linkage and fails closed"
    ;;
  legacy_v1)
    accept_proposal "$p1" none act-legacy-source-accept >/dev/null
    head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$head" --action-id act-legacy-source-confirm >/dev/null
    rm -rf "$ROOT/.agents/activations" "$ROOT/.agents/planning-sessions"
    rm -f "$ROOT/.agents/activation-required.yaml"
    python3 - "$ROOT/.agents/intent-contract.yaml" "$ROOT/.agents/work-queue.yaml" <<'PY'
import sys
intent_path, queue_path = sys.argv[1:]
intent_lines = open(intent_path, encoding="utf-8").readlines()
intent_lines = [line for line in intent_lines if line.strip().split(":", 1)[0] not in {
    "activation_required", "planning_session_id", "confirmation_id",
    "draft_revision_id", "draft_content_digest",
}]
open(intent_path, "w", encoding="utf-8").writelines(intent_lines)

queue_lines = open(queue_path, encoding="utf-8").readlines()
legacy = []
for line in queue_lines:
    if line.startswith("planning_session_id:"):
        break
    if line.strip().split(":", 1)[0] in {
        "activation_required", "materialized_by_confirmation_id",
        "materialized_queue_digest",
    }:
        continue
    legacy.append(line)
open(queue_path, "w", encoding="utf-8").writelines(legacy)
PY
    run_yardlet queue >"$EVIDENCE_DIR/legacy-v1-queue.out"
    run_yardlet run --next >"$EVIDENCE_DIR/legacy-v1-run.out"
    grep -q 'selected task YARD-001' "$EVIDENCE_DIR/legacy-v1-run.out" || fail "plain legacy v1 queue stopped being runnable"
    write_summary "modern record가 전혀 없는 plain legacy v1 intent/queue는 기존 runnable semantics를 유지함"
    ;;
  activation_action_linkage)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-linkage >/dev/null
    activation_path="$(find "$ROOT/.agents/activations" -type f -name '*.yaml' -print -quit)"
    action_path="$(find "$ROOT/.agents/planning-sessions" -path '*/actions/act-confirm-linkage.yaml' -print -quit)"
    cp "$activation_path" "$EVIDENCE_DIR/linkage-activation.yaml"
    cp "$action_path" "$EVIDENCE_DIR/linkage-action.yaml"

    rm "$action_path"
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/action-missing.err"; then
      fail "activation with missing action receipt became runnable"
    fi
    cp "$EVIDENCE_DIR/linkage-action.yaml" "$action_path"
    python3 - "$action_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^status: completed$", "status: rejected", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/action-rejected.err"; then
      fail "activation with rejected action receipt became runnable"
    fi
    cp "$EVIDENCE_DIR/linkage-action.yaml" "$action_path"
    python3 - "$action_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^request_digest: .*?$", "request_digest: forged", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/action-digest.err"; then
      fail "activation with digest-conflicting action receipt became runnable"
    fi
    cp "$EVIDENCE_DIR/linkage-action.yaml" "$action_path"
    python3 - "$activation_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^action_id: .*?$", "action_id: missing-action", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/activation-action.err"; then
      fail "activation pointing to another action became runnable"
    fi
    cp "$EVIDENCE_DIR/linkage-activation.yaml" "$activation_path"
    draft_path="$(find "$ROOT/.agents/planning-sessions" -path "*/drafts/$h1.yaml" -print -quit)"
    cp "$draft_path" "$EVIDENCE_DIR/linkage-draft.yaml"
    python3 - "$draft_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^session_id: .*?$", "session_id: forged-session", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    if run_yardlet run --next >/dev/null 2>"$EVIDENCE_DIR/draft-session.err"; then
      fail "confirmed draft with cross-session identity became runnable"
    fi
    cp "$EVIDENCE_DIR/linkage-draft.yaml" "$draft_path"
    for error in "$EVIDENCE_DIR"/action-*.err "$EVIDENCE_DIR/activation-action.err" "$EVIDENCE_DIR/draft-session.err"; do
      grep -q "unconfirmed_or_inconsistent" "$error" || fail "action linkage reason missing in $error"
    done
    write_summary "activation requires a same-session completed matching confirm action"
    ;;
  confirm_crash_replay)
    accept_proposal "$p1" none act-accept-1 >/dev/null
    h1="$(visible_head)"
    if [[ -f "$ROOT/.agents/work-queue.yaml" ]]; then
      cp "$ROOT/.agents/work-queue.yaml" "$EVIDENCE_DIR/pre-confirm-queue.yaml"
    else
      touch "$EVIDENCE_DIR/pre-confirm-queue.missing"
    fi
    run_yardlet planning confirm --expected-head "$h1" --action-id act-confirm-crash >/dev/null
    baseline="$EVIDENCE_DIR/confirm-baseline"
    cp -R "$ROOT" "$baseline"
    for window in prepare intent_only snapshots activation; do
      crash_root="$EVIDENCE_DIR/crash-$window"
      cp -R "$baseline" "$crash_root"
      python3 - "$crash_root" "$window" <<'PY'
import os
import re
import shutil
import sys

root, window = sys.argv[1:]
agents = os.path.join(root, ".agents")
sessions = os.path.join(agents, "planning-sessions")
session_dir = next(
    os.path.join(sessions, name)
    for name in os.listdir(sessions)
    if os.path.isdir(os.path.join(sessions, name))
)
action_path = os.path.join(session_dir, "actions", "act-confirm-crash.yaml")
text = open(action_path, encoding="utf-8").read()
text = re.sub(r"^status: completed$", "status: prepared", text, count=1, flags=re.M)
open(action_path, "w", encoding="utf-8").write(text)

events_dir = os.path.join(session_dir, "events")
for name in os.listdir(events_dir):
    path = os.path.join(events_dir, name)
    event = open(path, encoding="utf-8").read()
    if "action_id: act-confirm-crash" not in event:
        continue
    if "type: action.completed" in event:
        os.remove(path)
    elif window != "activation" and "type: draft.confirmed" in event:
        os.remove(path)

session_path = os.path.join(session_dir, "session.yaml")
session = open(session_path, encoding="utf-8").read()
if window != "activation":
    session = re.sub(r"^lifecycle: confirmed$", "lifecycle: open", session, count=1, flags=re.M)
    session = re.sub(r"^confirmation_id: .*?$", "confirmation_id: null", session, count=1, flags=re.M)
event_seqs = [int(name.split(".")[0]) for name in os.listdir(events_dir) if name.endswith(".yaml")]
session = re.sub(r"^next_seq: .*?$", f"next_seq: {max(event_seqs) + 1}", session, count=1, flags=re.M)
open(session_path, "w", encoding="utf-8").write(session)

activation_dir = os.path.join(agents, "activations")
if window != "activation" and os.path.isdir(activation_dir):
    shutil.rmtree(activation_dir)
if window == "prepare":
    for name in ("intent-contract.yaml", "work-queue.yaml"):
        path = os.path.join(agents, name)
        if os.path.exists(path):
            os.remove(path)
elif window == "intent_only":
    queue = os.path.join(agents, "work-queue.yaml")
    if os.path.exists(queue):
        os.remove(queue)
PY
      if [[ "$window" == "prepare" || "$window" == "intent_only" ]]; then
        if [[ -f "$EVIDENCE_DIR/pre-confirm-queue.yaml" ]]; then
          cp "$EVIDENCE_DIR/pre-confirm-queue.yaml" "$crash_root/.agents/work-queue.yaml"
        else
          rm -f "$crash_root/.agents/work-queue.yaml"
        fi
      fi
      run_in "$crash_root" planning confirm --expected-head "$h1" --action-id act-confirm-crash >/dev/null
      run_in "$crash_root" planning show --json >"$EVIDENCE_DIR/crash-$window.json"
      [[ "$(json_get "$EVIDENCE_DIR/crash-$window.json" session.lifecycle)" == "confirmed" ]] || fail "$window replay did not confirm session"
      [[ "$(json_get "$EVIDENCE_DIR/crash-$window.json" activation.status)" == "committed" ]] || fail "$window replay activation missing"
      [[ "$(json_get "$EVIDENCE_DIR/crash-$window.json" exact_active_parity)" == "true" ]] || fail "$window replay parity false"
      python3 - "$crash_root" <<'PY'
import os
import sys
root = sys.argv[1]
session_dir = next(
    os.path.join(root, ".agents", "planning-sessions", name)
    for name in os.listdir(os.path.join(root, ".agents", "planning-sessions"))
    if os.path.isdir(os.path.join(root, ".agents", "planning-sessions", name))
)
action = open(os.path.join(session_dir, "actions", "act-confirm-crash.yaml"), encoding="utf-8").read()
if "status: completed" not in action:
    raise SystemExit("confirm action did not converge to completed")
counts = {kind: 0 for kind in ("action.requested", "draft.confirm.prepared", "draft.confirmed", "action.completed")}
for name in os.listdir(os.path.join(session_dir, "events")):
    event = open(os.path.join(session_dir, "events", name), encoding="utf-8").read()
    if "action_id: act-confirm-crash" not in event:
        continue
    for kind in counts:
        if f"type: {kind}" in event:
            counts[kind] += 1
if any(count != 1 for count in counts.values()):
    raise SystemExit(f"duplicate or missing confirm effects: {counts}")
PY
    done
    write_summary "four confirm crash windows replay to one completed action and valid activation"
    ;;
  event_seq_crash)
    if (cd "$ROOT" && YARDLET_TEST_PLANNING_CRASH=after_event_write_before_next_seq \
      "$YARDLET_BIN" planning accept "$p1" --expected-head none --action-id act-event-crash \
      >"$EVIDENCE_DIR/event-crash.out" 2>"$EVIDENCE_DIR/event-crash.err"); then
      fail "event/next_seq crash injection did not terminate the process"
    fi
    accept_proposal "$p1" none act-event-crash >/dev/null
    show
    [[ "$(json_get "$EVIDENCE_DIR/show.json" session.next_seq)" -gt 1 ]] || fail "next_seq did not recover"
    python3 - "$ROOT" <<'PY'
import os
import sys
session_root = os.path.join(sys.argv[1], ".agents", "planning-sessions")
session_dir = next(os.path.join(session_root, name) for name in os.listdir(session_root) if os.path.isdir(os.path.join(session_root, name)))
events = []
for name in os.listdir(os.path.join(session_dir, "events")):
    if name.endswith(".yaml"):
        events.append(open(os.path.join(session_dir, "events", name), encoding="utf-8").read())
seqs = [int(next(line.split(":", 1)[1] for line in event.splitlines() if line.startswith("seq:"))) for event in events]
if len(seqs) != len(set(seqs)):
    raise SystemExit(f"duplicate event seq: {seqs}")
for kind in ("action.requested", "draft.accepted", "action.completed"):
    count = sum(f"type: {kind}" in event and "action_id: act-event-crash" in event for event in events)
    if count != 1:
        raise SystemExit(f"{kind} count was {count}")
PY
    write_summary "event 저장 뒤 next_seq 저장 전 crash가 무충돌 journal로 replay됨"
    ;;
  confirm_write_order_crash)
    accept_proposal "$p1" none act-accept-before-confirm-crash >/dev/null
    h1="$(visible_head)"
    baseline="$EVIDENCE_DIR/confirm-write-order-baseline"
    cp -R "$ROOT" "$baseline"
    for window in confirm_after_prepare confirm_after_intent_write confirm_after_activation_write confirm_after_effect_before_completion; do
      crash_root="$EVIDENCE_DIR/actual-$window"
      cp -R "$baseline" "$crash_root"
      if (cd "$crash_root" && YARDLET_TEST_PLANNING_CRASH="$window" \
        "$YARDLET_BIN" planning confirm --expected-head "$h1" --action-id act-actual-confirm \
        >"$EVIDENCE_DIR/$window.out" 2>"$EVIDENCE_DIR/$window.err"); then
        fail "$window injection did not terminate the process"
      fi
      run_in "$crash_root" planning confirm --expected-head "$h1" --action-id act-actual-confirm >/dev/null
      run_in "$crash_root" planning show --json >"$EVIDENCE_DIR/$window.json"
      [[ "$(json_get "$EVIDENCE_DIR/$window.json" session.lifecycle)" == "confirmed" ]] || fail "$window replay did not confirm"
      [[ "$(json_get "$EVIDENCE_DIR/$window.json" exact_active_parity)" == "true" ]] || fail "$window replay parity false"
      python3 - "$crash_root" <<'PY'
import os
import sys
session_root = os.path.join(sys.argv[1], ".agents", "planning-sessions")
session_dir = next(os.path.join(session_root, name) for name in os.listdir(session_root) if os.path.isdir(os.path.join(session_root, name)))
receipt = open(os.path.join(session_dir, "actions", "act-actual-confirm.yaml"), encoding="utf-8").read()
if "status: completed" not in receipt:
    raise SystemExit("confirm receipt not completed")
events = [open(os.path.join(session_dir, "events", name), encoding="utf-8").read() for name in os.listdir(os.path.join(session_dir, "events")) if name.endswith(".yaml")]
for kind in ("action.requested", "draft.confirm.prepared", "draft.confirmed", "action.completed"):
    count = sum(f"type: {kind}" in event and "action_id: act-actual-confirm" in event for event in events)
    if count != 1:
        raise SystemExit(f"{kind} count was {count}")
PY
    done
    write_summary "실제 confirm write-order crash 네 지점이 수동 보정 없이 completed activation으로 replay됨"
    ;;
  action_effect_crash)
    action_base="$EVIDENCE_DIR/action-base"
    cp -R "$ROOT" "$action_base"

    accept_root="$EVIDENCE_DIR/action-accept"
    cp -R "$action_base" "$accept_root"
    if (cd "$accept_root" && YARDLET_TEST_PLANNING_CRASH=action_after_effect \
      "$YARDLET_BIN" planning accept "$p1" --expected-head none --action-id act-crash-accept >/dev/null 2>&1); then
      fail "accept effect crash injection did not terminate"
    fi
    run_in "$accept_root" planning accept "$p1" --expected-head none --action-id act-crash-accept >/dev/null

    reject_root="$EVIDENCE_DIR/action-reject"
    cp -R "$action_base" "$reject_root"
    if (cd "$reject_root" && YARDLET_TEST_PLANNING_CRASH=action_after_effect \
      "$YARDLET_BIN" planning reject "$p1" --expected-head none --action-id act-crash-reject >/dev/null 2>&1); then
      fail "reject effect crash injection did not terminate"
    fi
    run_in "$reject_root" planning reject "$p1" --expected-head none --action-id act-crash-reject >/dev/null

    answer_root="$EVIDENCE_DIR/action-answer"
    cp -R "$action_base" "$answer_root"
    if (cd "$answer_root" && YARDLET_TEST_PLANNING_CRASH=action_after_effect \
      "$YARDLET_BIN" planning answer "crash answer" --expected-head none --action-id act-crash-answer --worker fixture-planner >/dev/null 2>&1); then
      fail "answer effect crash injection did not terminate"
    fi
    run_in "$answer_root" planning answer "crash answer" --expected-head none --action-id act-crash-answer --worker fixture-planner >/dev/null

    rejected_root="$EVIDENCE_DIR/action-rejected-receipt"
    cp -R "$action_base" "$rejected_root"
    if (cd "$rejected_root" && YARDLET_TEST_PLANNING_CRASH=action_after_rejected_effect \
      "$YARDLET_BIN" planning accept "$p1" --expected-head forged-head --action-id act-crash-rejected >/dev/null 2>&1); then
      fail "rejected receipt crash injection did not terminate"
    fi
    if run_in "$rejected_root" planning accept "$p1" --expected-head forged-head --action-id act-crash-rejected >"$EVIDENCE_DIR/rejected-replay.out" 2>"$EVIDENCE_DIR/rejected-replay.err"; then
      fail "replayed rejected action unexpectedly succeeded"
    fi
    grep -q "stale_head" "$EVIDENCE_DIR/rejected-replay.err" || fail "replayed rejection reason changed"

    undo_root="$EVIDENCE_DIR/action-undo"
    cp -R "$action_base" "$undo_root"
    run_in "$undo_root" planning accept "$p1" --expected-head none --action-id act-undo-accept-1 >/dev/null
    run_in "$undo_root" planning show --json >"$EVIDENCE_DIR/undo-first.json"
    uh1="$(json_get "$EVIDENCE_DIR/undo-first.json" session.current_head)"
    run_in "$undo_root" planning answer "second revision" --expected-head "$uh1" --action-id act-undo-answer --worker fixture-planner >/dev/null
    run_in "$undo_root" planning show --json >"$EVIDENCE_DIR/undo-proposal.json"
    up2="$(json_get "$EVIDENCE_DIR/undo-proposal.json" pending_proposals.0.proposal_id)"
    run_in "$undo_root" planning accept "$up2" --expected-head "$uh1" --action-id act-undo-accept-2 >/dev/null
    run_in "$undo_root" planning show --json >"$EVIDENCE_DIR/undo-second.json"
    uh2="$(json_get "$EVIDENCE_DIR/undo-second.json" session.current_head)"
    if (cd "$undo_root" && YARDLET_TEST_PLANNING_CRASH=action_after_effect \
      "$YARDLET_BIN" planning undo --expected-head "$uh2" --action-id act-crash-undo >/dev/null 2>&1); then
      fail "undo effect crash injection did not terminate"
    fi
    run_in "$undo_root" planning undo --expected-head "$uh2" --action-id act-crash-undo >/dev/null
    run_in "$undo_root" planning show --json >"$EVIDENCE_DIR/undo-replayed.json"
    [[ "$(json_get "$EVIDENCE_DIR/undo-replayed.json" session.current_head)" == "$uh1" ]] || fail "undo effect replay did not restore parent"

    python3 - "$accept_root" "$reject_root" "$answer_root" "$undo_root" "$rejected_root" <<'PY'
import os
import sys
for root, action_id, effect, status in zip(
    sys.argv[1:],
    ("act-crash-accept", "act-crash-reject", "act-crash-answer", "act-crash-undo", "act-crash-rejected"),
    ("draft.accepted", "draft.rejected", "user.message", "draft.undo", "action.rejected"),
    ("completed", "completed", "completed", "completed", "rejected"),
):
    session_root = os.path.join(root, ".agents", "planning-sessions")
    session_dir = next(os.path.join(session_root, name) for name in os.listdir(session_root) if os.path.isdir(os.path.join(session_root, name)))
    receipt = open(os.path.join(session_dir, "actions", action_id + ".yaml"), encoding="utf-8").read()
    if f"status: {status}" not in receipt or "effect_event_id:" not in receipt:
        raise SystemExit(f"terminal linked receipt missing for {action_id}")
    events = [open(os.path.join(session_dir, "events", name), encoding="utf-8").read() for name in os.listdir(os.path.join(session_dir, "events")) if name.endswith(".yaml")]
    count = sum(f"type: {effect}" in event and f"action_id: {action_id}" in event for event in events)
    if count != 1:
        raise SystemExit(f"{action_id} effect count was {count}")
PY
    write_summary "accept reject undo answer prepared-effect crash가 linked completed receipt로 한 번 수렴함"
    ;;
  active_queue_guard)
    accept_proposal "$p1" none act-guard-accept >/dev/null
    guard_head="$(visible_head)"
    guard_base="$EVIDENCE_DIR/guard-base"
    cp -R "$ROOT" "$guard_base"
    for state in queued needs_user partial blocked; do
      state_root="$EVIDENCE_DIR/guard-$state"
      cp -R "$guard_base" "$state_root"
      cat >"$state_root/.agents/work-queue.yaml" <<EOF
schema_version: 1
queue_id: queue-existing-$state
intent_id: intent-existing-$state
selection_policy:
  default_order: priority_then_created_at
  require_planning_gate: true
  skip_if_blocked: true
  skip_if_approval_required: true
tasks:
  - id: EXISTING-001
    title: existing active task
    state: $state
    priority: 10
    risk: low
    kind: implementation
EOF
      cp "$state_root/.agents/work-queue.yaml" "$EVIDENCE_DIR/$state.queue.before"
      if run_in "$state_root" planning confirm --expected-head "$guard_head" --action-id "act-guard-$state" >"$EVIDENCE_DIR/$state.out" 2>"$EVIDENCE_DIR/$state.err"; then
        fail "$state active queue was overwritten"
      fi
      cmp "$EVIDENCE_DIR/$state.queue.before" "$state_root/.agents/work-queue.yaml" || fail "$state queue bytes changed"
      grep -q "active_queue_not_drained" "$EVIDENCE_DIR/$state.err" || fail "$state guard reason missing"
    done

    corrupt_root="$EVIDENCE_DIR/guard-corrupt"
    cp -R "$guard_base" "$corrupt_root"
    ch1="$guard_head"
    run_in "$corrupt_root" planning confirm --expected-head "$ch1" --action-id act-corrupt-confirm-1 >/dev/null
    run_in "$corrupt_root" new "next plan" --worker fixture-planner >/dev/null
    run_in "$corrupt_root" planning show --json >"$EVIDENCE_DIR/corrupt-next.json"
    cp2="$(json_get "$EVIDENCE_DIR/corrupt-next.json" pending_proposals.0.proposal_id)"
    run_in "$corrupt_root" planning accept "$cp2" --expected-head none --action-id act-corrupt-accept-2 >/dev/null
    run_in "$corrupt_root" planning show --json >"$EVIDENCE_DIR/corrupt-head.json"
    ch2="$(json_get "$EVIDENCE_DIR/corrupt-head.json" session.current_head)"
    activation_path="$(find "$corrupt_root/.agents/activations" -type f -name '*.yaml' -print -quit)"
    python3 - "$activation_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^status: committed$", "status: prepared", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
    cp "$corrupt_root/.agents/intent-contract.yaml" "$EVIDENCE_DIR/corrupt.intent.before"
    cp "$corrupt_root/.agents/work-queue.yaml" "$EVIDENCE_DIR/corrupt.queue.before"
    if run_in "$corrupt_root" planning confirm --expected-head "$ch2" --action-id act-corrupt-confirm-2 >"$EVIDENCE_DIR/corrupt.out" 2>"$EVIDENCE_DIR/corrupt.err"; then
      fail "corrupt activation guard failed open"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/corrupt.err" || fail "corrupt activation error was swallowed"
    cmp "$EVIDENCE_DIR/corrupt.intent.before" "$corrupt_root/.agents/intent-contract.yaml" || fail "corrupt guard changed intent bytes"
    cmp "$EVIDENCE_DIR/corrupt.queue.before" "$corrupt_root/.agents/work-queue.yaml" || fail "corrupt guard changed queue bytes"
    write_summary "unfinished active states와 corrupted activation이 active bytes 불변으로 confirm을 거절함"
    ;;
  concurrent_action)
    set +e
    (run_yardlet planning accept "$p1" --expected-head none --action-id act-concurrent >"$EVIDENCE_DIR/concurrent-1.out" 2>"$EVIDENCE_DIR/concurrent-1.err") &
    pid1=$!
    (run_yardlet planning accept "$p1" --expected-head none --action-id act-concurrent >"$EVIDENCE_DIR/concurrent-2.out" 2>"$EVIDENCE_DIR/concurrent-2.err") &
    pid2=$!
    wait "$pid1"; status1=$?
    wait "$pid2"; status2=$?
    set -e
    [[ "$status1" -eq 0 && "$status2" -eq 0 ]] || fail "concurrent replay statuses were $status1/$status2"
    show
    python3 - "$ROOT" <<'PY'
import os
import sys
session_root = os.path.join(sys.argv[1], ".agents", "planning-sessions")
session_dir = next(os.path.join(session_root, name) for name in os.listdir(session_root) if os.path.isdir(os.path.join(session_root, name)))
drafts = [name for name in os.listdir(os.path.join(session_dir, "drafts")) if name.endswith(".yaml")]
actions = [name for name in os.listdir(os.path.join(session_dir, "actions")) if name == "act-concurrent.yaml"]
events = [open(os.path.join(session_dir, "events", name), encoding="utf-8").read() for name in os.listdir(os.path.join(session_dir, "events")) if name.endswith(".yaml")]
seqs = [int(next(line.split(":", 1)[1] for line in event.splitlines() if line.startswith("seq:"))) for event in events]
if len(drafts) != 1 or len(actions) != 1:
    raise SystemExit(f"canonical counts drafts/actions={len(drafts)}/{len(actions)}")
if len(seqs) != len(set(seqs)):
    raise SystemExit(f"event seq collision: {seqs}")
for kind in ("action.requested", "draft.accepted", "action.completed"):
    count = sum(f"type: {kind}" in event and "action_id: act-concurrent" in event for event in events)
    if count != 1:
        raise SystemExit(f"{kind} count was {count}")
PY
    write_summary "동시 CLI action이 하나의 revision receipt와 무충돌 journal로 수렴함"
    ;;
  accept_revision_crash)
    if (cd "$ROOT" && YARDLET_TEST_PLANNING_CRASH=accept_after_revision_write \
      "$YARDLET_BIN" planning accept "$p1" --expected-head none --action-id act-revision-crash \
      >"$EVIDENCE_DIR/accept-revision.out" 2>"$EVIDENCE_DIR/accept-revision.err"); then
      fail "accept revision-write crash injection did not terminate"
    fi
    action_path="$(find "$ROOT/.agents/planning-sessions" -path '*/actions/act-revision-crash.yaml' -print -quit)"
    [[ -n "$action_path" ]] || fail "prepared accept receipt missing"
    grep -q '^status: prepared$' "$action_path" || fail "accept receipt was not prepared"
    grep -Eq '^result_id: drv_' "$action_path" || fail "stable revision id was not prepared"
    grep -Eq '^effect_event_id: evt_' "$action_path" || fail "stable effect event id was not prepared"
    grep -Eq '^effect_event_type: draft\.(accepted|revised)$' "$action_path" || fail "stable effect type was not prepared"
    grep -q '^effect_event_digest: fnv1a64:' "$action_path" || fail "exact effect payload digest was not prepared"
    grep -q '^effect_event:' "$action_path" || fail "exact effect payload was not prepared"
    [[ "$(revision_count)" == "1" ]] || fail "revision crash did not leave exactly one immutable draft"
    prepared_result="$(sed -n 's/^result_id: //p' "$action_path")"
    accept_proposal "$p1" none act-revision-crash >/dev/null
    [[ "$(revision_count)" == "1" ]] || fail "accept replay duplicated the immutable draft"
    grep -q '^status: completed$' "$action_path" || fail "accept replay did not complete receipt"
    [[ "$(sed -n 's/^result_id: //p' "$action_path")" == "$prepared_result" ]] || fail "accept replay changed stable result id"
    cp "$action_path" "$EVIDENCE_DIR/accept-revision.completed.yaml"
    accept_proposal "$p1" none act-revision-crash >/dev/null
    cmp "$EVIDENCE_DIR/accept-revision.completed.yaml" "$action_path" || fail "completed accept replay changed its receipt"
    python3 - "$ROOT" <<'PY'
import os
import sys
session_root = os.path.join(sys.argv[1], ".agents", "planning-sessions")
session_dir = next(os.path.join(session_root, name) for name in os.listdir(session_root) if os.path.isdir(os.path.join(session_root, name)))
events = [open(os.path.join(session_dir, "events", name), encoding="utf-8").read() for name in os.listdir(os.path.join(session_dir, "events")) if name.endswith(".yaml")]
effects = [event for event in events if "action_id: act-revision-crash" in event and ("type: draft.accepted" in event or "type: draft.revised" in event)]
if len(effects) != 1:
    raise SystemExit(f"accept effect count was {len(effects)}")
PY
    write_summary "accept revision 저장 직후 crash가 prepared stable result/effect로 단일 draft와 completed receipt에 수렴함"
    ;;
  prepared_action_interlock)
    if (cd "$ROOT" && YARDLET_TEST_PLANNING_CRASH=accept_after_revision_write \
      "$YARDLET_BIN" planning accept "$p1" --expected-head none --action-id act-prepared-owner >/dev/null 2>&1); then
      fail "prepared interlock setup did not crash"
    fi
    for command in \
      "planning accept $p1 --expected-head none --action-id act-other-accept" \
      "planning reject $p1 --expected-head none --action-id act-other-reject" \
      "planning answer blocked --expected-head none --action-id act-other-answer --worker fixture-planner" \
      "planning undo --expected-head forged --action-id act-other-undo" \
      "planning confirm --expected-head forged --action-id act-other-confirm" \
      "new blocked-new-session --worker fixture-planner"; do
      set +e
      run_yardlet $command >"$EVIDENCE_DIR/interlock.out" 2>"$EVIDENCE_DIR/interlock.err"
      status=$?
      set -e
      [[ "$status" -ne 0 ]] || fail "prepared action allowed another mutation: $command"
      grep -q 'planning_action_in_progress' "$EVIDENCE_DIR/interlock.err" || fail "interlock reason missing for $command"
    done
    session_dir="$(dirname "$(dirname "$(find "$ROOT/.agents/planning-sessions" -path '*/actions/act-prepared-owner.yaml' -print -quit)")")"
    [[ "$(find "$session_dir/actions" -type f -name '*.yaml' | wc -l | tr -d ' ')" == "1" ]] || fail "blocked mutations created terminal receipts"
    accept_proposal "$p1" none act-prepared-owner >/dev/null
    grep -q '^status: completed$' "$session_dir/actions/act-prepared-owner.yaml" || fail "owner action did not recover"
    if find "$session_dir/actions" -type f -name '*.yaml' -exec grep -l '^status: rejected$' {} + | grep -q .; then
      fail "accepted effect coexists with a rejected terminal receipt"
    fi
    write_summary "unresolved prepared action이 다른 모든 session mutation을 차단하고 owner replay만 completed로 수렴함"
    ;;
  journal_corruption)
    accept_proposal "$p1" none act-journal >/dev/null
    journal_base="$EVIDENCE_DIR/journal-base"
    cp -R "$ROOT" "$journal_base"
    for mode in gap duplicate_event_id multi_match payload_mismatch next_seq_ahead filename_seq_mismatch session_identity_mismatch empty_event_id; do
      corrupt_root="$EVIDENCE_DIR/journal-$mode"
      cp -R "$journal_base" "$corrupt_root"
      python3 - "$corrupt_root" "$mode" <<'PY'
import os
import re
import shutil
import sys
root, mode = sys.argv[1:]
sessions = os.path.join(root, ".agents", "planning-sessions")
session_dir = next(os.path.join(sessions, name) for name in os.listdir(sessions) if os.path.isdir(os.path.join(sessions, name)))
events_dir = os.path.join(session_dir, "events")
names = sorted(name for name in os.listdir(events_dir) if name.endswith(".yaml"))
paths = [os.path.join(events_dir, name) for name in names]
if mode == "gap":
    os.remove(paths[1])
elif mode == "duplicate_event_id":
    first_id = re.search(r"^event_id: (.+)$", open(paths[0], encoding="utf-8").read(), re.M).group(1)
    text = open(paths[-1], encoding="utf-8").read()
    text = re.sub(r"^event_id: .+$", f"event_id: {first_id}", text, count=1, flags=re.M)
    open(paths[-1], "w", encoding="utf-8").write(text)
elif mode == "multi_match":
    source = next(path for path in paths if "type: draft.accepted" in open(path, encoding="utf-8").read())
    seq = len(paths) + 1
    text = open(source, encoding="utf-8").read()
    text = re.sub(r"^event_id: .+$", "event_id: evt-forged-multi", text, count=1, flags=re.M)
    text = re.sub(r"^seq: .+$", f"seq: {seq}", text, count=1, flags=re.M)
    open(os.path.join(events_dir, f"{seq:020}.yaml"), "w", encoding="utf-8").write(text)
    session_path = os.path.join(session_dir, "session.yaml")
    session = open(session_path, encoding="utf-8").read()
    session = re.sub(r"^next_seq: .+$", f"next_seq: {seq + 1}", session, count=1, flags=re.M)
    open(session_path, "w", encoding="utf-8").write(session)
elif mode == "payload_mismatch":
    source = next(path for path in paths if "type: draft.accepted" in open(path, encoding="utf-8").read())
    text = open(source, encoding="utf-8").read()
    text = re.sub(r"^proposal_id: .+$", "proposal_id: forged-proposal", text, count=1, flags=re.M)
    open(source, "w", encoding="utf-8").write(text)
elif mode == "next_seq_ahead":
    session_path = os.path.join(session_dir, "session.yaml")
    session = open(session_path, encoding="utf-8").read()
    session = re.sub(r"^next_seq: .+$", f"next_seq: {len(paths) + 2}", session, count=1, flags=re.M)
    open(session_path, "w", encoding="utf-8").write(session)
elif mode == "filename_seq_mismatch":
    os.rename(paths[-1], os.path.join(events_dir, "00000000000000000999.yaml"))
elif mode == "session_identity_mismatch":
    text = open(paths[-1], encoding="utf-8").read()
    text = re.sub(r"^session_id: .+$", "session_id: ses-forged", text, count=1, flags=re.M)
    open(paths[-1], "w", encoding="utf-8").write(text)
elif mode == "empty_event_id":
    text = open(paths[-1], encoding="utf-8").read()
    text = re.sub(r"^event_id: .+$", "event_id: ''", text, count=1, flags=re.M)
    open(paths[-1], "w", encoding="utf-8").write(text)
PY
      if run_in "$corrupt_root" planning accept "$p1" --expected-head none --action-id act-journal >"$EVIDENCE_DIR/$mode.out" 2>"$EVIDENCE_DIR/$mode.err"; then
        fail "journal corruption $mode failed open"
      fi
      grep -Eq 'planning_event_journal|planning_receipt_corrupt|terminal action receipt effect' "$EVIDENCE_DIR/$mode.err" || fail "journal corruption reason missing for $mode"
    done
    write_summary "journal gap duplicate multi-match payload mismatch next_seq ahead filename/seq/session/event id identity 변조가 모두 fail-closed됨"
    ;;
  completed_active_mismatch)
    accept_proposal "$p1" none act-first-accept >/dev/null
    first_head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$first_head" --action-id act-first-confirm >/dev/null
    first_session="$(json_get "$EVIDENCE_DIR/show.json" session.session_id)"
    run_yardlet goal "second express activation" --plan-only >/dev/null
    run_yardlet planning show --json >"$EVIDENCE_DIR/second-active.json"
    second_confirmation="$(json_get "$EVIDENCE_DIR/second-active.json" activation.confirmation_id)"
    printf '%s\n' "$first_session" >"$ROOT/.agents/planning-sessions/latest"
    if run_yardlet planning confirm --expected-head "$first_head" --action-id act-first-confirm >"$EVIDENCE_DIR/completed-mismatch.out" 2>"$EVIDENCE_DIR/completed-mismatch.err"; then
      fail "completed confirm replay returned an activation that is no longer current"
    fi
    grep -q 'completed_confirmation_active_mismatch' "$EVIDENCE_DIR/completed-mismatch.err" || fail "completed active mismatch reason missing"
    active_confirmation="$(sed -n 's/^confirmation_id: //p' "$ROOT/.agents/intent-contract.yaml" | head -n 1)"
    [[ "$active_confirmation" == "$second_confirmation" ]] || fail "failed replay changed current activation"
    write_summary "completed confirm replay가 receipt activation과 현재 active confirmation/session/head/digest 불일치를 거절함"
    ;;
  lock_timeout)
    barrier="$EVIDENCE_DIR/lock-barrier"
    mkdir -p "$barrier"
    (cd "$ROOT" && YARDLET_TEST_MUTATION_BARRIER="$barrier" \
      "$YARDLET_BIN" planning accept "$p1" --expected-head none --action-id act-lock-owner \
      >"$EVIDENCE_DIR/lock-owner.out" 2>"$EVIDENCE_DIR/lock-owner.err") &
    owner_pid=$!
    wait_for_file "$barrier/entered" "$owner_pid" || { kill "$owner_pid" 2>/dev/null || true; fail "stable mutation-lock barrier was not reached"; }
    set +e
    (cd "$ROOT" && YARDLET_TEST_LOCK_TIMEOUT_MS=100 \
      "$YARDLET_BIN" planning reject "$p1" --expected-head none --action-id act-lock-contender \
      >"$EVIDENCE_DIR/lock-contender.out" 2>"$EVIDENCE_DIR/lock-contender.err") &
    contender_pid=$!
    for _ in $(seq 1 100); do
      kill -0 "$contender_pid" 2>/dev/null || break
      sleep 0.02
    done
    if kill -0 "$contender_pid" 2>/dev/null; then
      kill "$contender_pid" 2>/dev/null || true
      touch "$barrier/release"
      wait "$owner_pid" || true
      fail "mutation lock wait was not bounded"
    fi
    wait "$contender_pid"; contender_status=$?
    set -e
    [[ "$contender_status" -ne 0 ]] || fail "lock contender unexpectedly succeeded"
    grep -q 'workspace_mutation_lock_timeout' "$EVIDENCE_DIR/lock-contender.err" || fail "bounded lock timeout reason missing"
    touch "$barrier/release"
    wait "$owner_pid"
    accept_proposal "$p1" none act-lock-owner >/dev/null
    [[ "$(revision_count)" == "1" ]] || fail "lock owner replay was not idempotent"
    write_summary "stable barrier에서 LOCK_NB contender가 bounded timeout으로 실패하고 owner가 단일 결과로 완료됨"
    ;;
  runtime_queue_confirm_race)
    accept_proposal "$p1" none act-race-first-accept >/dev/null
    first_head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$first_head" --action-id act-race-first-confirm >/dev/null
    run_yardlet new "replacement plan" --worker fixture-planner >/dev/null
    replacement="$(proposal)"
    accept_proposal "$replacement" none act-race-replacement-accept >/dev/null
    replacement_head="$(visible_head)"
    (cd "$ROOT" && git init -q && git config user.name fixture && git config user.email fixture@example.invalid && \
      git add .agents/yardlet.yaml && git commit -qm baseline)
    barrier="$EVIDENCE_DIR/runtime-race-barrier"
    mkdir -p "$barrier"
    (cd "$ROOT" && YARDLET_TEST_MUTATION_BARRIER="$barrier" \
      "$YARDLET_BIN" run --next --execute >"$EVIDENCE_DIR/runtime-race-run.out" 2>"$EVIDENCE_DIR/runtime-race-run.err") &
    run_pid=$!
    wait_for_file "$barrier/entered" "$run_pid" || { kill "$run_pid" 2>/dev/null || true; fail "runtime mutation barrier was not reached"; }
    (run_yardlet planning confirm --expected-head "$replacement_head" --action-id act-race-confirm \
      >"$EVIDENCE_DIR/runtime-race-confirm.out" 2>"$EVIDENCE_DIR/runtime-race-confirm.err") &
    confirm_pid=$!
    (run_yardlet add "added during runtime transition" \
      >"$EVIDENCE_DIR/runtime-race-add.out" 2>"$EVIDENCE_DIR/runtime-race-add.err") &
    add_pid=$!
    touch "$barrier/release"
    set +e
    wait "$confirm_pid"; confirm_status=$?
    wait "$add_pid"; add_status=$?
    set -e
    [[ "$add_status" -eq 0 ]] || fail "receipt-backed concurrent add failed with $add_status"
    wait_for_file "$barrier/worker-entered" "$run_pid"
    rm -f "$barrier/entered" "$barrier/release"
    touch "$barrier/worker-release"
    wait_for_file "$barrier/entered" "$run_pid" || { kill "$run_pid" 2>/dev/null || true; fail "finalize mutation barrier was not reached"; }
    (run_yardlet add "added during finalize" \
      >"$EVIDENCE_DIR/finalize-race-add.out" 2>"$EVIDENCE_DIR/finalize-race-add.err") &
    finalize_add_pid=$!
    touch "$barrier/release"
    set +e
    wait "$run_pid"; run_status=$?
    wait "$finalize_add_pid"; finalize_add_status=$?
    set -e
    [[ "$confirm_status" -ne 0 ]] || fail "concurrent confirm overwrote runtime queue transition"
    grep -Eq 'active_queue_not_drained|running_queue_isolated' "$EVIDENCE_DIR/runtime-race-confirm.err" || fail "runtime race rejection reason missing"
    [[ "$run_status" -eq 0 ]] || fail "runtime process failed with $run_status"
    [[ "$finalize_add_status" -eq 0 ]] || fail "receipt-backed finalize add failed with $finalize_add_status"
    run_yardlet queue >"$EVIDENCE_DIR/runtime-race-queue.out"
    grep -Eq 'running|failed|partial|done' "$EVIDENCE_DIR/runtime-race-queue.out" || fail "runtime queue state was lost"
    grep -q 'added during runtime transition' "$EVIDENCE_DIR/runtime-race-queue.out" || fail "runtime add was lost"
    grep -q 'added during finalize' "$EVIDENCE_DIR/runtime-race-queue.out" || fail "finalize add was lost"
    [[ "$(find "$ROOT/.agents/runtime-task-receipts" -type f -name '*.yaml' ! -name '*.committed.yaml' | wc -l | tr -d ' ')" == "2" ]] || fail "concurrent additions did not leave two exact origin receipts"
    [[ "$(find "$ROOT/.agents/runtime-task-receipts" -type f -name '*.committed.yaml' | wc -l | tr -d ' ')" == "2" ]] || fail "concurrent additions did not leave two committed ordinal markers"
    write_summary "run/finalize state transition, rejected confirm, and two receipt-backed additions serialized without lost updates"
    ;;
  receipt_v2_integrity)
    accept_proposal "$p1" none act-receipt-completed >/dev/null
    if accept_proposal "$p1" none act-receipt-rejected >/dev/null 2>&1; then
      fail "receipt fixture did not create a rejected terminal action"
    fi
    receipt_base="$EVIDENCE_DIR/receipt-base"
    cp -R "$ROOT" "$receipt_base"
    for terminal in completed rejected; do
      if [[ "$terminal" == "completed" ]]; then
        action_id="act-receipt-completed"
      else
        action_id="act-receipt-rejected"
      fi
      for mode in strip_event_id strip_event_type strip_event_digest strip_exact_payload forged_actor forged_target forged_result forged_parent forged_message multi_match; do
        corrupt_root="$EVIDENCE_DIR/receipt-$terminal-$mode"
        cp -R "$receipt_base" "$corrupt_root"
        python3 - "$corrupt_root" "$action_id" "$mode" <<'PY'
import json
import os
import re
import shutil
import sys

root, action_id, mode = sys.argv[1:]
sessions = os.path.join(root, ".agents", "planning-sessions")
session_dir = next(
    os.path.join(sessions, name)
    for name in os.listdir(sessions)
    if os.path.isfile(os.path.join(sessions, name, "actions", f"{action_id}.yaml"))
)
receipt_path = os.path.join(session_dir, "actions", f"{action_id}.yaml")
receipt = open(receipt_path, encoding="utf-8").read()

def strip_top_level(text, field):
    return re.sub(rf"^{field}:.*\n", "", text, count=1, flags=re.M)

if mode == "strip_event_id":
    receipt = strip_top_level(receipt, "effect_event_id")
elif mode == "strip_event_type":
    receipt = strip_top_level(receipt, "effect_event_type")
elif mode == "strip_event_digest":
    receipt = strip_top_level(receipt, "effect_event_digest")
elif mode == "strip_exact_payload":
    receipt = re.sub(r"^effect_event:\n(?:  .*\n)+", "", receipt, count=1, flags=re.M)
else:
    event_id = re.search(r"^effect_event_id: (.+)$", receipt, re.M).group(1)
    events_dir = os.path.join(session_dir, "events")
    event_path = next(
        os.path.join(events_dir, name)
        for name in os.listdir(events_dir)
        if name.endswith(".yaml") and f"event_id: {event_id}" in open(os.path.join(events_dir, name), encoding="utf-8").read()
    )
    event = open(event_path, encoding="utf-8").read()

    if mode == "multi_match":
        names = sorted(name for name in os.listdir(events_dir) if name.endswith(".yaml"))
        seq = len(names) + 1
        duplicate = re.sub(r"^event_id: .+$", "event_id: evt-forged-receipt-multi", event, count=1, flags=re.M)
        duplicate = re.sub(r"^seq: .+$", f"seq: {seq}", duplicate, count=1, flags=re.M)
        open(os.path.join(events_dir, f"{seq:020}.yaml"), "w", encoding="utf-8").write(duplicate)
        session_path = os.path.join(session_dir, "session.yaml")
        session = open(session_path, encoding="utf-8").read()
        session = re.sub(r"^next_seq: .+$", f"next_seq: {seq + 1}", session, count=1, flags=re.M)
        open(session_path, "w", encoding="utf-8").write(session)
    else:
        field_by_mode = {
            "forged_actor": "actor",
            "forged_target": "proposal_id",
            "forged_result": "draft_revision_id",
            "forged_parent": "related_revision_id",
            "forged_message": "message",
        }
        field = field_by_mode[mode]
        value = f"forged-{field}"

        def set_field(text, field, value, indent=""):
            pattern = rf"^{re.escape(indent)}{field}:.*$"
            replacement = f"{indent}{field}: {value}"
            if re.search(pattern, text, re.M):
                return re.sub(pattern, replacement, text, count=1, flags=re.M)
            return re.sub(
                rf"^{re.escape(indent)}recorded_at:",
                f"{replacement}\n{indent}recorded_at:",
                text,
                count=1,
                flags=re.M,
            )

        event = set_field(event, field, value)
        receipt = set_field(receipt, field, value, "  ")
        if mode == "forged_result":
            receipt = re.sub(r"^result_id: .+$", f"result_id: {value}", receipt, count=1, flags=re.M)

        values = {}
        for line in event.splitlines():
            if not line or line.startswith(" ") or ":" not in line:
                continue
            key, raw = line.split(":", 1)
            raw = raw.strip()
            if raw in {"''", '""'}:
                raw = ""
            elif len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
                raw = raw[1:-1]
            values[key] = int(raw) if key in {"schema_version", "seq"} else raw
        ordered = {}
        for key in [
            "schema_version", "event_id", "session_id", "seq", "type", "actor",
            "action_id", "action_request_digest", "message", "proposal_id",
            "draft_revision_id", "related_revision_id", "recorded_at",
        ]:
            if key in values and (key not in {"action_id", "action_request_digest", "message", "proposal_id", "draft_revision_id", "related_revision_id"} or values[key] != ""):
                ordered[key] = values[key]
        payload = json.dumps(ordered, ensure_ascii=False, separators=(",", ":")).encode()
        digest = 0xcbf29ce484222325
        for byte in payload:
            digest ^= byte
            digest = (digest * 0x100000001b3) & 0xffffffffffffffff
        receipt = re.sub(
            r"^effect_event_digest: .+$",
            f"effect_event_digest: fnv1a64:{digest:016x}",
            receipt,
            count=1,
            flags=re.M,
        )
        open(event_path, "w", encoding="utf-8").write(event)

open(receipt_path, "w", encoding="utf-8").write(receipt)
PY
        before="$(state_digest "$corrupt_root")"
        set +e
        if [[ "$terminal" == "completed" ]]; then
          run_in "$corrupt_root" planning accept "$p1" --expected-head none --action-id "$action_id" \
            >"$EVIDENCE_DIR/$terminal-$mode.out" 2>"$EVIDENCE_DIR/$terminal-$mode.err"
        else
          run_in "$corrupt_root" planning accept "$p1" --expected-head none --action-id "$action_id" \
            >"$EVIDENCE_DIR/$terminal-$mode.out" 2>"$EVIDENCE_DIR/$terminal-$mode.err"
        fi
        status=$?
        set -e
        [[ "$status" -ne 0 ]] || fail "$terminal v2 receipt corruption $mode failed open"
        grep -q 'planning_receipt_corrupt' "$EVIDENCE_DIR/$terminal-$mode.err" || fail "$terminal v2 receipt corruption reason missing for $mode"
        after="$(state_digest "$corrupt_root")"
        [[ "$before" == "$after" ]] || fail "$terminal v2 receipt corruption $mode mutated canonical state"
      done
    done
    for terminal in completed rejected; do
      legacy_root="$EVIDENCE_DIR/receipt-v1-$terminal"
      cp -R "$receipt_base" "$legacy_root"
      if [[ "$terminal" == "completed" ]]; then
        action_id="act-receipt-completed"
      else
        action_id="act-receipt-rejected"
      fi
      action_path="$(find "$legacy_root/.agents/planning-sessions" -path "*/actions/$action_id.yaml" -print -quit)"
      python3 - "$action_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^schema_version: 2$", "schema_version: 1", text, count=1, flags=re.M)
for field in ["effect_event_id", "effect_event_type", "effect_event_digest"]:
    text = re.sub(rf"^{field}:.*\n", "", text, count=1, flags=re.M)
text = re.sub(r"^effect_event:\n(?:  .*\n)+", "", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
      set +e
      run_in "$legacy_root" planning accept "$p1" --expected-head none --action-id "$action_id" \
        >"$EVIDENCE_DIR/v1-$terminal.out" 2>"$EVIDENCE_DIR/v1-$terminal.err"
      status=$?
      set -e
      if [[ "$terminal" == "completed" ]]; then
        [[ "$status" -eq 0 ]] || fail "explicit v1 completed compatibility branch regressed"
      else
        [[ "$status" -ne 0 ]] || fail "v1 rejected action unexpectedly succeeded"
        grep -q 'action_previously_rejected' "$EVIDENCE_DIR/v1-$terminal.err" || fail "explicit v1 rejected compatibility branch regressed"
      fi
    done
    write_summary "v2 completed/rejected receipt의 필수 exact effect와 immutable journal linkage 변조가 모두 planning_receipt_corrupt로 무변경 거절됨"
    ;;
  session_storage_integrity)
    accept_proposal "$p1" none act-session-storage >/dev/null
    session_base="$EVIDENCE_DIR/session-base"
    cp -R "$ROOT" "$session_base"
    for mode in missing_events empty_next_seq_ahead session_path_id latest_identity; do
      corrupt_root="$EVIDENCE_DIR/session-$mode"
      cp -R "$session_base" "$corrupt_root"
      python3 - "$corrupt_root" "$mode" <<'PY'
import os
import re
import shutil
import sys
root, mode = sys.argv[1:]
sessions = os.path.join(root, ".agents", "planning-sessions")
latest_path = os.path.join(sessions, "latest")
latest = open(latest_path, encoding="utf-8").read().strip()
session_dir = os.path.join(sessions, latest)
session_path = os.path.join(session_dir, "session.yaml")
events_dir = os.path.join(session_dir, "events")
if mode == "missing_events":
    shutil.rmtree(events_dir)
elif mode == "empty_next_seq_ahead":
    for name in os.listdir(events_dir):
        os.remove(os.path.join(events_dir, name))
elif mode == "session_path_id":
    text = open(session_path, encoding="utf-8").read()
    text = re.sub(r"^session_id: .+$", "session_id: ses-forged-path", text, count=1, flags=re.M)
    open(session_path, "w", encoding="utf-8").write(text)
elif mode == "latest_identity":
    alias = "ses-forged-latest"
    shutil.copytree(session_dir, os.path.join(sessions, alias))
    open(latest_path, "w", encoding="utf-8").write(alias + "\n")
PY
      before="$(state_digest "$corrupt_root")"
      if run_in "$corrupt_root" planning show --json >"$EVIDENCE_DIR/session-$mode.out" 2>"$EVIDENCE_DIR/session-$mode.err"; then
        fail "persisted session corruption $mode failed open"
      fi
      grep -Eq 'planning_session_corrupt|planning_event_journal' "$EVIDENCE_DIR/session-$mode.err" || fail "persisted session corruption reason missing for $mode"
      after="$(state_digest "$corrupt_root")"
      [[ "$before" == "$after" ]] || fail "persisted session corruption $mode mutated canonical state"
    done
    write_summary "persisted session의 journal directory, next_seq, path id, latest identity 변조가 모두 무변경 fail-closed됨"
    ;;
  runtime_envelope)
    accept_proposal "$p1" none act-runtime-envelope-accept >/dev/null
    head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$head" --action-id act-runtime-envelope-confirm >/dev/null
    runtime_base="$EVIDENCE_DIR/runtime-envelope-base"
    cp -R "$ROOT" "$runtime_base"
    for mode in title scope worker risk; do
      corrupt_root="$EVIDENCE_DIR/runtime-envelope-$mode"
      cp -R "$runtime_base" "$corrupt_root"
      python3 - "$corrupt_root/.agents/work-queue.yaml" "$mode" <<'PY'
import re
import sys
path, mode = sys.argv[1:]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
patterns = {
    "title": (r"^(\s+title:) .+$", r"\1 forged runtime title"),
    "scope": (r"^(\s+- )src/planning\.rs$", r"\1forged/runtime/scope"),
    "worker": (r"^(\s+preferred_worker:) .+$", r"\1 forged-worker"),
    "risk": (r"^(\s+risk:) .+$", r"\1 critical"),
}
pattern, replacement = patterns[mode]
current, count = re.subn(pattern, replacement, current, count=1, flags=re.M)
if count != 1:
    raise SystemExit(f"failed to mutate {mode}")
current, state_count = re.subn(r"^(\s+state:) queued$", r"\1 partial", current, count=1, flags=re.M)
if state_count != 1:
    raise SystemExit("failed to prepare finalization entry")
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
      run_in "$corrupt_root" planning show --json >"$EVIDENCE_DIR/runtime-$mode-show.json"
      [[ "$(json_get "$EVIDENCE_DIR/runtime-$mode-show.json" exact_active_parity)" == "false" ]] || fail "runtime $mode tamper retained exact_active_parity"
      before="$(state_digest "$corrupt_root")"
      for command in "queue" "run --next" "add blocked-runtime-write" "defer YARD-001" "resolve YARD-001" "recover"; do
        set +e
        run_in "$corrupt_root" $command >"$EVIDENCE_DIR/runtime-$mode-command.out" 2>"$EVIDENCE_DIR/runtime-$mode-command.err"
        status=$?
        set -e
        [[ "$status" -ne 0 ]] || fail "runtime $mode tamper allowed $command"
        grep -q 'active_runtime_envelope_mismatch' "$EVIDENCE_DIR/runtime-$mode-command.err" || fail "runtime envelope reason missing for $mode via $command"
        [[ "$before" == "$(state_digest "$corrupt_root")" ]] || fail "runtime $mode rejection changed canonical bytes via $command"
      done
    done
    state_root="$EVIDENCE_DIR/runtime-envelope-state-only"
    cp -R "$runtime_base" "$state_root"
    python3 - "$state_root/.agents/work-queue.yaml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
current, count = re.subn(r"^(\s+state:) queued$", r"\1 partial", current, count=1, flags=re.M)
if count != 1:
    raise SystemExit("failed to make the state-only Partial transition")
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
    run_in "$state_root" planning show --json >"$EVIDENCE_DIR/runtime-state-partial.json"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-state-partial.json" exact_active_parity)" == "true" ]] || fail "allowed Partial state broke parity"
    before="$(state_digest "$state_root")"
    if run_in "$state_root" resolve YARD-001 >"$EVIDENCE_DIR/runtime-state-resolve.out" 2>"$EVIDENCE_DIR/runtime-state-resolve.err"; then
      fail "proof 없는 state-only Partial이 Done으로 공개됨"
    fi
    grep -q 'dependency_output_proof_missing:dependency=YARD-001' "$EVIDENCE_DIR/runtime-state-resolve.err" || fail "proof 없는 resolve 진단이 누락됨"
    [[ "$before" == "$(state_digest "$state_root")" ]] || fail "proof 없는 resolve 거부가 canonical bytes를 변경함"
    run_in "$state_root" planning show --json >"$EVIDENCE_DIR/runtime-state-still-partial.json"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-state-still-partial.json" exact_active_parity)" == "true" ]] || fail "거부 후 Partial state parity가 깨짐"
    write_summary "activated runtime task는 state-only Partial을 허용하지만 proof 없는 Done 공개는 차단하고, title/scope/worker/risk 변조도 모든 mutation entry에서 bytes 불변으로 거절됨"
    ;;
  runtime_origin_contract)
    accept_proposal "$p1" none act-runtime-origin-accept >/dev/null
    head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$head" --action-id act-runtime-origin-confirm >/dev/null
    materialized_before="$(sed -n '/^materialized_queue:/,$p' "$ROOT/.agents/work-queue.yaml" | shasum | awk '{print $1}')"

    run_yardlet add "explicit runtime follow-up" --scope src/state.rs >/dev/null
    run_yardlet add "second runtime follow-up" --scope src/schemas.rs >/dev/null
    run_yardlet planning show --json >"$EVIDENCE_DIR/runtime-origin-added.json"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-origin-added.json" exact_active_parity)" == "true" ]] || fail "provenanced user add broke active parity"
    [[ "$materialized_before" == "$(sed -n '/^materialized_queue:/,$p' "$ROOT/.agents/work-queue.yaml" | shasum | awk '{print $1}')" ]] || fail "user add rewrote immutable materialized queue"
    grep -Eq "materialized_by_confirmation_id: (''|\"\")" "$ROOT/.agents/work-queue.yaml" || fail "user-added task was disguised as confirmed materialization"
    receipt="$(find "$ROOT/.agents/runtime-task-receipts" -type f -name 'YARD-002*.yaml' ! -name '*.committed.yaml' | head -n 1)"
    [[ -n "$receipt" && -f "$receipt" ]] || fail "user add did not persist an immutable origin receipt"
    [[ -f "${receipt%.yaml}.committed.yaml" ]] || fail "user add did not persist its committed ordinal marker"

    run_yardlet defer YARD-001 "audit pause" >/dev/null
    run_yardlet planning show --json >"$EVIDENCE_DIR/runtime-origin-deferred.json"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-origin-deferred.json" exact_active_parity)" == "true" ]] || fail "defer runtime overlay broke active parity"
    run_yardlet revive YARD-001 >/dev/null
    run_yardlet planning show --json >"$EVIDENCE_DIR/runtime-origin-revived.json"
    [[ "$(json_get "$EVIDENCE_DIR/runtime-origin-revived.json" exact_active_parity)" == "true" ]] || fail "revive runtime overlay broke active parity"

    origin_base="$EVIDENCE_DIR/runtime-origin-base"
    cp -R "$ROOT" "$origin_base"
    for mode in missing_receipt forged_receipt forged_title confirmed_disguise deleted_task reordered_tasks; do
      corrupt_root="$EVIDENCE_DIR/runtime-origin-$mode"
      cp -R "$origin_base" "$corrupt_root"
      case "$mode" in
        missing_receipt)
          rm -rf "$corrupt_root/.agents/runtime-task-receipts"
          ;;
        forged_receipt)
          receipt_path="$(find "$corrupt_root/.agents/runtime-task-receipts" -type f -name 'YARD-002*.yaml' ! -name '*.committed.yaml' | head -n 1)"
          python3 - "$receipt_path" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text, count = re.subn(r"^origin_action_id: .+$", "origin_action_id: forged-action", text, count=1, flags=re.M)
if count != 1:
    raise SystemExit("failed to forge runtime receipt")
open(path, "w", encoding="utf-8").write(text)
PY
          ;;
        forged_title)
          python3 - "$corrupt_root/.agents/work-queue.yaml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
current, count = re.subn(r"^(\s+title:) explicit runtime follow-up$", r"\1 forged follow-up", current, count=1, flags=re.M)
if count != 1:
    raise SystemExit("failed to forge added task title")
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
          ;;
        confirmed_disguise)
          confirmation="$(sed -n 's/^confirmation_id: //p' "$corrupt_root/.agents/work-queue.yaml" | head -n 1)"
          python3 - "$corrupt_root/.agents/work-queue.yaml" "$confirmation" <<'PY'
import re
import sys
path, confirmation = sys.argv[1:]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
current, count = re.subn(r"^(\s+materialized_by_confirmation_id:) (?:''|\"\")$", rf'\1 {confirmation}', current, count=1, flags=re.M)
if count != 1:
    raise SystemExit("failed to disguise added task")
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
          ;;
        deleted_task)
          python3 - "$corrupt_root/.agents/work-queue.yaml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
current, count = re.subn(r"(?ms)^- id: YARD-003\n.*?(?=^- id: |^planning_session_id:)", "", current, count=1)
if count != 1:
    raise SystemExit("failed to delete committed runtime task")
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
          ;;
        reordered_tasks)
          python3 - "$corrupt_root/.agents/work-queue.yaml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
pattern = re.compile(r"(?ms)^- id: (YARD-002|YARD-003)\n.*?(?=^- id: |^planning_session_id:)")
blocks = pattern.findall(current)
matches = list(pattern.finditer(current))
if blocks != ["YARD-002", "YARD-003"] or len(matches) != 2:
    raise SystemExit("failed to locate committed runtime task order")
first, second = matches
current = current[:first.start()] + second.group(0) + first.group(0) + current[second.end():]
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
          ;;
      esac
      before="$(state_digest "$corrupt_root")"
      if run_in "$corrupt_root" packet --task YARD-002 --dry-run >"$EVIDENCE_DIR/runtime-origin-$mode.out" 2>"$EVIDENCE_DIR/runtime-origin-$mode.err"; then
        fail "runtime origin corruption $mode produced a packet"
      fi
      grep -Eq 'active_runtime_(origin|envelope)_mismatch|unconfirmed_or_inconsistent' "$EVIDENCE_DIR/runtime-origin-$mode.err" || fail "runtime origin corruption reason missing for $mode"
      [[ "$before" == "$(state_digest "$corrupt_root")" ]] || fail "runtime origin corruption $mode changed canonical state"
    done
    write_summary "confirmed base contract remained immutable while committed receipt-backed additions preserved exact presence/order and defer/revive overlays stayed runnable"
    ;;
  confirmed_auto_runtime_envelope)
    accept_proposal "$p1" none act-confirmed-auto-accept >/dev/null
    head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$head" --action-id act-confirmed-auto-confirm >/dev/null
    (cd "$ROOT" && git init -q && git config user.name fixture && \
      git config user.email fixture@example.invalid && git add .agents/yardlet.yaml && \
      git commit -qm baseline)

    task_root="$EVIDENCE_DIR/confirmed-auto-task-control"
    cp -R "$ROOT" "$task_root"
    run_in "$task_root" run --task YARD-001 >"$EVIDENCE_DIR/confirmed-auto-task.out" \
      2>"$EVIDENCE_DIR/confirmed-auto-task.err"
    grep -q 'selected task YARD-001' "$EVIDENCE_DIR/confirmed-auto-task.out" || \
      fail "same confirmed queue did not admit the named task control"

    auto_root="$EVIDENCE_DIR/confirmed-auto-direct"
    cp -R "$ROOT" "$auto_root"
    run_in "$auto_root" run --auto >"$EVIDENCE_DIR/confirmed-auto-direct.out" \
      2>"$EVIDENCE_DIR/confirmed-auto-direct.err"
    [[ -n "$(find "$auto_root/.agents/runs" -name fixture-confirmed-auto-worker-entered -print -quit)" ]] || \
      fail "fresh confirmed queue auto run did not enter the worker"

    revived_root="$EVIDENCE_DIR/confirmed-auto-revived"
    cp -R "$ROOT" "$revived_root"
    run_in "$revived_root" defer YARD-001 "fixture pause" >/dev/null
    run_in "$revived_root" revive YARD-001 >/dev/null
    run_in "$revived_root" run --auto >"$EVIDENCE_DIR/confirmed-auto-revived.out" \
      2>"$EVIDENCE_DIR/confirmed-auto-revived.err"
    [[ -n "$(find "$revived_root/.agents/runs" -name fixture-confirmed-auto-worker-entered -print -quit)" ]] || \
      fail "defer/revive confirmed queue auto run did not enter the worker"

    tampered_root="$EVIDENCE_DIR/confirmed-auto-tampered"
    cp -R "$ROOT" "$tampered_root"
    python3 - "$tampered_root/.agents/work-queue.yaml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
current, materialized = text.split("materialized_queue:", 1)
current, count = re.subn(
    r"^(\s+title:) confirmed auto runtime fixture$",
    r"\1 forged runtime title",
    current,
    count=1,
    flags=re.M,
)
if count != 1:
    raise SystemExit("failed to mutate confirmed runtime title")
open(path, "w", encoding="utf-8").write(current + "materialized_queue:" + materialized)
PY
    if run_in "$tampered_root" run --auto >"$EVIDENCE_DIR/confirmed-auto-tampered.out" \
      2>"$EVIDENCE_DIR/confirmed-auto-tampered.err"; then
      fail "real runtime contract tamper was admitted by auto"
    fi
    grep -q 'active_runtime_envelope_mismatch' "$EVIDENCE_DIR/confirmed-auto-tampered.err" || \
      fail "real runtime contract tamper did not retain the envelope mismatch reason"

    write_summary "새 confirm과 defer/revive queue의 auto admission은 worker까지 진입하고 named task 대조군은 통과하며 실제 contract 변조는 거부됨"
    ;;
  writer_inventory)
    inventory="$EVIDENCE_DIR/writer-inventory.txt"
    : >"$inventory"
    while IFS= read -r file; do
      relative="${file#"$REPO_ROOT/"}"
      [[ "$relative" == "src/state.rs" ]] && continue
      awk '/^#\[cfg\(test\)\]/{exit} {print}' "$file" \
        | grep -nE '\.save_queue(_locked)?\(' \
        | sed "s#^#$relative:#" >>"$inventory" || true
    done < <(find "$REPO_ROOT/src" -type f -name '*.rs' | sort)
    [[ -s "$inventory" ]] || fail "workspace-wide queue writer inventory was unexpectedly empty"
    save_queue_body="$(sed -n '/pub fn save_queue(/,/^    }/p' "$REPO_ROOT/src/state.rs")"
    grep -q 'acquire_planning_lock' <<<"$save_queue_body" || fail "public compatibility queue writer does not acquire the workspace lock"
    grep -q 'save_queue_locked' <<<"$save_queue_body" || fail "public compatibility queue writer bypasses raw-byte CAS"
    locked_writer_body="$(sed -n '/pub fn save_queue_locked(/,/^    }/p' "$REPO_ROOT/src/state.rs")"
    grep -q 'PlanningLock' <<<"$locked_writer_body" || fail "locked queue writer does not require the guard token"
    grep -q 'write_str_atomic_cas' <<<"$locked_writer_body" || fail "locked queue writer bypasses raw-byte CAS"
    activated_writer_body="$(sed -n '/pub fn save_activated_queue_snapshot_locked(/,/^    }/p' "$REPO_ROOT/src/state.rs")"
    grep -q 'PlanningLock' <<<"$activated_writer_body" || fail "activation queue writer does not require the guard token"
    grep -q 'write_str_atomic_cas' <<<"$activated_writer_body" || fail "activation queue writer bypasses raw-byte CAS"
    architecture_guard="$(sed -n '/fn canonical_agents_state_writes_stay_behind_state_module/,/^}/p' "$REPO_ROOT/tests/state_architecture_guard.rs")"
    grep -q 'scan_dir' <<<"$architecture_guard" || fail "workspace-wide canonical writer architecture guard is missing"
    grep -q 'runtime-task-receipts' "$REPO_ROOT/tests/state_architecture_guard.rs" || fail "runtime receipt canonical path is outside the writer architecture guard"
    grep -q 'runtime-capability-receipts' "$REPO_ROOT/tests/state_architecture_guard.rs" || fail "runtime capability receipt path is outside the writer architecture guard"
    write_summary "all production Rust queue callers are inventoried; public and guard-token writers converge on state.rs raw-byte CAS"
    ;;
  express_concurrency)
    express_root="$EVIDENCE_DIR/express-workspace"
    mkdir -p "$express_root"
    run_in "$express_root" init >/dev/null
    barrier="$EVIDENCE_DIR/express-barrier"
    mkdir -p "$barrier"
    (cd "$express_root" && YARDLET_TEST_MUTATION_BARRIER="$barrier" \
      "$YARDLET_BIN" goal "first concurrent express goal" --plan-only \
      >"$EVIDENCE_DIR/express-first.out" 2>"$EVIDENCE_DIR/express-first.err") &
    first_pid=$!
    wait_for_file "$barrier/entered" "$first_pid" || { kill "$first_pid" 2>/dev/null || true; fail "first express process missed stable barrier"; }
    (cd "$express_root" && YARDLET_TEST_MUTATION_BARRIER="$barrier" \
      "$YARDLET_BIN" goal "second concurrent express goal" --plan-only \
      >"$EVIDENCE_DIR/express-second.out" 2>"$EVIDENCE_DIR/express-second.err") &
    second_pid=$!
    sleep 0.1
    touch "$barrier/release"
    set +e
    wait "$first_pid"; first_status=$?
    wait "$second_pid"; second_status=$?
    set -e
    [[ "$first_status" -eq 0 && "$second_status" -eq 0 ]] || fail "concurrent express transactions diverged: first=$first_status second=$second_status"
    run_in "$express_root" planning show --json >"$EVIDENCE_DIR/express-final.json"
    [[ "$(json_get "$EVIDENCE_DIR/express-final.json" exact_active_parity)" == "true" ]] || fail "concurrent express final activation parity false"
    session_count="$(find "$express_root/.agents/planning-sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    [[ "$session_count" == "2" ]] || fail "concurrent express did not leave two complete sessions"
    write_summary "two-process stable barrier에서 각 express goal의 create/propose/accept/confirm이 outer transaction으로 직렬화됨"
    ;;
  same_request_multi_session_recovery)
    barrier="$EVIDENCE_DIR/same-request-barrier"
    mkdir -p "$barrier"
    (cd "$ROOT" && exec env YARDLET_TEST_PLANNER_RESULT_BARRIER="$barrier" \
      "$YARDLET_BIN" planning answer "delayed same-request turn" --expected-head none \
      --action-id act-same-request-delayed --worker fixture-planner \
      >"$EVIDENCE_DIR/same-request-delayed.out" 2>"$EVIDENCE_DIR/same-request-delayed.err") &
    delayed_pid=$!
    wait_for_file "$barrier/result-ready" "$delayed_pid" || { kill "$delayed_pid" 2>/dev/null || true; fail "same-request planner did not reach result barrier"; }
    delayed_run="$(find "$ROOT/.agents/runs" -mindepth 1 -maxdepth 1 -type d -name 'plan-*' ! -exec test -e '{}/consumed' \; -print | sort | tail -n 1)"
    [[ -n "$delayed_run" && -f "$delayed_run/planning-result.json" ]] || fail "same-request unconsumed result missing"
    delayed_session="$(sed -n 's/^session_id: //p' "$delayed_run/plan-meta.yaml")"
    [[ -n "$delayed_session" ]] || fail "PlanMeta v2 session_id missing"
    kill -9 "$delayed_pid" 2>/dev/null || true
    wait "$delayed_pid" 2>/dev/null || true
    touch "$barrier/release"
    wait_for_worker_exit "$delayed_run" || fail "same-request orphan worker did not exit"

    accept_proposal "$p1" none act-same-request-accept >/dev/null
    old_head="$(visible_head)"
    run_yardlet planning confirm --expected-head "$old_head" --action-id act-same-request-confirm >/dev/null
    run_yardlet defer YARD-001 "finish baseline" >/dev/null
    run_yardlet new "initial planning request" --worker fixture-planner >/dev/null
    show
    current_session="$(json_get "$EVIDENCE_DIR/show.json" session.session_id)"
    [[ "$current_session" != "$delayed_session" ]] || fail "same-request fixture did not create a second session"
    current_proposals_before="$(find "$ROOT/.agents/planning-sessions/$current_session/proposals" -type f -name '*.yaml' | wc -l | tr -d ' ')"
    cp "$ROOT/.agents/intent-contract.yaml" "$EVIDENCE_DIR/same-request.intent.before"
    cp "$ROOT/.agents/work-queue.yaml" "$EVIDENCE_DIR/same-request.queue.before"
    if run_yardlet recover >"$EVIDENCE_DIR/same-request-recover.out" 2>"$EVIDENCE_DIR/same-request-recover.err"; then
      fail "stale exact-session result was recovered into another same-request session"
    fi
    grep -Eq 'stale_planner_output|stale_head|exact planning session' "$EVIDENCE_DIR/same-request-recover.err" || fail "same-request recovery error missing"
    [[ ! -e "$delayed_run/consumed" ]] || fail "rejected same-request result was marked consumed"
    current_proposals_after="$(find "$ROOT/.agents/planning-sessions/$current_session/proposals" -type f -name '*.yaml' | wc -l | tr -d ' ')"
    [[ "$current_proposals_before" == "$current_proposals_after" ]] || fail "same-request recovery attached proposal to current session"
    [[ "$(cat "$ROOT/.agents/planning-sessions/latest")" == "$current_session" ]] || fail "exact older-session recovery stole latest pointer"
    cmp "$EVIDENCE_DIR/same-request.intent.before" "$ROOT/.agents/intent-contract.yaml" || fail "same-request recovery changed active intent bytes"
    cmp "$EVIDENCE_DIR/same-request.queue.before" "$ROOT/.agents/work-queue.yaml" || fail "same-request recovery changed active queue bytes"
    write_summary "same initial request를 가진 다른 session으로 stale result가 이동하지 않고 active bytes와 latest pointer가 보존됨"
    ;;
  stale_planner_completion)
    accept_proposal "$p1" none act-stale-planner-accept-1 >/dev/null
    h1="$(visible_head)"
    answer_turn "scope correction" "$h1" act-stale-planner-fast >/dev/null
    p2="$(proposal)"
    barrier="$EVIDENCE_DIR/stale-planner-barrier"
    mkdir -p "$barrier"
    (cd "$ROOT" && exec env YARDLET_TEST_PLANNER_RESULT_BARRIER="$barrier" \
      "$YARDLET_BIN" planning answer "slow correction" --expected-head "$h1" \
      --action-id act-stale-planner-slow --worker fixture-planner \
      >"$EVIDENCE_DIR/stale-planner.out" 2>"$EVIDENCE_DIR/stale-planner.err") &
    slow_pid=$!
    wait_for_file "$barrier/result-ready" "$slow_pid" || { kill "$slow_pid" 2>/dev/null || true; fail "slow planner did not reach result barrier"; }
    slow_run="$(find "$ROOT/.agents/runs" -mindepth 1 -maxdepth 1 -type d -name 'plan-*' ! -exec test -e '{}/consumed' \; -print | sort | tail -n 1)"
    accept_proposal "$p2" "$h1" act-stale-planner-accept-2 >/dev/null
    h2="$(visible_head)"
    proposal_count_before="$(find "$ROOT/.agents/planning-sessions" -path '*/proposals/*.yaml' -type f | wc -l | tr -d ' ')"
    cp "$ROOT/.agents/work-queue.yaml" "$EVIDENCE_DIR/stale-planner.queue.before"
    touch "$barrier/release"
    set +e
    wait "$slow_pid"; slow_status=$?
    set -e
    [[ "$slow_status" -ne 0 ]] || fail "stale planner completion was automatically rebased"
    grep -q '^schema_version: 2$' "$slow_run/plan-meta.yaml" || fail "PlanMeta v2 schema missing"
    grep -q "^expected_head: $h1$" "$slow_run/plan-meta.yaml" || fail "PlanMeta expected_head mismatch"
    grep -q '^request_event_id: ' "$slow_run/plan-meta.yaml" || fail "PlanMeta request_event_id missing"
    grep -q '^request_digest: ' "$slow_run/plan-meta.yaml" || fail "PlanMeta request_digest missing"
    grep -Eq 'stale_planner_output|stale_head' "$EVIDENCE_DIR/stale-planner.err" || fail "stale planner completion reason missing"
    [[ "$(visible_head)" == "$h2" ]] || fail "stale planner completion changed visible head"
    proposal_count_after="$(find "$ROOT/.agents/planning-sessions" -path '*/proposals/*.yaml' -type f | wc -l | tr -d ' ')"
    [[ "$proposal_count_before" == "$proposal_count_after" ]] || fail "stale planner completion created a proposal"
    [[ ! -e "$slow_run/consumed" ]] || fail "stale planner completion was marked consumed"
    [[ ! -e "$ROOT/.agents/intent-contract.yaml" ]] || fail "stale planner completion activated intent state"
    cmp "$EVIDENCE_DIR/stale-planner.queue.before" "$ROOT/.agents/work-queue.yaml" || fail "stale planner completion changed active queue bytes"
    write_summary "worker completion 시 exact head CAS가 stale output을 rebase 없이 거절하고 canonical state를 보존함"
    ;;
  corrupt_recovery)
    accept_proposal "$p1" none act-corrupt-recovery-accept >/dev/null
    h1="$(visible_head)"
    barrier="$EVIDENCE_DIR/corrupt-recovery-barrier"
    mkdir -p "$barrier"
    (cd "$ROOT" && exec env YARDLET_TEST_PLANNER_RESULT_BARRIER="$barrier" \
      "$YARDLET_BIN" planning answer "restart recovery candidate" --expected-head "$h1" \
      --action-id act-corrupt-recovery-answer --worker fixture-planner \
      >"$EVIDENCE_DIR/corrupt-recovery-worker.out" 2>"$EVIDENCE_DIR/corrupt-recovery-worker.err") &
    interrupted_pid=$!
    wait_for_file "$barrier/result-ready" "$interrupted_pid" || { kill "$interrupted_pid" 2>/dev/null || true; fail "corrupt recovery planner did not reach result barrier"; }
    corrupt_run="$(find "$ROOT/.agents/runs" -mindepth 1 -maxdepth 1 -type d -name 'plan-*' ! -exec test -e '{}/consumed' \; -print | sort | tail -n 1)"
    kill -9 "$interrupted_pid" 2>/dev/null || true
    wait "$interrupted_pid" 2>/dev/null || true
    touch "$barrier/release"
    wait_for_worker_exit "$corrupt_run" || fail "corrupt recovery orphan worker did not exit"
    cp "$corrupt_run/planning-result.json" "$EVIDENCE_DIR/corrupt-recovery.valid-result.json"
    printf '{invalid-json\n' >"$corrupt_run/planning-result.json"
    state_manifest "$ROOT" >"$EVIDENCE_DIR/corrupt-recovery.before.manifest"
    state_before="$(state_digest "$ROOT")"
    if run_yardlet recover >"$EVIDENCE_DIR/corrupt-recovery.out" 2>"$EVIDENCE_DIR/corrupt-recovery.err"; then
      fail "corrupt planning result recovery succeeded"
    fi
    grep -Eq 'parsing|planning-result.json|expected ident' "$EVIDENCE_DIR/corrupt-recovery.err" || fail "corrupt recovery parse error was swallowed"
    state_manifest "$ROOT" >"$EVIDENCE_DIR/corrupt-recovery.after.manifest"
    if [[ "$state_before" != "$(state_digest "$ROOT")" ]]; then
      diff -u "$EVIDENCE_DIR/corrupt-recovery.before.manifest" "$EVIDENCE_DIR/corrupt-recovery.after.manifest" >&2 || true
      fail "corrupt recovery changed canonical bytes"
    fi
    [[ ! -e "$corrupt_run/consumed" ]] || fail "corrupt recovery was marked consumed"
    cp "$EVIDENCE_DIR/corrupt-recovery.valid-result.json" "$corrupt_run/planning-result.json"
    run_yardlet planning confirm --expected-head "$h1" --action-id act-corrupt-recovery-confirm >/dev/null
    activation_path="$(find "$ROOT/.agents/activations" -type f -name '*.yaml' -print -quit)"
    python3 - "$activation_path" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("queue_digest: ", "queue_digest: tampered-", 1)
path.write_text(text, encoding="utf-8")
PY
    corrupt_active_before="$(state_digest "$ROOT")"
    if run_yardlet recover >"$EVIDENCE_DIR/corrupt-activation-recovery.out" 2>"$EVIDENCE_DIR/corrupt-activation-recovery.err"; then
      fail "corrupt activation recovery succeeded"
    fi
    grep -q 'unconfirmed_or_inconsistent' "$EVIDENCE_DIR/corrupt-activation-recovery.err" || fail "corrupt activation recovery error was swallowed"
    [[ "$corrupt_active_before" == "$(state_digest "$ROOT")" ]] || fail "corrupt activation recovery changed canonical bytes"
    [[ ! -e "$corrupt_run/consumed" ]] || fail "corrupt activation recovery was marked consumed"
    write_summary "corrupt planning result와 corrupt activation 오류가 전파되고 active, session, proposal bytes와 consumed 상태가 보존됨"
    ;;
  restart_unconsumed_planner_recovery)
    accept_proposal "$p1" none act-restart-recovery-accept-1 >/dev/null
    h1="$(visible_head)"
    barrier="$EVIDENCE_DIR/restart-recovery-barrier"
    mkdir -p "$barrier"
    (cd "$ROOT" && exec env YARDLET_TEST_PLANNER_RESULT_BARRIER="$barrier" \
      "$YARDLET_BIN" planning answer "recovered scope correction" --expected-head "$h1" \
      --action-id act-restart-recovery-answer --worker fixture-planner \
      >"$EVIDENCE_DIR/restart-recovery-worker.out" 2>"$EVIDENCE_DIR/restart-recovery-worker.err") &
    interrupted_pid=$!
    wait_for_file "$barrier/result-ready" "$interrupted_pid" || { kill "$interrupted_pid" 2>/dev/null || true; fail "restart recovery planner did not reach result barrier"; }
    recovered_run="$(find "$ROOT/.agents/runs" -mindepth 1 -maxdepth 1 -type d -name 'plan-*' ! -exec test -e '{}/consumed' \; -print | sort | tail -n 1)"
    exact_session="$(sed -n 's/^session_id: //p' "$recovered_run/plan-meta.yaml")"
    exact_head="$(sed -n 's/^expected_head: //p' "$recovered_run/plan-meta.yaml")"
    kill -9 "$interrupted_pid" 2>/dev/null || true
    wait "$interrupted_pid" 2>/dev/null || true
    touch "$barrier/release"
    wait_for_worker_exit "$recovered_run" || fail "restart recovery orphan worker did not exit"
    [[ ! -e "$ROOT/.agents/intent-contract.yaml" ]] || fail "restart fixture unexpectedly has active intent"
    cp "$ROOT/.agents/work-queue.yaml" "$EVIDENCE_DIR/restart-recovery.queue.before"
    run_yardlet recover >"$EVIDENCE_DIR/restart-recovery.out"
    [[ -e "$recovered_run/consumed" ]] || fail "successful canonical proposal apply was not marked consumed"
    recovered_proposal="$(find "$ROOT/.agents/planning-sessions/$exact_session/proposals" -type f -name '*.yaml' | sort | tail -n 1)"
    [[ -f "$recovered_proposal" ]] || fail "restart recovery did not create exact-session proposal"
    grep -q "^session_id: $exact_session$" "$recovered_proposal" || fail "recovered proposal owner mismatch"
    grep -q "^expected_head: $exact_head$" "$recovered_proposal" || fail "recovered proposal head mismatch"
    [[ ! -e "$ROOT/.agents/intent-contract.yaml" ]] || fail "recovery directly activated intent"
    cmp "$EVIDENCE_DIR/restart-recovery.queue.before" "$ROOT/.agents/work-queue.yaml" || fail "recovery directly activated queue"
    recovered_proposal_id="$(sed -n 's/^proposal_id: //p' "$recovered_proposal")"
    accept_proposal "$recovered_proposal_id" "$h1" act-restart-recovery-accept-2 >/dev/null
    h2="$(visible_head)"
    [[ ! -e "$ROOT/.agents/intent-contract.yaml" ]] || fail "proposal accept activated intent"
    cmp "$EVIDENCE_DIR/restart-recovery.queue.before" "$ROOT/.agents/work-queue.yaml" || fail "proposal accept activated queue"
    run_yardlet planning confirm --expected-head "$h2" --action-id act-restart-recovery-confirm >/dev/null
    show
    [[ "$(json_get "$EVIDENCE_DIR/show.json" exact_active_parity)" == "true" ]] || fail "explicit confirm after recovery lost exact parity"
    write_summary "restart recovery가 exact session/head proposal만 만들고 consumed는 성공 후, active state는 explicit confirm 후에만 기록함"
    ;;
  release_hook_disabled)
    (cd "$ROOT" && YARDLET_TEST_PLANNING_CRASH=accept_after_revision_write \
      "$YARDLET_BIN" planning accept "$p1" --expected-head none --action-id act-release-hook \
      >"$EVIDENCE_DIR/release-hook.out" 2>"$EVIDENCE_DIR/release-hook.err")
    action_path="$(find "$ROOT/.agents/planning-sessions" -path '*/actions/act-release-hook.yaml' -print -quit)"
    grep -q '^status: completed$' "$action_path" || fail "release binary exposed planning crash hook"
    [[ "$(revision_count)" == "1" ]] || fail "release crash-hook probe duplicated revision"
    write_summary "release binary가 test-only planning crash environment를 무시함"
    ;;
  *)
    fail "unknown scenario $SCENARIO"
    ;;
esac
