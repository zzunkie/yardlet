---
name: partial
description: partial 이어받기 시 아티팩트 선작성
source: learned
---
이전 워커가 result.json 없이 종료된 태스크를 이어받으면: (1) 이전 run worktree(.agents/worktrees/run-*)에서 작업 결과물을 먼저 회수·이식하고, (2) 누적 증거로 result.json/handoff.md를 즉시 작성한 뒤, (3) 장시간 검증은 백그라운드 유한 라운드로 돌려 아티팩트를 갱신한다. 검증을 아티팩트보다 앞세우면 동일한 무기록 종료가 반복된다.
