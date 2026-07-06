---
name: tui
description: TUI 키 동작의 분기 로직은 순수 함수로 분리해 테스트
source: learned
---
Home Enter 처럼 상태에 따라 행동이 갈리는 키는 (state, 게이트 플래그, busy) -> Action enum 을 반환하는 순수 함수로 결정 로직을 뽑는다. handle_* 는 그 Action 을 실행만 한다. 워커/터미널 없이 매핑을 단위 테스트할 수 있고, 승인 같은 불변식(승인 대기는 절대 Run 아님)을 테스트로 못박을 수 있다. 실행형 액션은 app.is_busy() 게이트를 넣고, 승인 검사를 busy 보다 먼저 둔다. 실제 실행은 run::run_next 의 게이트가 최종 강제하므로 UI 는 안내 우선.
