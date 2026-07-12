---
name: builtin-bundle-reverify-cli-fixture-leg
description: builtin-bundle-reverify에 CLI fixture leg 절차 추가
source: learned
---
기존 builtin-bundle-reverify 절차(blob 대조, normalized sha1 증명, 금지 표면 grep, rsync dogfood)에 다음 CLI leg를 추가: /tmp fixture에서 (1) 빈 repo yardlet init 후 core 5종+marker 확인과 overlay 미설치 확인, (2) 재실행 후 skills 트리 shasum 동일성, (3) 동명 사용자 skill 선배치 후 no-clobber, (4) 최소 work-queue.yaml(2 task, 한쪽만 overlay skills)을 만들어 yardlet packet --dry-run으로 overlay가 해당 task packet에만 노출되는지 확인.
