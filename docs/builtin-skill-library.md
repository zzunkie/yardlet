# Built-in Skill Library 결정 문서 (YARD-003)

> Yardlet fresh install에 번들할 최소 skill library, activation 계층, 확장 정책의 확정 기록.
> 입력: `docs/research/builtin-skill-local-evidence.md` (LE/WF/CORE-D/PRESET-D/OVERLAY-D/OC),
> `docs/research/builtin-skill-candidate-ledger.md` (SPW/ANT/GGL/GHC/KDS/HDN/AGG).
> 이 문서는 결정만 확정한다. 어떤 SKILL.md, script, asset, preset 파일도 생성·복사·설치·수정하지
> 않으며, init/auto_equip/classifier/loader 구현, V010 기능, release는 전부 범위 밖이다(10절).
> 정정: 2026-07-12 (YARD-005) — 독립 review(`docs/reviews/builtin-skill-library-review.md`)
> F-002·F-004·F-005 반영. SPW-07/SPW-08/ANT-04를 실제 trigger 수명의 overlay로 재배정하고
> member별 단일 계층 matrix(8.1절)를 추가했으며, explicit 충돌 규칙(6.2절)과 외부 skill 채택의
> I4 SOT 정합(7절 4단계, 9절)을 고정했다. adaptation 조건은 원장 정정판(YARD-005)과 동기화했다.
> 잔여 정정: 2026-07-12 (YARD-008). ANT-02를 network가 필요한 `mcp-authoring` task overlay로
> 단일 재배정하고, SPW-13 포함 예정 원문의 external URL·API·worker·tool·비용 표면을 제거하는
> self-contained adaptation과 immutable inventory 정정을 8.1절까지 동기화했다.
> 정책 결정: 2026-07-12 (YARD-007). 외부 원출처 skill 채택에 새 human approval
> gate를 추가하지 않고 기존 I4를 유지한다. 결정적 provenance·license·정적 위험
> 검사와 eval prune을 fail-closed로 적용하고, 설치는 명시적 `yardlet skill apply`로만 수행한다.

## 1. 결정 원칙

1. **역추적 가능성**: 모든 채택·보류·제외 결정은 로컬 evidence ID(LE/WF/CORE-D/PRESET-D/OVERLAY-D/OC)와
   후보 원장 ID(SPW/ANT 등)를 병기한다. 근거 없는 항목은 존재하지 않는다.
2. **검증된 후보만 번들**: 원장에서 static-verified(commit 고정 + license 전문 + 파일 inventory +
   script 정적 열람, 원장 8절) 상태인 후보만 최소 세트에 넣는다. inventory 수준까지만 확인된
   후보(ANT-05 문서군 등)는 보류한다. 미검증 후보는 어떤 계층에도 넣지 않는다.
3. **상태 코드 해석**: 원장의 E(eligible)는 무조건 채택 가능, C(conditional)는 이 문서가 채택 조건을
   명시할 때만 조건부 채택 가능. 조건은 8절 결정 원장에 기록하며, 조건 미충족 상태의 설치는 없다.
4. **계층 유일성**: 한 skill은 정확히 하나의 계층(core/preset/overlay)에만 속한다. 계층은 activation
   수명으로 구분한다(2절).
5. **비복제**: 로컬 `local-reference-catalog`(local-reference-catalog)의 catalog·preset은 OC-001~OC-005의
   식별자 수준 관찰만 비교 근거로 쓴다. provenance가 없으므로(OC-004) 어떤 항목도 원장 후보나
   preset member로 승격하지 않고, member 구성도 복제하지 않는다.
6. **권한 독립**: 계층 배정과 분류 결과는 network, secret, browser, native toolchain, deploy,
   external mutation 권한을 자동 부여하지 않는다(로컬 결론 7항).

## 2. Activation 3계층 정의

| 계층 | Activation 수명 | 포함 내용 | 켜는 신호 | 권한 |
|---|---|---|---|---|
| Core workflow | 설치 즉시, 모든 repo, 상시 | stack 무관 절차(계획, 진단, 구현 검증, review, 종결) | 없음(항상) | 기존 worker 권한 내 로컬 작업만 |
| Product preset | repo 분류 확정 시, repo 수명 동안 | archetype 전문 절차(framework 관례, 경계 검증) | manifest + path/script 교차 확인(6절) | 추가 권한 없음 |
| Task-triggered overlay | task가 요구할 때, task 수명 동안만 | 도구·외부 자원이 얽힌 절차(browser, DB, media, publish) | task intent + 관련 path(6절) | 필요 권한은 명시적 opt-in, 기본 거부 |

비중첩 규칙:

- core에는 stack 특화 내용을 넣지 않는다. preset에는 task 수명 도구 요구(browser 구동, 외부
  다운로드)를 넣지 않는다. overlay는 repo에 관련 파일이 있다는 이유만으로 상시 승격하지 않는다
  (로컬 evidence 4.3절 결론).
- 같은 수요가 두 계층에 걸치면 더 짧은 수명 쪽에 배정한다(fail-closed). ANT-03이 그 사례다(5절).
- task-time network를 유지하는 ANT-02도 같은 규칙에 따라 repo-lifetime preset이 아니라
  `mcp-authoring` overlay에만 둔다. product preset 분류는 overlay 권한을 암묵적으로 켜지 않는다.
- **설치와 활성화의 구분(YARD-005 추가)**: "번들 설치"는 fresh install에 파일이 포함된다는 뜻이고,
  계층은 **packet catalog에 주입되는 활성화 수명**으로만 정의한다. core에는 모든 task에 공통인
  lifecycle 단계(계획→구현→진단→검증→review 요청)의 절차만 남긴다. 특정 이벤트(feedback 수신,
  branch 종결)나 특정 작업 유형(UI 신규/개편)에만 유효한 절차는 발생 조건이 있는 overlay다.
- **단일 배정 원장**: 번들 member 각각은 core/preset/overlay 중 정확히 하나의 계층에만 배정되며,
  그 배정과 trigger, 배포 파일 목록은 8.1절 matrix가 단일 원장이다(YARD-004 F-004 반영).

## 3. Core workflow 확정 (7개)

CORE-D1~D7(WF-001~WF-008)에서 도출한 7개로 확정한다. 7개 상한을 준수하며, `local-reference-catalog`의
core preset 7종(OC-002)과 개수가 같은 것은 우연이고 구성은 독립 도출했다(원장 6.2절과 동일 입장).

| # | Workflow | 해결하는 반복 수요 | 채택 후보 | 포함 이유 | 제외·보류한 대안 | Adaptation |
|---|---|---|---|---|---|---|
| C1 | task-planning | CORE-D1, WF-001: 작업 전 scope·acceptance 고정 | SPW-04 (C, 조건부) | 4개 repo에서 stack 무관하게 반복되는 수요. 순수 문서형, 권한 요구 없음 | SPW-05 제외(Yardlet queue 실행 모델과 구조 중복), SPW-10 보류(script 동봉 + discuss-mode 부재) | 높음: "task 내부 구현 계획"으로 재범위화해 planner의 intent/queue 계획과 역할 분리하고, 미채택 skill을 가리키는 REQUIRED SUB-SKILL 참조 문구(원장 SPW-04 정적 확인)를 제거. 둘 다 없이는 설치하지 않는다 |
| C2 | repo-orientation | CORE-D2, WF-002: 수정 전 repo map·AGENTS·test 전략 선행 독해 | 없음(적격 후보 부재) | 수요는 LE-001~LE-021 전반에서 강함. 그러나 원장 조사 범위(원장 3절 원천 9개)에서 이 수요를 다루는 적격 skill이 발견되지 않았다 | 대안 부재. Yardlet native A1 asset discovery + H1 catalog 주입이 최소 기능을 이미 제공 | 해당 없음: fresh install은 native 메커니즘으로 충족하고, 7절 확장 정책의 1순위 gap으로 기록한다 |
| C3 | evidence-first-debugging | CORE-D3, WF-005: 실패 시 원인 경로 우선 추적 | SPW-02 (E) | 언어 무관 방법론, network 불요, static-verified | 제외 대안 없음. 로컬 학습 자산 `golden-failed-check-repair`는 특정 실패 재현 특화로 보완 관계(원장 6.1절) | 중상: fixture 문서(test-*.md) 번들 제외, `find-polluter.sh`는 선택 동봉, SKILL.md의 env/keychain/codesign 예시 블록(pinned L91-106, 원장 SPW-02 정적 확인) 제거 또는 중립 예시 대체. 제거 전 설치 금지(YARD-004 F-002 반영) |
| C4 | implement-with-tests | CORE-D4, WF-003/WF-004: scope에 맞는 구현과 narrow-first validation | SPW-01 (E) | Rust/pnpm/Bun/Yarn repo 모두에서 build·lint·test gate가 반복 명시됨. 문서형, 요구 권한 없음 | `local-reference-catalog` `delivery-cycle` 부적격(OC-004 provenance 부재) | 낮음: Claude Code 가정 표현 소폭 중립화 |
| C5 | verification-before-completion | CORE-D5, WF-005/WF-008: 완료 주장 전 독립 검증 | SPW-03 (E) | 단일 SKILL.md, 요구 없음. Yardlet evaluator·verdict 계약(docs/skills.md)과 정합 | 제외 대안 없음. 로컬 `git-finish` 계열은 git 종결 특화 학습 자산으로 보완 관계 | 낮음 |
| C6 | review-cycle | CORE-D5, WF-008: acceptance·regression·security 독립 review | SPW-06 (C, 조건부) | review 요청은 모든 구현 task의 공통 검증 단계. 문서형, 요구 없음 | `local-reference-catalog` `review-pr` 부적격(OC-004). 수신 측 SPW-07은 feedback 수신 task에만 유효해 overlay로 재배정(5절, YARD-004 F-004 반영) | SPW-06 중간: subagent dispatch 표현을 Yardlet review task(kind: review) 생성으로 번역 |
| C7 | safe-delivery | CORE-D6, WF-006: worktree·selective staging·branch 종결 규율 | 없음(상시 member 없음) | 4개 repo에서 delivery 경계가 반복됨. 상시 규율 부분은 Yardlet native(worktree 기계화, `.agents/rules/multi-session-safety.md` 계열 rules)가 이미 담당 | SPW-09 제외(Yardlet이 worktree를 기계적으로 관리, `.agents/rules/worktree-tooling.md`와 중복, 원장의 "미채택이 타당" 판단 채택). SPW-08은 실제 trigger가 branch 종결 task이고 push/PR 선택지를 포함해 overlay branch-finishing으로 재배정(5절, YARD-004 F-002/F-004 반영) | 해당 없음(member 없는 core workflow. gap은 native rules로 상쇄, 종결 절차는 overlay가 담당) |

CORE-D7(documentation/handoff, WF-007)은 core 7개에 넣지 않는다. 자연 후보였던 ANT-07
doc-coauthoring이 license 불명으로 제외됐고(원장 5절), 검증된 대체 후보가 없으며, handoff 자체는
Yardlet의 checkpoint/handoff 메커니즘이 담당한다. 미검증 후보를 채우려고 상한을 소진하는 대신
C2와 함께 7절 확장 정책의 gap으로 넘긴다. 형식별 문서 동작(WF-007의 overlay 부분)은 5절 overlay
수요로만 유지한다.

core 번들 skill은 SPW-01, SPW-02, SPW-03, SPW-04, SPW-06의 5종이다(YARD-005 정정: 초판의
SPW-07·SPW-08은 실제 trigger 수명에 맞춰 overlay로 재배정, 5절·8.1절). C2와 C7은 member 없는
core workflow로 남는다. 채택분은 전부 `obra/superpowers@d884ae0` 고정, MIT, static-verified다.
단일 maintainer 저장소이므로 채택 시 commit 고정에 더해 로컬 사본(fork) 보관을 번들 정책으로
확정한다(원장 9절 입력 수용). core workflow 수는 C1~C7로 7개이며 상한을 준수한다.

## 4. Product preset 확정

### 4.1 도출 원칙과 비복제 선언

preset 분류 체계는 workspace의 실제 repo archetype 근거(PRESET-D1~D8, LE-001~LE-021)에서만
도출했다. `local-reference-catalog`의 preset 22종(OC-002)은 식별자와 규모만 관찰했고, 이 절의 preset 이름,
분류 신호, member 구성 어느 것도 그 catalog에서 가져오지 않았다. member는 원장의 static-verified
후보 중 채택 조건을 충족한 것만 넣는다. member가 없는 preset도 분류 대상으로 정의한다:
분류가 확정되면 core만 적용되고, 그 사실이 7절 확장 정책의 gap candidate 입력이 된다.

### 4.2 Preset 목록

| Preset | 수요 근거 | 분류 신호(1차 manifest + 2차 교차 확인) | Bundled member | Gap 처리 |
|---|---|---|---|---|
| cli-rust | PRESET-D1 (LE-001) | `Cargo.toml` + bin target 또는 clap/ratatui dependency | 없음 | S2 gap 기록 |
| web-ui | PRESET-D2 부분, LE-018 (LE-002/LE-014 frontend package 포함) | `package.json` + react/next/vite dependency + src/component path | 없음(ANT-04는 trigger가 UI 신규/개편 task라서 overlay ui-design으로 재배정, 5절; YARD-004 F-004 반영) | 추가 수요는 S2 |
| fullstack-monorepo | PRESET-D2 (LE-002, LE-003, LE-006, LE-014) | `package.json`의 workspaces 또는 `pnpm-workspace.yaml` + 복수 package | 없음 | web-ui/backend-api와 복수 적용 허용, monorepo 고유 절차는 S2 gap |
| backend-api | PRESET-D3 (LE-004, LE-005, LE-007) | backend framework dependency + domain/DTO/entity path + service test | 없음 | S2 gap |
| data-ml | PRESET-D4 (LE-009) | `pyproject.toml` + data/ML dependency + backtest/data test path | 없음 | S2 gap. live trading 수요로 확대 금지 |
| gitops-infra | PRESET-D5 (LE-010) | `Chart.yaml`/Helm templates/Argo path | 없음 | S2 gap. cluster mutation 기본 금지 유지 |
| docs-knowledge | PRESET-D6 (LE-011, LE-012; LE-020·LE-021은 manifest 확인으로 근거에서 제외, evidence 정정판) | docs/templates/CONVENTIONS 중심 + code manifest 부재 | 없음 (ANT-07 license 불명 제외) | S2 gap. manifest 없으면 구현 preset 추정 금지 |
| native-mobile | PRESET-D7 (LE-015) | React Native dependency + android/ios path | 없음 | S2 gap. release/signing은 overlay |
| game-godot | PRESET-D7 (LE-016) | `project.godot` | 없음 | S2 gap |
| desktop-media | PRESET-D7 (LE-013) | `go.mod`/desktop framework + frontend + asset pipeline path | 없음 | S2 gap |
| agent-tooling | PRESET-D8 (LE-001, LE-004, LE-005, LE-017; WF-015) | MCP/agent/worker contract path + 관련 dependency | 없음(ANT-02는 task-time network를 유지하므로 overlay `mcp-authoring`으로 재배정) | ANT-05는 보류(8절). MCP 작성 수요는 5절 overlay가 담당 |

PRESET-D7은 로컬 evidence의 제한(4.2절: toolchain이 크게 달라 거대 preset 부적합)을 그대로 수용해
소형 preset 3개로 분리했다.

## 5. Task-triggered overlay 확정

overlay는 OVERLAY-D1~D10을 그대로 수요 원장으로 채택하고, Yardlet 자체 skill 작성 메커니즘
(docs/skills.md S2/S3, OC-005)에서 도출한 skill-authoring 1개를 추가한다. 여기에 YARD-005 정정으로
실제 trigger가 task 수명인 member 3종(SPW-07, SPW-08, ANT-04)을 core/preset에서 이 계층으로
재배정하며 overlay 3개(review-feedback, branch-finishing, ui-design)를 추가 정의한다(YARD-004
F-004 반영). YARD-008에서는 task-time WebFetch를 유지하는 ANT-02를 `mcp-authoring`으로 추가
재배정한다. positive/negative 신호는 로컬 evidence 4.3절 표의 내용을 결정으로 승격한다.
member는 검증·조건 충족 후보만 넣는다.

| Overlay | 수요 근거 | Bundled member | 결정 노트 |
|---|---|---|---|
| browser-visual-evidence | OVERLAY-D1 (WF-009, LE-012) | ANT-03 (C, 조건부) | 원장은 preset 후보로 적어두었으나, playwright 설치(최초 1회 network)와 서버 구동 요구는 repo 수명 상시 활성화에 부적합하다. WF-009가 명시한 task-triggered 계층에 배정한다(2절 fail-closed 규칙). 설치 network는 task 시점 사용자 승인 opt-in |
| database-migration | OVERLAY-D2 (WF-010) | 없음 | S2 gap |
| security-secret-boundary | OVERLAY-D3 (WF-008, LE-006, LE-007) | 없음 | S2 gap. secret 값 읽기·출력이 필요한 작업은 stop 신호 유지 |
| ci-deploy-gitops | OVERLAY-D4 (WF-011, LE-010) | 없음 | S2 gap. publish/deploy/cluster mutation은 승인 없이는 stop |
| data-quality-benchmark | OVERLAY-D5 (WF-012) | 없음 | S2 gap |
| media-artifact | OVERLAY-D6 (WF-013) | 없음 | S2 gap. 생성 도구·license 미검증 상태에서는 활성화하지 않음 |
| native-realtime | OVERLAY-D7 (WF-014) | 없음 | S2 gap |
| external-publish | OVERLAY-D8 (LE-008, LE-017, LE-019) | 없음 | S2 gap. 사용자 승인 없는 외부 게시 금지 |
| research-citation | OVERLAY-D9 (LE-020, LE-021) | 없음 | S2 gap |
| agent-tool-contract | OVERLAY-D10 (WF-015) | 없음 | preset agent-tooling과 구분: preset은 repo 관례, overlay는 contract 변경 task 한정 |
| mcp-authoring | PRESET-D8, LE-017, WF-015; 원장 ANT-02 본문 network 확인 | ANT-02 (C, 조건부: `scripts/`·`example_evaluation.xml`·`requirements.txt` 제외, SKILL.md의 외부 fetch는 task 시점 명시적 network opt-in으로 재작성) | MCP server 작성·개선 task에서만 활성화. repo가 agent-tooling으로 분류됐다는 사실만으로 켜지지 않는다. eval API key·network는 배포 제외로 제거하고, 본문 fetch는 기본 거부 후 task opt-in으로만 허용 |
| review-feedback | CORE-D5, WF-008; 원장 SPW-07 trigger("Use when receiving code review feedback") | SPW-07 (E) | review feedback 수신·반영 task에서만 활성화. core C6(요청 측)과 한 쌍이지만 activation 수명이 달라 계층을 분리한다(YARD-004 F-004 반영). Yardlet feedback cycle(inject_failed_checks)과 review verdict 수신이 trigger |
| branch-finishing | CORE-D6, WF-006; 원장 SPW-08 trigger("implementation is complete... decide how to integrate") | SPW-08 (C, 조건부: merge/push/PR 선택지를 NeedsUser 결정 흐름(`decision_question`)과 push 승인 gate 뒤로 재작성. 자동 push 금지) | branch 종결·통합 결정 task에서만 활성화(YARD-004 F-002/F-004 반영). push는 identity.md gate 목록의 outward-facing 행위로 기존 승인 경로를 그대로 따른다 |
| ui-design | PRESET-D2, LE-018; 원장 ANT-04 trigger("when building new UI or reshaping an existing one") | ANT-04 (E) | web-ui로 분류된 repo의 UI 신규 구축·개편 task에서만 활성화. repo-lifetime preset이 아니라 task-lifetime이다(YARD-004 F-004 반영, 2절 fail-closed 규칙) |
| skill-authoring | docs/skills.md S2/S3, OC-005; 원장 6.3절 | SPW-13 (C, 조건부: self-contained 재작성 `SKILL.md`와 `persuasion-principles.md`만 포함. external spec URL, raw API·single-shot subagent·5회 반복 비용, graphviz/render, push/PR, 외부 cross-skill 지시를 본문에서 제거. 1,150줄 `anthropic-best-practices.md`와 나머지 subagent 문서·script·asset 제외. 재작성 전 설치 금지) | skill 작성 task에서 queue에 명시적으로 배정된 `skill_author`·evaluator·review worker만 사용한다. 잔여 요구는 해당 configured worker 호출 비용뿐이며, 별도 raw API 반복이나 추가 network·secret·tool·subagent·external mutation은 없다. ANT-01과 동시 채택 금지 권고를 수용해 택1(SPW-13), ANT-01은 보류(8절) |

## 6. Multi-signal deterministic classification 정책

분류는 결정적이고 감사 가능해야 한다(identity.md I1, routing과 동일한 policy-vs-mechanism 자세).
같은 입력은 항상 같은 출력을 내고, 판정에 쓰인 신호가 기록된다. 이 절은 정책이며 구현 명세가 아니다.

### 6.1 신호 5종과 우선순위 (높은 것부터)

1. **Explicit user signal**: 사용자가 preset, skill, 금지 범위를 명시하면 모든 자동 추론에 우선한다
   (로컬 결론 4항). 명시적 금지는 절대 거부권이다. 같은 우선순위 안에서 explicit 신호끼리 충돌하는
   경우의 규칙은 6.2절에 고정되어 있다.
2. **Negative signal (자동 veto)**: scaffold 기본 README, code manifest 부재, provenance 없는
   local catalog 흔적은 해당 preset 추론을 차단한다(로컬 결론 5항, LE-018~LE-021). veto는 특정
   preset을 끄는 것이지 다른 preset을 켜는 근거가 아니다.
3. **Repo manifest (1차 positive)**: tracked manifest(`Cargo.toml`, `pyproject.toml`, `go.mod`,
   `package.json`, `project.godot`, `Chart.yaml`)가 preset 후보를 제안한다(로컬 결론 1항).
4. **File/path·script 교차 확인 (확정 조건)**: manifest 제안은 대응하는 2차 신호(source/bin path,
   workspace packages, framework dependency, test script)가 있을 때만 확정된다(로컬 결론 2항).
   repo 이름, package 이름, 디렉토리 이름은 신호가 아니다. LE-014(`mobile` 이름의 web repo)가
   구속력 있는 반례다.
5. **Task intent (overlay 전용)**: overlay는 task가 해당 작업을 요구할 때만 켠다(로컬 결론 3항).
   repo에 `Dockerfile`이나 image dependency가 있다는 사실만으로 overlay를 켜지 않는다.

### 6.2 Tie-break, 충돌, no-match

- **복수 preset 허용**: 서로 다른 preset의 확정 조건이 각각 충족되면 합집합으로 적용한다
  (로컬 결론 6항, LE-002/LE-006). preset 간 동률은 충돌이 아니다.
- **Tie-break**: 하나의 manifest가 여러 preset에 걸치면(예: `package.json`이 web-ui와
  fullstack-monorepo 양쪽 후보) 각 preset의 구별 신호(4번 신호)가 충족된 것만 켠다. 구별 신호가
  모두 없으면 어느 쪽도 켜지 않는다. 최근접 추정으로 채우지 않는다.
- **충돌 규칙**: positive 추론과 negative veto가 충돌하면 veto가 이긴다(fail-closed). 단 explicit
  user positive는 자동 veto보다 우선한다(사용자가 명시하면 scaffold repo에도 preset을 켤 수 있다).
- **Explicit 신호 내부 충돌(YARD-005 추가, YARD-004 F-005 반영)**: 같은 대상에 explicit positive와
  explicit negative가 함께 주어지면 **negative가 이긴다**(fail-closed, 입력 순서 무관). 예:
  한 입력에 `web-ui 사용`과 `web-ui 사용 금지`가 모두 있으면 결과는 항상 `web-ui` 비활성이다.
  충돌 사실은 분류 기록에 남고 분류 결과 보고에 포함되어 사용자가 볼 수 있으며, 재활성화는
  사용자가 충돌 없는 새 explicit positive를 주는 방법뿐이다. 이 규칙으로 같은 입력은 구현 순서와
  무관하게 항상 같은 출력을 낸다.
- **No-match fallback**: 어떤 preset도 확정되지 않으면 core만 적용하고, no-match 사실을 gap
  candidate로 기록해 7절 확장 정책의 입력으로 넘긴다. 억지 분류는 하지 않는다.
- **권한 독립**: 분류 결과는 어떤 권한도 부여하지 않는다(1절 원칙 6). overlay가 요구하는 권한은
  7절의 opt-in 절차를 따로 통과해야 한다.

## 7. On-demand research/create/apply 확장 정책

fresh install이 못 채운 수요(C2, CORE-D7, member 없는 preset/overlay 전부)는 설치를 부풀리는
대신 이 확장 경로로 채운다. 기존 구현(docs/skills.md S2/S3, `yardlet skill research/create/apply`)
위의 정책 계층이며, 단계는 서로 분리되고 어느 단계도 다음 단계를 자동 승격하지 않는다.

| 단계 | 내용 | 경계 |
|---|---|---|
| 1. Discovery | gap candidate(preset gap, no-match 기록, telemetry 반복 실패 주제) 또는 사용자 topic에서 출발. aggregator(skills.sh 등)는 발견 용도로만 쓴다 | aggregator는 provenance anchor가 아니다(원장 5.1절 DS-01, not-a-candidate) |
| 2. Provenance·license 검증 | 원출처 저장소에 원장 1절의 5기준(표준 정합성, 검증 가능한 maintainer, 유지 증거, license 명시, commit 고정 가능)을 상시 gate로 적용. 채택 참조는 immutable commit SHA로 고정 | 기준 미달 원천은 이후 단계로 넘어가지 못한다 |
| 3. 정적 위험 검사 | bundled scripts/assets 전수 정적 열람, network endpoint, secret·tool 요구 목록화. frontmatter `allowed-tools`는 experimental이므로 신뢰하지 않고 파일 inspection으로만 판정(원장 2.2절) | 후보 script 실행, 로그인, secret 제공, 쓰기 권한 부여 금지 |
| 4. 기존 gate 정합 적용 (YARD-007) | 외부 원출처 skill 채택에 새 human approval gate를 신설하지 않는다. SOT는 docs/skills.md I4와 identity.md의 기존 gate 원칙이다. provenance·license 검증, bundled file 전수 정적 위험 검사, canonical single-writer, post-apply eval prune이 fail-closed로 작동하며 설치는 명시적 `yardlet skill apply`로만 수행한다. network·secret·tool·external mutation은 실제 사용 시점의 기존 opt-in gate를 별도로 통과한다 | 미확인 항목은 채택하지 않고 fail-closed로 종료한다 |
| 5. 격리 생성 | draft는 queue-isolated worker가 run dir(`.agents/runs/<id>/`)에만 쓴다. live intent와 queue를 건드리지 않는다(S2 구현과 정합) | worker는 canonical state에 직접 쓰지 못한다 |
| 6. 적용 | `yardlet skill apply`로 deterministic core(`state.rs`)만이 canonical 위치에 쓴다. name은 Agent Skills spec의 디렉토리 일치 규칙을 검증하고, 기존 skill을 clobber하지 않는다 | 단일 작성자 원칙(I3) |
| 7. Post-apply 검증 | S4 skill score(dependent review verdict 기반)가 적용 후 품질을 판정한다. version bump는 score를 reset하고, floor 미달이 지속되면 auto-prune 대상이 된다 | 검증자는 실행자가 아니다 |

**권한 기본 거부**: secret, network, tool(browser, graphviz, playwright 등) 요구는 모든 단계에서
기본 거부다. 필요한 skill은 요구를 문서화하고, 실제 사용 시점에 명시적 opt-in(예: worker profile의
`invocation.pass_env`, task 시점 승인)을 따로 통과해야 한다. ANT-02의 eval script 제외와
`mcp-authoring` overlay 본문 WebFetch opt-in, ANT-03의 playwright 설치 opt-in, SPW-02의
env/keychain/codesign 예시 제거, SPW-13의 외부·도구·반복 worker 표면 제거, SPW-08의 push 승인
gate가 이 정책의 적용 사례다(4~5절, 8.1절).

## 8. 결정 원장 (후보 전체 처분)

| 후보 ID | 처분 | 계층/위치 | 조건 | 근거 |
|---|---|---|---|---|
| SPW-01 | 채택 | Core C4 | 표현 중립화(낮음) | CORE-D4, WF-003/004; 원장 E |
| SPW-02 | 채택 | Core C3 | fixture 제외, `find-polluter.sh` 선택 동봉, env/keychain/codesign 예시 블록 제거(제거 전 설치 금지) | CORE-D3, WF-005; 원장 E + YARD-005 정적 확인 |
| SPW-03 | 채택 | Core C5 | 없음(낮음) | CORE-D5, WF-005/008; 원장 E |
| SPW-04 | 조건부 채택 | Core C1 | task 내부 구현 계획으로 재범위화 + 미채택 skill 참조(REQUIRED SUB-SKILL) 문구 제거 필수. 미충족 시 미설치 | CORE-D1, WF-001; 원장 C + YARD-005 정적 확인, planner 중복 |
| SPW-05 | 제외 | 없음 | 해당 없음 | Yardlet queue 실행 모델과 구조 중복(원장 6.3절) |
| SPW-06 | 조건부 채택 | Core C6 | subagent 표현을 review task 생성으로 번역 | CORE-D5, WF-008; 원장 C |
| SPW-07 | 채택 | Overlay review-feedback | 없음(낮음) | WF-008; 원장 E. trigger가 feedback 수신 task라 overlay 배정(YARD-004 F-004) |
| SPW-08 | 조건부 채택 | Overlay branch-finishing | NeedsUser 결정 흐름 연결, push는 승인 gate 뒤, 자동 push 금지 | CORE-D6, WF-006; 원장 C + YARD-005 정적 확인(push/PR 지시). trigger가 branch 종결 task라 overlay 배정(YARD-004 F-002/F-004) |
| SPW-09 | 제외 | 없음 | 해당 없음 | Yardlet worktree 기계화 및 rules와 중복(원장 C, 미채택 타당 의견 수용) |
| SPW-10 | 보류 | 없음 | 재평가 조건: discuss-mode 구현 + script 일체 제거 | OVERLAY 후보였으나 script 5종 동봉, 현재 활성 계기 부재 |
| SPW-11 | 제외 | 없음 | 해당 없음 | subagent 아키텍처 충돌(원장 5절) |
| SPW-12 | 제외 | 없음 | 해당 없음 | 동일 충돌 + bash 종속(원장 5절) |
| SPW-13 | 조건부 채택 | Overlay skill-authoring | self-contained `SKILL.md` + `persuasion-principles.md`만 포함. external URL, raw API/subagent 반복, graphviz/render, push/PR, Claude 전용 runtime·package·MCP 표면 제거. 재작성 전 설치 금지 | docs/skills.md S2/S3, OC-005; ANT-01과 택1; YARD-008 포함 예정 본문 전수 확인 |
| SPW-14 | 제외 | 없음 | 해당 없음 | packet catalog 주입(H1)과 이중 dispatcher 충돌(원장 5절) |
| ANT-01 | 보류 | 없음 | 재평가 조건: skill_author 참고 문헌으로 `quick_validate.py` 계열만 발췌 검토 | SPW-13과 동일 목적 택1에서 탈락. 전체 번들은 과잉(원장) |
| ANT-02 | 조건부 채택 | Overlay mcp-authoring | `scripts/`·`example_evaluation.xml`·`requirements.txt` 제외 + 본문 WebFetch 지시를 task-time network opt-in으로 재작성(미고정 main 참조 경고 포함) | PRESET-D8, LE-017/WF-015; eval script는 API key·network 요구로 billing guard 충돌, 본문 fetch는 script 제외로 안 사라지므로 repo-lifetime preset에서 제거(YARD-008) |
| ANT-03 | 조건부 채택 | Overlay browser-visual-evidence | Claude Code 가정 중립화, playwright 설치는 task 시점 승인 opt-in | OVERLAY-D1, WF-009; 원장의 preset 제안을 로컬 evidence의 task-triggered 판정으로 override(5절) |
| ANT-04 | 채택 | Overlay ui-design | 없음(낮음) | PRESET-D2/LE-018; 원장 E, 순수 문서형. description이 UI 신규/개편 task trigger를 명시해 overlay 배정(YARD-004 F-004) |
| ANT-05 | 보류 | 없음 | 재평가 조건: 채택 범위 확정 + 대상 문서 전수 열람(원장 9절 조건) | 60+ 파일 전량 번들 과대, 현 workspace 수요 제한적 |
| ANT-06 | 제외 | 없음 | 해당 없음 | claude.ai artifact 전용 + 설치 network 과다(원장 5절) |
| ANT-07 | 제외 | 없음 | 해당 없음 | license 불명. CORE-D7 gap의 직접 원인(3절) |
| ANT-08~11 | 제외 | 없음 | 해당 없음 | 재배포 불가 license(source-available, 원장 5절) |
| ANT-12 | 제외 | 없음 | 해당 없음 | 현 workspace 수요 무관. 필요 시 7절 경로로 재평가 |
| GGL-01 | 제외(번들) | 7절 discovery 원천 | 해당 없음 | Google 제품 특화로 수요 무관(원장) |
| GHC-01 | 제외(번들) | 7절 discovery 원천 | 해당 없음 | per-skill provenance 이질, 전수 검증 없이 번들 불가(원장) |
| KDS-01 | 제외 | 없음 | 해당 없음 | 도메인 무관(원장 5절) |
| HDN-01 | 제외 | 없음 | 해당 없음 | license 없음 + provenance 신뢰 부족(원장 5절) |
| DS-01 (구 AGG-01) | 비후보(not-a-candidate) | 7절 discovery 한정 | 해당 없음 | 원출처 아님, commit 고정 원천 불가. 원장 5.1절에서 candidate 원장과 분리(YARD-004 F-003 반영) |

번들 합계 11종(YARD-008 정정): core 5(SPW-01/02/03/04/06), preset member 0,
overlay member 6(ANT-02, ANT-03, SPW-13, SPW-07, SPW-08, ANT-04). 전부 원장 8절의 static-verified
(script 정적 열람 포함, 채택분 표면 재검증 포함) 상태이며, inventory 수준 후보는 하나도 포함하지
않았다. 각 member의 유일 계층 배정, activation trigger, 배포 파일 목록, 잔여 요구는 8.1절 matrix가
단일 원장이다.

### 8.1 번들 member activation matrix (단일 배정 원장, YARD-005 추가)

기준: pinned commit(`obra/superpowers@d884ae0`, `anthropics/skills@9d2f1ae`)의 파일 inventory에서
"배포 포함"과 "배포 제외"를 확정한 실제 배포 대상 목록이다. "잔여 요구"는 adaptation 완료 후 남는
network·secret·tool·subagent 요구이며, adaptation 미완료 상태의 설치는 전 member 공통으로 금지다.
superpowers 채택분은 repo LICENSE(MIT) 사본과 pinned commit provenance 표기를, anthropics 채택분은
skill별 `LICENSE.txt`를 함께 배치한다.

| Member | 계층(유일) | Activation | 배포 포함 | 배포 제외(adaptation) | 잔여 요구와 gate |
|---|---|---|---|---|---|
| SPW-01 | Core C4 | 상시 | `SKILL.md`, `testing-anti-patterns.md` | 없음(표현 중립화만) | 없음(로컬 테스트는 기존 worker 권한) |
| SPW-02 | Core C3 | 상시 | `SKILL.md`(env/keychain/codesign 예시 블록 제거판), `root-cause-tracing.md`, `defense-in-depth.md`, `condition-based-waiting.md`, `condition-based-waiting-example.ts`, (선택) `find-polluter.sh` | `CREATION-LOG.md` 1개, `test-*.md` 4개, 원문 L91-106 예시 블록 | 없음(제거판 기준. 로컬 테스트만) |
| SPW-03 | Core C5 | 상시 | `SKILL.md` | 없음 | 없음 |
| SPW-04 | Core C1 | 상시 | `SKILL.md`(task 내부 계획 재범위화 + 미채택 skill 참조 제거판), `plan-document-reviewer-prompt.md` | 원문의 REQUIRED SUB-SKILL 문구 | git commit 지시(로컬, 기존 권한 내) |
| SPW-06 | Core C6 | 상시 | `SKILL.md`(subagent dispatch를 review task 생성으로 번역판), `code-reviewer.md` | 원문의 subagent 용어 | 없음(review task는 기존 queue 메커니즘) |
| SPW-07 | Overlay review-feedback | review feedback 수신·반영 task | `SKILL.md` | 없음 | 없음 |
| SPW-08 | Overlay branch-finishing | branch 종결·통합 결정 task | `SKILL.md`(merge/push/PR 선택지를 NeedsUser + push 승인 gate 뒤로 재작성판) | 원문의 무조건 push/PR 절차 | git push/PR은 사용자 승인 gate 뒤(기본 미실행) |
| SPW-13 | Overlay skill-authoring | skill 작성·개선 task | self-contained `SKILL.md`(pinned spec 필수 구조를 local checklist로 내장하고 external URL, raw API/subagent 반복, graphviz/render, push/PR, external cross-skill을 제거한 재작성판), `persuasion-principles.md` | `anthropic-best-practices.md`(외부 docs/images, Claude model/API, package·MCP 도구 표면), `render-graphs.js`, `graphviz-conventions.dot`, `testing-skills-with-subagents.md`, `examples/CLAUDE_MD_TESTING.md` | queue에 명시된 configured `skill_author`·evaluator·review worker 호출 비용. 별도 raw API 반복이나 추가 network·secret·tool·subagent·external mutation 없음 |
| ANT-02 | Overlay mcp-authoring | MCP server 작성·개선 task | `SKILL.md`(WebFetch 지시를 task-time network opt-in 표기로 재작성판), `LICENSE.txt`, `reference/` 문서 4종 | `scripts/` py 2종, `example_evaluation.xml`, `requirements.txt` | 외부 문서 fetch는 task 시점 network opt-in(기본 거부). API key 요구는 배포 제외로 제거됨 |
| ANT-03 | Overlay browser-visual-evidence | browser·visual 검증 task | `SKILL.md`(Claude Code 가정 중립화판), `LICENSE.txt`, `scripts/with_server.py`, examples py 3종 | 없음 | python3 + playwright(최초 설치 network는 task 시점 opt-in) |
| ANT-04 | Overlay ui-design | web-ui 분류 repo의 UI 신규·개편 task | `SKILL.md`, `LICENSE.txt` | 없음 | 없음 |

집계: Core 5 + Preset 0 + Overlay 6 = 11종. 모든 member가 정확히 한 계층에만 나타나고, 이 표와
2절 계층 정의·5절 overlay trigger가 일치한다.

## 9. 기존 정책과의 정합성

- **I1 deterministic core**: 분류(6절)와 적용(7절 6단계)은 결정적 규칙이고, skill 내용 생성은
  worker 뒤에 있다(docs/skills.md의 generates-vs-records 구분 그대로).
- **I3 단일 작성자**: 이 문서의 어떤 결정도 worker의 canonical state 직접 쓰기를 허용하지 않는다.
- **I4와 human approval의 관계(YARD-007 결정)**: 외부 원출처 skill 채택에 새 human
  gate를 추가하지 않는다. 결정적 provenance·license·정적 위험 검사와 eval prune,
  git 가역성, canonical single-writer가 안전을 담당한다. 설치는 명시적 `yardlet skill apply`로만
  수행하고, network·secret·tool·push·deploy 등은 실제 사용 시점의 기존 gate를 유지한다.
- **H1 주입**: 번들 skill은 기존 catalog 주입 경로를 그대로 탄다. 새 주입 경로를 만들지 않는다.
- **Policy vs mechanism**: 분류 표와 telemetry gap 신호의 관계는 routing과 telemetry의 관계
  (docs/routing-and-telemetry.md)와 동형이다. telemetry는 gap을 제안할 뿐 분류를 바꾸지 않는다.

## 10. Out of scope 재확인

이 문서는 결정 기록이며 다음을 수행하지 않고, 후속 작업도 이 문서를 근거로 자동 개시되지 않는다.

- SKILL.md, bundled script, asset, preset 등 실제 skill 파일의 생성·복사·설치·수정
- init, auto_equip, runtime classifier, loader, registry, CLI 동작의 구현과 테스트 코드 변경
- V010 기능 또는 그 밖의 roadmap 기능 구현
- release, 배포, package publish, version bump, changelog 갱신
- 외부 저장소·catalog에 대한 어떤 mutation

## 11. Acceptance 자체 점검

| Criterion | 판정 | 근거 |
|---|---|---|
| core workflow 7개 이하 + 항목별 수요/원장 ID/포함 이유/제외 대안/adaptation | Pass | 3절 표(workflow 7개, member 5종, 각 열 기록) |
| 3계층의 activation 수명·내용 비중첩 정의 + member별 단일 계층 배정 | Pass (YARD-008) | 2절 표와 비중첩 규칙(설치/활성화 구분), 8.1절 matrix(11종 각 1계층). ANT-02를 task-time network 수명의 mcp-authoring overlay로 이동 |
| 채택 member의 배포 파일·잔여 요구가 실제 배포 대상 기준으로 고정 | Pass (YARD-008) | 8.1절 matrix + 원장 정정판의 정적 확인. SPW-13 포함 예정 원문의 외부·API·worker·tool·비용 표면 전수 기록과 제거 결정 포함 |
| preset은 repo archetype 근거 도출 + `local-reference-catalog` 비복제 | Pass | 4.1절 선언, 4.2절 표의 PRESET-D/LE 근거(LE-020/021 정정 반영), 1절 원칙 5 |
| 5신호 classification의 우선순위·tie-break·충돌·no-match + explicit 내부 충돌 고정 | Pass (YARD-005) | 6절(6.2절 negative-wins 규칙 포함). F-005 전반부 해소 |
| 확장 정책의 단계 분리 + secret·network·tool 기본 거부 + 기존 I4 SOT 정합 | Pass (YARD-005) | 7절 표(4단계 정정)와 기본 거부 문단, 9절. F-005 후반부 해소 |
| 모든 결정의 evidence ID·candidate ID 역추적 + 미검증 후보 미포함 | Pass | 8절 결정 원장(DS-01 분리 반영), 1절 원칙 2 |
| 구현 명세로 확장하지 않고 out-of-scope 재확인 | Pass | 6절 서두, 10절 |
