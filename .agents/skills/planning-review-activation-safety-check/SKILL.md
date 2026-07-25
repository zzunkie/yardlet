---
name: planning-review-activation-safety-check
description: planning-review-activation-safety-check
source: learned
---
TUI 플랜 검토/확정 리뷰 시 안전성 근원은 코어 crate::planning::confirm의 expected_head_matches + 정확 revision 로드 + validate_active_activation임을 먼저 확인하고, TUI가 이를 우회하지 않는지 grep으로 검증한다: (1) src/ui/*.rs에 직접 canonical write(save_activated_*/save_intent) 없음, (2) accept/reject/confirm/revision이 crate::planning::* 코어만 호출. 그다음 격리 테스트 isolated_review_accepts_then_confirms_only_the_displayed_head / _surfaces_stale_head / _rejects 를 cargo test --bin yardlet planning_review 로 fresh 재실행해 active 불변·exact head·stale/duplicate/reject를 코드 대신 런타임으로 재확인한다.
