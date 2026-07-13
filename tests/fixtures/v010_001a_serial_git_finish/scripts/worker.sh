#!/usr/bin/env bash
set -euo pipefail

run_dir="$1"
task_id="$2"
role="$3"
attempts_dir="$4"
packets_dir="$5"
sterile_home="$6"

[[ "$HOME" == "$sterile_home" ]]
[[ "${XDG_CONFIG_HOME:-}" == "$sterile_home/.config" ]]
[[ "${GIT_CONFIG_GLOBAL:-}" == "$sterile_home/global.gitconfig" ]]
[[ "${GIT_CONFIG_SYSTEM:-}" == "$sterile_home/system.gitconfig" ]]
[[ "${GIT_CONFIG_NOSYSTEM:-}" == "1" ]]
[[ -f "$sterile_home/global.gitconfig" && ! -s "$sterile_home/global.gitconfig" ]]
[[ -f "$sterile_home/system.gitconfig" && ! -s "$sterile_home/system.gitconfig" ]]
[[ ! -e "$sterile_home/.gitconfig" ]]
[[ ! -e "$sterile_home/.config/git/config" ]]
[[ -z "${GIT_CONFIG:-}" ]]
[[ -z "${GIT_CONFIG_COUNT:-}" ]]
[[ -z "${GIT_CONFIG_PARAMETERS:-}" ]]

mkdir -p "$attempts_dir" "$packets_dir" "$run_dir"
counter="$attempts_dir/$task_id"
attempt=0
[[ -f "$counter" ]] && attempt="$(cat "$counter")"
attempt=$((attempt + 1))
printf '%s' "$attempt" >"$counter"
cat >"$packets_dir/${task_id}-${attempt}.md"

run_id="$(basename "$run_dir")"
status="done"
verdict_pass="true"
follow_up_tasks="[]"
case "$role" in
  builder)
    printf 'builder\n' > builder.txt
    summary="builder completed"
    ;;
  reviewer)
    if [[ "$attempt" -eq 1 ]]; then
      printf 'failed-check\n' > reviewer-failed-check.txt
      summary="reviewer exposed one failed check"
      status="partial"
      verdict_pass="false"
      follow_up_tasks='[{"title":"apply fixture reviewer remediation","reason":"reviewer failed check를 정확히 한 번 수정한다","kind":"implementation","risk":"low","acceptance":["review.txt가 remediated 상태다"],"allowed_scope":["review.txt"],"depends_on":[],"preferred_worker":"remediator","required_capabilities":[],"decision_question":"","insert":"next","runs_before":[]}]'
    else
      [[ "$(cat review.txt)" == "remediated" ]]
      printf 'review-pass\n' > reviewer-pass.txt
      summary="reviewer remediation passed"
    fi
    ;;
  remediator)
    printf 'remediated\n' > review.txt
    summary="reviewer failed check remediated once"
    ;;
  rereviewer)
    [[ "$(cat review.txt)" == "remediated" ]]
    printf 'independent-pass\n' > rereview.txt
    summary="independent re-review passed"
    ;;
  *)
    exit 65
    ;;
esac

cat >"$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "$status",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "question_for_user": null,
  "compact_summary": "$summary",
  "verdict": [{"criterion_id": "AC-001", "pass": $verdict_pass, "evidence": "$role attempt $attempt"}],
  "harness_suggestions": [],
  "follow_up_tasks": $follow_up_tasks
}
EOF
printf '# Fixture handoff\n\n%s\n' "$summary" >"$run_dir/handoff.md"
