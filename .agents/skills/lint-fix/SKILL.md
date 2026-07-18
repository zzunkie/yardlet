---
name: lint-fix
description: lint-fix 주장 과거 커밋 실증법
source: learned
---
lint 수정 커밋을 리뷰할 때 '고쳤다'는 주장을 현재 HEAD의 lint 통과만으로 믿지 말라. (1) git worktree add --detach /tmp/<name> <pre-fix-commit>으로 임시 worktree 생성, (2) CARGO_TARGET_DIR을 별도 임시 경로로 두고 동일 lint 명령을 실행해 정확한 실패(규칙명, exit code)를 확인, (3) 현재 HEAD에서 동일 명령 exit 0 확인, (4) allow/suppress 카운트를 pre/post 커밋에서 grep -c로 대조해 억제로 통과시킨 게 아님을 확인, (5) git worktree remove와 임시 target 제거로 정리.
