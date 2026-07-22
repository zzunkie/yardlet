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
FIXTURE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$EVIDENCE_DIR"

source "$FIXTURE_ROOT/../support/fixture-binary-preflight.sh"
preflight_fixture_binary "$YARDLET_BIN" \
  capability-coverage-trigger-matrix \
  bounded-capability-scout-contract

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

json_unique_len() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print(len(set(value)))
PY
}

json_max_audit_cache_hits() {
  python3 - "$1" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
print(max((len(set(audit.get("cache_hits", []))) for audit in value["capability_audits"]), default=0))
PY
}

json_digest() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(encoded.encode()).hexdigest())
PY
}

run_in() {
  local root="$1"
  shift
  (cd "$root" && "$YARDLET_BIN" "$@")
}

setup_workspace() {
  local root="$1"
  local sandbox_contract="${2:-sandboxed}"
  local sandbox_line=""
  case "$sandbox_contract" in
    sandboxed)
      sandbox_line="      sandbox_args: [sandboxed]"
      ;;
    absent)
      ;;
    unverifiable)
      sandbox_line="      sandbox_args: ['{unknown_sandbox_mode}']"
      ;;
    *)
      fail "unknown sandbox contract fixture: $sandbox_contract"
      ;;
  esac
  mkdir -p "$root/src" "$root/fixture-worker"
  printf '[package]\nname = "capability-fixture"\nversion = "0.1.0"\nedition = "2021"\n' >"$root/Cargo.toml"
  printf 'fn main() {}\n' >"$root/src/main.rs"
  cp "$SCRIPT_DIR/worker.sh" "$SCRIPT_DIR/planner-worker.sh" \
    "$SCRIPT_DIR/scout-worker.sh" "$root/fixture-worker/"
  chmod +x "$root/fixture-worker/"*.sh
  run_in "$root" init >/dev/null
  cat >"$root/.agents/workers.yaml" <<EOF
schema_version: 1
workers:
  - id: fixture-worker
    kind: cli_worker
    capabilities: [shell, image_generation]
    best_for: provider-free deterministic capability fixtures
    billing:
      mode: subscription_backed_only
    invocation:
      command: $root/fixture-worker/worker.sh
      supports_noninteractive: true
      output_contract: files
      args: ["{run_dir}", "--workspace-marker=$root"]
$sandbox_line
      full_access_args: [full]
    limits:
      max_wall_minutes: 1
      max_retries: 0
routing:
  default_worker: fixture-worker
  fallback_order: [fixture-worker]
  planning_gate:
    primary: fixture-worker
    fallback: ""
EOF
}

scout_count() {
  local root="$1"
  find "$root/.agents/runs" -path '*/scout-result.json' -type f 2>/dev/null | wc -l | tr -d ' '
}

active_digest() {
  local root="$1"
  (
    cd "$root"
    for path in .agents/intent-contract.yaml .agents/work-queue.yaml; do
      if [[ -f "$path" ]]; then
        shasum "$path"
      else
        printf 'absent  %s\n' "$path"
      fi
    done
  ) | shasum | awk '{print $1}'
}

record_count() {
  local root="$1"
  local pattern="$2"
  find "$root/.agents/planning-sessions" -path "$pattern" -type f 2>/dev/null | wc -l | tr -d ' '
}

show_json() {
  local root="$1"
  local output="$2"
  run_in "$root" planning show --json >"$output"
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

assert_audit() {
  local path="$1"
  local decision="$2"
  local hard="$3"
  local soft_count="$4"
  [[ "$(json_get "$path" capability_audits.0.tasks.0.trigger.decision)" == "$decision" ]] || \
    fail "unexpected decision in $path"
  [[ "$(json_len "$path" capability_audits.0.tasks.0.trigger.soft_signals)" == "$soft_count" ]] || \
    fail "unexpected soft signal count in $path"
  if [[ -n "$hard" ]]; then
    [[ "$(json_get "$path" capability_audits.0.tasks.0.trigger.hard_signals.0)" == "$hard" ]] || \
      fail "unexpected hard signal in $path"
    [[ "$(json_len "$path" capability_audits.0.tasks.0.trigger.hard_signals)" == "1" ]] || \
      fail "hard signal was not independent in $path"
  else
    [[ "$(json_len "$path" capability_audits.0.tasks.0.trigger.hard_signals)" == "0" ]] || \
      fail "unexpected hard signal in $path"
  fi
}

run_planning_case() {
  local name="$1"
  local request="$2"
  local decision="$3"
  local hard="$4"
  local soft_count="$5"
  local root
  root="$(mktemp -d "$EVIDENCE_DIR/$name.XXXXXX")"
  setup_workspace "$root"
  run_in "$root" new "$request" --worker fixture-worker >"$EVIDENCE_DIR/$name-new.out"
  show_json "$root" "$EVIDENCE_DIR/$name.json"
  assert_audit "$EVIDENCE_DIR/$name.json" "$decision" "$hard" "$soft_count"
}

case "$SCENARIO" in
  trigger_matrix)
    "$YARDLET_BIN" eval fixtures --json \
      --fixture capability-coverage-trigger-matrix \
      >"$EVIDENCE_DIR/core-trigger-matrix.json"
    [[ "$(json_get "$EVIDENCE_DIR/core-trigger-matrix.json" passed)" == "true" ]] || \
      fail "typed core trigger matrix failed"
    [[ "$(json_len "$FIXTURE_ROOT/data/trigger-matrix.json" hard_signals)" == "7" ]] || \
      fail "fixture data does not enumerate seven hard signals"

    run_planning_case explicit \
      "fixture:explicit_research_request 리서치" scout explicit_research_request 0
    run_planning_case missing-skill \
      "fixture:selected_skill_missing" scout selected_skill_missing 0
    run_planning_case missing-capability \
      "fixture:no_ready_worker_capability" scout no_ready_worker_capability 0
    run_planning_case current-fact \
      "fixture:current_external_fact_dependency latest" scout current_external_fact_dependency 0
    run_planning_case material-choice \
      "fixture:material_external_choice_dependency recommend" scout material_external_choice_dependency 0
    run_planning_case soft-zero \
      "fixture:soft_zero" no_scout "" 0
    # Fixture-only markers are inert without this explicit opt-in.
    run_planning_case soft-one-marker-off \
      "fixture:soft_one weak-context:" no_scout "" 0
    export YARDLET_TEST_PLANNING_SIGNAL_MARKERS=1
    run_planning_case soft-one \
      "fixture:soft_one weak-context:" observe "" 1
    run_planning_case soft-two \
      "fixture:soft_two weak-context: unfamiliar-domain:" scout "" 2
    unset YARDLET_TEST_PLANNING_SIGNAL_MARKERS
    write_summary "built-in core에서 hard 7종과 soft 0/1/2를 확인하고 실제 planning projection의 직접 입력 경로를 대조함"
    ;;

  scout_policy)
    root="$(mktemp -d "$EVIDENCE_DIR/scout-policy.XXXXXX")"
    setup_workspace "$root"
    before_active="$(active_digest "$root")"
    run_in "$root" new "fixture:scout_policy" --worker fixture-worker \
      >"$EVIDENCE_DIR/scout-policy-new.out"
    show_json "$root" "$EVIDENCE_DIR/scout-policy-first.json"
    first_packet="$(find "$root/.agents/runs"/scout-* -maxdepth 1 -name task-packet.md -print -quit 2>/dev/null)"
    [[ -n "$first_packet" ]] || fail "scout packet evidence missing"
    cp "$first_packet" "$EVIDENCE_DIR/scout-packet.md"
    [[ "$(grep -c '^- alpha capability topic$' "$first_packet")" == "1" ]] || \
      fail "normalized duplicate topic was not deduplicated"
    [[ "$(grep -c '^- .* capability topic$' "$first_packet")" == "3" ]] || \
      fail "scout topic budget was not exactly three"
    grep -q '^maximum research cycles: 1$' "$first_packet" || fail "cycle budget missing"
    grep -q '^maximum topics this cycle: 3$' "$first_packet" || fail "topic budget missing"
    grep -q '^required source order: workspace_skill_catalog -> user_skill_library -> external_primary_source$' \
      "$first_packet" || fail "source order missing"
    [[ "$(scout_count "$root")" == "1" ]] || fail "scout ran more than once"
    [[ "$(json_get "$EVIDENCE_DIR/scout-policy-first.json" capability_audits.0.max_cycles)" == "1" ]] || \
      fail "persisted cycle budget mismatch"
    [[ "$(json_get "$EVIDENCE_DIR/scout-policy-first.json" capability_audits.0.max_topics_per_cycle)" == "3" ]] || \
      fail "persisted topic budget mismatch"
    [[ "$(json_get "$EVIDENCE_DIR/scout-policy-first.json" capability_audits.0.tasks.0.disposition)" == "report_no_change" ]] || \
      fail "incomplete external authority did not fail closed"
    [[ "$(json_get "$EVIDENCE_DIR/scout-policy-first.json" capability_audits.0.tasks.0.scout_result.candidate)" == "none" ]] || \
      fail "failed-closed external candidate remained visible as adoptable"
    proposal="$(json_get "$EVIDENCE_DIR/scout-policy-first.json" pending_proposals.0.proposal_id)"
    run_in "$root" planning accept "$proposal" --expected-head none --action-id act-cache-accept \
      >"$EVIDENCE_DIR/cache-accept.out"
    head="$(json_get <(run_in "$root" planning show --json) session.current_head)"
    run_in "$root" planning answer "fixture:scout_policy" --expected-head "$head" \
      --action-id act-cache-answer --worker fixture-worker >"$EVIDENCE_DIR/cache-answer.out"
    show_json "$root" "$EVIDENCE_DIR/scout-policy-second.json"
    [[ "$(scout_count "$root")" == "1" ]] || fail "fresh cache duplicated scout"
    [[ "$(json_max_audit_cache_hits "$EVIDENCE_DIR/scout-policy-second.json")" == "3" ]] || \
      fail "second turn did not reuse all three unique bounded topics"
    [[ "$(record_count "$root" '*/proposals/*.yaml')" == "2" ]] || fail "proposal cardinality mismatch"
    [[ "$(active_digest "$root")" == "$before_active" ]] || fail "planning changed active state"
    "$YARDLET_BIN" eval fixtures --json --fixture bounded-capability-scout-contract \
      >"$EVIDENCE_DIR/core-scout-contract.json"
    [[ "$(json_get "$EVIDENCE_DIR/core-scout-contract.json" passed)" == "true" ]] || \
      fail "bounded scout mechanism fixture failed"
    write_summary "source order, 1 cycle/3 topics, normalized dedup, fresh cache, authority fail-closed, confirm 전 active-state 불변을 증명함"
    ;;

  restart_after_scout)
    root="$(mktemp -d "$EVIDENCE_DIR/restart-after-scout.XXXXXX")"
    setup_workspace "$root"
    run_in "$root" new "fixture:restart_after_scout" --worker fixture-worker \
      >"$EVIDENCE_DIR/restart-after-scout-new.out"
    show_json "$root" "$EVIDENCE_DIR/restart-after-scout-before.json"
    audit_digest="$(json_digest "$EVIDENCE_DIR/restart-after-scout-before.json" capability_audits)"
    initial_scout_count="$(scout_count "$root")"
    proposal_count="$(record_count "$root" '*/proposals/*.yaml')"
    "$SCRIPT_DIR/restart.sh" "$YARDLET_BIN" "$root" "$EVIDENCE_DIR/restart-after-scout-once.json"
    "$SCRIPT_DIR/restart.sh" "$YARDLET_BIN" "$root" "$EVIDENCE_DIR/restart-after-scout-twice.json"
    [[ "$(json_digest "$EVIDENCE_DIR/restart-after-scout-once.json" capability_audits)" == "$audit_digest" ]] || \
      fail "restart changed capability evidence"
    [[ "$(json_digest "$EVIDENCE_DIR/restart-after-scout-twice.json" capability_audits)" == "$audit_digest" ]] || \
      fail "second restart changed capability evidence"
    [[ "$(scout_count "$root")" == "$initial_scout_count" ]] || fail "restart duplicated scout"
    [[ "$(record_count "$root" '*/proposals/*.yaml')" == "$proposal_count" ]] || \
      fail "restart duplicated proposal"
    [[ "$(json_get "$EVIDENCE_DIR/restart-after-scout-twice.json" capability_audits.0.tasks.0.disposition)" == "record_tool_candidate" ]] || \
      fail "restart lost typed disposition"
    write_summary "scout 완료 후 두 fresh planning process가 evidence를 byte-stable하게 복구하고 scout/proposal cardinality를 보존함"
    ;;

  restart_before_confirm)
    root="$(mktemp -d "$EVIDENCE_DIR/restart-before-confirm.XXXXXX")"
    setup_workspace "$root"
    run_in "$root" new "fixture:restart_before_confirm recommend" --worker fixture-worker \
      >"$EVIDENCE_DIR/restart-before-confirm-new.out"
    show_json "$root" "$EVIDENCE_DIR/restart-before-confirm-proposal.json"
    proposal="$(json_get "$EVIDENCE_DIR/restart-before-confirm-proposal.json" pending_proposals.0.proposal_id)"
    run_in "$root" planning accept "$proposal" --expected-head none --action-id act-pending-accept \
      >"$EVIDENCE_DIR/restart-before-confirm-accept.out"
    show_json "$root" "$EVIDENCE_DIR/restart-before-confirm-before.json"
    head="$(json_get "$EVIDENCE_DIR/restart-before-confirm-before.json" session.current_head)"
    audit_digest="$(json_digest "$EVIDENCE_DIR/restart-before-confirm-before.json" capability_audits)"
    initial_scout_count="$(scout_count "$root")"
    proposal_count="$(record_count "$root" '*/proposals/*.yaml')"
    "$SCRIPT_DIR/restart.sh" "$YARDLET_BIN" "$root" "$EVIDENCE_DIR/restart-before-confirm-once.json"
    "$SCRIPT_DIR/restart.sh" "$YARDLET_BIN" "$root" "$EVIDENCE_DIR/restart-before-confirm-twice.json"
    [[ "$(json_get "$EVIDENCE_DIR/restart-before-confirm-twice.json" session.current_head)" == "$head" ]] || \
      fail "restart lost confirm-ready head"
    [[ "$(json_digest "$EVIDENCE_DIR/restart-before-confirm-twice.json" capability_audits)" == "$audit_digest" ]] || \
      fail "restart changed pending decision evidence"
    [[ "$(json_get "$EVIDENCE_DIR/restart-before-confirm-twice.json" capability_audits.0.tasks.0.pending_question)" == \
      "격리된 후보 A와 B 중 어느 쪽을 선택할까요?" ]] || fail "pending decision was not preserved"
    [[ "$(json_get "$EVIDENCE_DIR/restart-before-confirm-twice.json" capability_audits.0.tasks.0.disposition)" == "ask_user" ]] || \
      fail "pending decision lost ask_user disposition"
    [[ "$(scout_count "$root")" == "$initial_scout_count" ]] || fail "restart duplicated scout"
    [[ "$(record_count "$root" '*/proposals/*.yaml')" == "$proposal_count" ]] || \
      fail "restart duplicated proposal"
    write_summary "confirm 준비 head와 pending question/disposition이 두 fresh process에서 유지되고 중복 실행이 없음"
    ;;

  active_state_isolation)
    root="$(mktemp -d "$EVIDENCE_DIR/active-isolation.XXXXXX")"
    setup_workspace "$root"
    run_in "$root" goal "baseline covered goal" --plan-only >"$EVIDENCE_DIR/baseline-goal.out"
    before="$(active_digest "$root")"
    cp "$root/.agents/intent-contract.yaml" "$EVIDENCE_DIR/active-intent-before.yaml"
    cp "$root/.agents/work-queue.yaml" "$EVIDENCE_DIR/active-queue-before.yaml"
    run_in "$root" new "fixture:active_state_isolation 리서치" --worker fixture-worker \
      >"$EVIDENCE_DIR/active-isolation-new.out"
    after="$(active_digest "$root")"
    cp "$root/.agents/intent-contract.yaml" "$EVIDENCE_DIR/active-intent-after.yaml"
    cp "$root/.agents/work-queue.yaml" "$EVIDENCE_DIR/active-queue-after.yaml"
    printf 'before=%s\nafter=%s\n' "$before" "$after" >"$EVIDENCE_DIR/active-digests.txt"
    [[ "$before" == "$after" ]] || fail "queue-isolated scout mutated canonical active state"
    [[ "$(scout_count "$root")" == "1" ]] || fail "sandboxed malicious scout did not run exactly once"
    scout_log="$(find "$root/.agents/runs" -name worker-output.log -path '*/scout-*/*' -print -quit)"
    [[ -n "$scout_log" ]] || fail "sandboxed malicious scout log missing"
    grep -q 'malicious-write-attempted' "$scout_log" || fail "malicious write attempt was not exercised"
    ! grep -Fq "$root" "$scout_log" || fail "child received the live workspace path"

    closed_root="$(mktemp -d "$EVIDENCE_DIR/active-isolation-empty-contract.XXXXXX")"
    setup_workspace "$closed_root" absent
    run_in "$closed_root" goal "baseline covered goal" --plan-only >/dev/null
    closed_before="$(active_digest "$closed_root")"
    run_in "$closed_root" new "fixture:active_state_isolation 리서치" --worker fixture-worker \
      >"$EVIDENCE_DIR/active-isolation-empty-contract.out"
    [[ "$(active_digest "$closed_root")" == "$closed_before" ]] || \
      fail "empty sandbox contract changed active state"
    [[ "$(scout_count "$closed_root")" == "0" ]] || fail "empty sandbox contract spawned a scout"
    grep -q 'sandbox contract failed closed' "$EVIDENCE_DIR/active-isolation-empty-contract.out" || \
      fail "empty sandbox contract did not report fail-closed disposition"

    write_summary "adversarial scout는 live 경로 없이 disposable copy에서 1회 실행됐고 빈 generic sandbox 계약은 spawn 전에 fail closed함"
    ;;

  missing_capability_dogfood)
    root="$(mktemp -d "$EVIDENCE_DIR/missing-capability-dogfood.XXXXXX")"
    setup_workspace "$root"
    run_in "$root" worker status >"$EVIDENCE_DIR/worker-status.txt"
    grep -q 'fixture-worker \[invocable\]' "$EVIDENCE_DIR/worker-status.txt" || \
      fail "fixture worker did not pass real guard readiness"
    skills_before="$(find "$root/.agents/skills" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
    active_before="$(active_digest "$root")"
    run_in "$root" goal "dogfood nondeterministic capability" \
      --requires nondeterministic_entropy_probe --plan-only >"$EVIDENCE_DIR/dogfood-goal.out"
    show_json "$root" "$EVIDENCE_DIR/dogfood-before-restart.json"
    [[ "$(json_get "$EVIDENCE_DIR/dogfood-before-restart.json" capability_audits.0.tasks.0.coverage.status)" == "external-tool-needed" ]] || \
      fail "dogfood did not record external-tool-needed coverage"
    [[ "$(json_get "$EVIDENCE_DIR/dogfood-before-restart.json" capability_audits.0.tasks.0.coverage.reason_code)" == "no_ready_worker_capability" ]] || \
      fail "dogfood reason code mismatch"
    [[ "$(json_get "$EVIDENCE_DIR/dogfood-before-restart.json" capability_audits.0.tasks.0.trigger.hard_signals.0)" == "no_ready_worker_capability" ]] || \
      fail "dogfood trigger mismatch"
    [[ "$(json_get "$EVIDENCE_DIR/dogfood-before-restart.json" capability_audits.0.tasks.0.disposition)" == "record_tool_candidate" ]] || \
      fail "dogfood disposition mismatch"
    [[ "$(json_len "$EVIDENCE_DIR/dogfood-before-restart.json" capability_audits.0.tasks)" == "1" ]] || \
      fail "dogfood did not leave exactly one typed task disposition"
    [[ "$(active_digest "$root")" == "$active_before" ]] || fail "dogfood activated before confirm"
    [[ "$(scout_count "$root")" == "1" ]] || fail "dogfood scout count mismatch"
    "$SCRIPT_DIR/restart.sh" "$YARDLET_BIN" "$root" "$EVIDENCE_DIR/dogfood-after-restart.json"
    [[ "$(scout_count "$root")" == "1" ]] || fail "dogfood restart duplicated scout"
    head="$(json_get "$EVIDENCE_DIR/dogfood-after-restart.json" session.current_head)"
    pre_confirm="$(active_digest "$root")"
    run_in "$root" planning confirm --expected-head "$head" --action-id act-dogfood-confirm \
      >"$EVIDENCE_DIR/dogfood-confirm.out"
    show_json "$root" "$EVIDENCE_DIR/dogfood-after-confirm.json"
    post_confirm="$(active_digest "$root")"
    printf 'before_goal=%s\npre_confirm=%s\npost_confirm=%s\n' \
      "$active_before" "$pre_confirm" "$post_confirm" >"$EVIDENCE_DIR/dogfood-active-digests.txt"
    [[ "$pre_confirm" == "$active_before" ]] || fail "restart changed active digest"
    [[ "$post_confirm" != "$pre_confirm" ]] || fail "explicit confirm did not materialize active state"
    [[ "$(json_get "$EVIDENCE_DIR/dogfood-after-confirm.json" exact_active_parity)" == "true" ]] || \
      fail "dogfood confirm lost exact active parity"
    skills_after="$(find "$root/.agents/skills" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
    [[ "$skills_before" == "$skills_after" ]] || fail "dogfood installed or changed a skill"
    [[ ! -d "$root/node_modules" && ! -d "$root/target" && ! -d "$root/.git" ]] || \
      fail "dogfood performed an unexpected install or repository mutation"
    write_summary "guard-ready worker가 선언하지 않은 nondeterministic_entropy_probe를 실제 goal 경로에서 scout 1회, record_tool_candidate 1개, explicit confirm으로 재현함"
    ;;

  *)
    fail "unknown scenario: $SCENARIO"
    ;;
esac
