---
name: run-git-finish-checkpoint-oid
description: 정리로 유실된 run 브랜치는 git-finish checkpoint OID로 복구 검증
source: learned
---
worktree/브랜치 정리 후 done task의 코드가 main에 실제로 있는지 의심되면: (1) .agents/checkpoints/git-finish/<run-id>.json의 expected_oid/owned_oids를 읽고 (2) git cat-file -t <oid>로 객체 생존 확인 (3) git merge-base --is-ancestor <oid> main으로 병합 여부 판정 (4) 미병합이면 git branch <name> <oid>로 dangling 커밋을 복구한다. status가 safety_blocked(branch_does_not_match_target_ref 등)인 run은 push되지 않았을 가능성이 높다. 사례: YARD-013 fb653fd.
