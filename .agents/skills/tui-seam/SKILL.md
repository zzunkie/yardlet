---
name: tui-seam
description: TUI 첫-프레임 타이밍 리뷰: 마커 정직성 + 지연 seam 재현
source: learned
---
TUI startup 타이밍을 독립 검토할 때: (1) PTY fixture 의 first-frame 마커 문자열을 `grep -rn` 해 렌더 소스(src/ui/i18n.rs)와 테스트에만 존재하고 별도 println 유출이 없는지 확인해 '첫 raw 바이트'가 아닌 '안전 콘텐츠 프레임'을 재는지 검증한다. (2) `run()` 에서 첫 terminal.draw 가 recovery/Snapshot::load(worker --version probe)/supports_keyboard_enhancement 보다 앞인지 확인하고, pre-fix 커밋으로 어느 동기 경계가 막았는지 git 대조한다. (3) `YARDLET_FIXTURE_RECOVERY_DELAY_MS`(debug 전용) + 느린 --version worker 로 fixture 를 fresh 재실행해 first_safe_frame_ms 를 직접 재측정한다. (4) 로딩 중 canonical 키가 게이트되는지 sentinel(예: worker-invoked)로 실증한다.
