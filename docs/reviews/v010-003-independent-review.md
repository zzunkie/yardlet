# V010-003 remediation 최종 독립 재검토

## 최종 판정

**PASS.** AC-001부터 AC-008까지 모두 통과했다. 1차 review의 HIGH-001부터
HIGH-004와 MEDIUM-001은 현재 fixture를 remediation parent production에 얹었을 때
각각 원 증상으로 실패했고, 현재 HEAD의 동일 fixture와 14개 실제-process suite에서는
모두 통과했다. 미해결 critical, major, high, medium failed check는 없다.

검토 HEAD는 `9a6ece91ad3cc22e7d94ba72eef75ddac8f5b0bd`, YARD-009 production
commit은 `7a41942db42f161301b4b314b04937194a877193`, 그 remediation parent는
`8dae92c6724a1e0f02873e47446a233eba6bf56e`다.

## 기준과 evidence provenance

- 현재 checkout의 tracked 계약 `docs/v0.10-shared-session-state-contract.md` 전체를
  읽었고 SHA-256은
  `8dabe01c969fca5bd9c7a28ed4a0da0114503526309990afa6770a8175cca8f4`다.
- roadmap의 V010-003 요구는 root checkout의 ignored 내부 문서
  `/Users/zzunkie/Desktop/workspace/yard/docs/yardlet-roadmap.md:696-752`에서
  읽었다. SHA-256은
  `cf4d16bac80f735ae58c8a2c410631dddbb35e6e3a140a18af1067b42cd8025b`다.
- 1차 review는 독립 review worktree의
  `/Users/zzunkie/Desktop/workspace/yard/.agents/worktrees/run-20260714-190212/docs/reviews/v010-003-independent-review-round-1.md`
  에서 읽었다. SHA-256은
  `759d2b6fd06ce42eefd519a2563594245972bc587a3fd48fedf8810c1fae3e74`다.
- 현재 branch에는 위 roadmap과 1차 review가 없고, task packet이 지정한
  `.agents/runs/run-20260714-195009/evidence/repo-summary.md`도 시작부터 없었다.
  `git check-ignore -v docs/yardlet-roadmap.md`는 `.gitignore:50`을 반환했다.
  이 portability 결함은 아래 MINOR-001에 기록한다. 활성 intent, queue 또는 기존
  `.agents/runs` history는 fixture 입력으로 읽거나 수정하지 않았다.
- 현재 branch에 있는 `docs/reviews/v010-003-dogfood.md`와
  `docs/reviews/v010-003-remediation.md`의 SHA-256은 각각
  `34ed2aa8e5aa7f5bcaa0841c340fb61370df0c35b528771cff4a7eb4b00b0cd2`,
  `6a679d4fd956670c7852b58a0081baeca71e6ba6ef01b7c65722b53a97856869`다.

YARD-009 diff는 `src/run.rs`, `src/schemas.rs`, `src/state.rs`,
`src/workers/mod.rs`, V010-003 process test와 fixture, remediation 문서의 7개
파일뿐이다. `git diff --check 8dae92c..7a41942`는 exit 0이었다. V010-004
resource runtime, V010-002A/B skill lifecycle, V010-005/008 UI redesign,
auth, payment, deploy, release, publication 또는 broad cleanup은 없었다.

## 원 failed check의 독립 red-green

Red는 tracked source를 바꾸지 않고 `git archive 8dae92c`로 만든
`target/v010003-red-snapshot.vD3XmE`에 현재 HEAD의
`tests/v010_003_task_channels_process.rs`와 worker fixture만 overlay해 실행했다.
따라서 같은 assertion이 remediation 전 production과 현재 production을 직접
구분한다.

| finding | remediation 전 red | 현재 HEAD green과 source evidence |
|---|---|---|
| HIGH-001 live normalized progress와 artifact event | `provider_progress_is_canonical_while_worker_lives_and_artifacts_keep_attempt_provenance` exit 101, `normalized events were not visible while the worker lived`. `git grep`도 parent의 `artifact.created`를 `src/schemas.rs` enum/serde 4곳에서만 찾았다. | 같은 process test가 pass했다. `src/workers/mod.rs:292-317, 934-978`이 raw flush 뒤 complete public line을 live sink로 보내고, `src/run.rs:660-710`이 exact raw span을 canonical event로 쓴다. `src/run.rs:4497-4652`는 result/evaluation/checkpoint/handoff/worker-declared artifact에 exact attempt, worker, digest를 기록한다. |
| HIGH-002 redirect-superseded question과 stale answer | `redirect_closes_superseded_question_and_stale_answer_fails_without_mutation` exit 101, `redirect did not record a question.closed event`. | 같은 test가 pass했다. `src/state.rs:2503-2524`가 close event를 projection하고, `src/state.rs:3076-3113`이 stopped attempt의 open question을 redirect action causality로 닫는다. `src/run.rs:1183-1194`는 actionable open question이 없으면 fail closed한다. |
| HIGH-003 unavailable producer fallback | `unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet` exit 101, `prepared attempt does not match invocation`. | 같은 test가 pass했다. `src/run.rs:1212-1230`이 answer 기록 전에 actual ready worker를 resolve하고, worker가 바뀌면 selected worker 소유 explicit packet attempt를 만든다. |
| HIGH-004 redirect receipt 뒤 spawn 전 crash | `redirect_receipt_crash_retries_same_action_and_runs_stored_attempt_once` exit 101, `redirect did not stop after the terminal receipt`. Parent에는 stable crash boundary가 없었다. | 같은 test가 pass했다. `src/run.rs:1391-1431`은 stored prepared redirect attempt를 restart에서 찾고 receipt 뒤 failpoint를 제공한다. `src/state.rs:3227-3238`은 cancelled queue state를 pending continuation으로 복구한다. Test는 같은 action retry 뒤 attempt 2개 유지, redirect `worker.started` 정확히 1개, task Done을 확인한다. |
| MEDIUM-001 question/completion ordering | `needs_user_question_precedes_worker_completed_and_is_its_cause` exit 101, `asked.seq < completed.seq` assertion 실패. | 같은 test가 pass했다. `src/run.rs:934-972`는 needs_user result의 question을 먼저 기록하고 `worker.completed`가 exact asked event를 causation으로 참조하게 한다. |

현재 green 명령 `cargo test --test v010_003_task_channels_process -- --nocapture`는
14 passed, 0 failed, exit 0이었다. 위 다섯 test 외에도 native resume, text-only
explicit packet, raw overwrite 방어, verified PID redirect, decoy PID 방어,
independent drain, bounded index rebuild를 같은 실제 binary subprocess에서 실행했다.

## 필수 반례 직접 점검

| 반례 | 판정과 독립 evidence |
|---|---|
| attempt/raw overwrite | PASS. `tests/v010_003_task_channels_process.rs:943-991`이 0600 stdout/stderr/combined log와 sentinel create-new overwrite 거절을 확인했다. `attempt_capture_separates_stdout_stderr_and_refuses_overwrite`도 fresh exit 0이다. |
| stale answer | PASS. `tests/v010_003_task_channels_process.rs:1116-1178`이 redirect action의 exact `question.closed`, stale answer non-zero, attempt/event bytes 불변, receipt 부재를 확인했다. |
| false live redirect | PASS. `tests/v010_003_task_channels_process.rs:550-647`이 stop/checkpoint/reason/guidance와 `live_message_delivered: false`를, `tests/v010_003_task_channels_process.rs:710-832`가 mutable decoy PID 생존과 verified real worker 종료를 확인했다. `redirect_requires_observed_terminal_state_before_new_guidance_attempt`도 exit 0이다. |
| seq gap | PASS. `src/state.rs:2324-2366`은 session gap/conflict 뒤 mutation을 fail closed한다. `sequence_gap_and_collision_are_fail_closed` fresh exit 0이다. |
| index corruption | PASS. `src/state.rs:2614-2644`는 canonical projection에서 최대 128 event tail index를 다시 만든다. malformed-index unit test와 `tests/v010_003_task_channels_process.rs:833-895`의 deleted-index restart가 모두 exit 0이다. |
| duplicate action | PASS. `src/state.rs:2688-2950`은 answer의 stable id, digest, terminal receipt를 replay하고 다른 digest를 conflict로 거절한다. answer idempotency unit test와 redirect receipt crash process test가 모두 exit 0이다. |
| independent drain | PASS. `tests/v010_003_task_channels_process.rs:397-470`이 YARD-ASK NeedsUser 중 YARD-DRAIN의 worker, validation, completion과 Done을 확인하고 두 worker의 raw stream 비혼합 및 restart question 복원을 확인했다. |

## AC-001부터 AC-008 최종 판정

| AC | 판정 | exact source 또는 command evidence와 contradiction |
|---|---|---|
| AC-001 | **PASS** | `src/state.rs:2445-2611`은 `(intent_id, task_id)`당 하나의 deterministic channel을 session seq로 replay하고 attempt를 `attempt.prepared` 순서로 정렬한다. text continuation `tests/v010_003_task_channels_process.rs:246-395`, independent two-worker restart `tests/v010_003_task_channels_process.rs:397-470`, fallback worker `tests/v010_003_task_channels_process.rs:1182-1230`이 distinct attempt, worker identity, raw stream과 answer causality를 확인했다. |
| AC-002 | **PASS** | live sink는 `src/workers/mod.rs:292-317, 934-978`, canonical writer는 `src/run.rs:660-710`, artifact writer는 `src/run.rs:4497-4652`다. Process suite는 live worker 중 message/tool event의 exact stdout span, private reasoning 배제, 다섯 artifact role과 attempt provenance, text-only fallback, raw overwrite 거절을 확인했다. |
| AC-003 | **PASS** | `src/run.rs:1019-1090`은 question id, asked event/seq, attempt와 prior context를 기록한다. `src/state.rs:2688-2950`은 answer, action receipt와 새 attempt를 exact causality로 기록한다. stale close process test와 ordering test가 모두 green이다. |
| AC-004 | **PASS** | `src/run.rs:1212-1230`은 actual selected worker와 producer/session capability를 대조하고, `src/state.rs:2851-2880`은 exact session ref가 있을 때만 native resume를 선택한다. Native process test `tests/v010_003_task_channels_process.rs:474-549`, text-only test `tests/v010_003_task_channels_process.rs:246-395`, unavailable producer fallback test `tests/v010_003_task_channels_process.rs:1182-1230`이 모두 pass했다. |
| AC-005 | **PASS** | `src/cli.rs:1401-1464`가 run-owned process provenance를 검증하고 terminal observation 뒤에만 redirect action을 기록한다. `src/state.rs:2959-3240`은 reason, `live_message_delivered: false`, close/checkpoint, guidance와 새 attempt를 감사 가능하게 잇는다. stop, decoy PID, duplicate redirect, receipt crash tests가 모두 pass했다. |
| AC-006 | **PASS** | `tests/v010_003_task_channels_process.rs:397-470`의 actual parallel batch가 NeedsUser와 independent validation task를 함께 시작하고 후자를 Done까지 drain했다. `ready_set_includes_validation_tasks`와 dependency 관련 full-suite regressions도 exit 0이다. |
| AC-007 | **PASS** | session seq gap fail-closed `src/state.rs:2290-2393`, canonical replay와 attempt ordering `src/state.rs:2445-2611`, bounded index rebuild `src/state.rs:2614-2644`를 확인했다. Deleted/malformed index, 140-line compaction, raw/event bytes 보존, restart recovery가 unit/process에서 pass했다. |
| AC-008 | **PASS** | `docs/reviews/v010-003-dogfood.md`, `docs/reviews/v010-003-remediation.md`, 14개 actual-process fixture, 위 parent-red/HEAD-green, 그리고 이 별도 final review가 concurrency, contextual answer, native/explicit continuation, redirect, compaction, restart와 원 finding 폐쇄를 재검증했다. 현재 branch의 roadmap/round-1/repo-summary 부재는 MINOR-001 portability contradiction으로 남기되 behavior와 final 판정을 막는 high/medium 결함은 아니다. |

## Validation

2026-07-14 KST에 이 review run에서 fresh하게 실행했다.

| command | exit | 관찰 결과 |
|---|---:|---|
| parent production + current fixture의 finding별 5개 `cargo test` | 각 101 | 원 finding별 기대 red 5개 재현 |
| `cargo test --test v010_003_task_channels_process -- --nocapture` | 0 | 14 passed, 0 failed |
| 6개 반례 filter test | 각 0 | seq gap, malformed index, answer idempotency, redirect terminal gate, validation ready-set, raw overwrite 각각 1 passed |
| `cargo fmt --check` | 0 | output 없음 |
| `cargo clippy --all-targets --all-features -- -D warnings` | 0 | dev profile 완료, warning error 없음 |
| `cargo build` | 0 | dev profile 완료 |
| `cargo test` | 0 | unit 410, integration 3 + 1 + 2 + 8 + 1 + 37 + 14, 총 476 passed |

명령별 결과와 red 증상은
`.agents/runs/run-20260714-195009/validation.log`에 보존했다.

## Findings와 잔여 failed checks

Critical, major, high, medium finding과 failed check는 없다.

### MINOR-001 - evidence anchor portability

현재 feature branch는 ignored root roadmap, 다른 worktree의 1차 review, 존재하지 않는
`repo-summary.md`에 의존한다. 동일 checkout만 보존하면 최초 normative/review artifact의
원문 접근성이 떨어진다. 구체적 개선은 후속 evidence 정리 시 V010-003 normative excerpt와
1차 review를 tracked stable path에 보존하고, 생성되지 않은 repo-summary 링크는 실제
Yardlet 생성 artifact로 대체하는 것이다. 이 final review는 exact path, digest, finding,
red-green 결과를 함께 기록해 현재 판정의 재현성을 보완한다.
