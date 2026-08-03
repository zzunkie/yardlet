# 제네릭 워커 세션 재개 계약 독립 검토 (YARD-002)

- 검토 대상 구현: `f181b61` "yardlet(YARD-001): 제네릭 워커의 opt-in native session resume 구현" (현재 브랜치에 머지됨)
- 검토 유형: read-only 독립 검토 (제품 코드 미수정)
- 검토 HEAD: `1b44827`
- 판정 요약: **AC-001 ~ AC-005 전부 PASS → status: done**
- 실행 게이트: `cargo fmt -- --check` = 0, `cargo clippy --all-targets --all-features -- -D warnings` = 0, `cargo test --all-features` = 0 (856 passed / 0 failed / 31 test binaries), public-scan clean

---

## 수용 기준 판정 (file:line + test evidence)

### AC-001 — 선택적 세션 계약 선언 + 캡처 규칙·resume template 동시 검증, 기존 profile 무변경 로드 · **PASS**

증거 (코드):
- 스키마가 opt-in: `src/schemas.rs:2224-2227` `Invocation.session: Option<GenericSessionInvocation>` 에 `#[serde(default, skip_serializing_if = "Option::is_none")]`. 하위 구조 `GenericSessionInvocation{capture, resume_args}` (`src/schemas.rs:2231-2241`), `GenericSessionCapture{stream, prefix}` (`src/schemas.rs:2243-2249`).
- 세션 선언 시에만 검증: `src/schemas.rs:2332` `let Some(session) = &self.session else { return Ok(()) }` — 미선언이면 즉시 통과. 선언 시 capture.stream ∈ {stdout,stderr} (`:2334-2342`), prefix non-empty·single-line (`:2344-2347`), resume_args placeholder 검증(`:2349-2380`)이 함께 강제된다.
- 캡처 규칙과 resume template이 한 블록에서 함께 검증됨 → "선언 시 캡처 규칙과 resume argument template이 함께 검증"을 만족.

증거 (테스트):
- `src/schemas.rs` unit `generic_session_contract_is_opt_in_and_rejects_incomplete_templates` — legacy profile(session 생략)이 `validate().unwrap()` 통과하고 `session.is_none()`; 완전 선언 profile 통과; 불완전 5종(빈 capture, prefix 누락, {session} 0개, {session} 2개, resume {prompt} 불일치) 각각 명시 error로 거절.
- process `invalid_contract_and_strict_billing_are_rejected_before_probe_or_worker_spawn` — `session-capture`/`session-resume-ref`/`session-resume-prompt` 케이스가 probe·worker spawn 이전에 거절됨.
- process `legacy_stdin_transport_and_default_offline_probe_remain_invocable` — 세션 블록 없는 기존 profile이 그대로 실행되어 packet을 stdin으로 전달.

### AC-002 — 세션 지원 워커의 answer가 같은 worker·정확히 같은 session ref의 NativeResume으로 실행, 답변 1회 전달 후 완료 · **PASS**

증거 (코드):
- fresh child에서 세션 ref 캡처: `src/workers/mod.rs:924-955` `session_capture_rule` + `prefixed_session_ref_from_line`, 스트리밍 캡처 `capture_prefixed_session_ref` (`:957`), EOF 잔여 처리 (spawn 루프). 캡처된 ref는 `outcome.session_id` → `worker.completed` payload (`src/run.rs:1957`) → 이벤트 리플레이로 producer attempt의 `worker_session_ref` (`src/state.rs:3724-3730`)로 기록.
- answer 결정: `src/run.rs:2302-2319` `same_worker` 확인 후 `supports_native_resume` 계산, `worker_session_ref`를 `same_worker`일 때만 전달. `src/state.rs:4054-4072`에서 `native`(=supports_native_resume && non-empty ref)일 때 `ContinuationMode::NativeResume`로 설정하고 ref 저장.
- 실행: `src/run.rs:2881-2888` NativeResume이면 `session_id = attempt.worker_session_ref`, `effective_chained = true` → spawn `resume=true`. `src/workers/mod.rs:1210-1223`에서 generic 분기가 `build_generic_resume_command`로 정확한 session ref를 사용.
- 답변 1회: `build_generic_resume_command`(`src/workers/mod.rs:690-748`)가 placeholder를 `Command` argv에 직접 확장(shell 미개입), `{prompt}`가 packet을 정확히 1회 치환.

증거 (테스트):
- process `generic_answer_uses_captured_session_ref_and_declared_native_resume_template` — `resume-argv[2] == "fixture session ref"`, `resume-prompt`에 답변 문자열 count==1, `resume-stdin` 비어 있음(argument transport 중복 없음), attempt record `continuation: native_resume` + `worker_session_ref: fixture session ref`, `worker.completed`가 ref 유지, 최종 status done.
- unit `generic_resume_uses_the_profile_command_and_preserves_each_argument_boundary` — resume argv 순서/경계 보존.
- process(v010_003) `native_resume_preserves_session_ref_and_answer_causality` — 세션 ref·인과 보존.

### AC-003 — resume 가능 판정은 worker id 문자열이 아니라 profile 세션 계약 + 현재 fresh child의 ref로; 전역/타 attempt 추측 없음 · **PASS**

증거 (코드):
- `supports_native_resume`가 `&str`이 아닌 `&WorkerProfile`을 받도록 시그니처 변경: `src/workers/mod.rs:509-511` — generic 경로는 `profile.invocation.session.is_some()`로 판정(내장 codex/claude-code는 out-of-scope로 id 유지). 계약 완전성은 로드시 검증(`src/schemas.rs:2332-2380`) + `build_generic_resume_command`의 재검증(`src/workers/mod.rs:698-711`)으로 보장.
- ref 출처 고정: producer는 열린 질문을 낸 바로 그 attempt(`src/run.rs:2234-2238`, `attempt_id == question.attempt_id`), 그 ref는 해당 attempt의 fresh child에서만 유래(`src/state.rs:3724-3730`). resume 시 재캡처 없음: `src/workers/mod.rs:929-931` `if resume { return None }`. 전역 세션 파일 미참조.
- worker 변경 차단: `same_worker` gate(`src/run.rs:2302,2316`) → 다른 worker는 ref 상속 불가.

증거 (테스트):
- unit `generic_resume_uses_the_profile_command_and_preserves_each_argument_boundary` — 세션 블록 있는 profile에 대해 `supports_native_resume(&profile) == true` 단언(id 무관, profile 기반).
- process(v010_003) `unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet` — worker 변경 시 continuation의 `worker_session_ref`가 null이고, producer의 `worker.completed`는 `producer-session-ref`를 유지.

### AC-004 — 계약/ref 없으면 ExplicitPacket fallback, 불완전·모호 template은 실행 전 거절, 빈/내장 전용 command로 추락 금지 · **PASS**

증거 (코드):
- 계약 없음·ref 없음 → ExplicitPacket: `src/state.rs:4054-4072` (native 조건 불충족 시 `ContinuationMode::ExplicitPacket`). 이중 안전망: `src/schemas.rs:3505-3509` attempt validation이 NativeResume에 non-empty `worker_session_ref` 강제.
- 불완전/모호 template 실행 전 거절: `src/schemas.rs:2332-2380` 로드 검증; `build_generic_resume_command`가 spawn 직전 재검증(`src/workers/mod.rs:698-707`)하며 빈 session ref(`:704-706`)와 세션 계약 부재(`:709-711`)에 bail.
- 빈/내장 전용 command 추락 방지: spawn 분기(`src/workers/mod.rs:1198-1224`) — generic resume은 `_ =>` 팔에서 `build_generic_resume_command`로만, 내장은 `build_resume_command`로만; `session.ok_or_else`로 ref 부재를 오류화(`:1213-1216`).

증거 (테스트):
- process `generic_answer_without_a_captured_session_ref_uses_explicit_packet_fallback` — SESSION_REF 미방출 시 `resume-argv` 미생성, packet에 "Explicit continuation packet" 포함, attempt `continuation: explicit_packet`.
- process `invalid_contract_and_strict_billing_are_rejected_before_probe_or_worker_spawn` — 불완전 세션 계약 3종 거절.
- process(v010_003) `unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet` — worker 변경 시 explicit_packet fallback.

### AC-005 — sandbox/full·model·effort·image 인자, 환경 정화, 결과 파일 계약 무약화 + fmt·전체 feature suite 통과 · **PASS** (env 정화 resume 경로 직접 단언은 관측상 부재 — 결함 아님)

증거 (코드):
- resume command가 access/model/effort/image 인자를 fresh와 동일 구조로 보존: `build_generic_resume_command`(`src/workers/mod.rs:713-745`)가 full_access_args/sandbox_args, model_args(explicit), effort_args(explicit), image_args를 적용 — `build_generic_command`(`src/workers/mod.rs:657-679`)와 대칭.
- 환경 정화 유지: 두 빌더 모두 `cmd.env_clear()` 호출(`:745`, `:681`), 이후 `spawn_internal`이 정화된 env를 fresh/resume 공통 경로에서 적용(`src/workers/mod.rs:1261-1263`). env 자체는 billing-policy로 스크럽됨.
- 결과 파일 계약: resume_args의 `{run_dir}` 확장으로 worker가 result.json을 run_dir에 기록(테스트 fixture가 실증).

증거 (실행/테스트):
- `cargo fmt -- --check` = **0**, `cargo clippy --all-targets --all-features -- -D warnings` = **0**, `cargo test --all-features` = **0** (856 passed / 0 failed / 31 binaries). (본 run의 `validation.log` 참조.)
- unit `generic_resume_uses_the_profile_command_and_preserves_each_argument_boundary` — resume argv 전체 순서 `[resume, "session ref with spaces", <packet>, "safe mode", --model, fixture-model, --effort, high, --image, "image one.png"]`, program·cwd 보존.
- fresh 경로 env 정화는 `generic_argument_transport_preserves_argv_boundaries_and_delivers_the_packet_once`, `legacy_stdin_transport_and_default_offline_probe_remain_invocable`가 `last-secret == absent`로 단언.

관측(비차단): resume 경로에 대한 env-scrub 직접 단언(예: resume fixture에서 `last-secret == absent`)은 없다. env 적용이 fresh/resume 공통 코드라 구조상 분기 불가하므로 결함은 아니지만, 회귀망 강화 여지가 있어 후속 과제로 제안한다.

---

## Positive · Negative 매트릭스 (실제 test로 확인)

| 시나리오 | 기대 | 확인 test | 결과 |
|---|---|---|---|
| 세션 지원 profile + ref 캡처 → answer | NativeResume, 같은 ref, 답변 1회 | `generic_answer_uses_captured_session_ref_and_declared_native_resume_template` | ok |
| legacy profile (세션 생략) | 무변경 로드·실행 | `generic_session_contract_is_opt_in_...`, `legacy_stdin_transport_...` | ok |
| session ref 유실 | ExplicitPacket fallback | `generic_answer_without_a_captured_session_ref_uses_explicit_packet_fallback` | ok |
| 불완전 세션 template | spawn 전 거절 | `invalid_contract_and_strict_billing_are_rejected_...`, `generic_session_contract_is_opt_in_...` | ok |
| worker 변경 | ref 미상속, ExplicitPacket | `unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet` | ok |
| argv 경계·access·cwd 보존 | 경계 유지 | `generic_resume_uses_the_profile_command_and_preserves_each_argument_boundary` | ok |

---

## 잔여 위험 (residual risk)

1. **[minor] resume 경로 env-scrub 회귀 단언 부재.** fresh 경로만 `last-secret == absent`를 단언한다. 구조상 공통 코드라 현재는 안전하나, 향후 resume가 별도 env 조립 경로로 갈라질 경우를 대비한 명시 단언이 없다. → 후속 과제 제안(FT-1).
2. **[minor] resume_args에 `{run_dir}` 필수 검증 없음.** fresh `args`와 동일하게 검증은 강제하지 않는다(대칭이라 약화는 아님). `{run_dir}`를 빠뜨린 profile은 worker가 결과 파일 위치를 모를 수 있으나, 이는 기존 generic 계약과 동일한 profile 작성자 책임 범위다.
3. **[info] NativeResume packet은 전체 컴파일 packet.** 답변만이 아닌 full packet(task·repo·conversation)을 프롬프트로 전달한다. 답변 문자열은 1회만 나타나 AC-002를 만족하며, 이는 기존 내장 answer-resume packet 의미와 동일(범위 밖)하므로 결함이 아니다.

## 실행 명령 (독립 재실행)

```
cargo fmt -- --check                                          # exit 0
cargo clippy --all-targets --all-features -- -D warnings      # exit 0
cargo test --all-features                                     # exit 0 (856 passed / 0 failed)
# 대상 회귀만:
cargo test --all-features generic_session_contract_is_opt_in_and_rejects_incomplete_templates
cargo test --all-features --test generic_worker_contract_process
cargo test --all-features --test v010_003_task_channels_process unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet
```
