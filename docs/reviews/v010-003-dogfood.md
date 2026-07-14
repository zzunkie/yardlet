# V010-003 process dogfood

## 범위와 기준

이 문서는 YARD-007의 제한 remediation 증거다. 규범 기준은
`docs/v0.10-shared-session-state-contract.md`의 task channel, attempt,
question/answer, redirect, replay 및 derived index 계약과 task packet의
AC-001부터 AC-005, SEC-001, SEC-002다.

현재 worktree에는 내부 문서인 `docs/yardlet-roadmap.md`와 run 시작 시점의
`evidence/repo-summary.md`가 없었다. 따라서 task packet에 보존된 exact failed
check와 공개 계약 문서를 기준으로 구현 및 검증 범위를 고정했다. 활성 intent,
queue 및 기존 run history는 수정하거나 fixture 입력으로 사용하지 않았다.

## Red

선행 production red는 `93cf06b`의 parent에서 다음 상태였다.

- `src/parallel.rs`가 `t.has_validation()` task를 ready set에서 제외했다.
- 당시 `cargo test ready_set_excludes_all_validation_tasks`는 그 잘못된 동작을
  고정했다.
- `.agents/task-channels/`는 ignore되지 않았고 attempt raw file은 일반 umask에서
  private mode를 보장하지 않았다.

`93cf06b`가 이 세 production red를 먼저 보수한 뒤, YARD-007은 누락된 실제-process
story를 테스트로 추가했다. fixture 구현 전 실행 명령은 다음과 같다.

```bash
cargo test --test v010_003_task_channels_process -- --nocapture
```

관찰 결과는 4 pass, 3 fail이었다.

- `native_resume_preserves_session_ref_and_answer_causality`: native session-bearing
  attempt를 만들지 못해 task가 `partial`이었다.
- `running_redirect_records_stop_checkpoint_guidance_and_restart_dedupe`: stop 이후
  continuation이 하나로 수렴하지 않고 attempt가 3개였다.
- `deleted_derived_index_rebuilds_from_canonical_facts_with_bounded_tail`: fixture가
  128개를 넘는 canonical event를 만들지 못했다.

이 red는 compile 또는 파일 부재 오류가 아니라 fake worker를 통과한 실제 Yardlet
subprocess state가 acceptance story를 충족하지 못한 결과였다.

## Fix

선행 `93cf06b`의 최소 production 수정은 현재 source에 다음과 같이 남아 있다.

- `src/parallel.rs`는 validation-bearing runnable task를 parallel ready set에
  포함한다.
- `src/run.rs`의 공통 finalization은 parallel worktree에서 validation을 실행하고
  `validation.started`, `validation.completed`를 attempt에 연결한다.
- `src/workers/mod.rs`는 attempt별 stdout/stderr를 create-new로 열고 existing path를
  거절하며 private file helper를 사용한다.
- `.gitignore`는 `/.agents/task-channels/`를 operational state로 제외한다.

YARD-007은 production schema나 state writer를 넓히지 않고 다음 fixture와 assertion만
추가했다.

- generic worker identity 두 개로 question task와 validation task를 분리했다.
- 같은 fake binary가 Codex built-in adapter 인자를 받아 stable
  `worker_session_ref`를 공개하고 resume invocation을 기록한다.
- long-running worker가 checkpoint를 쓴 뒤 실제 signal stop을 받고 redirect
  continuation을 실행한다.
- index task가 140개 public progress line을 내고 answer subprocess 전에 derived
  index를 삭제한다.
- exact `asked_event_id`, `asked_seq`, bounded prior position, action/event causality,
  raw stream identity 및 restart 뒤 attempt count를 직접 읽어 확인한다.

## Green 관찰 state

`tests/v010_003_task_channels_process.rs`의 7개 Unix subprocess test가 다음 상태를
확인한다.

1. `YARD-ASK`와 `YARD-DRAIN`이 같은 parallel batch에서 서로 다른 worker identity로
   시작한다. `YARD-ASK`는 `question.asked` 뒤 `needs_user`, `YARD-DRAIN`은
   `worker.started`, `validation.started`, `validation.completed`,
   `completion.recorded` 뒤 `done`이다.
2. text-only answer는 exact question event를 지목하고 `explicit_packet` attempt를
   만든다. 첫 stdout/stderr는 새 attempt가 생긴 뒤에도 byte 동일하다.
3. native worker의 첫 `worker.completed`가
   `11111111-1111-4111-8111-111111111111` session ref를 보존한다. answer가 만든 새
   `native_resume` attempt는 같은 ref, exact `user.answered` causation 및
   `act-native-answer`를 가진다. 실제 invocation도 `exec resume`과 exact ref를
   포함한다.
4. running redirect는 기존 attempt를 `cancelled`로 관찰하고 checkpoint, reason,
   guidance, `live_message_delivered: false`를 기록한 뒤 정확히 한 `redirect` attempt를
   만든다. 같은 action을 새 CLI process에서 다시 요청해도 새 attempt가 실행되지
   않는다.
5. 128개를 넘는 event의 index를 삭제한 뒤 answer CLI process가 canonical event와
   raw bytes를 덮어쓰지 않고 index를 재생성한다. `tail_events <= 128`,
   `event_count == canonical event count`, `highest_applied_seq == max(seq)`다.
6. `git check-ignore`는 task-channel 및 raw evidence를 ignore하지만
   `.agents/skills/fixture-probe/SKILL.md`는 ignore하지 않는다.
7. umask 022에서도 stdout, stderr, combined log가 모두 0600이다. 미리 존재하는
   다음 attempt stdout path는 `attempt raw stream already exists`로 거절되고 sentinel
   bytes가 유지된다.

Targeted green 명령은 다음과 같다.

```bash
cargo test --test v010_003_task_channels_process -- --nocapture
cargo test ready_set_includes_validation_tasks -- --nocapture
cargo test attempt_capture_separates_stdout_stderr_and_refuses_overwrite -- --nocapture
cargo test channel_replay_recovers_a_deleted_or_malformed_bounded_index -- --nocapture
cargo test redirect_requires_observed_terminal_state_before_new_guidance_attempt -- --nocapture
```

관찰 결과는 process test 7/7 pass, 관련 unit test 각 1/1 pass다. 이어서 실행한
`cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`,
`cargo build`, `cargo test`도 모두 exit 0이었다. 전체 test의 실제 관찰치는 unit
409/409, builtin bundle 3/3, Git finish process 1/1, state architecture 2/2,
V010-001 replay 8/8, serial Git finish process 1/1, V010-002 process 37/37,
V010-003 process 7/7 pass다. 명령별 결과는 현재 run의 `validation.log`에도 보존했다.
