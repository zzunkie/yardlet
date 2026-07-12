# Built-in Skill Library 독립 검증 (YARD-004 최종 재검증)

검증일: 2026-07-12 (Asia/Seoul)  
검증 대상: YARD-001부터 YARD-003까지의 현재 산출물, 직접 인용 workspace 경로, pinned upstream 원출처  
workspace 기준: `main@3f0b6f74466c93d688c78e30bd21ee4cdc648119`  
최종 판정: **승인**

AC-001부터 AC-007까지 모두 통과했다. 채택 11종은 모두 immutable commit, license, provenance,
원본 file inventory와 권한 표면을 원출처에서 다시 확인했다. 제외 후보는 license, 과도한 network,
subagent architecture 충돌 위험을 기준으로 7종을 표본 재검증했다. 미평가 후보는 pass로 승격하지
않고 blocked evidence로 유지된다.

## 1. 검증 범위와 방법

검증한 연구 산출물은 다음 3개다.

- `docs/research/builtin-skill-local-evidence.md`
- `docs/research/builtin-skill-candidate-ledger.md`
- `docs/builtin-skill-library.md`

주요 재현 명령은 다음과 같다. 외부 source의 script는 실행하지 않았고 GitHub REST API와 raw content
GET만 사용했다.

```bash
git status --short
git diff --name-only
git ls-files --others --exclude-standard
git diff -- src tests templates Cargo.toml Cargo.lock CHANGELOG.md README.md README.ko.md .agents/skills

# local evidence 1.1절 alias mapping 적용 후 File.exist?/Dir.glob으로 인용 검사
# 결과: checked=111 missing=0
wc -l <workspace>/local-reference-catalog/catalog/skills.tsv
find <workspace>/local-reference-catalog/skills -mindepth 1 -maxdepth 1 -type d | wc -l
find <workspace>/local-reference-catalog/presets -name '*.skills' | wc -l
grep -cve '^[[:space:]]*$' <workspace>/local-reference-catalog/presets/core.skills
find <workspace> -maxdepth 2 -name project.godot -type f

gh api repos/<org>/<repo>
gh api repos/<org>/<repo>/commits/<full-sha>
gh api 'repos/<org>/<repo>/git/trees/<full-sha>?recursive=1'
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/<full-sha>/<path>

cargo test
```

로컬 경로 검사는 evidence 문서 1.1절의 alias를 실제 workspace-relative path로 바꾼 뒤 일반 경로는
존재 여부, glob은 match 존재 여부를 확인했다. `workspace-game`은 `project.godot`의 유일 match와
교차 fingerprint를 사용했다. 결과는 111개 인용 모두 존재, game match 1개였다. `local-reference-catalog`는
`catalog/skills.tsv` 91행, skill directory 90개, preset 22개, core member 7개로 문서와 일치했다.
내용이나 preset 구조는 복제하지 않았다.

## 2. 공식 표준과 upstream 유지 상태

Agent Skills 표준은
`agentskills/agentskills@38a2ff82958afee88dadf4831509e6f7e9d8ef4e`의
[`docs/specification.mdx`](https://github.com/agentskills/agentskills/blob/38a2ff82958afee88dadf4831509e6f7e9d8ef4e/docs/specification.mdx)에서
확인했다. `SKILL.md`, `name`, `description`, 부모 directory 일치, 선택 `license`와 `compatibility`,
experimental `allowed-tools`, optional `scripts/references/assets`, progressive disclosure와 500줄 권고에
대한 후보 원장 2절의 요약이 원문과 일치한다.

2026-07-12에 각 repo metadata와 pinned commit endpoint를 다시 조회했다.

| 원천 | pinned full SHA | archived | 현재 license | 현재 HEAD 일치 | 판정 |
|---|---|---:|---|---:|---|
| `agentskills/agentskills` | `38a2ff82958afee88dadf4831509e6f7e9d8ef4e` | false | Apache-2.0 | 예 | 표준 원천 유지 |
| `anthropics/skills` | `9d2f1ae187231d8199c64b5b762e1bdf2244733d` | false | repo null, skill별 license | 예 | 채택 원천 유지 |
| `obra/superpowers` | `d884ae04edebef577e82ff7c4e143debd0bbec99` | false | MIT | 예 | 채택 원천 유지 |
| `google/skills` | `b1287583ccfaa32e65b34f274e62ebdab4cb35eb` | false | Apache-2.0 | 예 | 비번들 참고 원천 유지 |
| `github/awesome-copilot` | `30472ecf0fe34cc561df958c08501ecc5ca80ea4` | false | MIT | 예 | 비번들 discovery 원천 유지 |
| `K-Dense-AI/scientific-agent-skills` | `4d97e293dc6f604fb6b63dcd49b9028df413d65b` | false | MIT | 예 | 제외 pin 재현 |
| `hoodini/ai-agents-skills` | `f7a43d8f852550a4f834240dc874cf9f56e7eec7` | false | null | 예 | 제외 pin 재현 |

재현 URL 형식은 `https://api.github.com/repos/<org>/<repo>/commits/<full-sha>`다. 모든 pinned endpoint가
200 응답과 같은 full SHA를 반환했다. 후보 원장의 조사 시점 유지 상태와 license가 현재 원출처와
일치한다.

## 3. 최종 채택 후보 11종 전수 재검증

공통 provenance는 후보 원장 ID에서 public upstream, full SHA, source path로 이어진다.
`obra/superpowers` 채택분의 license는 pinned repo
[`LICENSE`](https://github.com/obra/superpowers/blob/d884ae04edebef577e82ff7c4e143debd0bbec99/LICENSE),
blob `abf0390320aa14406af7a520b9b0739fdda9bf08`의 MIT 전문이다. `anthropics/skills` 채택분은 각 skill의
`LICENSE.txt`를 확인했다. ANT-02와 ANT-03은 Apache-2.0 blob
`4f881c52d1f72f4cfb720e339e2d35c3058d01a9`, ANT-04는 Apache-2.0 blob
`f433b1a53f5b830a205fd2df78e2b34974656c7b`다.

| ID | pinned source와 원본 inventory | 원출처 요구 표면 | 결정 문서의 배포 판정 | 결과 |
|---|---|---|---|---|
| SPW-01 | `skills/test-driven-development`, 2 files | 로컬 test, 추가 network/secret/tool 없음 | 2 files 포함, 표현 중립화 | Pass |
| SPW-02 | `skills/systematic-debugging`, 11 files | `SKILL.md` L96-105의 env, keychain, `codesign`; shell 1 | 예시 제거, fixture `test-*.md` 4개와 creation log 제외, shell 선택 | Pass |
| SPW-03 | `skills/verification-before-completion`, 1 file | 로컬 validation만 | 단일 문서 포함 | Pass |
| SPW-04 | `skills/writing-plans`, 2 files | L61, L162-170의 미채택 subagent skill 참조 | 참조 제거와 task 내부 계획 재범위화 전 설치 금지 | Pass |
| SPW-06 | `skills/requesting-code-review`, 2 files | reviewer subagent dispatch | Yardlet review task로 번역 | Pass |
| SPW-07 | `skills/receiving-code-review`, 1 file | feedback 수신 task trigger, 추가 권한 없음 | `review-feedback` overlay에 단일 배정 | Pass |
| SPW-08 | `skills/finishing-a-development-branch`, 1 file | L121-125 `git push`, PR, branch cleanup 선택 | NeedsUser 및 push gate 뒤로 이동 | Pass |
| SPW-13 | `skills/writing-skills`, 7 files | 외부 spec URL, raw API/subagent 반복 비용, graphviz/render, push/PR, Claude API/MCP/package 표면 | self-contained `SKILL.md`와 `persuasion-principles.md`만 포함, 나머지 5 files 제외, 재작성 전 설치 금지 | Pass |
| ANT-02 | `skills/mcp-builder`, 10 files | `SKILL.md` L41-71/L203-213 WebFetch, eval의 Anthropic client/API key/network, requirements | scripts 2, XML, requirements 제외. 본문 fetch는 task-time network opt-in | Pass |
| ANT-03 | `skills/webapp-testing`, 6 files | Python, Playwright/browser, local server subprocess, 최초 설치 network | browser task overlay, 설치 network opt-in | Pass |
| ANT-04 | `skills/frontend-design`, 2 files | 순수 문서, UI 신규/개편 task trigger, 추가 권한 없음 | `ui-design` overlay에 단일 배정 | Pass |

원본 tree는 두 repo 모두 `truncated=false`였다. SPW-02의 `test-*.md`는 4개다.
`github/awesome-copilot@30472ec...`는 top-level skill directory 371개, 모든 depth의
`^skills/.*/SKILL.md$` 386개다. 후보 원장의 386 표기는 후자의 recursive 정의와 명령을 명시하므로
일치한다.

## 4. 제외 후보 위험 기반 표본

| ID | immutable source, license, bundled content | network, secret, tool, activation 위험 | 제외 판정 |
|---|---|---|---|
| ANT-06 | Anthropic pin, Apache-2.0, 5 files | init script가 `npm install -g pnpm`, Vite 및 다수 package install 수행 | 과도한 설치 network와 용도 부적합, 제외 타당 |
| ANT-07 | Anthropic pin, `SKILL.md` 1개, skill LICENSE 없음, repo license null | 문서 workflow이나 재배포 provenance가 license gate에서 막힘 | 불명 license, 제외 타당 |
| ANT-08 | Anthropic pin, docx 61 files, blob `c55ab42...` | source-available 약관이 제3자 배포를 금지 | fresh install 재배포 제외 타당 |
| SPW-11 | Superpowers pin, MIT, `SKILL.md` 1개 | parallel subagent dispatcher를 task trigger로 강제 | Yardlet queue 경계 충돌, 제외 타당 |
| SPW-12 | Superpowers pin, MIT, 6 files | subagent 세션과 bash script 3개 종속 | architecture와 tool 종속, 제외 타당 |
| SPW-14 | Superpowers pin, MIT, 4 files | 1% 가능성에도 skill invocation을 강제하는 이중 dispatcher | packet catalog 충돌, 제외 타당 |
| HDN-01 | `hoodini/...@f7a43d8...`, repo license null | 개인 AI-generated curation, provenance와 재배포 근거 부족 | 제외 타당 |

ANT-12, GGL-01, GHC-01처럼 앞선 수요 gate에서 제외된 묶음은 후보 원장 4.1절과 8절에서
`전수 미평가` 또는 inventory 수준으로 표시된다. 이는 pass가 아닌 blocked evidence이고, 채택 상태가
바뀌면 정적 전수 검증을 선행하도록 규정되어 있다.

## 5. 3계층, core 상한, classifier matrix

결정 문서 2절은 core를 모든 repo 상시, product preset을 repo 분류 이후 repo 수명, overlay를 관련
task 수명으로 정의한다. 같은 수요가 겹치면 더 짧은 수명에 배정하고 권한은 별도 opt-in으로 둔다.
8.1절 member matrix 집계는 11 row, 11 unique다.

| 계층 | member 수 | member |
|---|---:|---|
| Core | 5 | SPW-01, SPW-02, SPW-03, SPW-04, SPW-06 |
| Product preset | 0 | 없음, 11개 archetype은 gap candidate로 유지 |
| Task-triggered overlay | 6 | SPW-07, SPW-08, SPW-13, ANT-02, ANT-03, ANT-04 |

core workflow는 C1부터 C7까지 정확히 7개다. C2와 C7은 native mechanism/rule로 충족하는 member 없는
workflow이고, 조건부 member는 adaptation 완료 전 설치 금지다. ANT-02는 task-time network를
유지하므로 repo-lifetime preset이 아닌 `mcp-authoring` overlay에만 배정되어 비중첩 규칙과 일치한다.

같은 정책 규칙을 각 행에 두 번 적용했다. 두 번째는 입력 신호의 나열 순서만 반대로 했다.

| 입력 신호 | 결과 A | 결과 B | 판정 |
|---|---|---|---|
| `Cargo.toml` + bin target + clap | `cli-rust`, core | 동일 | Pass |
| `package.json` + React + component path | `web-ui`, core | 동일 | Pass |
| pnpm workspace + 복수 package + React | `web-ui` + `fullstack-monorepo`, core | 동일 | Pass |
| 이름은 mobile, 실제 PWA/relay, React Native/android/ios 없음 | 확인된 `web-ui`만 | 동일 | Pass |
| docs/templates/CONVENTIONS + code manifest 없음 | `docs-knowledge`, core | 동일 | Pass |
| `Dockerfile` + UI 개편 task + web-ui 확정 | `web-ui` + `ui-design`, deploy overlay 없음 | 동일 | Pass |
| explicit `web-ui 사용` + explicit `web-ui 금지` | `web-ui` 비활성, negative-wins | 동일 | Pass |
| manifest만 있고 2차 path/script 없음 | preset 없음, core-only | 동일 | Pass |

8행 모두 입력 순서와 무관하게 같은 결과다. explicit 내부 충돌은 negative-wins, manifest 단독은 미확정,
no-match는 core-only다. 분류는 network, secret, tool 또는 external mutation 권한을 부여하지 않는다.
확장 정책은 discovery, provenance/license, 정적 위험 검사, 기존 gate 정합, 격리 생성, deterministic
apply, post-apply 검증을 분리하며 기본 권한 거부를 명시한다.

## 6. AC-001부터 AC-007 판정

| Criterion | 판정 | 독립 재현 근거 |
|---|---|---|
| AC-001 | **Pass** | local evidence alias 적용 111개 인용 `missing=0`, game match 1개, catalog 91/90/22/7 실측. evidence 문서 1.1절, 2-4절에서 관찰과 inferred need를 분리하고 `local-reference-catalog` 비복제 경계를 명시 |
| AC-002 | **Pass** | 공식 spec과 7개 source full SHA의 commit endpoint를 재조회. 전부 접근 가능, `archived=false`, 현재 HEAD 및 license 상태가 원장 2-3절과 일치. DS-01은 candidate가 아닌 discovery source로 분리 |
| AC-003 | **Pass** | 채택 11종의 pinned tree, license blob, source path, bundled files, network/secret/tool/subagent surface를 전수 대조. 제외 위험 표본 7종 재검증. blocked evidence를 pass로 승격하지 않음 |
| AC-004 | **Pass** | 결정 문서 core workflow C1-C7 7개. 8.1절 11 row/11 unique, Core 5/Preset 0/Overlay 6. activation 수명과 member가 비중첩이며 모든 결정이 LE/WF/CORE-D/PRESET-D/OVERLAY-D/OC 및 candidate ID로 역추적 가능 |
| AC-005 | **Pass** | 8행 classifier를 신호 순서만 바꿔 반복해 전부 동일. explicit conflict negative-wins, no-match core-only, 권한 독립. 7절 확장 단계와 network/secret/tool 기본 거부가 `docs/skills.md` I4 및 `docs/identity.md` gate SOT와 일치 |
| AC-006 | **Pass** | reviewer가 현재 산출물, 직접 인용 workspace path, pinned upstream raw source를 독립 재검증하고 AC별 pass/fail을 기록했다. 접근 실패한 초기 license 명령은 재실행 전 근거로 사용하지 않았고 미평가 항목은 blocked evidence로 유지 |
| AC-007 | **Pass** | pre/post `git status`, diff, untracked 목록에서 intent 변경은 research 2개, decision 1개, review 2개와 packet이 요구한 현재 run 산출물뿐이다. `.agents/skills/builtin-evidence-citation-reverify/SKILL.md`는 없고 source/test/template/manifest/release/changelog diff도 없음. 외부는 GET만 사용 |

## 7. Findings와 변경 범위

차단 finding은 없다. critical, major, minor finding도 발견하지 않았다. 따라서 remediation follow-up은
필요하지 않다.

최종 workspace 변경 목록은 다음 범위다.

- 연구 문서: `docs/research/builtin-skill-local-evidence.md`,
  `docs/research/builtin-skill-candidate-ledger.md`
- 결정 문서: `docs/builtin-skill-library.md`
- 독립 review 문서: `docs/reviews/builtin-skill-library-review.md`,
  `docs/reviews/builtin-skill-library-reverification.md`
- worker contract가 요구한 현재 run의 `result.json`, `report.md`, `handoff.md`, `validation.log`

Rust source, tests, templates, manifest, release, changelog, 실제 `SKILL.md`, bundled script/asset/preset은
변경되지 않았다. public origin에 push, issue, PR 또는 catalog mutation을 수행하지 않았다.

**최종 승인.** 이 승인은 research 결과와 정책 결정의 검증까지만 포함한다. 실제 skill 생성, 복사,
설치, init/auto_equip/classifier/loader/registry 구현, V010, release는 별도 intent 없이는 시작하지 않는다.
