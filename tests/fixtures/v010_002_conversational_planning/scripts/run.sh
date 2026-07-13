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
ROOT="$(mktemp -d "$EVIDENCE_DIR/workspace.XXXXXX")"
PLANNER="$ROOT/planner-worker.sh"
cp "$SCRIPT_DIR/planner-worker.sh" "$PLANNER"
chmod +x "$PLANNER"

fail() {
  printf 'fixture failure: %s\n' "$*" >&2
  exit 1
}

run_yardlet() {
  (cd "$ROOT" && "$YARDLET_BIN" "$@")
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
    grep -q "running_queue_isolated" "$EVIDENCE_DIR/running.err" || fail "running isolation error missing"
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
  *)
    fail "unknown scenario $SCENARIO"
    ;;
esac
