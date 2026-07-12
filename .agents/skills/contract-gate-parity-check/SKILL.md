---
name: contract-gate-parity-check
description: contract-gate-parity-check
source: learned
---
계약 문서가 runnable/승인/안전 판정 조건 목록을 명시하면, fixture나 구현의 판정 predicate를 조건 단위로 1:1 대조하라. 각 조건의 좌변 필드명을 grep해 predicate 코드에서 실제로 읽히는지 확인하고, 읽히지 않는 필드는 변조 반례(기대: 판정 거부)로 재현 절차를 남겨라. digest가 저장 문자열인 fixture에서는 digest 검사가 linkage 변조를 잡지 못하므로 id 등가 조건을 생략하면 안 된다.
