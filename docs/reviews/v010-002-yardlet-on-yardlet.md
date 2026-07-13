# V010-002 Yardlet-on-Yardlet 증거

- 대상: 대화형 planning, immutable draft revision, semantic diff, explicit confirm, exact promotion
- 실행일: 2026-07-14 (Asia/Seoul)
- 실행 루트: `.agents/runs/run-20260714-011920/dogfood-v010-002/workspace`
- 실행 주체: 이 worktree에서 빌드한 실제 `yardlet`과 로컬 `codex` planning worker
- 원래 dogfood 판정: 세 content turn, accept, reject, undo, fresh-process 복원, explicit confirm을 거친 뒤 visible draft와 active intent/queue가 field와 digest 양쪽에서 일치했다.
- 보수 판정: terminal proposal, undo linkage, stripped provenance, stable prepared effect, immutable journal 검증, completed-active 일치, bounded process lock, runtime queue 경쟁, receipt/session/runtime envelope P0를 포함한 결정적 process test 31개가 통과했다. YARD-008 독립 재검토도 blocker 없이 통과했으며, V010-002 최종 완료 표시는 남은 queue task와 최종 review가 끝난 뒤에만 갱신한다.

## 1. 증거 경계

dogfood는 격리 workspace에서 실행했다. planning session, proposal, draft,
event, action receipt, active intent, active queue, activation은 모두 Yardlet
core가 `.agents/`에 기록했다. 이 문서를 만들기 위해 기존 운영 state를
수동 편집하지 않았다.

```text
.agents/planning-sessions/ses_20260713164132243292000_000001/
  session.yaml
  proposals/*.yaml
  drafts/*.yaml
  events/00000000000000000001.yaml ... 00000000000000000030.yaml
  actions/*.yaml
.agents/activations/cnf_20260713164851099828000_000002.yaml
.agents/intent-contract.yaml
.agents/work-queue.yaml
```

결정적 재현은 `tests/fixtures/v010_002_conversational_planning/scripts/run.sh`
가 담당한다. 실제 worker 응답의 문구는 달라질 수 있으므로 live dogfood와
결정적 process fixture를 분리해 증거로 남겼다.

### 1.1 roadmap task anchor projection

`docs/yardlet-roadmap.md`는 `.gitignore` 대상이라 run-owned review worktree에
자동 투영되지 않는다. reviewer가 parent checkout의 ignored 파일에 의존하지 않도록,
이 문서가 2026-07-14 parent SOT의 V010-002 task anchor를 다음과 같이 투영한다.
parent 파일 SHA-256은
`14be3c7bb787548cb598910019daacc6d64b83f7a15809ad877a1d22e6f96156`이다.

```text
### V010-002: Multi-turn conversational planning

**Intent:** Let a user and planner jointly produce a bounded intent and plan
without leaving Yardlet or rewriting the request from scratch.

In scope:

- `yardlet new` starts or resumes a planning session.
- The planning worker streams its investigation and messages into a planning
  channel.
- Each turn may propose a patch to summary, scope, out-of-scope, acceptance,
  ambiguity, tasks, dependencies, routing, and validation.
- Yardlet validates and records the patch, then shows a semantic before/after
  diff beside the conversation.
- The user can revise, undo/reject a proposal, answer a planning question, and
  explicitly confirm the final contract and queue.
- Planning history and confirmed provenance survive restart.

Out of scope:

- Letting free-form chat silently mutate an active running queue.
- Auto-confirming a plan merely because ambiguity is low.
- Replacing `yardlet goal` as the express path.

Acceptance:

- A user can exclude an adjacent surface, change acceptance, split/merge a task,
  and reorder dependencies through separate natural-language turns.
- Every accepted turn produces an inspectable structured diff and reason.
- Rejected proposals leave the draft unchanged.
- Confirmation promotes exactly the visible draft; no hidden re-plan occurs on
  the transition to execution.
- A fresh process can reopen the planning channel and continue it.

Dogfood proof:

- Plan one real Yardlet slice through at least three turns: initial request,
  scope correction, and acceptance correction. Confirm that the active intent
  and queue match the visible final draft exactly.
```

이 projection은 task anchor이며 completion claim이 아니다. parent SOT의
V010-002 완료 상태와 evidence link는 AC-001부터 AC-007까지의 독립 재검토가
모두 pass한 뒤에만 기록한다.

## 2. RED에서 GREEN까지

production code를 추가하기 전에 아래 process test 9개를 먼저 만들었다.

```bash
cargo test --test v010_002_conversational_planning_process
```

첫 실행은 `yardlet planning` subcommand가 없어 9/9가 동일하게 실패했고
exit 101이었다. 구현 뒤 같은 명령은 9/9 pass, exit 0이 되었다. 시나리오는
accept, reject, undo, stale head, restart-confirm, partial promotion,
running isolation, goal regression, multi-turn dogfood다.

### 2.1 promotion hardening RED에서 GREEN까지

독립 검토가 찾은 실패를 수정하기 전에 process scenario 5개를 추가했다.

```text
running 14 tests
9 passed; 5 failed; exit 101

failed:
- disposed_proposals_cannot_be_accepted_or_rejected_again
- undo_rejects_corrupt_current_or_parent_revisions
- stripped_modern_provenance_does_not_fall_back_to_legacy
- confirmation_requires_its_completed_matching_action_receipt
- interrupted_confirmation_replay_converges_without_duplicate_effects
```

실패 관찰은 rejected proposal 재수락, 손상 digest undo, modern-to-Legacy
우회, action receipt 누락 activation 실행, confirm prepare event 중복과 각각
일치했다. 구현 뒤 같은 명령은 기존 9개 journey를 포함해 14/14 pass,
exit 0이었다.

### 2.2 planning transaction hardening RED에서 GREEN까지

YARD-005에서는 완료된 snapshot을 수동으로 잘라 만든 crash 상태와 별도로,
실제 CLI process가 core write 직후 종료되는 scenario 5개를 추가했다.

RED에서 `event_seq_crash`는 crash hook이 없어 process가 종료되지 않았고 exit
101이었다. `concurrent_action`은 같은 head와 action id를 사용한 두 process가
draft revision 두 개를 만들어 `drafts/actions=2/1`로 실패했다. 이는 각각 event
저장과 `next_seq` 저장 사이의 recovery 부재, workspace single-writer 부재를 직접
재현했다.

GREEN에서는 다음 경계를 실제 process로 통과했다.

```text
running 19 tests
19 passed; 0 failed; exit 0

new transaction scenarios:
- event_write_before_next_seq_crash_replays_without_a_journal_collision
- actual_confirm_write_order_crashes_replay_without_manual_state_repair
- prepared_non_confirm_actions_replay_their_existing_effect_once
- unfinished_active_queue_and_corrupt_activation_block_confirm_without_clobber
- concurrent_cli_actions_converge_to_one_receipt_and_collision_free_journal
```

`YARDLET_TEST_PLANNING_CRASH` fixture hook가 실제 binary를 다음 위치에서 exit 86으로
종료했다.

- event file atomic create 직후, session `next_seq` CAS 전
- `draft.confirm.prepared` 직후, 기존 fresh-workspace queue를 둔 상태
- active intent atomic write 직후, queue write 전
- activation receipt atomic create 직후, session 및 action completion 전
- `draft.confirmed` effect 직후, action receipt completion 전
- accept, reject, undo, answer effect 직후와 rejected receipt effect 직후

재실행은 수동 YAML 보정 없이 같은 action id를 사용했다. 각 action은 같은 terminal
receipt와 정확히 하나의 typed effect event로 수렴했고, confirm은 exact draft parity와
valid activation을 복원했다. 두 동시 CLI process는 모두 같은 canonical accept 결과를
반환했으며 revision 1개, receipt 1개, action effect 종류별 event 1개와 중복 없는 seq를
남겼다.

### 2.3 YARD-007 transaction blocker RED에서 GREEN까지

YARD-007은 수동 YAML로 만든 baseline을 사용하지 않고 실제 `yardlet init` 상태에서
confirm write order를 재현하도록 fixture를 교체했다. 구현 전에 추가한 여섯 process
scenario의 RED는 다음 fail-open을 직접 드러냈다.

- `accept_after_revision_write` crash hook이 없어 process가 종료되지 않았다.
- completed confirm replay가 이후 express goal activation을 무시하고 오래된 activation을
  반환했다.
- seq gap이 있는 event journal이 정상 session처럼 열렸다.
- workspace lock과 runtime queue 경쟁 fixture의 stable barrier가 존재하지 않았다.

GREEN에서는 전체 process suite가 다음 결과로 수렴했다.

```text
running 25 tests
25 passed; 0 failed; exit 0

new transaction scenarios:
- accept_revision_write_crash_replays_from_the_prepared_exact_effect
- unresolved_prepared_action_interlocks_every_other_session_mutation
- journal_corruption_fails_closed_for_every_identity_and_cardinality_rule
- completed_confirm_replay_requires_its_activation_to_still_be_current
- workspace_mutation_lock_has_a_stable_barrier_and_bounded_timeout
- runtime_queue_transition_wins_atomically_over_concurrent_confirm
```

accept는 immutable revision을 쓰기 전에 prepared receipt에 stable revision/result id와
effect event의 exact id, type, payload, digest를 CAS한다. revision 저장 직후 exit 86으로
종료해도 같은 action replay가 revision 하나, event 하나, 같은 completed receipt로
수렴한다. 같은 session에 unresolved prepared action이 있으면 answer, accept, reject,
undo, confirm, new session mutation은 `planning_action_in_progress`로 닫히며, 해당 action
owner의 replay만 먼저 끝낼 수 있다.

event journal은 seq 1부터 N까지의 연속성, canonical filename과 내부 seq/session/event
identity, unique event id와 exact payload, action/type cardinality, `next_seq` 상한을 모두
검증한다. gap, duplicate id, multi-match, payload mismatch, filename/seq mismatch,
session mismatch, empty event id, `next_seq` ahead는 session을 열기 전에 fail-closed한다.
completed confirm replay도 receipt의
activation이 현재 active intent와 queue의 confirmation/session/head/digest와 정확히
일치할 때만 같은 결과를 반환한다.

`planning.lock`은 planning 전용 임시 lock이 아니라 workspace mutation lock이다.
`LOCK_EX|LOCK_NB`와 bounded timeout을 사용하고, `EINTR`, `EAGAIN`, `EWOULDBLOCK`만
재시도하며, descriptor는 `CLOEXEC`로 worker process에 넘기지 않는다. 내부 transaction
helper는 이미 획득한 guard를 받으므로 재진입하지 않는다. crash와 barrier hook는 debug
build에서만 활성이고 release binary에서는 같은 환경 변수를 주어도 accept가 끝까지
완료된다.

confirm뿐 아니라 `add`, run의 Queued-to-Running 전이, finalize, orphan recovery의 queue
load-mutate-save도 같은 lock과 raw-byte CAS 경계를 사용한다. stable barrier가 있는 두
process fixture는 run과 confirm, add가 경쟁할 때 stale confirm은 거절되고 runtime state와
receipt-backed user add가 모두 보존됨을 확인한다. activated queue는 confirmed 당시 immutable
`materialized_queue`를 provenance digest 경계로 보존하고, confirm 이후 task는 빈
materialization marker와 별도 immutable origin receipt로 append한다.

### 2.4 YARD-008 independent audit P0 RED에서 GREEN까지

production 변경 전에 black-box process scenario 5개를 추가했다. 첫 RED는 completed v2
receipt에서 `effect_event_id`를 제거한 replay가 표준 `planning_receipt_corrupt` 계약으로
닫히지 않아 exit 101이 된 실제 결과였다. runtime recovery 진입도 title이 변조된 active
queue를 정상 상태로 취급해 별도 RED로 재현됐다.

GREEN에서는 기존 25개와 새 5개를 합친 process suite가 다음 결과로 수렴했다.

```text
running 31 tests
31 passed; 0 failed; exit 0

new audit scenarios:
- v2_terminal_receipts_require_the_exact_immutable_effect_event
- persisted_session_storage_identity_and_journal_are_fail_closed
- activated_runtime_envelope_allows_only_task_state_changes
- production_queue_writers_are_guarded_by_the_workspace_transaction
- concurrent_express_goals_are_one_transaction_each
```

schema-version 2 completed/rejected receipt는 effect event id, type, digest, exact payload를
모두 요구한다. receipt payload의 canonical JSON byte와 FNV-1a digest는 같은 immutable
journal event와 일치해야 하며 actor, target, result, parent, message 또는 양쪽 exact event를
함께 위조해도 semantic linkage가 맞지 않으면 `planning_receipt_corrupt`로 active state를
바꾸지 않고 거절한다. schema version 1은 effect metadata가 없는 기존 receipt를 위한
명시적 compatibility branch로만 남는다.

persisted session은 events directory 부재, 빈 journal의 앞선 `next_seq`, session path/id
불일치, latest pointer/session identity 불일치를 정상 projection으로 열지 않는다. 반대로
events directory가 존재하고 artifact가 없으며 `next_seq: 1`인 새 session 초기 상태만
첫 event append를 위해 허용한다.

activated runtime queue는 confirmed task의 id와 상대 순서를 고정하고 worker/model/effort,
dependency, skill/capability, scope, acceptance, goal/validation/approval 등 실행 계약을
materialized queue와 비교한다. typed scheduler metadata는 별도 runtime 변화로 허용한다.
process fixture는 title, scope, worker, risk 변조가 모든 진입점에서 canonical byte 불변으로
실패하고, receipt-backed `add`, `defer`, `revive`, `Partial`에서 `Done` 전이는 parity를
유지함을 검사한다.

CLI, parallel, UI, run과 recovery의 production queue mutation은 guard를 받은 locked writer와
raw-byte CAS를 사용한다. compatibility `save_queue` wrapper도 내부에서 같은 workspace lock을
획득한다. express goal은 create/propose/accept/confirm 전체를 하나의 outer lock에서 실행하며,
stable barrier를 둔 두 process가 각각 완결된 session과 exact active parity를 남겼다.

### 2.5 독립 감사 FAIL 후 직접 폐쇄

YARD-008 자체 검증 뒤 별도 read-only auditor가 실제 구버전 파일과 누락 entrypoint를 다시
실행해 네 가지 P0를 찾았다. digest가 없던 schema v1 event replay는 duplicate
`action.completed`를 추가했고, strict whole-queue comparator는 정상 `add`, `defer`, `revive`를
막았다. 또 TUI recovery는 activation 오류를 표시하기 전에 active state를 바꿨고,
`status`, `packet`, `approve`는 forged queue를 trusted input으로 사용했다.

직접 수정은 다음 black-box 기준으로 닫았다.

- schema v1 completed/rejected replay는 receipt와 journal byte를 바꾸지 않고, v1 receipt는
  schema v1의 단일 digestless effect에만 연결된다.
- confirmed base task는 삭제, 재정렬, 실행 계약 변조가 불가능하다. post-confirm user add와
  worker follow-up은 append-only이며 `runtime-task-receipts/`의 exact contract digest가 있어야 한다.
- 정상 confirmed queue에서 `add`, `defer`, `revive`와 run/finalize 경쟁 add가 성공하고,
  immutable materialized queue와 activation digest는 그대로다.
- Snapshot, status, TUI startup recovery, packet, CLI/TUI approval은 공통 activation gate를
  side effect보다 먼저 실행한다. corrupt state에서는 packet, approval, archive, consumed marker,
  intent, queue가 모두 무변경이다.

## 3. 실제 세 turn

초기 요청은 production runtime 변경을 제외하고 V010-002 proof 문서,
결정적 process fixture, 두 README만 계획하는 저위험 slice였다.

| turn | 사용자 입력과 action | 저장 결과 |
|---:|---|---|
| 1 | 초기 요청을 실제 Codex로 planning한 뒤 proposal accept | `prp_20260713164439129614000_000004`를 `drv_20260713164446251011000_000002`로 accept. active intent와 queue는 그대로 유지 |
| 2 | allowed path를 정확히 제한하는 scope correction 뒤 proposal reject | `prp_20260713164610725475000_000004` reject. visible head는 turn 1 revision 그대로 유지 |
| 3 | 세 turn, accept/reject/undo, restart, confirm, field/digest parity를 acceptance에 추가한 proposal accept 후 undo | `prp_20260713164840156315000_000004`를 `drv_20260713164850875518000_000002`로 revise한 뒤 undo해 turn 1 revision 복원 |

undo 뒤 별도 `yardlet planning show --json` process를 실행해 session과
visible head가 복원됨을 확인했다. 그 fresh process에서 복원한 head를
`--expected-head`로 넘겨 `dogfood-confirm-final` action을 명시적으로
confirm했다. confirm action을 같은 action id로 한 번 더 호출했을 때 같은
activation을 반환해 idempotent recovery도 확인했다.

## 4. ordered channel과 restart 결과

최종 projection은 다음 값을 보고했다.

```json
{
  "session_id": "ses_20260713164132243292000_000001",
  "lifecycle": "confirmed",
  "current_head": "drv_20260713164446251011000_000002",
  "confirmation_id": "cnf_20260713164851099828000_000002",
  "next_seq": 31,
  "channel_turn_count": 3,
  "rejected_proposal_count": 1,
  "undo_count": 1,
  "exact_active_parity": true
}
```

저장 event는 seq 1부터 30까지 빈틈없이 이어졌다. content event는
`user.message` 3개, `worker.message` 3개, `draft.proposed` 3개였고,
`draft.accepted`, `draft.rejected`, `draft.revised`, `draft.undo`,
`draft.confirm.prepared`, `draft.confirmed`와 각 action receipt event가 같은
session에 기록됐다.

## 5. exact field와 digest parity

독립 검증은 active YAML에서 activation provenance만 제거한 intent와 task
materialization provenance만 제거한 queue를 visible draft의 두 객체와
구조적으로 비교했다. 이어 같은 FNV-1a JSON digest 경계에서 visible draft와
provenance 포함 active 문서 두 개를 receipt와 비교했다.

```json
{
  "exact_fields": true,
  "exact_active_parity": true,
  "draft_digest": "fnv1a64:2cc0a590c02250bf",
  "intent_digest": "fnv1a64:70e294b9ed74a88f",
  "queue_digest": "fnv1a64:d8b4c2163123269a",
  "confirmation_id": "cnf_20260713164851099828000_000002"
}
```

`draft_content_digest`는 화면에 보인 draft 전체의 digest다.
`intent_digest`는 confirmation/session/revision linkage를 포함한 실제 active intent의
digest다. `queue_digest`는 같은 provenance와 confirm 당시 immutable
`materialized_queue`를 묶은 digest이며 이후 runtime task state 전이와 분리된다. 이 세
값은 각기 올바른 저장 경계를 검증하며 서로 대체하지 않는다.

## 6. 재현 명령

결정적 전체 journey는 네트워크나 provider API 없이 다음처럼 재현한다.

```bash
cargo build
cargo test --test v010_002_conversational_planning_process
evidence="$(mktemp -d)"
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" dogfood
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" terminal_proposal
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" undo_integrity
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" stripped_modern
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" activation_action_linkage
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" confirm_crash_replay
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" event_seq_crash
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" confirm_write_order_crash
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" action_effect_crash
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" active_queue_guard
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" concurrent_action
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" accept_revision_crash
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" prepared_action_interlock
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" journal_corruption
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" completed_active_mismatch
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" lock_timeout
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" runtime_queue_confirm_race
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" receipt_v2_integrity
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" session_storage_integrity
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" runtime_envelope
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" runtime_origin_contract
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" writer_inventory
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" express_concurrency
cargo build --release
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/release/yardlet "$evidence" release_hook_disabled
```

live planning은 격리 workspace에서 로컬 subscription CLI worker를 사용해
다음 action 순서로 실행했다.

```bash
yardlet new "<initial request>" --worker codex
yardlet planning accept <proposal-1> --expected-head none --action-id dogfood-accept-1
yardlet planning answer "<scope correction>" --expected-head <revision-1> --action-id dogfood-answer-2 --worker codex
yardlet planning reject <proposal-2> --expected-head <revision-1> --action-id dogfood-reject-2
yardlet planning answer "<acceptance correction>" --expected-head <revision-1> --action-id dogfood-answer-3 --worker codex
yardlet planning accept <proposal-3> --expected-head <revision-1> --action-id dogfood-accept-3
yardlet planning undo --expected-head <revision-2> --action-id dogfood-undo-3
yardlet planning show --json
yardlet planning confirm --expected-head <revision-1> --action-id dogfood-confirm-final
yardlet planning show --json
```

## 7. 안전 경계

- confirm 전에는 active intent와 queue가 바뀌지 않았다.
- reject와 stale-head action은 visible head를 바꾸지 않는다.
- incomplete activation 또는 confirmation/session/revision/digest/task linkage
  변조는 `unconfirmed_or_inconsistent`로 실행을 닫는다.
- accepted 또는 rejected proposal은 terminal이며 새 action으로 재사용할 수 없다.
- undo는 current revision digest와 parent의 same-session identity, digest,
  accepted event linkage를 검증한 뒤에만 head를 바꾼다.
- modern activation의 linkage를 전부 제거해도 durable origin marker가 Legacy
  fallback을 막는다.
- activation은 같은 session의 matching completed confirm action receipt와
  request digest가 모두 맞아야 runnable이다.
- confirm prepare 뒤 snapshot 전, intent-only, intent/queue 뒤 activation 전,
  activation 뒤 action completion 전의 replay는 각 effect event 하나와 completed
  receipt 하나로 수렴한다.
- workspace queue와 planning mutation은 bounded kernel single-writer lock과 raw-byte
  CAS 아래 수행되며 immutable revision/event/action create는 no-clobber이고
  session/action transition은 CAS다.
- event 저장 뒤 `next_seq` 저장 전 crash는 journal의 실제 최대 seq에서 cursor를
  복구하며 기존 event를 덮어쓰거나 중복 기록하지 않는다.
- journal load는 continuous seq, filename/embedded identity, unique exact payload,
  action/type cardinality, `next_seq` 상한을 모두 검증한다.
- accept prepared receipt는 immutable revision 저장 전에 stable result id와 exact effect
  event id/type/payload/digest를 CAS한다. terminal receipt는 이 예약값과 일치해야 한다.
- 같은 session의 unresolved prepared action은 owner replay를 제외한 다른 session
  mutation을 `planning_action_in_progress`로 차단한다.
- completed confirm replay는 receipt activation과 현재 active
  confirmation/session/head/digest가 정확히 같을 때만 성공한다.
- `planning.lock`은 `LOCK_EX|LOCK_NB`, bounded timeout, contention retry, `CLOEXEC`를
  사용하며 debug crash/barrier hook는 release binary에서 비활성이다.
- run, add, finalize, orphan recovery, confirm은 queue load-mutate-save를 같은 lock/CAS
  경계에서 수행하고 confirmed materialization과 mutable runtime state를 분리한다.
- v2 terminal action receipt의 effect id/type/digest/exact payload는 immutable journal event의
  canonical byte와 digest에 일치해야 한다. 실제 v1 digestless event replay는 기존 journal을
  변경하지 않으며 schema v1의 단일 effect에만 연결된다.
- persisted session의 journal directory와 session path/latest pointer identity는 필수다.
- activated current queue의 confirmed base task는 materialized queue와 id/order 및 immutable
  실행 field가 같다. typed scheduler metadata와 receipt-backed append-only runtime task만
  허용된다. runtime task의 committed ordinal은 존재와 순서를 고정하고, hard `runs_before`
  dependency와 stale decision capability clear는 typed receipt replay로만 허용된다. origin,
  commit, receipt 누락이나 계약 변조는 모든 entrypoint에서 active byte 불변으로 거절된다.
- Snapshot/status/TUI startup, packet, CLI/TUI approval도 같은 activation gate를 side effect보다
  먼저 실행한다.
- express goal create/propose/accept/confirm은 하나의 outer workspace transaction이다.
- Queued, Running, NeedsUser, Partial, Blocked가 남은 active queue는 새 confirm으로
  교체되지 않으며 active intent와 queue bytes가 그대로 남는다.
- activation guard parse 또는 linkage 오류는 inactive로 fail-open하지 않고 호출자에게
  `unconfirmed_or_inconsistent` 오류로 전파된다.
- confirmed 또는 running queue에 대한 free-form planning mutation은 거절된다.
- `yardlet goal` 기본 및 verifier 포함 express path는 planning worker 없이
  동작하면서 draft와 confirmation provenance를 기록한다.
- V010-003 이상의 task channel, runtime resource, TUI, adapter, GUI 범위는
  이 구현에서 확장하지 않았다.

## 8. YARD-008 및 독립 감사 폐쇄 fresh 검증 기록

최종 source와 fixture를 기준으로 2026-07-14에 다음 명령을 다시 실행했다.

독립 재감사는 실제 schema v1 completed/rejected replay의 receipt와 journal raw byte가
재시도 전후 동일함을 확인했다. receipt 누락, origin 위조, task contract 위조,
confirmation marker 위장은 `status`, `packet`, `approve`, `recover`에서 모두 exit 1로
거절됐고 canonical state digest는 불변이었다. 깨진 queue와 더 최신 unconsumed planning
result가 함께 있는 실제 PTY startup도 terminal 진입 전에 실패했으며 archive, approval,
consumed marker를 만들지 않았다. 최종 판정은 `PASS`, blocker 0개다.

그 뒤 production runtime mutator 교차검토에서 `runs_before`, stale capability migration,
confirmed task skill 재투영, runtime task 삭제/재정렬 회귀를 추가로 재현했다. 구현 전 두
정상 경로는 `active_runtime_envelope_mismatch` RED였고 삭제/재정렬은 잘못된 parity true였다.
수정 후 origin receipt의 committed ordinal inventory, exact dependency overlay,
typed capability migration receipt, newly-ingested-only skill projection으로 모두 GREEN이 됐다.
queue CAS 실패 전에는 decision conversation과 transition을 쓰지 않으며, receipt 준비 뒤
queue CAS와 commit 사이 crash는 exact after-queue digest로 commit marker만 복구한다.
queue CAS 전에 남은 well-formed uncommitted receipt는 canonical queue에 effect가 없고 commit
marker도 없을 때만 이후 retry가 대체한다. committed receipt나 이미 queue에 반영된 effect는
대체하지 않고 fail closed 또는 exact commit 복구로 수렴한다. 과거 conversation은 현재 queue의
typed interaction/capability receipt보다 먼저 pending question을 선점할 수 없다.

```text
cargo fmt --check
  exit 0
cargo clippy --all-targets --all-features -- -D warnings
  exit 0
cargo build
  exit 0
cargo test -q
  exit 0
  unit 392 passed
  builtin bundle 3 passed
  git-finish process 1 passed
  state architecture 2 passed
  V010-001 replay 8 passed
  serial Git finish process 1 passed
  V010-002 process 31 passed
cargo build --release
  exit 0
bash tests/fixtures/v010_002_conversational_planning/scripts/run.sh \
  target/release/yardlet <fresh-evidence-dir> release_hook_disabled
  status passed
```

README parity도 fresh 확인했다. 두 파일은 같은 순서의 section 19개, `yardlet` command
row 34개, 같은 canonical state tree entry를 가지며 `README.md`와 `README.ko.md` 모두
em dash가 0개다. 필수 read anchor로 지정된
`.agents/runs/run-20260714-035949/evidence/repo-summary.md`는 이 worker가 시작할 때 존재하지
않았으며, source와 test 검증에는 이를 정상 증거로 가정하지 않았다.
