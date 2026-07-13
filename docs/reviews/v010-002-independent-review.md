# V010-002 독립 리뷰

- 리뷰 일자: 2026-07-14, Asia/Seoul
- 리뷰 대상 commit: `1a39f29127b6bf3b34f5997daf9f7f982ffb4298`
- parent roadmap SHA-256: `14be3c7bb787548cb598910019daacc6d64b83f7a15809ad877a1d22e6f96156`
- 최종 판정: **PASS**

V010-002의 계약, 구현, 자동화 테스트, 실제 process evidence를 builder 보고와 분리해
다시 검토했다. AC-001부터 AC-007까지 모두 pass다. critical 또는 major blocker는
없다. 아래 minor 두 건은 승인 조건을 깨지 않지만 후속 문서와 packet 생성 시 바로잡을
가치가 있다.

## 1. Findings

### F-001, minor: builder dogfood 문서의 process test 수가 한 곳에서 오래된 값이다

- 증거: `docs/reviews/v010-002-yardlet-on-yardlet.md:8`은 35개라고 쓰지만 같은 문서
  `:611`과 fresh integration 실행은 37개를 보고한다.
- 영향: 실제 테스트 누락은 없고 37/37이 통과했다. 다만 문서 첫 요약만 읽으면 현재
  matrix 크기를 잘못 이해할 수 있다.
- 구체적 수정: builder dogfood 문서 `:8`의 35를 37로 갱신하거나, 변하기 쉬운 총개수
  대신 해당 integration command와 결과 section 링크를 사용한다.

### F-002, minor: task packet이 존재하지 않는 `repo-summary.md`를 read anchor로 지정했다

- 증거: `.agents/runs/run-20260714-064416/task-packet.md:128`은
  `.agents/runs/run-20260714-064416/evidence/repo-summary.md`를 지정하지만 실제 run에는
  `run.yaml`과 `task-packet.md`만 있었고 해당 파일 read는 exit 1이었다.
- 영향: 이번 판정은 실제 source, parent roadmap, committed contract, 독립 process
  evidence를 직접 읽어 충족했으므로 AC 판정에는 영향이 없다. 하지만 reviewer가
  시작 시 불필요한 missing-anchor 진단을 해야 했다.
- 구체적 수정: packet 작성 전에 read anchor 존재를 검증하고, reviewer run에도 필요한
  repo summary를 먼저 생성하거나 존재하지 않는 anchor는 packet에서 제외한다.

## 2. 계약 기준

parent SOT의 V010-002는 `/Users/zzunkie/Desktop/workspace/yard/docs/yardlet-roadmap.md:456-494`에
있다. 이 파일은 worktree에 투영되지 않는 ignored 문서이므로 committed dogfood 문서가
`docs/reviews/v010-002-yardlet-on-yardlet.md:33-81`에 같은 task anchor와 parent SHA-256을
투영한다. reviewer가 parent 파일을 직접 hash한 결과도 위 SHA-256과 일치했다.

공유 session state contract에서는 explicit confirmation과 projection 분리를
`docs/v0.10-shared-session-state-contract.md:51-75`, entity와 action vocabulary를
`:98-108` 및 `:254-283`, confirm 유일 경로를 `:369-405`, persistence와 crash recovery를
`:407-501`, invalid-state 동작을 `:514-550`에 규정한다.

## 3. AC별 traceability

### AC-001: planning session, ordered channel, proposal, semantic diff

판정: **PASS**

- 계약: roadmap `:463-472`와 contract `:51-75`, `:98-108`, `:254-283`.
- source: `src/schemas.rs:208-383`이 session, turn CAS, proposal, immutable revision,
  event, action receipt를 정의한다. `src/planning.rs:380-460`은 summary,
  allowed/out-of-scope, acceptance, ambiguity, tasks, dependencies, routing,
  validation을 구조적 before/after diff로 만든다. `src/planner.rs:331-386`은 정확한
  recorded turn을 planning worker에 넘기고, `src/cli.rs:969-1148`은 `new`, channel,
  accept, reject, undo, answer, confirm을 노출한다.
- automated test: `planning::tests::semantic_diff_covers_every_contract_plan_surface`와
  process tests `proposal_accept_is_explicit_and_does_not_activate`,
  `proposal_reject_preserves_the_visible_head`, `undo_restores_the_parent_revision`.
- actual process: `review-evidence/dogfood/independent-parity.json`의 journal은 seq 1..38이
  연속이고 `user.message`, `worker.message`, `draft.proposed`가 각각 4개다. accept,
  revise, reject, undo, confirm event도 같은 session에 순서대로 남았다.

### AC-002: immutable revision, action integrity, stale/reject/undo 반례

판정: **PASS**

- 계약: roadmap `:482-488`, contract `:352-365`, `:371-381`, `:536-550`.
- source: `src/state.rs:467-505`가 proposal, revision, event를 immutable no-clobber
  writer로 저장한다. `src/planning.rs:930-1125`가 action idempotency와 terminal receipt
  linkage를 검증하고, `:1241-1472`가 stale head와 disposed proposal을 거절하며,
  `:1475-1577`이 current digest, parent identity, accepted-event linkage를 통과한 undo만
  적용한다.
- automated test: 37개 process suite 중 stale head, terminal proposal, undo integrity,
  receipt integrity, journal corruption, prepared-action interlock 시나리오가 모두 pass.
- actual process: `stale-head/stale.err`는 `stale_head`, `terminal-proposal/*.err`는
  `proposal_already_disposed`, `undo-integrity/*.err`는 corrupt digest, missing parent,
  cross-session parent를 거절했다. 각 scenario summary는 exit 0이고 head 또는 revision
  count 불변을 fixture가 확인했다.

### AC-003: restart persistence와 exact session/turn recovery

판정: **PASS**

- 계약: roadmap `:472`, `:488`, contract `:407-501`.
- source: `src/state.rs:403-464`가 session과 latest pointer identity를, `:508-600`이
  contiguous journal과 restart cursor를 검증한다. `src/planning.rs:2273-2336`은 persisted
  session, event, proposal, current draft, activation을 다시 projection한다.
  `src/planner.rs:1329-1440`은 PlanMeta v2의 exact session, expected head, request event,
  request digest를 확인한 뒤 proposal만 복구한다.
- automated test: `restart_restores_history_and_confirmed_provenance`,
  `same_request_sessions_never_steal_an_unconsumed_planner_result`,
  `stale_planner_completion_is_rejected_without_rebase`,
  `restart_recovery_creates_only_the_exact_session_proposal` 모두 pass.
- actual process: `restart/summary.json`은 fresh process가 head와 history를 복원하고 같은
  confirm action replay가 committed provenance로 수렴했음을 기록한다. dogfood의
  pre-confirm과 final JSON도 별도 CLI process에서 같은 head를 보였다.

### AC-004: explicit confirm, exact promotion, atomic crash recovery, runnability

판정: **PASS**

- 계약: roadmap `:486-487`, contract `:369-405`, `:447-501`, `:536-550`.
- source: `src/planning.rs:1666-1721`이 visible revision에서 active intent와 immutable
  materialized queue를 직접 만든다. `:1724-1988`은 expected head, active queue isolation,
  revision integrity, prepare receipt, snapshots, activation, completed effect를 한 lock/CAS
  transaction과 replayable write order로 연결한다. `:2074-2258`은 confirmation, action,
  session, revision, intent/queue digest, task materialization, exact draft fields를 모두 읽어
  runnable 여부를 fail-closed로 판단한다. `src/run.rs:554-568`은 worker 선택 전에 이 gate를
  호출한다.
- automated test: `partial_or_tampered_promotion_is_not_runnable`,
  `confirmation_requires_its_completed_matching_action_receipt`,
  `actual_confirm_write_order_crashes_replay_without_manual_state_repair`,
  `every_confirmation_linkage_predicate_fails_closed_when_tampered` 모두 pass.
- actual process: `partial-promotion/*.err`에서 missing activation, intent-only, queue-only,
  confirmation id, draft id, materialization id, intent digest 변조가 모두
  `unconfirmed_or_inconsistent`로 non-runnable이었다. `activation-linkage/*.err`에서 missing,
  rejected, digest-conflicting, wrong action receipt와 cross-session draft도 거절됐다.
  `confirm-crash/summary.json`은 prepare 뒤, intent write 뒤, activation write 뒤, confirmed
  effect 뒤의 네 실제 crash가 각각 effect 1개, completed receipt 1개, valid activation으로
  수렴했음을 기록한다.

### AC-005: running queue 격리와 `yardlet goal` express path

판정: **PASS**

- 계약: roadmap `:474-478`.
- source: `src/planning.rs:302-313`은 confirmed session의 free-form mutation을 거절하고,
  `:1833-1851`은 running 또는 미완료 active queue 교체를 거절한다.
  `src/planner.rs:291-325`와 `src/planning.rs:1991-2034`는 planner 호출 없이 deterministic
  draft를 create, propose, accept, confirm하고 provenance를 남긴다.
- automated test: `running_and_confirmed_queues_reject_free_form_planning_mutation`,
  `goal_express_path_records_confirmation_without_a_planner`,
  `concurrent_express_goals_are_one_transaction_each` 모두 pass.
- actual process: `running-isolation/late.err`는 confirmed session mutation을,
  `running-isolation/running.err`는 `active_queue_not_drained: running_queue_isolated`를
  반환했다. `goal-regression/goal-default.json`은 task 1개, `goal-verify.json`은 verifier를
  포함한 task 2개이고 둘 다 confirmation/action/session/revision/digest provenance와
  `exact_active_parity: true`를 남겼다. fixture planner marker는 생성되지 않았고 두 queue는
  fresh `run --next`에서 prepared 상태로 진입했다.

### AC-006: Yardlet-on-Yardlet multi-turn dogfood와 field parity

판정: **PASS**

- 계약: roadmap `:490-494`.
- source와 fixture: `tests/fixtures/v010_002_conversational_planning/scripts/run.sh:379-404`가
  4 content turn, accept, reject, undo, fresh show, explicit confirm을 실제 binary process로
  실행한다. 이는 최소 3 turn 조건보다 강하다.
- automated test: `three_turn_dogfood_promotes_the_exact_visible_draft` pass.
- actual process: `dogfood/pre-confirm.json`은 lifecycle open, activation null, visible head
  `drv_20260713214719234575000_000002`를 기록한다. `dogfood/dogfood-final.json`은 같은
  head가 confirmation `cnf_20260713214720993224000_000002`로 승격되고 4 turn, reject 1,
  undo 1, exact parity true임을 기록한다.
- 독립 field 비교: `dogfood/independent-parity.json`에서 intent 14개 필드, queue 5개 필드,
  task 13개 필드가 모두 true다. confirmation, session, revision linkage도 true다. 독립
  FNV-1a JSON 계산 결과 draft `ff85a0ea04a84f2c`, intent `b8734647d679ea88`, materialized
  queue `6354ad6a4f520d0f`, activated queue `c7a82f63f418d766`이 저장값과 각각 일치했다.

### AC-007: 독립 전체 검증과 문서 parity

판정: **PASS**

- `cargo fmt --check`: exit 0.
- `cargo clippy --all-targets --all-features -- -D warnings`: exit 0.
- `cargo build`: exit 0.
- `cargo test`: exit 0. unit 396, builtin bundle 3, git-finish process 1,
  state architecture 2, V010-001 replay 8, serial git-finish process 1,
  V010-002 process 37, 총 448개 pass, failure 0.
- targeted `cargo test --test v010_002_conversational_planning_process -- --nocapture`:
  37 passed, 0 failed, exit 0.
- README mirror: 두 파일의 `##` section은 같은 순서와 개수 19개, `yardlet` command row는
  각각 34개, `.agents/` state tree는 20개 entry가 같은 순서다. em dash grep은 둘 다
  match가 없어 exit 1이었다. 새 planning command와 explicit confirm 설명은
  `README.md:90-114`, `:249-258`, `README.ko.md:88-111`, `:235-244`에서 1:1이다.

상세 command와 exit status는
`.agents/runs/run-20260714-064416/validation.log`, 직접 replay manifest는
`.agents/runs/run-20260714-064416/review-evidence/process-replay-manifest.json`에 있다.

## 4. 최종 verdict

**PASS.** AC-001부터 AC-007까지 source, automated test, actual-process evidence가 모두
존재하고 reviewer의 fresh replay와 전체 Rust 검증에서 failure가 없었다. V010-002는
승인 조건을 충족한다.
