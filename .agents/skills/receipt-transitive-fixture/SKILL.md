---
name: receipt-transitive-fixture
description: receipt 기반 이행 의존(transitive) 결함 재현 fixture
source: learned
---
A→B→C 이행 의존 시나리오를 재현할 때는 worker 실행 없이 state 레이어에서 조립한다: (1) 각 upstream run에 run.yaml(task_id·intent_id 일치) + dependency-outputs manifest + snapshots/0000.bin을 쓰고, (2) 중간 태스크 B의 run_id로 save_serial_integration_receipt에 dependency_input_overlays(upstream task_id, path, digest)를 기록한 뒤, (3) materialize_resolved_dependency_outputs를 downstream 태스크로 호출한다. 선언 여부는 task.depends_on만 바꿔 토글한다. src/state.rs tests의 transitive_dependency_chain_fixture 참조.
