---
name: rescue-diff
description: rescue 브랜치 diff의 파일별 이식 판정
source: learned
---
dangling/rescue 커밋을 최신 main에 재통합할 때: git diff <base>..<commit> -- <file> | git apply --check 를 파일별로 돌려 clean 적용 파일과 수동 통합 파일을 먼저 분류한다. clean 파일은 working-tree apply, 충돌 파일만 손으로 이식한 뒤 git diff <commit> -- <files> 로 누락 0을 증명한다.
