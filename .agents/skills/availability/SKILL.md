---
name: availability
description: availability 표시 게이트는 실행 의미 공급자와 교차 대조
source: learned
---
TUI 키 힌트의 availability 게이트를 리뷰할 때는 diff만 보지 말고 각 키의 실행 의미를 정의하는 공급자 함수(defer_task, Workspace::tidy, Monitor fallback, handoff 로더, trust 리포트 소스)를 직접 열어 게이트 조건과 1:1 대조한다. 근사값(예: approvals_needed 역참조)은 해당 상태 부분집합에서 원본 판정(is_granted)과 동치인지 필터 정의로 증명한다.
