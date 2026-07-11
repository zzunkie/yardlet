---
name: golden-failed-check-repair
description: golden-failed-check-repair-재현
source: learned
---
자율 피드백 루프를 라이브로 재검증할 때: mktemp 디렉터리에 yardlet init 후 (1) workers.yaml에 generic adapter로 sh 스크립트 worker 등록(attempts 파일 증가 + result.json에 done 주장), (2) queue에 goal{condition, max_feedback_cycles:1, feedback_policy:inject_failed_checks}과 validation `test "$(cat attempts)" -ge 2` 를 가진 task 작성, (3) yardlet run --auto --accept-ambiguity 실행. 기대: 1차 Partial(evaluator가 worker의 done 주장을 validation exit=1로 기각)→feedback.json cycle 1/1→packet에 'Feedback cycle' 주입→2차 Done, transitions queued→running→partial→running→done. 원형은 src/run.rs 테스트 auto_retry_injects_failed_validation_then_converges_to_done.
