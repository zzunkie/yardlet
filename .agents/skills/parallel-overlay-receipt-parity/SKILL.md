---
name: parallel-overlay-receipt-parity
description: parallel-overlay-receipt-parity
source: learned
---
parallel 경로의 #32 계열(overlay provenance) 검증 절차: (1) tracked harness 파일을 커밋 후 owning root에서 dirty로 만들고 run_batch process fixture를 직접 호출한다(git_preflight는 auto 경로에만 있음). (2) worker script와 task validation 양쪽에 같은 grep -Fxq를 넣어 'worker가 본 bytes = validation이 읽는 bytes'를 한 번에 고정한다. (3) parity gate 검증은 validation 명령 뒤에 owning root 파일을 덮어쓰는 tamper를 붙이고, validation.json all_passed=true를 먼저 단언해 validation 실패와 gate 차단을 구분한다. (4) receipt는 checkpoints/parallel-integration/<run-id>.yaml에서 읽고, serial store(serial-integration)가 비어 있음을 함께 단언한다(recovery 분류가 serial receipt None에 의존).
