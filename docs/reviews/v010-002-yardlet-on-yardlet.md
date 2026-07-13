# V010-002 Yardlet-on-Yardlet 증거

- 대상: 대화형 planning, immutable draft revision, semantic diff, explicit confirm, exact promotion
- 실행일: 2026-07-14 (Asia/Seoul)
- 실행 루트: `.agents/runs/run-20260714-011920/dogfood-v010-002/workspace`
- 실행 주체: 이 worktree에서 빌드한 실제 `yardlet`과 로컬 `codex` planning worker
- 원래 dogfood 판정: 세 content turn, accept, reject, undo, fresh-process 복원, explicit confirm을 거친 뒤 visible draft와 active intent/queue가 field와 digest 양쪽에서 일치했다.
- 보수 판정: terminal proposal, undo linkage, stripped provenance, confirm action linkage, 실제 write-order crash, non-confirm prepared-effect replay, active queue no-clobber, 두 CLI process 경쟁을 포함한 결정적 process test 19개가 통과했다. V010-002 최종 완료 표시는 독립 재검토 뒤에만 갱신한다.

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
`intent_digest`와 `queue_digest`는 confirmation/session/revision 및 task별
materialization linkage를 포함한 실제 active 문서의 digest다. 이 세 값은
각기 올바른 저장 경계를 검증하며 서로 대체하지 않는다.

## 6. 재현 명령

결정적 전체 journey는 네트워크나 provider API 없이 다음처럼 재현한다.

```bash
cargo build
cargo test --test v010_002_conversational_planning_process
evidence="$(mktemp -d)"
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" dogfood
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" terminal_proposal
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" undo_integrity
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" stripped_modern
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" activation_action_linkage
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" confirm_crash_replay
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" event_seq_crash
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" confirm_write_order_crash
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" action_effect_crash
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" active_queue_guard
tests/fixtures/v010_002_conversational_planning/scripts/run.sh target/debug/yardlet "$evidence" concurrent_action
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
- workspace planning mutation은 kernel single-writer lock 아래 수행되며 immutable
  revision/event/action create는 no-clobber이고 session/action transition은 CAS다.
- event 저장 뒤 `next_seq` 저장 전 crash는 journal의 실제 최대 seq에서 cursor를
  복구하며 기존 event를 덮어쓰거나 중복 기록하지 않는다.
- terminal action receipt는 action kind/status와 effect event type을 typed 값으로
  저장하고 exact event id 및 request digest를 연결한다.
- Queued, Running, NeedsUser, Partial, Blocked가 남은 active queue는 새 confirm으로
  교체되지 않으며 active intent와 queue bytes가 그대로 남는다.
- activation guard parse 또는 linkage 오류는 inactive로 fail-open하지 않고 호출자에게
  `unconfirmed_or_inconsistent` 오류로 전파된다.
- confirmed 또는 running queue에 대한 free-form planning mutation은 거절된다.
- `yardlet goal` 기본 및 verifier 포함 express path는 planning worker 없이
  동작하면서 draft와 confirmation provenance를 기록한다.
- V010-003 이상의 task channel, runtime resource, TUI, adapter, GUI 범위는
  이 구현에서 확장하지 않았다.
