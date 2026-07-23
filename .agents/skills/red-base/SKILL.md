---
name: red-base
description: RED 이식 시 base에 없는 심볼 처리
source: learned
---
tip 테스트가 base revision에 없는 production 심볼(신규 struct/fn/receipt 필드)을 참조하면, 해당 assertion만 제외하고 이식하되 구현자 handoff에 기록된 RED assertion(예: left: Bool(false))을 선두로 재배치해 실패 메시지를 기록과 1:1 대조하라. 제외한 assertion은 tip GREEN 실행으로만 검증됨을 report에 명시하라.
