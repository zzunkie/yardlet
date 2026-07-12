# Built-in Skill Library 정정판 독립 재검증 (YARD-006)

검증일: 2026-07-12 (Asia/Seoul)  
검증 대상: YARD-005 정정판 3개 문서, 직접 인용한 workspace 경로, pinned upstream 원문  
최종 판정: **승인**

AC-001부터 AC-007까지 모두 통과했다. YARD-004의 차단 사유 F-001부터 F-005는 정정판에서
해소됐고, 같은 읽기 전용 명령군과 같은 8행 classifier matrix를 다시 적용했을 때 재현됐다.
따라서 이 문서가 정한 연구 결과는 fresh install built-in skill library의 후속 구현 입력으로 사용할 수
있다. 실제 skill 생성, 설치, classifier 구현, release는 이번 승인 범위에 포함되지 않는다.

## 1. 확인 방법

YARD-004 review의 명령군을 그대로 사용했다.

```bash
git status --short --branch
git log --name-status -- docs/research/builtin-skill-local-evidence.md \
  docs/research/builtin-skill-candidate-ledger.md docs/builtin-skill-library.md

# local evidence 1.1절 mapping 적용 후 일반 path는 test -e, glob은 zsh glob expansion
find <workspace> -maxdepth 2 -name project.godot -type f
test -e <workspace>/<resolved-alias>/<cited-path>

# local-reference-catalog는 metadata만 실측
wc -l <workspace>/local-reference-catalog/catalog/skills.tsv
find <workspace>/local-reference-catalog/skills -mindepth 1 -maxdepth 1 -type d
find <workspace>/local-reference-catalog/presets -name '*.skills'
grep -cve '^[[:space:]]*$' <workspace>/local-reference-catalog/presets/core.skills

# upstream은 읽기 전용 GET만 사용
gh api repos/<org>/<repo>
gh api repos/<org>/<repo>/commits/<full-sha>
gh api 'repos/<org>/<repo>/git/trees/<full-sha>?recursive=1'
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/<full-sha>/<path>
```

후보 script는 실행하지 않았다. GitHub와 raw content에는 GET만 사용했고 secret, 로그인, 외부 쓰기
권한, public origin mutation은 사용하지 않았다. 로컬 code 회귀 확인은 `cargo test`로 수행했다.

## 2. YARD-004 차단 사유 재검증

### F-001 해소: alias mapping과 로컬 경로

`docs/research/builtin-skill-local-evidence.md:25-65`에 alias mapping과 `workspace-game`의 결정적
resolution 규칙이 생겼다. backtick path를 추출하고 mapping을 치환한 뒤 일반 path에는 `test -e`,
glob에는 zsh glob existence 검사를 적용했다. 세부 인용 108개가 모두 존재했고 catalog root도 별도로
존재했다. `find <workspace> -maxdepth 2 -name project.godot`는 한 건만 반환했고 교차 fingerprint도
존재했다. 비공개 game repo의 실명은 기록하지 않았다.

local reference catalog 실측도 문서와 일치했다.

| 관찰 | 재검증 값 |
|---|---:|
| `catalog/skills.tsv` | 91행, header + identifier 90개 |
| `skills/` 1-depth directory | 90개 |
| `presets/*.skills` | 22개 |
| `presets/core.skills` non-empty member | 7개 |
| catalog Git HEAD | 없음 |
| 2-depth LICENSE/README/provenance/version metadata | 없음 |

`docs/research/builtin-skill-local-evidence.md:71-113`의 LE/WF 인용도 위 존재 검사에 포함됐다.
`workspace-content-pipeline` worktree variant는 `.git` 파일의 `gitdir:`로 primary와 구분됐고 primary checkout 두 곳은
`.git` directory를 가졌다. 따라서 AC-001의 repo/path 단위 재현성과 비복제 비교 경계가 충족됐다.

### F-002 해소: 채택 11종의 실제 배포 대상과 위험 표면

공통 upstream을 다시 확인했다.

- `obra/superpowers@d884ae04edebef577e82ff7c4e143debd0bbec99`: commit 존재,
  `archived=false`, repo MIT license blob `abf0390...`.
- `anthropics/skills@9d2f1ae187231d8199c64b5b762e1bdf2244733d`: commit 존재,
  `archived=false`, 채택 3종의 skill별 Apache-2.0 license blob 확인.
- `mcp-builder`와 `webapp-testing` license blob은 `4f881c5...`, `frontend-design`은 별도 blob
  `f433b1a...`이며 전문은 Apache-2.0이다.

원출처 tree와 raw 본문을 8.1절(`docs/builtin-skill-library.md:236-259`)에 대조한 결과다.

| Member | pinned 원본 inventory | 원문 위험 또는 trigger | 8.1절 정정판 판정 |
|---|---:|---|---|
| SPW-01 | 2 files | local test only | 2 files 포함, 잔여 추가 권한 없음 |
| SPW-02 | 11 files | L93-105 env, keychain, `codesign` 예시 | 예시 블록과 fixture 5종 제외, 선택 script만 남김 |
| SPW-03 | 1 file | local verification | 단일 문서 포함, 요구 없음 |
| SPW-04 | 2 files | L61 등의 미채택 REQUIRED SUB-SKILL | 참조 제거와 task 내부 계획 재범위화 전 설치 금지 |
| SPW-06 | 2 files | reviewer subagent dispatch | Yardlet review task로 번역 |
| SPW-07 | 1 file | feedback 수신 시 trigger | `review-feedback` overlay로 단일 배정 |
| SPW-08 | 1 file | L121-125 `git push`, PR 선택지 | NeedsUser와 기존 push gate 뒤로 이동 |
| SPW-13 | 7 files | subagent pressure test, graphviz, `render-graphs.js` | script/asset/전제 문서 제외와 본문 재작성 전 설치 금지 |
| ANT-02 | 10 files | SKILL.md WebFetch, eval API key/network | script 4 files 제외, 본문 fetch는 task 시점 network opt-in |
| ANT-03 | 6 files | Python Playwright와 browser | browser task overlay, 최초 설치 network opt-in |
| ANT-04 | 2 files | UI 신규 구축·개편 trigger | `ui-design` overlay로 단일 배정 |

특히 YARD-004가 찾은 SPW-02의 secret-adjacent tool surface, SPW-13의 본문 내 subagent/graphviz
지시, ANT-02의 본문 WebFetch가 후보 원장 `:159-175,261-280,313-332`와 결정 문서
`:60,102,131,191-195,247,253-255`에 모두 반영됐다. adaptation 미완료 상태의 설치 금지도
8.1절에 명시됐다. AC-003과 AC-005의 최소 권한 조건을 충족한다.

### F-003 해소: full SHA와 DS-01 분리

후보 원장 `docs/research/builtin-skill-candidate-ledger.md:88-97`의 full SHA 7개를 GitHub commit
API에서 전부 확인했다. KDS-01과 HDN-01의 조사 시점 HEAD도 각각 문서의 full SHA와 같았다.
2026-07-12 재확인 기준으로 모든 원천은 `archived=false`였고 ledger의 license 상태와 일치했다.

Agent Skills 공식 사양은
`agentskills/agentskills@38a2ff82958afee88dadf4831509e6f7e9d8ef4e`의
`docs/specification.mdx`에서 재확인했다. `name`, `description`, 부모 directory 일치,
`compatibility`, experimental `allowed-tools`, `scripts/references/assets`, progressive disclosure와
500줄 권고에 대한 원장 `:49-70` 요약은 원문과 일치한다.

aggregator는 후보 요약표에 존재하지 않는다. 원장 `:403-410`에서 DS-01
`not-a-candidate`로, 결정 문서 `:183,228`에서 discovery 전용 비후보로만 존재한다. 반면
SPW/ANT/GGL/GHC/KDS/HDN candidate ID는 모두 full SHA가 있는 Git 원출처를 가리킨다. AC-002를
충족한다.

### F-004 해소: 3계층과 member 유일성

결정 문서 `docs/builtin-skill-library.md:30-49`는 설치와 활성화를 분리하고 core, preset, overlay의
수명을 정의한다. `:51-76`의 core workflow는 C1부터 C7까지 정확히 7개다.

8.1절을 기계적으로 추출한 결과 member row는 11개, unique member도 11개였고 기대 집합과 정확히
일치했다.

- Core 5: SPW-01, SPW-02, SPW-03, SPW-04, SPW-06
- Preset 1: ANT-02
- Overlay 5: SPW-07, SPW-08, SPW-13, ANT-03, ANT-04

YARD-004의 불일치 대상 SPW-07, SPW-08, ANT-04는 각각 원문 trigger와 같은 task-lifetime overlay로
이동했다(`docs/builtin-skill-library.md:128-131,251-256`). 같은 member가 두 계층에 나타나지 않는다.
AC-004를 충족한다.

### F-005 해소: explicit 충돌과 I4

결정 문서 `docs/builtin-skill-library.md:155-173`은 같은 대상의 explicit positive와 explicit
negative가 함께 있으면 negative가 이기는 fail-closed 규칙을 명시한다. 입력 순서와 무관하고 충돌
기록도 남기므로 같은 입력에 같은 결과가 나온다.

외부 skill 채택 정책은 `docs/builtin-skill-library.md:181-195,261-272`에서 기존 SOT를 따른다.
`docs/skills.md:33-39`의 I4는 skill에 별도 human gate가 없고 자동 절차와 opt-out을 두며,
`docs/identity.md:84-90`은 human gate를 push, deploy, secrets 같은 irreversible 또는
outward-facing 작업에 유보한다. 정정판은 외부 skill 채택에 새 gate를 만들지 않고 provenance/license,
정적 위험 검사, canonical single-writer, post-apply 평가를 fail-closed gate로 사용한다. network,
secret, browser 같은 실제 사용 권한은 기존 opt-in에 남긴다. 따라서 정책 SOT와 모순이 없다.

## 3. 제외 후보 위험 기반 표본

YARD-004와 같은 위험 표본을 pinned source에서 다시 확인했다.

| ID | 재검증 근거 | 판정 |
|---|---|---|
| ANT-06 | 5 files, init script가 pnpm 전역 설치와 다수 package install 수행 | network 과다 제외 타당 |
| ANT-07 | SKILL.md 1개, skill LICENSE 없음, repo license null | license 불명 제외 타당 |
| ANT-08 | docx 61 files, 제한적 LICENSE 전문 | 재배포 제외 타당 |
| SPW-11 | SKILL.md, parallel subagent dispatcher | Yardlet queue 경계 충돌 제외 타당 |
| SPW-12 | 6 files, subagent session과 실행 script 종속 | 제외 타당 |
| SPW-14 | 4 files, 1% 가능성에도 skill 강제 invoke | packet catalog dispatcher 충돌 제외 타당 |
| HDN-01 | `f7a43d8...`, repo license null | license/provenance 제외 타당 |

앞선 license 또는 수요 gate에서 제외된 후보의 `전수 미평가` 표기는 pass가 아니라 blocked evidence로
원장 `:139-141`에 정의돼 있다. 제외 상태가 바뀌면 후속 정적 검증을 먼저 해야 하므로 미확인 사항이
최소 세트로 승격되지 않는다.

## 4. Deterministic classifier 예시 matrix

YARD-004와 같은 8개 입력을 문서 규칙으로 두 번 판정했다. 두 실행의 결과가 모두 같았다.

| 입력 신호 | 결과 A | 결과 B | 판정 |
|---|---|---|---|
| `Cargo.toml` + bin target + clap | `cli-rust`, core | 동일 | Pass |
| workspace `package.json` + React + component path + 복수 package | `web-ui` + `fullstack-monorepo`, core | 동일 | Pass |
| React Native dependency + `android/` + `ios/` | `native-mobile`, core | 동일 | Pass |
| code manifest 없음 + `CONVENTIONS.md` + docs templates | `docs-knowledge`, core | 동일 | Pass |
| `Dockerfile` 존재, task는 UI text 수정 | deploy overlay 없음 | 동일 | Pass |
| web path + screenshot task + 승인 없음 | `browser-visual-evidence` 선택, 권한 blocked | 동일 | Pass |
| scaffold README + Vite manifest + explicit `web-ui 사용` | explicit override로 `web-ui` | 동일 | Pass |
| explicit `web-ui 사용` + explicit `web-ui 금지` | `web-ui` 비활성, negative-wins | 동일 | Pass |

## 5. AC verdict

| Criterion | 판정 | 재현 근거 |
|---|---|---|
| AC-001 | **Pass** | 1.1절 mapping 적용 세부 인용 108개 + catalog root 존재, game 유일 resolution, catalog 91/90/22/7 실측 |
| AC-002 | **Pass** | 공식 spec과 원천 7개의 full SHA 확인, KDS/HDN HEAD 일치, DS-01 candidate 원장 분리 |
| AC-003 | **Pass** | 채택 11종의 pinned tree, license, 본문·script 요구 전수 대조. 제외 위험 표본 7종 재검증 |
| AC-004 | **Pass** | core workflow 7개, 8.1절 11 row/11 unique, SPW-07/SPW-08/ANT-04 task overlay 정합 |
| AC-005 | **Pass** | 8행 classifier 반복 결과 일치, explicit 충돌 negative-wins, 권한 기본 거부, I4 SOT 일치 |
| AC-006 | **Pass** | 정정 작성자와 분리된 YARD-006 reviewer가 산출물, workspace, pinned upstream을 재검증했고 미평가 항목을 채택 근거로 사용하지 않음 |
| AC-007 | **Pass** | 시작 anchor가 이미 보고한 5개 baseline 변경을 preflight에서 확인했다. 이번 reviewer의 workspace 변경은 이 review 문서와 worker contract 필수 run 산출물뿐이며 code, skill, release, public origin을 변경하지 않음 |

## 6. Findings와 최종 승인

차단 finding은 없다. critical, major, minor finding도 발견하지 않았다. 따라서 최소 수정 요구와
remediation follow-up은 없다.

최종 승인 범위는 연구 결정의 검증까지다. 실제 built-in 파일 생성·복사·설치, init/auto_equip,
runtime classifier/loader/registry 구현, V010, release는 여전히 별도 승인과 별도 task가 필요하다.
