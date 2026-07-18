---
name: git-finish-crash-window
description: git-finish crash window별 복구 기대치
source: learned
---
git finish 중단 fixture를 판정할 때 crash window별 올바른 복구 형태를 구분하라: (1) Prepared 이후 push 전 중단은 복구가 pre-push check를 반드시 재실행하므로 check 횟수가 task당 +1이 정상이다. (2) push 성공 직후 중단은 remote가 이미 expected OID이므로 already_applied(checks 빈 배열, push_invoked=false, 재push 없음)로 수렴해야 하며 Pushed 형태를 강제하면 오탐이다. 실제 push 1회 증명은 record가 아니라 git wrapper log의 exact-refspec 성공 카운트로 하라. 또한 --force 금지 guard는 push 호출 라인에만 걸어야 한다: git worktree remove --force는 Yardlet 소유 worktree 정리의 정상 동작이다(.agents/worktrees/ 내부 경로인지로 판정).
