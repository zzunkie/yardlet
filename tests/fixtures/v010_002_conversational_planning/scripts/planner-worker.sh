#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'fixture-planner 1.0\n'
  exit 0
fi

run_dir="$1"
packet="$(cat)"
workspace="$(pwd)"
if grep -Eq 'Yardlet task packet|You are a hidden Yardlet worker' <<<"$packet"; then
  if grep -q 'first runtime task fails' <<<"$packet"; then
    mkdir -p "$run_dir"
    cat >"$run_dir/result.json" <<'EOF'
{
  "schema_version": 1,
  "run_id": "fixture-runtime-failure",
  "task_id": "YARD-001",
  "status": "failed",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": false, "failures": ["deterministic fixture failure"]},
  "question_for_user": null,
  "compact_summary": "첫 task의 결정적 runtime failure",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
    exit 0
  fi
  barrier="${YARDLET_TEST_MUTATION_BARRIER:?runtime fixture requires mutation barrier}"
  touch "$barrier/worker-entered"
  while [[ ! -f "$barrier/worker-release" ]]; do
    sleep 0.02
  done
  mkdir -p "$run_dir"
  cat >"$run_dir/result.json" <<'EOF'
{
  "schema_version": 1,
  "run_id": "fixture-runtime",
  "task_id": "YARD-001",
  "status": "partial",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "runtime queue race fixture",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
  exit 0
fi
counter="$workspace/.fixture-planning-turn"
turn=0
[[ -f "$counter" ]] && turn="$(cat "$counter")"
turn=$((turn + 1))
printf '%s' "$turn" >"$counter"

case "$turn" in
  1)
    summary="초기 deterministic slice"
    scope="src/planning.rs"
    excluded="src/ui/**"
    acceptance="초기 proposal이 visible draft가 된다"
    title="planning core 구현"
    ;;
  2)
    summary="scope correction이 반영된 deterministic slice"
    scope="src/planning.rs와 src/state.rs"
    excluded="src/ui/**와 provider API"
    acceptance="scope correction이 semantic diff에 보인다"
    title="planning core와 state writer 구현"
    ;;
  3)
    summary="거절할 acceptance correction"
    scope="src/planning.rs와 src/state.rs"
    excluded="src/ui/**와 provider API"
    acceptance="이 proposal은 거절되어 head를 바꾸지 않는다"
    title="거절 대상 proposal"
    ;;
  *)
    summary="최종 acceptance correction"
    scope="src/planning.rs와 src/state.rs"
    excluded="src/ui/**와 provider API"
    acceptance="visible draft와 active intent 및 queue가 정확히 일치한다"
    title="exact promotion을 검증한다"
    ;;
esac

second_task=""
first_goal=""
if [[ -f "$workspace/.fixture-two-task" ]]; then
  title="first runtime task fails"
  first_goal=',
    "goal": {
      "condition": "첫 runtime task는 결정적으로 실패한다",
      "max_feedback_cycles": 0,
      "feedback_policy": "inject_failed_checks"
    }'
  second_task=', {
    "id": "YARD-002",
    "title": "second runtime task remains runnable",
    "kind": "implementation",
    "risk": "low",
    "preferred_worker": "fixture-planner",
    "model": "auto",
    "effort": "auto",
    "depends_on": [],
    "skills": [],
    "required_capabilities": [],
    "allowed_scope": ["src/state.rs"],
    "acceptance": ["첫 task 실패 후 fresh process에서 runnable하다"],
    "worker_rationale": "deterministic fixture"
  }'
fi

mkdir -p "$run_dir"
cat >"$run_dir/planning-result.json" <<EOF
{
  "summary": "$summary",
  "rationale": "deterministic fixture turn $turn rationale",
  "allowed_scope": ["$scope"],
  "out_of_scope": ["$excluded"],
  "acceptance": [{"id": "AC-001", "statement": "$acceptance"}],
  "ambiguity": {"score": "low", "open_questions": []},
  "tasks": [{
    "id": "YARD-001",
    "title": "$title",
    "kind": "implementation",
    "risk": "low",
    "preferred_worker": "fixture-planner",
    "model": "auto",
    "effort": "auto",
    "depends_on": [],
    "skills": [],
    "required_capabilities": [],
    "allowed_scope": ["$scope"],
    "acceptance": ["$acceptance"]$first_goal,
    "worker_rationale": "deterministic fixture"
  }$second_task],
  "questions_for_user": []
}
EOF
if [[ -n "${YARDLET_TEST_PLANNER_RESULT_BARRIER:-}" ]]; then
  mkdir -p "$YARDLET_TEST_PLANNER_RESULT_BARRIER"
  touch "$YARDLET_TEST_PLANNER_RESULT_BARRIER/result-ready"
  while [[ ! -f "$YARDLET_TEST_PLANNER_RESULT_BARRIER/release" ]]; do
    sleep 0.02
  done
fi
printf 'fixture planning turn %s\n' "$turn"
printf '%s\n' "$packet" >"$run_dir/fixture-packet.md"
