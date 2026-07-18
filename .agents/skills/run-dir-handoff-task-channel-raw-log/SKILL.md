---
name: run-dir-handoff-task-channel-raw-log
description: run-dir handoff 원문 검증은 task-channel raw log로
source: learned
---
finalize(compact::write_handoff)는 run-dir handoff.md를 evaluator 요약으로 덮어쓴다(보존 fix 전까지). worker가 쓴 handoff/파일 원문을 리뷰하려면: (1) .agents/runs/<run>/attempts/<id>/stdout.log의 file_change item으로 무엇을 언제 썼는지 확정하고, (2) command 출력은 tail-truncate되므로 .agents/task-channels/<chn>/events/*.yaml의 raw_ref(byte_start/byte_end)로 원본 바이트 범위를 복원한다. rg 다중 파일 gate exit 0은 per-file 증거가 아님에 주의.
