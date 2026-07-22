---
name: run-typed-failure
description: 실제 run으로 typed-failure 기록을 만들 때의 종결 상태 기대치
source: learned
---
실제 `yardlet run --task <id> --execute` 실패로 typed_run_failure_projection이 세는 run 기록(run.yaml state failed|partial + completed_at + evaluation.json fatal failed check)을 만들려면 goal feedback cap(max_feedback_cycles, 기본 2) 이내에서 실패를 반복하라. cap 이내 실패는 run을 state=partial로 봉인하고 태스크를 Partial(terminal)로 남긴다. cap을 초과하거나 max_feedback_cycles를 0으로 두면 feedback question이 붙어 태스크와 run이 needs_user로 파킹되어 projection에 잡히지 않는다. fixture 단언은 task state=failed가 아니라 partial을 기대해야 한다. 표준 예시: tests/fixtures/same_intent_replan/scripts/run.sh.
