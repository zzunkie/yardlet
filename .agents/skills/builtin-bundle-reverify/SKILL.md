---
name: builtin-bundle-reverify
description: builtin-bundle-reverify
source: learned
---
Managed built-in bundle을 network 없이 독립 재검증하는 절차: (1) `git hash-object <bundle file>`를 manifest.yaml의 upstream_blob과 대조 - exact는 일치해야 하고 adapted는 달라야 정상. (2) normalized 주장은 파일 내용의 최종 newline 제거 변형에 대해 sha1('blob {len}\0'+content)를 계산해 upstream blob과 일치하는지로 증명. (3) 금지 표면은 테스트에 의존하지 말고 push/PR·외부 URL·subagent·keychain/codesign·webfetch/api-key를 직접 grep. (4) 분류 검증은 실제 repo를 node_modules/.git 제외 rsync로 /tmp에 복사해 dogfood하고, 오분류 시 walk_signals(depth 4, 400-entry 상한, .agents/.git/target/node_modules 제외, 정렬 depth-first)를 python으로 재현해 관찰 누락을 정량화한다.
