---
name: failover-process-fixture-worker-model
description: failover process fixture worker에는 model을 지정하라
source: learned
---
cross-worker failover를 거치는 process fixture를 만들 때 workers.yaml의 모든 fixture worker에 동일한 model: 값을 명시하라. model이 없으면 failover selection이 governing_model이 빈 routing_provenance를 task에 stamping해 이후 resolve가 'incomplete governing routing provenance'로 hard-error한다. (과거의 두 번째 함정이던 'worker X conflicts with governing worker Y' lineage dead-end는 수정됨: apply_selection_to_task가 이제 런타임 attempt 대신 governing 계약을 stamp하므로, failover 후 non-terminal task의 드레인 재시도는 정상 재resolve된다. 이제 auto 드레인의 exit code도 단언할 수 있다.) 참고: tests/v010_003_task_channels_process.rs의 parallel_failover_drain_retry_re_resolves_governing_lineage, parallel_failover_rejects_tampered_worktree_receipt_before_spawn.
