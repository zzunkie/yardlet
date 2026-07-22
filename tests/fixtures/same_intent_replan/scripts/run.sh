#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s <yardlet-bin> <evidence-dir> <scenario>\n' "$0" >&2
  exit 64
fi

YARDLET_BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EVIDENCE_DIR="$2"
SCENARIO="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$EVIDENCE_DIR"

fail() {
  printf 'fixture failure: %s\n' "$*" >&2
  exit 1
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value.get(part)
        if value is None:
            break
if value is None:
    print("none")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

json_audit_hard_total() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
signal = sys.argv[2]
print(sum(
    1
    for audit in value["capability_audits"]
    for task in audit["tasks"]
    if signal in task["trigger"]["hard_signals"]
))
PY
}

# Count sealed failed/partial run records of one intent+task that carry a
# fatal failed evaluator check — the exact predicate of
# Workspace::typed_run_failure_projection.
typed_failure_count() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import pathlib
import re
import sys

runs = pathlib.Path(sys.argv[1]) / ".agents" / "runs"
intent_id, task_id = sys.argv[2], sys.argv[3]
count = 0
for run_yaml in runs.glob("*/run.yaml"):
    text = run_yaml.read_text(encoding="utf-8")
    def field(name):
        match = re.search(rf"^{name}: (.+)$", text, re.MULTILINE)
        return match.group(1).strip().strip("'\"") if match else ""
    if field("intent_id") != intent_id or field("task_id") != task_id:
        continue
    if field("state") not in ("failed", "partial") or not field("completed_at"):
        continue
    evaluation = run_yaml.parent / "evaluation.json"
    if not evaluation.is_file():
        continue
    checks = json.loads(evaluation.read_text(encoding="utf-8")).get("checks", [])
    if any(check.get("fatal") and not check.get("passed") for check in checks):
        count += 1
print(count)
PY
}

queue_task_state() {
  python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
task_id = sys.argv[2]
match = re.search(rf"- id: {re.escape(task_id)}\n(.*?)(?=\n- id: |\Z)", text, re.DOTALL)
if not match:
    raise SystemExit(f"task {task_id} not found")
state = re.search(r"^\s+state: (\S+)$", match.group(1), re.MULTILINE)
print(state.group(1) if state else "missing")
PY
}

run_in() {
  local root="$1"
  shift
  (cd "$root" && "$YARDLET_BIN" "$@")
}

show_json() {
  local root="$1"
  local output="$2"
  run_in "$root" planning show --json >"$output"
}

setup_workspace() {
  local root="$1"
  mkdir -p "$root/src" "$root/fixture-worker"
  printf '[package]\nname = "replan-fixture"\nversion = "0.1.0"\nedition = "2021"\n' >"$root/Cargo.toml"
  printf 'fn main() {}\n' >"$root/src/main.rs"
  cp "$SCRIPT_DIR/worker.sh" "$SCRIPT_DIR/planner-worker.sh" \
    "$SCRIPT_DIR/task-worker.sh" "$SCRIPT_DIR/scout-worker.sh" "$root/fixture-worker/"
  chmod +x "$root/fixture-worker/"*.sh
  (
    cd "$root"
    git init -q
    git config user.name fixture
    git config user.email fixture@example.invalid
    git add Cargo.toml src/main.rs
    git commit -qm fixture
  )
  run_in "$root" init >/dev/null
  cat >"$root/.agents/workers.yaml" <<EOF
schema_version: 1
workers:
  - id: fixture-worker
    kind: cli_worker
    model: fixture-model
    capabilities: [shell]
    best_for: provider-free deterministic replan fixtures
    billing:
      mode: subscription_backed_only
    invocation:
      command: $root/fixture-worker/worker.sh
      supports_noninteractive: true
      output_contract: files
      args: ["{run_dir}", "--workspace-marker=$root"]
      sandbox_args: [sandboxed]
      full_access_args: [full]
    limits:
      max_wall_minutes: 1
      max_retries: 0
routing:
  default_worker: fixture-worker
  fallback_order: [fixture-worker]
  allow_preferred_worker_failover: false
  planning_gate:
    primary: fixture-worker
    fallback: ""
EOF
}

write_summary() {
  local detail="$1"
  python3 - "$EVIDENCE_DIR/summary.json" "$SCENARIO" "$detail" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {"status": "passed", "scenario": sys.argv[2], "detail": sys.argv[3]},
        ensure_ascii=False,
        indent=2,
    ) + "\n",
    encoding="utf-8",
)
PY
}

case "$SCENARIO" in
  same_intent_replan)
    root="$(mktemp -d "$EVIDENCE_DIR/replan.XXXXXX")"
    setup_workspace "$root"

    # A workspace with no confirmed intent has nothing to replan.
    if run_in "$root" planning replan "fixture:replan_retry" \
      >"$EVIDENCE_DIR/replan-unconfirmed.out" 2>&1; then
      fail "replan succeeded without a confirmed active intent"
    fi
    grep -q 'confirmed active intent' "$EVIDENCE_DIR/replan-unconfirmed.out" || \
      fail "unconfirmed replan rejection reason missing"

    # Turn 1: plan, accept, and confirm the seed intent through the real gate.
    run_in "$root" new "fixture:replan_seed" --worker fixture-worker \
      >"$EVIDENCE_DIR/seed-new.out"
    show_json "$root" "$EVIDENCE_DIR/seed-show.json"
    intent_id="$(json_get "$EVIDENCE_DIR/seed-show.json" session.intent_id)"
    [[ "$intent_id" != "none" && -n "$intent_id" ]] || fail "seed intent id missing"
    [[ "$(json_audit_hard_total "$EVIDENCE_DIR/seed-show.json" repeated_typed_failure)" == "0" ]] || \
      fail "typed failure signal fired without run history"
    proposal="$(json_get "$EVIDENCE_DIR/seed-show.json" pending_proposals.0.proposal_id)"
    run_in "$root" planning accept "$proposal" --expected-head none \
      --action-id act-replan-seed-accept >"$EVIDENCE_DIR/seed-accept.out"
    head="$(json_get <(run_in "$root" planning show --json) session.current_head)"
    run_in "$root" planning confirm --expected-head "$head" \
      --action-id act-replan-seed-confirm >"$EVIDENCE_DIR/seed-confirm.out"
    seed_confirmation="$(sed -n 's/^confirmation_id: //p' "$root/.agents/work-queue.yaml")"
    [[ -n "$seed_confirmation" ]] || fail "seed confirmation id missing from activated queue"

    # A freshly confirmed queue is live, not settled: replan must refuse.
    if run_in "$root" planning replan "fixture:replan_retry" \
      >"$EVIDENCE_DIR/replan-live.out" 2>&1; then
      fail "replan superseded a live queue"
    fi
    grep -q 'live tasks' "$EVIDENCE_DIR/replan-live.out" || \
      fail "live-queue replan rejection reason missing"

    # Two real failing executions inside the feedback cap: each seals a
    # `partial` run record backed by a fatal failed evaluator check, and the
    # drain settles the task Partial — a failure-settled terminal hold.
    for attempt in 1 2; do
      run_in "$root" run --task YARD-001 --execute \
        >"$EVIDENCE_DIR/run-fail-$attempt.out" 2>&1 || true
      [[ "$(queue_task_state "$root/.agents/work-queue.yaml" YARD-001)" == "partial" ]] || \
        fail "attempt $attempt did not settle the task partial"
      [[ "$(typed_failure_count "$root" "$intent_id" YARD-001)" == "$attempt" ]] || \
        fail "attempt $attempt did not seal a typed failure run record"
    done

    # Explicit same-intent replan over the failure-settled queue.
    run_in "$root" planning replan "fixture:replan_retry" --worker fixture-worker \
      >"$EVIDENCE_DIR/replan.out"
    show_json "$root" "$EVIDENCE_DIR/replan-show.json"
    [[ "$(json_get "$EVIDENCE_DIR/replan-show.json" session.intent_id)" == "$intent_id" ]] || \
      fail "replan session did not keep the confirmed intent id"
    [[ "$(json_audit_hard_total "$EVIDENCE_DIR/replan-show.json" repeated_typed_failure)" == "1" ]] || \
      fail "replan audit did not raise repeated_typed_failure from the real run history"
    [[ "$(json_get "$EVIDENCE_DIR/replan-show.json" capability_audits.0.tasks.0.trigger.decision)" == "scout" ]] || \
      fail "repeated typed failure did not force the scout decision"

    # Promote the replacement plan: same intent id, task re-queued.
    proposal="$(json_get "$EVIDENCE_DIR/replan-show.json" pending_proposals.0.proposal_id)"
    run_in "$root" planning accept "$proposal" --expected-head none \
      --action-id act-replan-retry-accept >"$EVIDENCE_DIR/replan-accept.out"
    head="$(json_get <(run_in "$root" planning show --json) session.current_head)"
    run_in "$root" planning confirm --expected-head "$head" \
      --action-id act-replan-retry-confirm >"$EVIDENCE_DIR/replan-confirm.out"
    show_json "$root" "$EVIDENCE_DIR/replan-confirmed.json"
    [[ "$(json_get "$EVIDENCE_DIR/replan-confirmed.json" exact_active_parity)" == "true" ]] || \
      fail "replanned confirmation lost exact active parity"
    grep -q "^intent_id: $intent_id\$" "$root/.agents/work-queue.yaml" || \
      fail "replanned queue changed the intent id"
    [[ "$(queue_task_state "$root/.agents/work-queue.yaml" YARD-001)" == "queued" ]] || \
      fail "replanned queue did not requeue the task"
    grep -q 'retry replan fixture task' "$root/.agents/work-queue.yaml" || \
      fail "replanned queue did not adopt the replacement plan"

    # The replan confirm archived the seed drain; the archive must exist at
    # the canonical intent path AND at the seed confirmation's drain path.
    archive_dir="$root/.agents/intents/$intent_id"
    [[ -f "$archive_dir/work-queue.yaml" ]] || \
      fail "replan confirm did not archive the seed drain"
    grep -q 'seed replan fixture task' \
      "$archive_dir/drains/$seed_confirmation/work-queue.yaml" || \
      fail "seed drain not preserved under its confirmation-scoped archive path"
    retry_confirmation="$(sed -n 's/^confirmation_id: //p' "$root/.agents/work-queue.yaml")"
    [[ -n "$retry_confirmation" && "$retry_confirmation" != "$seed_confirmation" ]] || \
      fail "replan confirm did not mint a fresh confirmation id"

    # Second same-intent replan cycle: the replanned task inherits the
    # intent's consumed feedback cap, so its next real failing run settles
    # NeedsUser (goal_feedback_exhausted) — the YARD-008 settled shape replan
    # still accepts. Replanning + confirming again triggers the second archive
    # of the same intent id — the exact overwrite the confirmation-scoped
    # drain snapshots exist to survive.
    run_in "$root" run --task YARD-001 --execute \
      >"$EVIDENCE_DIR/run-fail-3.out" 2>&1 || true
    [[ "$(queue_task_state "$root/.agents/work-queue.yaml" YARD-001)" == "needs_user" ]] || \
      fail "cap-exhausted rerun did not settle the replanned task needs_user"
    grep -q 'needs_user_origin: goal_feedback_exhausted' "$root/.agents/work-queue.yaml" || \
      fail "cap-exhausted rerun did not record the goal_feedback_exhausted origin"
    run_in "$root" planning replan "fixture:replan_retry" --worker fixture-worker \
      >"$EVIDENCE_DIR/replan2.out"
    show_json "$root" "$EVIDENCE_DIR/replan2-show.json"
    [[ "$(json_get "$EVIDENCE_DIR/replan2-show.json" session.intent_id)" == "$intent_id" ]] || \
      fail "second replan session did not keep the confirmed intent id"
    proposal="$(json_get "$EVIDENCE_DIR/replan2-show.json" pending_proposals.0.proposal_id)"
    run_in "$root" planning accept "$proposal" --expected-head none \
      --action-id act-replan-retry2-accept >"$EVIDENCE_DIR/replan2-accept.out"
    head="$(json_get <(run_in "$root" planning show --json) session.current_head)"
    run_in "$root" planning confirm --expected-head "$head" \
      --action-id act-replan-retry2-confirm >"$EVIDENCE_DIR/replan2-confirm.out"

    # Both drains of the same intent id survive the second archive: the seed
    # drain is untouched, the retry drain has its own confirmation-scoped
    # snapshot, and the canonical single-archive path serves the latest drain.
    grep -q 'seed replan fixture task' \
      "$archive_dir/drains/$seed_confirmation/work-queue.yaml" || \
      fail "second archive lost the seed drain snapshot"
    grep -q 'retry replan fixture task' \
      "$archive_dir/drains/$retry_confirmation/work-queue.yaml" || \
      fail "retry drain not preserved under its confirmation-scoped archive path"
    grep -q 'retry replan fixture task' "$archive_dir/work-queue.yaml" || \
      fail "canonical intent archive does not serve the latest drain"
    [[ -f "$archive_dir/drains/$seed_confirmation/final-report.md" ]] || \
      fail "seed drain snapshot missing its final report"

    write_summary "confirmed intent를 실제 실패 run 2회로 Partial 종결시킨 뒤 planning replan이 같은 intent id 세션을 열고, 그 planning audit이 실제 run 기록에서 repeated_typed_failure를 발화했으며, 대체 계획 confirm까지 같은 intent로 완결됨; 같은 intent의 2회 confirm(replan)에서 각 drain 아카이브가 confirmation-scoped drains/ 경로에 보존되고 canonical 아카이브는 최신 drain을 유지함"
    ;;

  *)
    fail "unknown scenario: $SCENARIO"
    ;;
esac
