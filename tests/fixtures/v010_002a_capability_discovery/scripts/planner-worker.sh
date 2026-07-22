#!/usr/bin/env bash
set -euo pipefail

run_dir="${1:?planner fixture requires run directory}"
packet="$(cat)"
mkdir -p "$run_dir"

scenario="base"
for candidate in \
  explicit_research_request selected_skill_missing no_ready_worker_capability \
  only_unusable_skill_matches repeated_typed_failure \
  current_external_fact_dependency material_external_choice_dependency \
  soft_zero soft_one soft_two scout_policy restart_after_scout \
  restart_before_confirm active_state_isolation; do
  if grep -q "fixture:$candidate" <<<"$packet"; then
    scenario="$candidate"
    break
  fi
done

skills='[]'
capabilities='[]'
questions='[]'
tasks=''
case "$scenario" in
  selected_skill_missing)
    skills='["fixture-skill-that-is-not-installed"]'
    ;;
  only_unusable_skill_matches)
    skills='["fixture-unusable-skill"]'
    ;;
  no_ready_worker_capability|restart_after_scout|active_state_isolation)
    capabilities='["nondeterministic_entropy_probe"]'
    ;;
  restart_before_confirm)
    capabilities='["nondeterministic_entropy_probe"]'
    questions='["격리된 후보 A와 B 중 어느 쪽을 선택할까요?"]'
    ;;
  scout_policy)
    tasks=$(cat <<'JSON'
    {
      "id": "YARD-001",
      "title": "alpha capability topic",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "required_capabilities": ["missing_alpha"],
      "allowed_scope": ["src"],
      "acceptance": ["alpha"],
      "worker_rationale": "fixture"
    },
    {
      "id": "YARD-002",
      "title": " alpha   capability topic ",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "required_capabilities": ["missing_alpha"],
      "allowed_scope": ["src"],
      "acceptance": ["alpha duplicate"],
      "worker_rationale": "fixture"
    },
    {
      "id": "YARD-003",
      "title": "beta capability topic",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "required_capabilities": ["missing_beta"],
      "allowed_scope": ["src"],
      "acceptance": ["beta"],
      "worker_rationale": "fixture"
    },
    {
      "id": "YARD-004",
      "title": "gamma capability topic",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "required_capabilities": ["missing_gamma"],
      "allowed_scope": ["src"],
      "acceptance": ["gamma"],
      "worker_rationale": "fixture"
    }
JSON
)
    ;;
esac

if [[ -z "$tasks" ]]; then
  tasks=$(cat <<JSON
    {
      "id": "YARD-001",
      "title": "$scenario capability task",
      "kind": "implementation",
      "risk": "low",
      "preferred_worker": "fixture-worker",
      "skills": $skills,
      "required_capabilities": $capabilities,
      "allowed_scope": ["src"],
      "acceptance": ["typed capability evidence is visible"],
      "worker_rationale": "provider-free capability fixture"
    }
JSON
)
fi

cat >"$run_dir/planning-result.json" <<JSON
{
  "summary": "$scenario provider-free capability plan",
  "rationale": "deterministic V010-002A fixture",
  "allowed_scope": ["src"],
  "out_of_scope": ["external mutation"],
  "acceptance": [{"id": "AC-001", "statement": "typed capability evidence is visible"}],
  "ambiguity": {"score": "low", "open_questions": []},
  "tasks": [$tasks],
  "questions_for_user": $questions
}
JSON
printf 'planned fixture scenario %s\n' "$scenario"
