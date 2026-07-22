---
name: same-session-two-turn-planning-fixture-run-histo
description: same-session two-turn planning fixture로 run-history 신호 검증
source: learned
---
planning 신호가 run 기록 projection에서 공급되는지 실제 바이너리로 검증할 때: (1) `yardlet new`로 turn 1을 만들고 `planning show --json`의 session.intent_id를 읽는다. (2) 그 intent_id로 봉인된 run 기록(run.yaml의 state failed/partial + completed_at, evaluation.json의 fatal failed check)을 temp workspace의 .agents/runs/에 seed한다. (3) `planning accept <proposal> --expected-head none` 후 `planning answer ... --expected-head <head>`로 같은 session의 turn 2를 돌리고, 두 번째 show --json의 capability_audits 전체에서 해당 hard signal 총수를 센다(turn 1은 0이어야 함). tests/fixtures/v010_002a_capability_discovery/scripts/run.sh의 repeated-failure 블록이 표준 예시다.
