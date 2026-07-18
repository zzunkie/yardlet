---
name: rescue-history-only
description: rescue 브랜치 history-only 보존 후 삭제 검증
source: learned
---
rescue 브랜치를 -s ours로 main에 머지해 보존했다는 주장은 3단계로 검증한다: (1) git branch -a --list '*rescue*'로 브랜치 부재 확인, (2) 머지 커밋의 두 번째 부모가 rescue tip OID이고 git diff --stat <merge>^1 <merge>가 비어 tree 변경 0인지 확인, (3) 보존 대상 OID들이 git merge-base --is-ancestor로 main과 origin/main의 조상인지 확인. worktree에는 .agents/checkpoints가 없을 수 있으므로 checkpoint 파일 대신 OID ancestry를 직접 검증한다.
