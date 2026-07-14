# V010-003 1차 review failed checks 제한 remediation

## 기준과 범위

이 문서는 YARD-009가 `docs/reviews/v010-003-independent-review-round-1.md`의
HIGH-001부터 HIGH-004와 MEDIUM-001만 재현하고 보수한 증거다. 규범 기준은
`docs/v0.10-shared-session-state-contract.md`의 event, action, ordering,
persistence, replay 계약과 root checkout의 내부 roadmap
`docs/yardlet-roadmap.md:696-752`다.

현재 remediation worktree의 HEAD에는 1차 review 문서와 roadmap 문서가 없었다.
1차 review 문서는 같은 저장소의 독립 review worktree에서, roadmap은 root
checkout에서 읽기 전용으로 확인했다. task packet이 지정한
`.agents/runs/run-20260714-192013/evidence/repo-summary.md`도 run 시작 시 존재하지
않았다. 활성 intent, queue 또는 기존 run history는 수정하거나 fixture 입력으로
사용하지 않았다.

Production 변경은 `src/workers/mod.rs`, `src/run.rs`, `src/state.rs`와 additive
`src/schemas.rs`에 한정했다. Process 증거는
`tests/v010_003_task_channels_process.rs`와
`tests/fixtures/v010_003_task_channels/worker.sh`만 확장했다.

## HIGH-001: live normalized progress와 artifact event

### Red

실제 Codex adapter-shaped fixture가 공개 message와 tool JSON line을 쓴 뒤 3초간
살아 있도록 만들고 다음 명령을 실행했다.

```bash
cargo test --test v010_003_task_channels_process \
  provider_progress_is_canonical_while_worker_lives_and_artifacts_keep_attempt_provenance \
  -- --nocapture
```

수정 전 strict worker PID 생존 조건에서 다음과 같이 실패했다.

```text
normalized events were not visible while the worker lived
test result: FAILED. 0 passed; 1 failed
```

별도 artifact assertion까지 진행한 선행 실행은 다음 결함도 직접 확인했다.

```text
missing artifact role worker_result: {}
```

### Fix

- `src/workers/mod.rs:292-327`은 reader별 complete line을 raw file flush 뒤
  normalize하고 누적 byte offset을 exact `raw_ref`에 반영한다.
- `src/workers/mod.rs:672-702`는 기존 `spawn_attempt` compatibility를 유지하면서
  canonical sink를 받는 additive `spawn_attempt_with_sink`를 제공한다.
- `src/run.rs:660-712`는 worker 공개 event를 `src/state.rs` writer를 통해 즉시
  append한다. 같은 raw span의 duplicate는 payload가 같을 때만 idempotent하다.
- Codex 및 Claude normalizer의 reasoning, thinking, analysis 배제 규칙은 유지했다.
- `src/run.rs:4497-4663`은 `result.json`, `evaluation.json`, `checkpoint.md`,
  `handoff.md`와 result가 명시한 실제 created/modified file을 content digest,
  role, producer worker와 exact attempt를 가진 `artifact.created`로 기록한다.
  worker-declared path는 producer root 밖으로 해석되거나 실제 file이 아니면
  등록하지 않는다.

### Green

동일 process test는 worker PID가 살아 있는 동안 `worker.message`, `tool.started`,
`tool.completed`를 읽었고, 각 raw span을 stdout bytes에 다시 대조했다. 종료 뒤에는
`worker_result`, `evaluation`, `checkpoint`, `handoff`, `worker_declared` 다섯 role이
같은 attempt provenance와 non-empty digest를 가짐을 확인했다. Private reasoning은
normalized payload에 없었다.

## HIGH-002: redirect-superseded question과 stale answer

### Red

```bash
cargo test --test v010_003_task_channels_process \
  redirect_closes_superseded_question_and_stale_answer_fails_without_mutation \
  -- --nocapture
```

수정 전 결과는 다음과 같았다.

```text
redirect did not record a question.closed event
test result: FAILED. 0 passed; 1 failed
```

### Fix

- `src/schemas.rs:1681-1763`에 additive `question.closed` event vocabulary를
  추가했다.
- `src/state.rs:2503-2522`는 canonical close event를 replay해 answer가 없는
  question만 `Closed`로 projection한다.
- `src/state.rs:3076-3140`은 redirect 대상 attempt의 모든 unanswered open
  question을 같은 `action_id`와 연속 causation으로 먼저 닫고, checkpoint 및 새
  attempt가 그 close fact 뒤를 잇게 한다.
- `src/run.rs:1173-1233`은 channel에 question history가 있지만 actionable open
  question이 없으면 legacy fresh run으로 떨어지지 않고 `question_closed`로
  fail closed한다.

### Green

같은 actual-process test는 q1 redirect, q2 answer, task Done 뒤 q1 stale answer를
실행했다. q1 close event의 action은 exact redirect action이었고 stale answer는
non-zero로 끝났다. Attempt, event, terminal receipt bytes는 호출 전후 동일했다.

## HIGH-003: unavailable producer의 fallback continuation

### Red

```bash
cargo test --test v010_003_task_channels_process \
  unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet \
  -- --nocapture
```

Worker A가 question을 만든 뒤 A command를 unavailable하게 하고 ready worker B를
fallback으로 둔 수정 전 결과는 다음과 같았다.

```text
yardlet: prepared attempt does not match invocation
test result: FAILED. 0 passed; 1 failed
```

### Fix

`src/run.rs:1173-1233`의 answer preparation이 현재 worker readiness와 fallback
policy를 먼저 resolve한다. 선택 worker가 producer와 같고 exact session ref와 native
capability가 있을 때만 native resume를 유지한다. Worker가 바뀌면 selected worker
소유 `explicit_packet` attempt를 answer event와 action causality로 기록한다.

### Green

같은 process test에서 B 소유 `explicit_packet` attempt가 exact
`act-fallback-answer` causality로 실행돼 task가 Done이 됐다. 기존
`native_resume_preserves_session_ref_and_answer_causality`도 함께 통과해 same-worker
native path가 유지됨을 확인했다.

## HIGH-004: redirect receipt 이후 spawn 이전 crash recovery

### Red

```bash
cargo test --test v010_003_task_channels_process \
  redirect_receipt_crash_retries_same_action_and_runs_stored_attempt_once \
  -- --nocapture
```

수정 전에는 stable crash injection 경계가 없어 redirect가 그대로 완료됐고 다음
assertion에서 실패했다.

```text
redirect did not stop after the terminal receipt
test result: FAILED. 0 passed; 1 failed
```

### Fix

- `src/run.rs:1391-1412`는 모든 prepared answer/redirect continuation을 restart에서
  찾는다. Debug fixture 환경의 `YARDLET_TEST_CRASH_AFTER_REDIRECT_RECEIPT=1`은
  terminal receipt와 prepared attempt 확인 뒤 새 run directory 또는 worker spawn
  전에만 failpoint를 연다.
- `src/state.rs:3224-3240`은 cancelled run이 Queued로 돌아온 경우 terminal redirect
  receipt를 반환하기 전에 task를 pending continuation 상태로 두어 same action CLI
  retry가 기존 precondition을 통과하게 한다.
- Retry는 `redirect_task` terminal receipt를 먼저 replay하고 `run_next`가 stored
  attempt id를 그대로 사용한다. 새 attempt id를 만들지 않는다.

### Green

Process test는 live worker를 실제 signal로 취소하고 terminal receipt 뒤 crash를
주입했다. Restart한 새 CLI process가 같은 action id를 재요청한 뒤 attempt 수 2개를
유지했고, redirect attempt의 `worker.started`는 정확히 1개였으며 task는 Done으로
수렴했다. 기존 verified PID, decoy PID, `live_message_delivered: false` tests도 함께
유지됐다.

## MEDIUM-001: question.asked와 worker.completed ordering

### Red

```bash
cargo test --test v010_003_task_channels_process \
  needs_user_question_precedes_worker_completed_and_is_its_cause \
  -- --nocapture
```

수정 전 결과는 다음과 같았다.

```text
assertion failed: number(asked, "seq") < number(completed, "seq")
test result: FAILED. 0 passed; 1 failed
```

### Fix

`src/run.rs:931-952`는 imported `result.json`의 needs_user question을 terminal event
전에 해석한다. `record_result_question`은 exact asked event를 반환하고
`worker.completed(needs_user)`는 그 event id를 직접 causation으로 사용한다.
Finalization의 기존 호출은 같은 attempt와 text를 idempotently 재사용한다.

### Green

같은 process test가 `question.asked.seq < worker.completed.seq`, completed result
`needs_user`, completed causation이 exact asked event id임을 모두 확인했다.

## 전체 반례와 AC trace

| 항목 | 구현자 확인 근거 |
|---|---|
| AC-001 | fallback B actual-process test가 distinct B attempt, answer action/event causality와 completion을 확인했다. |
| AC-002 | live PID test가 exact raw spans와 공개 message/tool event를, 종료 뒤 artifact role과 attempt provenance를 확인했다. Raw overwrite 및 0600 process test도 유지됐다. |
| AC-003 | q1 close와 stale no-mutation test, needs_user ordering test가 exact question/action/channel position을 확인했다. |
| AC-004 | 기존 native resume, same-worker explicit packet과 새 unavailable producer fallback test가 모두 통과했다. |
| AC-005 | 기존 verified stop/redirect audit와 새 receipt crash/same action retry가 exactly-once stored attempt를 확인했다. |
| AC-006 | `parallel_independent_task_records_validation_completion`이 NeedsUser와 독립 validation task drain을 확인했다. |
| AC-007 | 기존 seq gap fail-closed unit test와 deleted/malformed index replay, bounded tail process test가 유지됐다. |
| AC-008 | 이 remediation과 14개 actual-process fixture까지는 작성됐다. 최종 AC-001부터 AC-008 판정은 remediation 작성과 분리된 read-only review run의 책임이다. |

Attempt/raw overwrite, false live redirect, seq gap, index corruption, duplicate action과
independent drain의 기존 반례는 전체 regression suite에 남아 있다. 이번 diff에는
V010-004 resource runtime, V010-002A/B skill lifecycle, V010-005/008 UI redesign,
provider-private reasoning 수집, auth, payment, deploy, publication 또는 broad cleanup이
없다.

## Green gate

Finding별 narrow 명령 5개는 각각 1 passed, 0 failed였다. 확장된 process suite는
다음 명령에서 14 passed, 0 failed였다.

```bash
cargo test --test v010_003_task_channels_process -- --nocapture
```

2026-07-14 최종 fresh gate 결과는 다음과 같다.

| 명령 | 결과 |
|---|---|
| `cargo fmt --check` | exit 0 |
| `cargo clippy --all-targets --all-features -- -D warnings` | exit 0 |
| `cargo build` | exit 0 |
| `cargo test --test v010_003_task_channels_process -- --nocapture` | exit 0, 14 passed |
| `cargo test --quiet` | exit 0, 476 passed across 8 test binaries |
| `git diff --check` | exit 0 |

명령별 실제 출력과 장기 process test의 count는 이 run의 `validation.log`에 함께
보존한다.
