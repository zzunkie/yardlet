# V010-002A missing-capability planning dogfood

- 실행일: 2026-07-21 (Asia/Seoul)
- 대상: `yardlet 0.10.0`, YARD-002/YARD-003 위의 YARD-005 isolation remediation
- 원칙: provider-free, 외부 검색·설치·게시·deploy·push 없음

## 1. 실제 readiness와 요청

현재 Yardlet workspace에서 `yardlet worker status`를 읽기 전용으로 실행한 결과
`codex` 0.144.1은 guard 기준 `invocable`, `claude-code`는 `disabled`였다. 현재
`workers.yaml`에서 ready worker가 선언한 tool capability는 `image_generation`뿐이며,
dogfood에 사용한 `nondeterministic_entropy_probe`는 어느 ready worker도 선언하지
않는다.

추가 provider 호출을 만들지 않기 위해 process dogfood는 이 capability 경계를
그대로 복제한 provider-free `fixture-worker`를 사용한다. 이 worker는 실제
`--version` probe와 billing-env guard를 통과하고 `shell`, `image_generation`만
선언한다. 기록된 readiness는 다음과 같다.

```text
fixture-worker [invocable]
  [ok] binary
  [ok] version yardlet-capability-fixture-worker 1.0
  [ok] billing-env AI-billing env clean
  => safe to invoke under current policy (auth not verified offline)
```

실제 express planning 요청은 다음과 같다.

```bash
yardlet goal "dogfood nondeterministic capability" \
  --requires nondeterministic_entropy_probe \
  --plan-only
```

## 2. coverage, trigger, source, disposition

2026-07-21 재현에서 `yardlet planning show --json`은 한 task에 다음 typed 결과를
남겼다.

```json
{
  "coverage": {
    "status": "external-tool-needed",
    "confidence": "high",
    "freshness": "fresh",
    "reason_code": "no_ready_worker_capability",
    "worker_readiness_evidence": "no guard-ready worker declares this capability"
  },
  "trigger": {
    "decision": "scout",
    "hard_signals": ["no_ready_worker_capability"],
    "soft_signals": []
  },
  "source_order": [
    "workspace_skill_catalog",
    "user_skill_library",
    "external_primary_source"
  ],
  "sources_consulted": [
    "workspace_skill_catalog",
    "user_skill_library"
  ],
  "disposition": "record_tool_candidate",
  "pending_question": null
}
```

외부 source까지 확장하지 않았고 typed disposition은 정확히 한 개인
`record_tool_candidate`였다. worker script는 skill 또는 tool을 설치하지 않았으며,
fixture는 실행 전후 `.agents/skills/**` digest가 같고 `node_modules`, `target`, `.git`이
새로 생기지 않았음을 검사한다.

## 3. restart와 confirm 경계

첫 실행의 session/head는 다음과 같았다.

```text
session = ses_20260720221322117195000_000001
head = drv_20260720221322696767000_000009
lifecycle before confirm = open
scout count before restart = 1
```

별도 process인 `scripts/restart.sh`가 `yardlet planning show --json`을 다시 실행한
뒤에도 같은 session, head, coverage evidence, trigger, source, disposition을 읽었다.
scout count는 1로 유지되어 duplicate scout가 없었다. confirm도 fresh CLI process로
실행했다.

```text
active digest before goal = 6377514bd8e85d7333899e498af3f62a761d3b8e
active digest before confirm = 6377514bd8e85d7333899e498af3f62a761d3b8e
active digest after confirm = 070290f8479fb6904c714091328acc4877a06d19
lifecycle after confirm = confirmed
exact_active_parity after confirm = true
```

digest 값은 임시 workspace와 생성 시각에 따라 달라질 수 있다. 재현에서 중요한
불변식은 goal/scout/restart 동안 앞의 두 digest가 같고, 오직 explicit confirm 뒤에만
digest가 바뀌며 `exact_active_parity`가 `true`가 된다는 점이다.

## 4. bounded scout와 authority 증거

provider-free process fixture는 다음을 함께 검사한다.

- hard signal 7종 각각은 단독으로 `scout`이며 soft signal은 `0=no_scout`,
  `1=observe`, `2=scout`다.
- packet은 normalized duplicate topic을 한 번만 포함하고 한 cycle에서 최대 3개
  topic만 전달한다.
- source order는 `workspace_skill_catalog -> user_skill_library ->
  external_primary_source`다.
- license가 빈 external candidate는 `report_no_change`로 정규화되고 candidate가
  제거된다.
- 같은 planning session의 다음 turn은 3개 unique topic cache를 재사용하고 scout를
  다시 실행하지 않는다.
- scout 뒤와 confirm 준비 상태에서 각각 두 번 fresh process로 열어도 audit,
  pending question, proposal cardinality가 보존된다.

## 5. active-state isolation remediation 증거

`malicious_scout_cannot_mutate_active_state`는 packet의 금지 문구를 의도적으로 무시하는
generic provider-free scout를 실행한다. 이 scout는 `.agents/intent-contract.yaml`에
쓰기를 시도하지만 child의 cwd, `{run_dir}`, workspace 안 worker executable은 모두
다음 형태의 disposable copy 경로로 바뀐다.

```text
worker-cwd = /var/.../yardlet-planning-scout-20260721-071320-de9d33ab5c458b10-96887
run-dir = /var/.../yardlet-planning-scout-20260721-071320-de9d33ab5c458b10-96887/.yardlet-scout-output
worker executable = /var/.../yardlet-planning-scout-20260721-071320-de9d33ab5c458b10-96887/fixture-worker/worker.sh
before = 1e64ab198880904da0aababc6d256090484c50ac
after  = 1e64ab198880904da0aababc6d256090484c50ac
```

fixture는 child 로그 어디에도 live workspace root가 없음을 확인한다. malicious write는
disposable copy의 intent에만 반영되고, live active intent와 queue를 합친 digest는 동일하다.
macOS의 `/var`와 `/private/var` alias도 binary와 workspace를 canonicalize한 뒤 상대 경로를
계산하므로 live executable로 되돌아가지 않는다.

같은 scenario는 `sandbox_args`가 없는 별도 generic profile도 실행한다. 이 경우 scout
subprocess와 `scout-result.json`은 생기지 않고 planning output에는 다음 근거가 보인다.

```text
scout sandbox contract failed closed without active-state mutation:
generic planning scout sandbox contract failed closed: sandbox_args must be non-empty
```

공백, unknown placeholder, full-access와 동일한 generic 계약도 guard unit test에서
거절된다. 마지막 방어층으로 external fixture worker가 live path를 미리 hard-code해
active snapshot을 바꾸는 반례도 실행한다. `src/planner.rs`는 spawn 직후 전후 digest가
다르면 typed `PlanningScoutActiveSnapshotMutation` 오류로 audit 전체를 중단하며, worker의
`scout-result.json`을 live run evidence, cache, proposal에 채택하지 않는다.

## 6. 재현 명령

```bash
cargo test --test v010_002a_capability_discovery_process \
  hard_and_soft_trigger_matrix_matches_the_typed_core -- --nocapture
cargo test --test v010_002a_capability_discovery_process \
  scout_is_bounded_ordered_deduplicated_cached_and_authority_closed -- --nocapture
cargo test --test v010_002a_capability_discovery_process \
  restart_ -- --nocapture
cargo test --test v010_002a_capability_discovery_process \
  missing_nondeterministic_capability_stops_at_one_visible_disposition -- --nocapture
target/debug/yardlet eval fixtures --json \
  --fixture capability-coverage-trigger-matrix \
  --fixture bounded-capability-scout-contract
```

보안 반례와 generic fail-closed, digest reject는 다음 명령으로 재현한다.

```bash
cargo test --test v010_002a_capability_discovery_process \
  malicious_scout_cannot_mutate_active_state -- --nocapture
cargo test \
  planner::tests::scout_active_snapshot_mutation_aborts_before_result_adoption \
  -- --nocapture
cargo test \
  guard::tests::generic_scout_sandbox_contract_fails_closed_when_missing_or_unverifiable \
  -- --nocapture
```

2026-07-21 final fresh 결과는 eval fixture 2/2, capability process 6/6,
`cargo clippy --all-targets --all-features -- -D warnings`, 전체 `cargo test`가 모두
통과했다. 전체 test는 unit 472개와 모든 integration suite를 통과했다. 재현 명령은
다음과 같다.

```bash
cargo test --test v010_002a_capability_discovery_process
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

## 7. 독립 리뷰 후속 조치 (2026-07-22, YARD-005)

2026-07-22 독립 리뷰(YARD-002)는 blocking 0건, minor 6건(F1~F6)을 판정했다. 이 절은
그 후속 조치와 남은 결정을 기록한다.

### 반영된 변경 (F1, F3, F5, F6)

- **F1**: `request_capability_signals`의 자연어 신호는 identifier 경계 단어 매칭으로
  좁혔다. `research-policy`, `researcher`처럼 용어를 내장만 한 요청은 더 이상
  `explicit_research_request`를 올리지 않는다(한국어 어간은 활용형이 어간을 그대로
  확장하므로 substring 유지). fixture 전용 마커(`weak-context:`, `unfamiliar-domain:`,
  `약한 매치:`, `낯선 도메인:`)는 production 기본 경로에서 비활성이며
  `YARDLET_TEST_PLANNING_SIGNAL_MARKERS=1`로만 켜진다. process fixture는 opt-in 없이
  마커가 무시되는 대조군(`soft-one-marker-off`)을 함께 검증한다. 고정 테스트:
  `planner::tests::capability_signals_ignore_embedded_terms_and_fixture_markers_by_default`.
- **F3**: scout worker가 실제로 반환한 결과만 scout 캐시에 저장한다. 로컬
  `fallback_scout_result`는 보수적 대역이므로 캐시에서 제외되어, worker가 복구되면
  같은 intent에서 scout가 재시도된다(미채택 scout의 at-least-once 재시도로,
  기존 restart 무중복 불변식과 충돌하지 않음). 고정 테스트:
  `planner::tests::failed_scout_falls_back_without_caching_the_local_disposition`
  (fallback 미캐시)과 기존 worker-scout 테스트의 캐시 유지 단언.
- **F5**: production 격리 경로가 쓰는 복사 헬퍼를 `copy_scout_workspace`로 개명했다
  (`for_fixture` 접미사 제거, src/memory.rs).
- **F6**: 미사용 `assess_workspace`/`CapabilityDiscoveryWorkspaceInput`을 삭제하고
  main.rs의 mod 수준 `allow(dead_code)`와 templates.rs의 stale allow 2건을 제거했다.
  기존 workspace projection 테스트는 planner가 조합하는 실제 projection
  (`capability_catalog_projection` + `capability_readiness_projection`)을 pure core에
  직접 연결하는 형태로 유지된다.

### F2: hard signal 2종 단계적 배선 계획 (이번 슬라이스에서는 문서화만)

core 계약과 eval/process fixture는 hard signal 7종을 전부 검증하지만, production
planning 경로가 실제로 공급하는 신호는 5종이다. `only_unusable_skill_matches`와
`repeated_typed_failure`(`typed_failure_count`)는 공급자가 없어 end-to-end로 도달
불가하다. 본문 4절의 "hard signal 7종" 서술은 core 층 계약 기준이다. 배선 계획:

1. **`typed_failure_count`**: 같은 intent의 완료 run 기록(evaluation의 failed
   checks, run 상태)을 읽기 전용으로 요약하는 history projection을 추가하고,
   `audit_planning_content`의 base signals 조립부에서 task 단위로 공급한다.
   임계값은 이미 research-policy(`repeated_failure_hard`)가 소유하므로 core 변경은
   없다.
2. **`only_unusable_skill_matches`**: skill catalog projection에 "매치는 있으나
   사용 불가(access level 또는 required capability 불일치)" typed 판정을 추가한 뒤
   같은 조립부에서 공급한다.

두 배선 모두 planning 입력 표면을 넓히므로 이번 minor 정리 범위 밖이며, 후속
태스크로 제안했다(YARD-005 result의 follow_up_tasks).

### F4: active digest 백스톱 확장 결정 = 기각(현 시점)

`load_active_snapshot_texts` 기반 백스톱을 canonical `.agents/` 전체로 확장하는
제안은 현 시점에서 기각한다. 근거:

- 1차 격리(disposable copy, 경로 재작성, env 세척, packet/result의 live 경로 bail)가
  live 경로 전달 자체를 차단하고, process fixture가 child 로그의 live 경로 부재를
  검증한다. 백스톱은 승격 의미론에 직접 닿는 두 파일(intent-contract, work-queue)의
  변조를 잡는 최후 방어선으로 이미 그 역할을 다한다.
- 전체 확장은 scout spawn마다 canonical 트리 digest 비용을 추가하고, runtime
  디렉터리(runs/checkpoints/handoffs/telemetry) 제외 규칙이 새 유지보수 표면이 된다.
- 재평가 조건: scout 경로에 새 쓰기 표면이 생기거나, workers/billing/skills 변조가
  같은 planning turn 안에서 승격 결정에 영향을 주는 경로가 추가되면 채택을 다시
  검토한다.
