---
name: v09-audit-evidence-map
description: v09-audit-evidence-map
source: learned
---
v0.9 메커니즘을 다시 감사할 때 line number보다 심볼을 기준으로 찾는다. goal 계약은 `schemas::TaskGoal`, 실패 원장과 상태 결정은 `run::feedback_for_run` / `feedback_next_state`, scout와 명시 적용은 `memory::scout` / `apply_scout`, heartbeat는 `watch::run`, 결정론적 fixture는 `eval_fixtures::run`, H4 채굴은 `trust::mine`과 `cli::cmd_harness`가 기준이다. 최종 처분과 보류 조건은 `docs/v0.9-mechanism-absorption.md`, 정의 원문은 `~/Downloads/yardlet-v0.9-v1-final-roadmap.md` section 10과 `.agents/memory/v09-merged-roadmap.md`를 대조한다.
