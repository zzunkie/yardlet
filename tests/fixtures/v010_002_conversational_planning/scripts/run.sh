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
    [[ "$(visible_head)" == "$h2" ]] || fail "corrupt digest undo changed head"
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
    [[ "$(visible_head)" == "$h2" ]] || fail "missing parent undo changed head"
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
    [[ "$(visible_head)" == "$h2" ]] || fail "cross-session parent undo changed head"
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
    rm -rf "$ROOT/.agents/activations" "$ROOT/.agents/planning-sessions"
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
            "materialized_by_confirmation_id",
            "activation_required",
        }:
            continue
        stripped.append(line)
    open(path, "w", encoding="utf-8").writelines(stripped)
PY
    if run_yardlet run --next >"$EVIDENCE_DIR/stripped.out" 2>"$EVIDENCE_DIR/stripped.err"; then
      fail "stripped modern activation fell back to Legacy"
    fi
    grep -q "unconfirmed_or_inconsistent" "$EVIDENCE_DIR/stripped.err" || fail "stripped modern failure reason missing"
    write_summary "modern activation marker survives stripped linkage and fails closed"
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
    cat >"$ROOT/.agents/work-queue.yaml" <<'EOF'
schema_version: 1
queue_id: queue-existing-fresh
intent_id: ''
selection_policy:
  default_order: priority_then_created_at
  require_planning_gate: true
  skip_if_blocked: true
  skip_if_approval_required: true
tasks: []
EOF
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
  *)
    fail "unknown scenario $SCENARIO"
    ;;
esac
