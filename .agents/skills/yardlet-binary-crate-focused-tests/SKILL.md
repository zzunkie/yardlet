---
name: yardlet-binary-crate-focused-tests
description: yardlet-binary-crate-focused-tests
source: learned
---
yardlet은 lib 타깃이 없는 binary crate다. 모듈 내 #[cfg(test)] 유닛 테스트를 좁혀 실행할 땐 `cargo test --bin yardlet <필터>`를 쓴다 — `cargo test --lib`는 'no library targets found'로 실패한다. 전체 스위트는 그냥 `cargo test`.
