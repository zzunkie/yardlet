---
name: commit-range-detached-worktree
description: commit-range 독립 리뷰는 detached worktree에서 게이트 실행
source: learned
---
커밋 범위 X..Y를 독립 리뷰할 때: (1) `git worktree add --detach <scratchpad>/review-<tip> <tip>`으로 리뷰 tip 전용 worktree를 만들고, (2) 전체 게이트(cargo test/fmt/clippy)와 focused 테스트를 그 worktree에서 실행해 현재 브랜치의 후속 커밋 오염 없이 '리뷰된 리비전' 증거를 남기고, (3) 종료 시 `git worktree remove --force`로 정리한다. diff는 `git diff X..Y -- <file>`로 파일별 추출해 읽는다.
