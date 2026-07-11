---
name: git-finish-4
description: git-finish 완료 판정 4-투영 일관성 검증법
source: learned
---
git-finish 완료 집계 일관성을 검증할 때는 네 지점을 한 번에 대조한다: (1) src/run.rs state_after_git_finish의 Done→Partial 강등과 partial-reason 파일, (2) src/trust.rs telemetry_done의 허용 상태 집합, (3) src/report.rs의 git-finish.json user_line 렌더, (4) 실제 run의 queue.yaml/run.yaml/telemetry.jsonl/final-report 스냅샷. 허용 상태 집합은 반드시 GitFinishStatus::verified_complete와 문자열까지 일치해야 한다(빈 문자열 = 기록 없음 포함).
