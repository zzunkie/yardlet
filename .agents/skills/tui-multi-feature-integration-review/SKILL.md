---
name: tui-multi-feature-integration-review
description: tui-multi-feature-integration-review
source: learned
---
여러 독립 TUI 슬라이스의 최종 통합 리뷰는 각 seam을 명명 테스트로 fresh 재실행해 앵커 증거를 만들고(예: tui_startup_process first_safe_frame_ms, tui_i18n_leak, planning_review, text_input), 합성은 main_loop 디스패치 경계 4점(시작 게이트→화면 디스패치→현지화 렌더→공유 입력 매핑)을 코드로 따라가 충돌 부재를 확인하라. cargo test는 --quiet가 이름을 숨기므로 AC별 앵커는 대상 지정 재실행으로 명명 증거를 남긴다.
