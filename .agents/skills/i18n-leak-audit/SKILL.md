---
name: i18n-leak-audit
description: i18n-leak-audit
source: learned
---
yardlet에서 한국어 화면 영어 누수를 감사할 때: (1) `grep -rn '"running"\|"done"\|"failed"\|"blocked"\|"partial"\|"deferred"\|"queued"\|"needs' src/ui/`로 하드코딩 상태 리터럴을, (2) `grep -rn '{:?}' src/ui src/compact.rs src/run.rs`로 Debug enum 누수를 찾는다. (3) src/ui/i18n.rs의 L 테이블 상태 라벨 필드 수를 TaskState 8개 variant와 대조해 필드 부재를 확인한다. 정적 chrome은 번역돼도 dynamic 상태 콘텐츠가 로컬라이즈 계층을 바이패스하는 게 전형 패턴이다.
