---
name: process-fixture-summary-json
description: process fixture summary.json 증거 확보
source: learned
---
보호 브랜치 process fixture의 summary.json을 durable 증거로 남기려면 scripts/run.sh <yardlet-bin> <evidence-dir>를 절대 경로 evidence-dir로 직접 재실행하라. 상대 경로는 subshell cd 때문에 workspace 파일 생성이 깨진다. 내부 cargo 테스트는 성공 시 summary를 삭제하므로, 리뷰에서 계수(public_remote_commands, protected_head_pushes 등)를 인용하려면 별도 재실행이 유일한 방법이다.
