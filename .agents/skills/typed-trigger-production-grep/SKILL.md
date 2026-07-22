---
name: typed-trigger-production-grep
description: typed trigger 신호는 production 공급자 grep으로 도달성 판정
source: learned
---
typed signal core(예: CapabilityDiscoverySignals)를 리뷰할 때 core 단위 테스트의 N/N 통과만 믿지 말고, 각 신호 필드의 setter를 `grep -rn '<field>\s*=' src/`로 찾아 테스트/fixture 외 production 코드 공급자가 존재하는지 확인하라. 공급자가 없는 신호는 문서의 'N종 지원' 주장과 달리 end-to-end로 도달 불가이며, 이는 별도 finding으로 기록한다.
