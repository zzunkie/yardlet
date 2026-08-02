---
name: readiness-1-1
description: readiness 계약 리뷰 시 여섯 공급자 1:1 대조
source: learned
---
제네릭/내장 워커 실행 가능 판정을 리뷰할 때는 표시 문자열이 아니라 여섯 소비처가 모두 guard::probe/guard::invocation_contract의 같은 결과를 쓰는지 확인한다: (1) cli.rs worker status(probe+stages/verdict), (2) snapshot.rs TUI(probe→readiness.label + readiness_cache_key 캐시 무효화), (3) routing.rs resolve_order(probe().readiness==Ready), (4) planner.rs pick_ready_worker(동일), (5) guard.rs capability_readiness_projection + routing.rs ready_capabilities_from_projection(==Ready 필터), (6) workers/mod.rs spawn_internal의 invocation_contract 재확인. `grep -n 'probe(\|Readiness::Ready\|invocation_contract'`로 도달성을 판정하라.
