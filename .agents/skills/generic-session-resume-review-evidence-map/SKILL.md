---
name: generic-session-resume-review-evidence-map
description: generic-session-resume-review-evidence-map
source: learned
---
제네릭 세션 재개 계약 검토 시 인과 사슬을 이 6점으로 추적: (1) 캡처규칙 src/workers/mod.rs session_capture_rule(resume 시 None), (2) ref 기록 run.rs worker.completed payload + state.rs replay가 producer.worker_session_ref 채움, (3) 판정 run.rs same_worker && supports_native_resume(&profile), (4) 모드 state.rs answer_question native 분기, (5) 실행 run.rs continuation==NativeResume → session_id·resume=true, (6) command build_generic_resume_command 재검증+argv 직접확장. positive/negative는 generic_worker_contract_process.rs와 v010_003 fallback 테스트로 확인하고, 반드시 cargo test --all-features(slow tier 포함)로 exit status를 새로 기록.
