---
name: generic-fixture-attempt-env-scrub-last-secret
description: generic fixture 워커의 attempt별 env-scrub 단언은 last-secret 사본으로
source: learned
---
tests/generic_worker_contract_process.rs의 fake worker.sh는 매 호출 상단에서 $capture/last-secret에 present/absent를 기록한다. 특정 분기(probe/resume/fresh)의 청구-비밀 세정을 단언하려면 그 분기 안에서 `cp "$capture/last-secret" "$capture/<branch>-secret"`로 복사한 뒤 테스트에서 `<branch>-secret == "absent"`를 단언하라. 값이 근거 있는지는 build_generic_* 커맨드의 cmd.env_clear() + 공통 env 맵 적용(src/workers/mod.rs)이 보장한다. 단언만 먼저 넣어 파일-부재 RED로 비공허성을 확인한 뒤 캡처를 추가할 것.
