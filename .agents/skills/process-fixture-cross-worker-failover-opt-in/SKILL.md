---
name: process-fixture-cross-worker-failover-opt-in
description: process fixture의 cross-worker failover는 opt-in 명시 필요
source: learned
---
cross-worker failover/continuation을 검증하는 process fixture를 만들 때 workers.yaml fixture에 routing.allow_preferred_worker_failover: true를 명시하라. preferred_worker가 지정된 task는 default fail-closed라서 opt-in 없이는 fallback 자체가 오류로 끝난다 (tests/v010_003_task_channels_process.rs:1190 참고).
