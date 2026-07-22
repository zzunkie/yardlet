---
name: superseded-task-closure
description: superseded-task closure 검증법
source: learned
---
사용자가 '목표가 다른 태스크로 대체 구현됐으니 done으로 기록만 하라'고 지시하면, 기록 전에 현 워크트리에서 읽기 전용 3단계로 실증한다: (1) git log --oneline -- <대상 파일>로 대체 커밋이 현 브랜치 히스토리에 있는지, (2) grep으로 구 결함 패턴(예: 구 단언 문자열)이 소멸했는지, (3) 대체 구현의 핵심 상수/단언을 sed로 읽어 acceptance 각 항목에 매핑되는지 확인한 뒤 그 라인 번호를 verdict evidence로 남긴다. 테스트 재실행은 하지 않는다(중복 구현/검증 금지 지시 준수).
