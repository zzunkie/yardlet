# V010-001 공유 session/state 계약 및 replay fixture 독립 검토

- 검토 대상: `docs/v0.10-shared-session-state-contract.md`, `tests/fixtures/v010_001_shared_state/**`, `tests/v010_001_shared_state_replay.rs`
- 검토자 역할: 계약 작성(YARD-001), fixture 구축(YARD-002), 결함 수정(run-20260712-234603)에 참여하지 않은 독립 architecture/state reviewer (YARD-003)
- 검토 이력: 1차 검토 run-20260712-233333 (partial, F-001 medium + F-002~F-004 minor), 수정 작업 run-20260712-234603, 2차 재검토 run-20260712-235209 (본 판정)
- 검토일: 2026-07-12
- 판정 요약: **AC-001부터 AC-006까지 전부 pass.** 1차에서 발견한 결함 4건은 모두 해소를 코드/문서 원문과 테스트 실행으로 확인했다. 남은 것은 비차단 관찰 6건뿐이며 high/medium failed check는 없다.

## 1. 2차 검증 방법

1. 계약 문서 전체(677행), replay 테스트(618행), canonical fixture(333행), legacy fixture 9개 파일을 1차와 독립적으로 다시 정독했다. 1차 보고서는 결함 목록 확인용으로만 참조하고, 각 기준은 원문에서 재검증했다.
2. `cargo test --test v010_001_shared_state_replay` 실행: 8/8 pass, exit 0. `cargo test` 전체 스위트 실행: 309 + 3 + 1 + 2 + 8 = 323 pass, 0 fail, exit 0 (증거: `.agents/runs/run-20260712-235209/validation.log`).
3. 계약이 인용한 저장소 근거를 재차 원문 대조했다 (`src/state.rs:1-5`, `src/state.rs:198-210`, `src/state.rs:261-288`, `src/state.rs:296-311`, `src/state.rs:815-826`, `src/schemas.rs:150-201`, `src/schemas.rs:230-248`, `src/planner.rs:559-597`, `src/planner.rs:1322-1340`, `src/run.rs:115-135`, `src/run.rs:1356-1389`, `tests/state_architecture_guard.rs:20-31`). 전부 정확했다.
4. `.agents/skills/contract-gate-parity-check/SKILL.md` 절차대로 §9.2 조건 목록과 runnable gate를 조건 단위 1:1 재대조하고, 각 좌변 필드가 predicate에서 실제로 읽히는지 grep으로 확정했다.
5. 수정 범위 확인: 변경된 파일은 계약 문서, `canonical.json`, 테스트 파일 3건뿐이고 legacy fixture와 `src/**`, Yardlet 운영 상태는 건드리지 않았다 (out_of_scope 준수).

## 2. 1차 결함 해소 확인

### F-001 (medium) 해소: runnable gate가 §9.2 전 조건을 구현하고 변조 반례가 테스트로 고정됨

1차 지적: gate가 §9.2 조건 중 `queue.intent_id == intent.id`와 `activation.draft_revision_id == confirmed draft head`를 구현하지 않았고, activation 변조 반례가 미시험이었다 (FC-1, FC-2, FC-3).

해소 증거:

- 누락 조건 1: `tests/v010_001_shared_state_replay.rs:243`에 `queue["intent_id"] == intent["id"]`가 추가되었다.
- 누락 조건 2: `tests/v010_001_shared_state_replay.rs:222-230`이 confirmed 상태의 draft head를 정확히 하나만 허용하는 방식으로 구성하고(둘 이상이면 None, 즉 fail closed), `:244-245`가 `confirmed_draft_head.is_some()`과 `activation["draft_revision_id"].as_str() == confirmed_draft_head`를 요구한다. activation 부재 시 None 비교의 우연 통과도 `is_some()` 가드로 막았다.
- FC-1 폐쇄: `mismatched_queue_intent`(`:427-431`)가 `queue.intent_id`를 `int_other`로 변조하고 runnable 0을 assertion으로 고정한다.
- FC-2 폐쇄: `dangling_draft_revision`(`:421-425`)이 `activation.draft_revision_id`를 `drv_999`로 변조하고 runnable 0을 고정한다.
- FC-3 폐쇄: `uncommitted_activation`(`:409-413`, status를 `prepared`로)과 `mismatched_intent_digest`(`:415-419`)가 각각 runnable 0을 고정한다. `without_activation`(`:400-407`)은 activation record 자체 제거를 커버한다.

red-green 확인: 기준 테스트(`canonical_state_replays_one_channel_with_two_accountable_attempts`)는 무변조 fixture에서 runnable == `["tsk_1"]`을 요구하고, 위 변조 테스트 4종은 동일 fixture의 in-memory 변조에서 runnable 0을 요구한다. 두 방향이 모두 pass하므로 gate가 해당 필드를 실제로 읽는다는 사실이 실행으로 증명된다. fixture 파일 자체를 건드리지 않고 반례가 재현 가능해졌으므로 1차의 FC-1~FC-3 재현 절차는 테스트 스위트 안으로 흡수되었다.

§9.2 조건과 gate의 최종 parity (전부 충족):

| §9.2 조건 | gate 위치 | 변조 테스트 |
|---|---|---|
| `queue.intent_id == intent.id` | `:243` | `:427-431` |
| `queue.confirmation_id == intent.confirmation_id` | `:246-247` 경유 (transitive) | 없음 (gate 존재) |
| `activation.confirmation_id == queue.confirmation_id` | `:247` | 없음 (gate 존재) |
| `activation.draft_revision_id == confirmed draft head` | `:222-230`, `:244-245` | `:421-425` |
| `activation.intent_digest == digest(intent)` | `:248` (저장 digest 문자열 비교) | `:415-419` |
| `activation.queue_digest == digest(queue)` | `:249` | 없음 (gate 존재) |
| `activation.status == committed` | `:240` | `:409-413` |
| `task.materialized_by_confirmation_id == activation.confirmation_id` | `:250` | 없음 (gate 존재) |
| 일반 gate 통과 | `:238` errors 비어 있음 + `:251` task state | gap/conflict/unknown 테스트 |

추가로 gate는 `draft.confirmed` event와 activation의 confirmation_id 일치(`:231-236`), `activation.intent_id == intent.id`, `activation.queue_id == queue.id`(`:241-242`)도 요구한다. §9.2보다 약한 지점은 없다.

### F-002 (minor) 해소: 첫 proposal의 head 승격 규칙 단일화, fixture 상태 정합

계약 §4.4(문서 138-143행)가 "최초 proposal이 검증을 통과하면 core는 같은 transition에서 `draft.proposed` provenance event와 `accepted` revision을 함께 기록해 그 revision을 첫 head로 만든다"로 규칙을 단일화했고, §5.2의 `draft.proposed` 행(227행)과 §9.1 첫 행(375행)이 같은 문장 구조로 정렬되었다. fixture `canonical.json:8-19`의 `drv_1` 상태는 `proposed`에서 `superseded`로 수정되어 새 규칙(accepted 첫 head가 revise로 superseded됨)과 정확히 일치한다. 이중 정의는 더 이상 없다.

### F-003 (minor) 해소: attempt 종결 어휘 단일화

`canonical.json:307`의 evt_17 `worker.completed` payload가 `result: "succeeded"`(§4.5 attempt terminal 어휘)로 수정되었고, 테스트 `:383`이 그 값을 고정한다. §5.2 `worker.completed` 행(246행)에 "payload.result는 section 4.5 attempt terminal state 어휘를 MUST 쓴다"가 명시되어 어휘 축이 계약에 고정되었다. att_1의 `needs_user`(`canonical.json:208`)와 함께 두 attempt 모두 §4.5 어휘를 쓴다.

### F-004 (minor) 해소: §14 최소 스토리와 action.completed의 관계 명시

계약 §14 전문(595-600행)이 "이 fixture에서 top-level activation은 action_id와 status: committed를 포함하는 confirm action의 terminal receipt projection이므로 별도 action.completed event를 최소 story에서 생략한다. section 9.1과 section 10.1의 규범은 그대로 유지되며, production canonical writer는 별도 action.completed event와 ActionReceipt record를 MUST 기록한다"로 생략 사유와 규범 유지 관계를 명시했다. fixture의 `activation`은 실제로 `action_id: act_confirm`과 `status: committed`를 갖는다(`canonical.json:21-30`). §9.1/§10.1 규범과 fixture 사이의 어긋남은 해소되었다.

## 3. 기준별 교차 검증 (2차)

### AC-001. 공통 vocabulary와 persistence boundary, 중복 상태 머신 불요: PASS

§3(불변식 8개), §4(entity 관계도와 정의 표, session/draft/attempt lifecycle), §5(event envelope와 23종 vocabulary), §6(action 11종), §7(surface projection 표)이 단일 의미 계층을 정의한다. §7은 CLI/TUI/GUI/conversational planning/durable task channel/runtime resources/generic worker adapter 각각에 대해 같은 action endpoint 사용과 별도 transition 금지를 명시한다. §10이 canonical 10개 record family와 derived index를 분리하고, legacy 파일의 조용한 재분류를 금지한다. task lifecycle 8종은 `src/schemas.rs:230-248`의 `TaskState`와 정확히 일치함을 재확인했다. 1차의 어휘 혼용(F-003)이 해소되어 vocabulary 단일성이 fixture까지 관통한다. 반례 탐색: surface별 독자 상태 머신을 허용하는 문장을 다시 찾았으나 없었다.

### AC-002. stable IDs, ordering, ownership, provenance, causality: PASS

§8.1(opaque id, prefix 권장, legacy `run_id`의 `attempt_id` alias, `worker_session_ref` 분리), §8.2(session별 strictly increasing `seq`가 유일한 정렬 키, wall clock과 파일 순서 금지), §8.3(actor/producer/digest/evaluator 요구), §8.4(action receipt idempotency, causation/correlation), §12.2(invalid-state matrix 11행)를 재확인했다. fixture 실행 증거: `fixture_ids_and_causation_form_a_complete_stable_chain`이 18개 event의 id 유일성, seq 1..18 연속성, 모든 비루트 event의 causation 선행 참조를 전수 검증하고, `replay_ignores_delivery_order_wall_clock_and_derived_index`가 event 역순 전달 + `recorded_at` 전면 교체 + `derived_index` 제거에서 baseline과 동일 snapshot을 증명한다. 테스트 실행 pass.

### AC-003. 명시적 confirm 전 runnable 금지, crash/restart 후 유지: PASS (1차 fail에서 전환)

계약: §9.1 전이표에서 commit 행만 runnable yes이고, §9.2가 조건 10개 전부와 "Planner result, queue 파일 존재, TaskState::Queued 단독은 confirm 증거가 아니다"를 명시하며, §11.2 crash window 12행이 각각 non-runnable 기본값을 갖는다.

fixture 실행 증거 (전부 이번 실행에서 pass 확인):

- confirm 우회 반례 6종이 각각 runnable 0: `draft.confirmed` event 제거, activation record 제거, `activation.status != committed`, `activation.intent_digest` 불일치, `activation.draft_revision_id` dangling, `queue.intent_id` 불일치 (`confirm_gate_duplicate_delivery_and_crash_restarts_converge`, `:393-431`).
- 중복 confirm/중복 전달 방어: 전체 18 event를 통째로 중복 입력해도 snapshot이 baseline과 동일 (`:433-442`).
- crash/restart 유지: §11.2 대표 지점 7곳([0, 5, 6, 11, 12, 15, 18] 이후 crash, 부분 적용 후 전체 재전달)에서 재시작 후 동일 final snapshot으로 수렴 (`:444-451`). 지점 5(confirm prepare 후 commit 전)와 6(commit 직후 materialize 전)이 §11.2의 핵심 crash window를 커버한다.
- F-001 해소로 gate가 §9.2 전 조건을 판정하므로, 1차에서 성립하지 않았던 "어떤 경로로도 runnable이 될 수 없다"의 fixture 증명이 이제 성립한다.

### AC-004. replay/crash recovery/version tolerance 결정성과 fail-safe, legacy degrade: PASS

- 결정성: replay의 정렬 키는 `seq`뿐이고 dedupe는 BTreeMap, wall clock/난수/파일 열거 순서는 assertion 입력에 없다. 역순 전달과 `recorded_at` 조작, derived index 제거에도 snapshot 동일 (실행 pass).
- fail-safe: sequence gap(`sequence_gap:10-11`)과 seq 충돌(`sequence_conflict:7`)에서 runnable 0. 같은 event_id에 다른 payload인 conflicting duplicate는 `conflicting_duplicate:evt_07_task_materialized`로 격리되고 runnable 0. runnability에 영향을 주는 unknown schema_version 2 event는 `unsupported_semantics`로 fail closed되고 runnable 0 (실행 pass).
- version tolerance: schema_version 0 event는 `kind` 어댑터 경유로 replay되어 `adapted_event_ids`에 기록되고 runnable이 유지되며, additive unknown field(`future_display_hint`)는 보존 목록에 남는다 (실행 pass).
- legacy no-index: `derived-index.json` 부재를 assertion으로 강제하고, 실행 전후 fixture tree의 byte 동일성으로 read-only를 증명하며, channel 1개, attempt 2개(run-legacy-1, run-legacy-2), `recorded_state: queued`에 `runnability: unknown`으로 false-runnable이 없다. §13.10과 일치 (실행 pass).

### AC-005. fixture가 저장 state만으로 task channel 1개와 accountable attempt 2개를 재구성: PASS

- 테스트 실행: `canonical_state_replays_one_channel_with_two_accountable_attempts` pass. channel 1개, attempt 2개. att_1은 codex/worker-session-a에 qst_1만 갖고, att_2는 claude-code/worker-session-b에 ans_1(기록된 answer와의 대조로 causation 검증), art_1, `result: succeeded`를 갖는다. completion은 cmp_1. worker/session/result provenance 혼입 없음.
- fixture inspection: `canonical.json`의 18개 event를 §14 표와 seq 단위로 1:1 대조했다. planning 개시(1), draft 2 revision(2-3), 명시적 confirm 3단계(4-6), task materialize(7), attempt 1 준비/시작/질문/needs_user(8-11), 답변(12), answer가 인과로 연 attempt 2(13-14), artifact(15), validation(16), succeeded(17), completion(18)이 전부 일치한다. 입력은 fixture 저장 값뿐이며 `.agents/runs/**` 채굴, 현재 시간, 난수 의존이 없다.

### AC-006. 독립 검토가 모순/누락/unsafe ambiguity 없음을 확인: PASS (1차 fail에서 전환)

본 2차 검토는 작성/수정 작업과 분리된 상태에서 전체 기준을 원문과 실행으로 재검증했다. 1차의 medium 결함 1건과 minor 모순 3건은 모두 해소가 확인되었고, 새 결함 탐색(gate parity 재대조, 변조 반례의 red-green 확인, 계약 내부 상호참조 재검, 인용 근거 재대조)에서 high/medium 결함은 발견되지 않았다. unsafe ambiguity(false-runnable을 유발할 수 있는 계약 문구)도 발견하지 못했다. 남은 것은 아래 비차단 관찰뿐이다.

## 4. 잔여 관찰 (비차단, 조치 불요)

- O-1: canonical 하네스의 channel 1개는 `queue.tasks[0]`에서 구성적으로 만들어진다. 단일 task fixture 목적에는 충분하나 다중 task 시나리오는 다루지 않는다.
- O-2: legacy fixture의 `conversations/YARD-001.yaml`, `transitions/YARD-001.yaml`은 하네스 assertion이 소비하지 않는다 (§13.5, §13.6의 turn 부착/transition 적용 규칙은 fixture 미검증). V010-003 통합 시점에 자연 커버 예상.
- O-3: legacy 정렬이 §13.4의 (typed started_at, mtime, stable path) tuple 대신 (started_at, run_id)만 쓴다. display fallback이므로 저위험.
- O-4: §9.2의 `runnable_reason: unconfirmed_or_inconsistent`가 하네스 snapshot에 없다 (cosmetic).
- O-5: legacy 하네스의 `runnability: "unknown"` 상수는 §13.10 규칙(adoption policy 없이는 무조건 unknown)의 충실한 구현이다.
- O-6 (2차 신규): sequence gap 시 하네스는 §12.2의 "gap 전까지만 표시"와 달리 gap 이후 event도 channel projection에 fold한다. 다만 안전 관련 절반(gap 이후 mutation/runnable 금지)은 errors 경유 runnable 0으로 지켜지고, 표시 절단은 §14가 fixture assertion으로 요구하지 않으므로 결함이 아닌 하네스 단순화로 판단한다.

## 5. 최종 verdict 표

| 기준 | 판정 | 핵심 근거 |
|---|---|---|
| AC-001 공통 vocabulary/persistence boundary | pass | 계약 §3-§7, §10; `src/schemas.rs:230-248` 일치; F-003 해소로 어휘 단일성 관통 |
| AC-002 IDs/ordering/ownership/provenance/causality | pass | 계약 §8, §12.2; chain 전수 테스트와 결정성 테스트 실행 pass |
| AC-003 confirm 전 runnable 금지, crash 후 유지 | pass | F-001 해소: gate가 §9.2 전 조건 구현, 우회 반례 6종 + 중복 전달 + crash 7지점 실행 pass |
| AC-004 replay/recovery/version tolerance/legacy | pass | 8개 테스트 실행 pass; legacy read-only byte 증명; fail-closed 전 분기 확인 |
| AC-005 fixture 재구성 (channel 1, attempt 2) | pass | 테스트 실행 + 18 event 대 §14 표 1:1 inspection 양쪽 확인 |
| AC-006 독립 검토, 모순/누락 없음 | pass | 1차 결함 4건 해소 확인, 2차 신규 탐색에서 high/medium 결함 없음 |

Failed checks: 없음. 전체 스위트 323 pass, exit 0 (`.agents/runs/run-20260712-235209/validation.log`).
