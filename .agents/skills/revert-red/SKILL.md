---
name: revert-red
description: 단일 파일 원위치 revert 로 RED 재검증
source: learned
---
fix 와 fixture 가 한 커밋에 있고 수정이 소스 파일 하나에 한정될 때: 먼저 `git diff <fix> HEAD -- <file>` 이 비어 있음을 확인한 뒤 `git checkout <fix>^ -- <file>` 로 그 파일만 되돌리고 재빌드해 HEAD 의 fixture 를 실행하면 worktree 이식 없이 RED 를 재현할 수 있다. 기대 실패 문자열까지 대조하고, `git checkout HEAD -- <file>` 원복 + 재빌드 + 동일 fixture GREEN 과 `git status` 청결까지 확인해야 종료다. 조건이 안 맞으면(후속 커밋이 그 파일을 건드림, 다중 파일 수정) 기존 red 스킬의 worktree 이식 방식을 쓴다.
