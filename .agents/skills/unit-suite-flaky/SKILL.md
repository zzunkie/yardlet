---
name: unit-suite-flaky
description: unit-suite 부하 flaky 재현 하니스
source: learned
---
유닛 테스트 부하 flaky를 재현/검증할 때: (1) cargo test --bin yardlet --no-run으로 바이너리 경로 확보. (2) 코어수 2-3배의 `yes > /dev/null` burner와 8-10개의 `while :; do /bin/sh -c ':'; done` fork storm을 백그라운드로 띄운다(spawn 지연이 실제 메커니즘이므로 fork storm 필수). (3) 전체 스위트를 프리빌드 바이너리로 직접 반복 실행하고, 필요하면 --test-threads를 코어수 이상으로 올리고 스위트 2벌을 동시 실행한다. 대상 테스트만 돌리면 스위트 내부 경합이 빠져 재현이 잘 안 된다. (4) 재현 실패 시 테스트의 고정 초 단위 데드라인(spawn 상한, hook 상한)을 감사해 완화한다. 검증은 수정 바이너리로 같은 하니스를 재실행. 주의: 하니스 실행 중 cargo 재빌드 금지(실행 중 바이너리를 덮어씀).
