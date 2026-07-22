---
name: provider-refusal-fixture
description: provider-refusal fixture 수동 재현 절차
source: learned
---
provider refusal 경로를 손으로 재검증할 때: scratchpad에 git init + yardlet init 후 tests/fixtures/provider_response_refusal/worker.sh를 복사하고 .agents/workers.yaml의 provider_response_refusal_patterns에 'provider declined response'를 설정, args로 시나리오(success/exhausted/unclassified)를 넘겨 `yardlet run --task YARD-001 --execute`를 실행한다. 검증 지점: run.yaml의 output_contract_incident(cause/recovery_consumed/terminal_attempt_id), task-channels/*/attempts 수와 worker_id, packet-attempt-2.txt의 'result.json first'/'Do not repeat', failover.json 유무. 쉘 cwd가 이전 명령에서 이동해 있을 수 있으니 yardlet 바이너리는 반드시 worktree 절대 경로로 지정한다.
