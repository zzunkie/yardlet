# Built-in Skill Candidate Ledger (YARD-002)

> Yardlet fresh install에 번들할 built-in skill 후보의 외부 원출처 원장.
> 최소 세트 확정(YARD-003)과 독립 검증(YARD-004)의 입력 문서이며, 이 문서 자체는
> 어떤 skill 파일도 생성/복사/설치하지 않는다.
> 정정: 2026-07-12 (YARD-005) — YARD-004 review F-002·F-003 반영. KDS-01·HDN-01 commit 고정,
> aggregator를 DS-01로 분리(5.1절), SPW-02/04/07/08/13과 ANT-02/04의 실제 요구·trigger 보강.
> 잔여 정정: 2026-07-12 (YARD-008). 동일 pinned tree를 다시 대조해 SPW-02 fixture와
> GHC-01 inventory 수치를 바로잡고, SPW-13 포함 예정 본문의 모든 외부·도구·worker·비용 표면과
> ANT-02의 task 수명 network 요구를 단일 계층 결정에 반영했다.

## 0. 조사 메타

| 항목 | 값 |
|---|---|
| 조사 기준일 | 2026-07-12 (Asia/Seoul) |
| 조사 주체 | Yardlet run `run-20260712-151807-yard-002` (task YARD-002, researcher) |
| 조사 방법 | GitHub REST API(`gh api`)로 repo metadata, git tree, blob을 commit 고정 상태로 조회. 파일 본문은 `raw.githubusercontent.com/<org>/<repo>/<commit>/<path>` 정적 열람 |
| 실행 안전성 | 후보 저장소 clone 없음, bundled script 실행 0회, 로그인/쓰기 작업 0회, secret 제공 0회. 모든 network 접근은 읽기 전용 GET |
| license 판별 | repo-level license API + skill별 LICENSE 파일 blob SHA 비교(동일 SHA = 동일 전문) 후 blob 본문 확인 |
| 재검증 (YARD-005) | 2026-07-12: 제외 후보 commit 고정(KDS/HDN), 채택 후보 SKILL.md 본문 표면 재검증(읽기 전용 GET). 명령은 8절 |
| 재검증 (YARD-008) | 2026-07-12: SPW-02/SPW-13/GHC-01 tree와 SPW-13·ANT-02 pinned 본문 및 포함 예정 참고문을 읽기 전용 GET으로 재검증. script 실행 0회. 명령은 8절 |

## 1. Source selection 기준

후보 원천(repository)은 아래 5개 기준을 모두 통과해야 원장 등재 대상이 된다.
star 수는 참고 신호일 뿐 단독 선정 근거로 쓰지 않는다.

1. **표준 정합성**: Agent Skills 표준(2절)의 SKILL.md 구조를 따르는 실제 skill을 배포한다.
2. **공식성 또는 검증 가능한 maintainer**: 표준 제정 조직, first-party vendor org,
   또는 신원이 공개된 활동적 maintainer가 관리한다.
3. **유지 증거**: `archived: false`이고 조사 기준일로부터 30일 이내 push가 있다.
4. **License 명시**: repo-level 또는 skill-level license가 파일로 존재하고 재배포 가능 여부를 판정할 수 있다.
5. **Commit 고정 가능**: 공개 git 저장소로서 immutable commit SHA 단위 참조와 재검증이 가능하다.

디렉토리형 aggregator(skills.sh, openagentskills.dev, skillsmp.com, skills.rest 등)는
원출처가 아니라 색인이므로 provenance anchor로 쓰지 않으며, candidate ID를 부여하지 않고
discovery source로만 분리 관리한다(5.1절 DS-01).

## 2. Agent Skills 공식 표준

- 표준 주체: Anthropic이 최초 개발 후 open standard로 공개, 현재 `agentskills` GitHub org에서 공동 관리.
  근거: https://agentskills.io (Open development 절), 사양 원문 저장소
  https://github.com/agentskills/agentskills (license Apache-2.0, archived=false, pushed 2026-07-10).
- 사양 영구 인용(commit 고정):
  https://github.com/agentskills/agentskills/blob/38a2ff82958afee88dadf4831509e6f7e9d8ef4e/docs/specification.mdx
  (게시본: https://agentskills.io/specification)
- Anthropic 공식 skill 저장소의 spec 사본은 위 사이트로 이관됨을 명시:
  https://github.com/anthropics/skills/blob/9d2f1ae187231d8199c64b5b762e1bdf2244733d/spec/agent-skills-spec.md
- 참조 validator: `skills-ref`
  https://github.com/agentskills/agentskills/tree/38a2ff82958afee88dadf4831509e6f7e9d8ef4e/skills-ref

### 2.1 필수 사항 (spec 기준)

| 필드 | 제약 |
|---|---|
| `name` | 필수. 1-64자, lowercase 영숫자와 hyphen만, hyphen 시작/끝/연속 금지, **부모 디렉토리명과 일치** |
| `description` | 필수. 1-1024자, 무엇을 하는지와 언제 쓰는지를 함께 기술 |
| 구조 | skill = `SKILL.md`를 가진 디렉토리. frontmatter(YAML) + Markdown body |

### 2.2 권고/선택 사항 (spec 기준)

| 필드/규칙 | 내용 |
|---|---|
| `license` | 선택. license 이름 또는 번들 license 파일 참조 |
| `compatibility` | 선택, 최대 500자. 요구 환경(제품, system package, network 접근 등)이 있을 때만 |
| `metadata` | 선택. string-to-string map, 표준 외 속성 저장용 |
| `allowed-tools` | 선택, experimental. 사전 승인 tool의 공백 구분 목록. 구현체별 지원 상이 |
| progressive disclosure | metadata(~100 tokens) -> SKILL.md body(<5000 tokens 권장) -> 참조 파일(필요 시) 3단계 로딩 |
| 크기 권고 | SKILL.md 500줄 미만 유지, 상세 자료는 `references/` 분리, 참조는 skill root 기준 상대 경로 1단계 |
| 선택 디렉토리 | `scripts/`(실행 코드), `references/`(문서), `assets/`(정적 자원) |

Yardlet 함의: `allowed-tools`는 experimental이므로 built-in 후보의 권한 판정은
frontmatter가 아니라 bundled 파일의 정적 inspection(4절)으로 한다.

## 3. Repository 유지/공식성 판정 매트릭스

조사 기준일 2026-07-12 시점 GitHub API 값. "판정"은 1절 기준 통과 여부.

| repo | 공식성 | archived | 최근 push | HEAD commit | license | stars | 판정 |
|---|---|---|---|---|---|---|---|
| `agentskills/agentskills` | 표준 org (spec + validator) | false | 2026-07-10 | `38a2ff8` | Apache-2.0 | 22.9k | 표준 원천으로 채택 |
| `anthropics/skills` | Anthropic 공식 | false | 2026-07-01 | `9d2f1ae` | repo-level 없음, skill별 LICENSE.txt | 160.4k | 후보 원천 채택 (license는 skill 단위 판정) |
| `obra/superpowers` | 공개 maintainer(obra, Jesse Vincent), 다중 harness 지원 | false | 2026-07-10 | `d884ae0` | MIT | 252.6k | 후보 원천 채택 |
| `google/skills` | Google 공식 (Cloud Next 2026 발표) | false | 2026-07-10 | `b128758` | Apache-2.0 | 14.5k | 원천 유효, 현 수요와 무관(4.4절 GGL-01) |
| `github/awesome-copilot` | GitHub org 공식 curation | false | 2026-07-11 | `30472ec` | MIT | 36.5k | on-demand research 원천만(4.4절 GHC-01) |
| `K-Dense-AI/scientific-agent-skills` | 기업 org, 과학 도메인 특화 | false | 2026-07-08 | `4d97e29` | MIT | 30.7k | 제외, 도메인 무관(5절 KDS-01) |
| `hoodini/ai-agents-skills` | 개인 curation, AI 생성 명시 | false | 2026-07-11 | `f7a43d8` | 없음(null) | 246 | 제외, license 불명(5절 HDN-01) |
| `openai/codex` | OpenAI 공식 | false | 2026-07-11 | 고정 불요(후보 아님) | Apache-2.0 | 97.3k | skill 소비자(harness)이며 skill library 아님, 원장 비대상 |
| `anthropics/claude-code` | Anthropic 공식 | false | 2026-07-11 | 고정 불요(후보 아님) | repo license null | 137.5k | 동일, harness repo로 비대상 |

pinned commit 전체 SHA:
- `anthropics/skills@9d2f1ae187231d8199c64b5b762e1bdf2244733d` (2026-07-01)
- `obra/superpowers@d884ae04edebef577e82ff7c4e143debd0bbec99` (2026-07-02)
- `agentskills/agentskills@38a2ff82958afee88dadf4831509e6f7e9d8ef4e` (2026-07-10)
- `google/skills@b1287583ccfaa32e65b34f274e62ebdab4cb35eb` (2026-07-10)
- `github/awesome-copilot@30472ecf0fe34cc561df958c08501ecc5ca80ea4` (2026-07-10)
- `K-Dense-AI/scientific-agent-skills@4d97e293dc6f604fb6b63dcd49b9028df413d65b` (2026-07-12 조사 시점 HEAD, 제외 후보 pin — YARD-005)
- `hoodini/ai-agents-skills@f7a43d8f852550a4f834240dc874cf9f56e7eec7` (2026-07-12 조사 시점 HEAD, 제외 후보 pin — YARD-005, YARD-004 검증 시점 SHA와 동일)

제외 후보의 pin은 "조사가 본 상태"를 고정하는 감사 anchor이며 채택 가능성을 뜻하지 않는다.

## 4. 후보 원장

상태 코드: **E**(eligible, 정적 검증 완료) / **C**(conditional, adaptation 전제 eligible) /
**X**(excluded, 8절에 사유). "실행 시 요구"는 skill이 지시하는 작업을 worker가 수행할 때
필요한 권한이고, "설치 시 요구"는 파일 번들 자체를 배치할 때 필요한 것(모든 후보 공통: 없음,
정적 파일 복사만)이다. bundled script는 전부 미실행 정적 목록화다.

### 4.1 요약표

| ID | skill | upstream | license | scripts | 실행 시 network | 실행 시 secret·tool·subagent | 상태 |
|---|---|---|---|---|---|---|---|
| SPW-01 | test-driven-development | obra/superpowers | MIT | 없음 | 불필요 | 없음 | E |
| SPW-02 | systematic-debugging | obra/superpowers | MIT | sh 1 | 불필요 | SKILL.md 예시가 env dump·keychain 열람·codesign 표면 포함(제거 대상, 4.2절) | E |
| SPW-03 | verification-before-completion | obra/superpowers | MIT | 없음 | 불필요 | 없음 | E |
| SPW-04 | writing-plans | obra/superpowers | MIT | 없음 | 불필요 | 미채택 subagent 계열 skill 참조 문구(제거 대상), git commit 지시(로컬) | C |
| SPW-05 | executing-plans | obra/superpowers | MIT | 없음 | 불필요 | 세션 분리 실행 모델 | C |
| SPW-06 | requesting-code-review | obra/superpowers | MIT | 없음 | 불필요 | subagent dispatch 지시(review task로 번역 대상) | C |
| SPW-07 | receiving-code-review | obra/superpowers | MIT | 없음 | 불필요 | 없음 | E |
| SPW-08 | finishing-a-development-branch | obra/superpowers | MIT | 없음 | 불필요 | git merge·`git push -u origin`·PR 선택지(승인 gate 대상, 4.2절) | C |
| SPW-09 | using-git-worktrees | obra/superpowers | MIT | 없음 | 불필요 | git worktree 조작(로컬) | C |
| SPW-10 | brainstorming | obra/superpowers | MIT | js/sh 4 + html 1 | 선택(로컬 서버 + 외부 이미지 1) | 로컬 포트 listen | C |
| SPW-11 | dispatching-parallel-agents | obra/superpowers | MIT | 없음 | 불필요 | 병렬 subagent dispatcher | X |
| SPW-12 | subagent-driven-development | obra/superpowers | MIT | bash 3 | 불필요 | subagent 세션 구조 종속 | X |
| SPW-13 | writing-skills | obra/superpowers | MIT | js 1 | 원문 SKILL.md의 외부 spec 링크와 포함 예정 참고문의 외부 문서·원격 이미지 링크(제거 대상, 4.2절) | raw API·single-shot subagent·반복 호출 비용, graphviz·shell, push/PR, Claude 전용 API·MCP·package 도구 표면(제거 대상, 4.2절) | C |
| SPW-14 | using-superpowers | obra/superpowers | MIT | 없음 | 불필요 | skill 강제 dispatch 메타 지시 | X |
| ANT-01 | skill-creator | anthropics/skills | Apache-2.0 | py 9 + eval-viewer | 불필요(eval은 로컬 `claude -p` 구동) | eval이 `claude` CLI subprocess 구동(비용 지점) | C |
| ANT-02 | mcp-builder | anthropics/skills | Apache-2.0 | py 2 + requirements | **필요: SKILL.md 본문 WebFetch 지시 + eval API 호출**(4.3절) | eval에 ANTHROPIC_API_KEY(배포 제외 대상) | C |
| ANT-03 | webapp-testing | anthropics/skills | Apache-2.0 | py 4 | 설치성 의존(playwright) 시 필요 | python3 + playwright/browser 바이너리 | C |
| ANT-04 | frontend-design | anthropics/skills | Apache-2.0 | 없음 | 불필요 | 없음 | E |
| ANT-05 | claude-api | anthropics/skills | Apache-2.0 | 없음(md 60+) | 불필요(내용상 API 사용 안내) | 없음(문서) | C |
| ANT-06 | web-artifacts-builder | anthropics/skills | Apache-2.0 | sh 2 + tar.gz | 필요(npm/pnpm 설치) | 전역 패키지 설치 도구 | X |
| ANT-07 | doc-coauthoring | anthropics/skills | **불명** | 없음 | 불필요 | 전수 미평가(license 단계 배제) | X |
| ANT-08 | docx | anthropics/skills | 독점(source-available) | 다수 | 전수 미평가(license 단계 배제) | 전수 미평가(license 단계 배제) | X |
| ANT-09 | pdf | anthropics/skills | 독점(source-available) | 다수 | 전수 미평가(license 단계 배제) | 전수 미평가(license 단계 배제) | X |
| ANT-10 | pptx | anthropics/skills | 독점(source-available) | 다수 | 전수 미평가(license 단계 배제) | 전수 미평가(license 단계 배제) | X |
| ANT-11 | xlsx | anthropics/skills | 독점(source-available) | 다수 | 전수 미평가(license 단계 배제) | 전수 미평가(license 단계 배제) | X |
| ANT-12 | 창작/기업용 6종 묶음 | anthropics/skills | Apache-2.0 | 일부 | 일부 필요 | 전수 미평가(수요 단계 배제) | X |
| GGL-01 | google/skills 전체(72) | google/skills | Apache-2.0 | 일부 | skill별 상이(전수 미평가, 비번들) | skill별 상이(전수 미평가, 비번들) | X |
| GHC-01 | awesome-copilot skills(386) | github/awesome-copilot | MIT | skill별 상이 | skill별 상이(전수 미평가, 비번들) | skill별 상이(전수 미평가, 비번들) | X |

"전수 미평가"는 앞선 gate(license 또는 수요)에서 제외가 확정되어 이후의 전수 정적 검사를 수행하지
않았다는 blocked-evidence 표기이며 pass가 아니다. 제외 상태가 바뀌려면 해당 검사를 먼저 통과해야 한다.
제외 후보의 위험 기반 표본 재검증 결과는 `docs/reviews/builtin-skill-library-review.md` 4절에 있다.

### 4.2 후보 상세 (obra/superpowers)

공통 provenance chain: GitHub org `obra`(공개 maintainer Jesse Vincent) -> repo `superpowers`
-> `skills/<name>/` @ `d884ae04edebef577e82ff7c4e143debd0bbec99` -> repo-level `LICENSE`(MIT).
skill별 LICENSE 파일은 없고 frontmatter에 license 필드도 없으므로 repo MIT가 전 skill에 적용된다.
공통 permalink 형식: `https://github.com/obra/superpowers/blob/d884ae04edebef577e82ff7c4e143debd0bbec99/skills/<name>/SKILL.md`

#### SPW-01 test-driven-development [E]
- source path: `skills/test-driven-development/`
- bundled: `SKILL.md`, `testing-anti-patterns.md` (모두 문서, script/asset 없음)
- 요구: network/secret/tool 없음. 지시 내용은 로컬 테스트 실행(기존 worker 권한 내)
- activation 범위: core 후보. 모든 구현 task에 적용 가능(언어 무관)
- overlap: `local-reference-catalog` `delivery-cycle`(식별자 수준, 내용 미비교), 로컬 yard skill 없음
- adaptation: 낮음. Claude Code 가정 표현 소폭 중립화
- verification: static-verified @ `d884ae0`

#### SPW-02 systematic-debugging [E]
- source path: `skills/systematic-debugging/`
- bundled: `SKILL.md`, 참조 문서 4(`root-cause-tracing.md`, `defense-in-depth.md`,
  `condition-based-waiting.md`, `condition-based-waiting-example.ts`), script 1(`find-polluter.sh`,
  로컬 테스트 이분탐색, network 호출 없음), skill 자체 테스트용 fixture 5
  (`CREATION-LOG.md` 1개 + `test-*.md` 4개)
- 정적 확인(YARD-005 보강): SKILL.md 본문의 multi-layer 디버깅 예시(pinned L91-106)가
  secret-bearing env 출력(`echo "IDENTITY: ${IDENTITY:+SET}..."`, `env | grep IDENTITY`),
  macOS keychain 열람(`security list-keychains`, `security find-identity -v`), `codesign` 실행을
  포함한다. secret 값 자체를 요구하지는 않으나 secret 인접 env·keychain·서명 tool 표면을 여는
  지시다(YARD-004 F-002)
- 요구: 로컬 테스트 실행 권한. network 없음. 단 위 예시 블록은 기본 배포에서 제거해야 하며,
  제거 전 상태로는 "secret/tool 요구 없음"이라 기록할 수 없다
- activation 범위: core 후보. 버그/테스트 실패 시 trigger
- overlap: 로컬 yard `golden-failed-check-repair`(범위 좁음, 보완 관계)
- adaptation: 중상. fixture 문서(test-*.md) 번들 제외, `find-polluter.sh`는 선택 동봉,
  L91-106 예시 블록은 제거 또는 중립 예시로 대체(제거 전 설치 금지)
- verification: static-verified @ `d884ae0` (본문 표면 재검증 2026-07-12)

#### SPW-03 verification-before-completion [E]
- source path: `skills/verification-before-completion/`
- bundled: `SKILL.md` 단일
- 요구: 없음
- activation 범위: core 후보. 완료 주장/commit 직전 trigger. Yardlet evaluator 및
  verdict 계약(docs/skills.md의 structured review verdicts)과 정합
- overlap: 로컬 yard `git-finish`, `git-finish-4`(git 종결 특화, 보완), `local-reference-catalog` `delivery-cycle`(식별자 수준)
- adaptation: 낮음
- verification: static-verified @ `d884ae0`

#### SPW-04 writing-plans [C]
- source path: `skills/writing-plans/`
- bundled: `SKILL.md`, `plan-document-reviewer-prompt.md`
- 정적 확인(YARD-005 보강): SKILL.md L61이 미채택 skill들을 "REQUIRED SUB-SKILL: Use
  superpowers:subagent-driven-development (recommended) or superpowers:executing-plans"로 지시한다
  (둘 다 이 원장에서 제외/조건부 상태). 또한 빈번한 git commit을 계획 단계에 포함하도록 지시한다(로컬)
- 요구: 로컬 git 작업 외 없음. 단 위 참조 문구를 제거하지 않으면 번들이 존재하지 않는 skill을
  요구하는 죽은 지시가 된다
- activation 범위: core 후보이나 조건부. Yardlet은 planner가 intent/queue를 이미 생성하므로
  이 skill은 "task 내부 구현 계획" 용도로 재범위화해야 함
- overlap: **높음**. Yardlet planner(`src/planner.rs`), 로컬 yard `planning-gate`,
  `local-reference-catalog` `planning-gate`(식별자 수준)
- adaptation: 높음(범위 재정의 + 미채택 skill 참조 문구 제거. 둘 다 없이는 설치 불가)
- verification: static-verified @ `d884ae0` (본문 표면 재검증 2026-07-12)

#### SPW-05 executing-plans [C]
- source path: `skills/executing-plans/`, bundled: `SKILL.md` 단일, 요구 없음
- activation 범위: 조건부. "별도 세션에서 계획 실행" 모델은 Yardlet queue 실행과 중복
- overlap: Yardlet work-queue 실행 모델 자체
- adaptation: 높음. SPW-04와 묶어 판단 권장
- verification: static-verified @ `d884ae0`

#### SPW-06 requesting-code-review [C]
- source path: `skills/requesting-code-review/`
- bundled: `SKILL.md`, `code-reviewer.md`(reviewer prompt)
- 요구: 없음(지시상 subagent dispatch 가정)
- activation 범위: core 후보. Yardlet에서는 subagent가 아니라 review task(kind: review) 생성으로 번역 필요
- overlap: Yardlet reviewer role + verdict 계약, `local-reference-catalog` `review-pr`(식별자 수준)
- adaptation: 중간(subagent 표현을 Yardlet queue 용어로)
- verification: static-verified @ `d884ae0`

#### SPW-07 receiving-code-review [E]
- source path: `skills/receiving-code-review/`, bundled: `SKILL.md` 단일, 요구 없음
- activation 범위: overlay 후보. review feedback 수신/반영 시 trigger. pinned frontmatter 원문도
  "Use when receiving code review feedback, before implementing suggestions"로 task 시점 trigger를
  명시한다(YARD-005 재확인)
- overlap: 낮음
- adaptation: 낮음
- verification: static-verified @ `d884ae0` (frontmatter 재검증 2026-07-12)

#### SPW-08 finishing-a-development-branch [C]
- source path: `skills/finishing-a-development-branch/`, bundled: `SKILL.md` 단일
- 정적 확인(YARD-005 보강): 본문 선택지가 git merge뿐 아니라 `git push -u origin <branch>`와
  PR 생성(pinned L121-132)을 포함한다. 초판의 "git 로컬 작업만" 기록은 틀렸다: push는 외부
  mutation 지시 표면이다(YARD-004 F-002). frontmatter trigger도 "Use when implementation is
  complete, all tests pass, and you need to decide how to integrate"로 종결 시점 task를 명시한다
- 요구: git 로컬 작업 + push/PR 선택지(외부 mutation, 승인 gate 대상)
- activation 범위: overlay 후보. branch 종결/통합 결정 task에서 trigger(YARD-004 F-004 반영,
  초판의 "core 또는 overlay" 이중 표기를 overlay로 확정)
- overlap: **높음**. 로컬 yard `git-finish`, `git-finish-4`, `process-git-finish`(이미 학습된 자산이 더 구체적)
- adaptation: 중간. merge/PR 선택지 제시를 Yardlet NeedsUser 결정 흐름에 연결하고, push는
  기존 승인 gate 뒤에 두며 자동 push는 금지
- verification: static-verified @ `d884ae0` (본문 표면 재검증 2026-07-12)

#### SPW-09 using-git-worktrees [C]
- source path: `skills/using-git-worktrees/`, bundled: `SKILL.md` 단일, 요구: git 로컬 작업만
- activation 범위: 조건부. Yardlet이 worktree 생성/정리를 이미 기계적으로 수행
- overlap: Yardlet worktree 메커니즘, `.agents/rules/worktree-tooling.md`, multi-session-safety rule
- adaptation: 높음(수동 절차 부분 삭제 필요), 규칙과 중복이면 미채택이 타당
- verification: static-verified @ `d884ae0`

#### SPW-10 brainstorming [C]
- source path: `skills/brainstorming/`
- bundled: `SKILL.md`, 문서 2(`spec-document-reviewer-prompt.md`, `visual-companion.md`),
  scripts 5(`server.cjs` 로컬 HTTP 서버, `helper.js`, `frame-template.html`,
  `start-server.sh`, `stop-server.sh`)
- 외부 endpoint(정적 발견): `server.cjs:106`이 로고 이미지
  `https://primeradiant.com/brand/superpowers-visual-brainstorming-logo.png` 참조(장식용).
  실행 시 로컬 포트 listen 필요. secret 불요
- activation 범위: overlay 후보. 설계 전 대화형 탐색. Yardlet discuss-mode 부재로 현재는 제한적
- overlap: Yardlet planner interview 단계와 부분 중복
- adaptation: 높음. visual-companion script 일체 제거(문서만 채택)를 전제로 C
- verification: static-verified @ `d884ae0`

#### SPW-13 writing-skills [C]
- source path: `skills/writing-skills/`
- bundled: `SKILL.md`, 문서 4(`anthropic-best-practices.md`, `persuasion-principles.md`,
  `testing-skills-with-subagents.md`, `examples/CLAUDE_MD_TESTING.md`),
  `graphviz-conventions.dot`(asset), `render-graphs.js`(script, 로컬 graphviz 필요)
- immutable 원문 표면 전수 확인(YARD-008, `d884ae0`):

  | 표면 | pinned 근거 | 원문에서 발생하는 요구 |
  |---|---|---|
  | external URL | `SKILL.md` L96, L638의 `https://agentskills.io/specification` | 링크를 따라가면 task-time network |
  | subagent·worker | L14, L34, L162, L236-253, L558-587의 pressure scenario·dispatch·RED/GREEN 반복 | fresh-context worker/subagent 실행과 Yardlet queue 경계 충돌 |
  | API·비용 | L577-585의 "slow and expensive", raw API call 또는 single-shot subagent, variant별 5회 이상 반복 | provider API 또는 worker CLI 비용이 반복 수만큼 발생. API secret은 원문에 직접 명시되지 않았지만 실제 provider 호출은 worker profile·billing gate 밖에서 자동 실행할 수 없음 |
  | local tool | L261-266 `wc`, L292-321 Graphviz·`render-graphs.js` | shell, Node 실행과 graphviz 설치 필요 |
  | external mutation | L664-666의 fork push·PR | git remote write와 PR 생성 승인 필요 |
  | cross-skill | L18, L393의 `superpowers:test-driven-development` 필수 전제 | Yardlet 번들 이름·activation과 맞지 않는 외부 skill 의존 |

- 포함 예정 참고문도 전수 확인했다. `anthropic-best-practices.md`는 1,150줄이며
  `platform.claude.com`, `code.claude.com` 문서 링크, `mintcdn.com` 원격 이미지 3종과 srcset을
  포함한다. 또한 Claude Haiku/Sonnet/Opus 비교, Claude.ai와 Anthropic API의 network/package
  차이, npm·PyPI·GitHub package pull, bash/filesystem/code execution, MCP의
  `BigQuery:bigquery_schema`·`GitHub:create_issue` 예시를 지시한다. 즉 그대로 포함하면 external
  network, Claude 전용 runtime/API, package 설치, MCP tool 및 외부 mutation 표면이 생긴다.
  `persuasion-principles.md`에는 URL/API/subagent/tool/secret 지시가 없었다.
- 제외 예정인 `testing-skills-with-subagents.md`와 `examples/CLAUDE_MD_TESTING.md`도 Claude Code
  subagent 세션 모델과 `~/.claude/skills` 경로를 전제한다. script/asset만 제외해서는 부족하다.
- 요구(원문): network(external spec/docs/images), provider API 또는 configured worker 반복 비용,
  subagent dispatch, shell/Node/graphviz, package 설치, MCP tools, push/PR. 직접 secret 문자열을
  요구하지는 않지만 provider API·external mutation은 기존 gate 밖에서 실행할 수 없다.
- activation 범위: overlay 후보. skill 작성/개선 시 trigger
- overlap: **높음**. Yardlet S2/S3 `skill_author`(docs/skills.md), ANT-01 skill-creator
- adaptation: 높음. 동봉은 self-contained 재작성 `SKILL.md`와
  `persuasion-principles.md`만이다. 나머지 문서·script·asset은 전부 제외한다. 재작성본에는 pinned
  Agent Skills 필수 구조를 짧은 local checklist로 직접 넣고, external URL, raw API/subagent 반복,
  Graphviz/render, external push/PR, Claude 전용 model/runtime/MCP/package 지시를 제거한다. 검증은
  Yardlet의 기존 `skill_author` task와 evaluator/review 계약으로 번역한다. 잔여 요구는 configured
  queue에 명시적으로 배정된 configured `skill_author`·evaluator·review worker 호출 비용뿐이며,
  별도 raw API 반복이나 추가 network·secret·tool·subagent·external mutation은 없다. 이 제거판이
  작성·검증되기 전에는 설치하지 않는다.
- verification: static-verified @ `d884ae0` (본문과 포함 예정 참고문 표면 재검증 2026-07-12)

### 4.3 후보 상세 (anthropics/skills)

공통 provenance chain: GitHub org `anthropics`(vendor 공식) -> repo `skills` ->
`skills/<name>/` @ `9d2f1ae187231d8199c64b5b762e1bdf2244733d` -> skill별 `LICENSE.txt`.
license blob 판별(동일 SHA = 동일 전문):
- Apache-2.0 (blob `4f881c5`, 11개 + `frontend-design`의 별도 blob `f433b1a`도 Apache-2.0 전문):
  algorithmic-art, brand-guidelines, canvas-design, claude-api, internal-comms, mcp-builder,
  skill-creator, slack-gif-creator, theme-factory, web-artifacts-builder, webapp-testing, frontend-design
- 독점 source-available (blob `c55ab42`, "© 2025 Anthropic, PBC. All rights reserved... governed by
  your agreement with Anthropic"): docx, pdf, pptx, xlsx
- LICENSE 파일 없음: doc-coauthoring (repo-level license도 null)

README(pinned)도 문서 4종을 "source-available, not open source"로 명시:
`https://github.com/anthropics/skills/blob/9d2f1ae187231d8199c64b5b762e1bdf2244733d/README.md`

#### ANT-01 skill-creator [C]
- source path: `skills/skill-creator/`
- bundled: `SKILL.md`, `LICENSE.txt`, agents 문서 3(`analyzer.md`, `comparator.md`, `grader.md`),
  `references/schemas.md`, `assets/eval_review.html`, `eval-viewer/`(py 1 + html 1),
  `scripts/` py 9(`__init__.py`, `quick_validate.py`, `package_skill.py`, `utils.py`,
  `run_eval.py`, `run_loop.py`, `aggregate_benchmark.py`, `generate_report.py`, `improve_description.py`)
- 정적 확인: `quick_validate.py`/`package_skill.py`/`utils.py`는 로컬 파일 작업만(직접 network import 없음).
  `run_eval.py`는 `claude -p` subprocess를 구동(로컬 worker CLI 재사용, 직접 API 호출 없음).
  단, eval 실행은 worker CLI 비용 발생 지점이므로 Yardlet billing guard 관점에서 명시적 실행으로 제한 필요
- 요구: 설치 시 없음. eval 계열 실행 시 python3 + `claude` CLI. secret 직접 요구 없음
- activation 범위: overlay 후보. skill 작성/평가 시 trigger
- overlap: **높음**. Yardlet S2/S3 skill_author, SPW-13
- adaptation: 높음. Yardlet은 자체 skill 작성 경로가 있으므로 검증 script(`quick_validate.py`)와
  구조 가이드만 발췌 참조가 적정. 전체 번들 채택은 과잉
- verification: static-verified @ `9d2f1ae`

#### ANT-02 mcp-builder [C]
- source path: `skills/mcp-builder/`
- bundled: `SKILL.md`, `LICENSE.txt`, reference 문서 4(python/node best practices, evaluation),
  `scripts/` py 2(`connections.py`, `evaluation.py`) + `example_evaluation.xml` + `requirements.txt`
- 정적 확인: `requirements.txt`= `anthropic>=0.39.0`, `mcp>=1.1.0`. `evaluation.py`가
  `from anthropic import Anthropic`으로 **실행 시 Anthropic API(=API key, network) 필요**.
  Yardlet 기본 sanitized env(billing var 스크럽, `src/guard.rs`)와 충돌하므로 eval script는
  기본 비활성 문서화 필요
- 정적 확인(YARD-005 보강): eval script와 별개로 **SKILL.md 본문 자체가 network를 지시한다**
  (YARD-004 F-002). pinned 본문이 `https://modelcontextprotocol.io/sitemap.xml`과 `.md` 페이지
  fetch, 그리고 "Use WebFetch to load `https://raw.githubusercontent.com/modelcontextprotocol/typescript-sdk/main/README.md`"
  (python-sdk 동일)를 지시한다. SDK README 참조는 **미고정 `main` branch**라서 내용이 변할 수 있다.
  따라서 `scripts/` 제외만으로는 실행 시 network 요구가 제거되지 않는다
- 요구: 설치 시 없음. 본문 절차 수행 시 외부 문서 fetch(network, opt-in 대상).
  eval 실행 시 pip install + ANTHROPIC_API_KEY + network(배포 제외 대상)
- activation 범위: `mcp-authoring` task-triggered overlay 후보. MCP/agent repo라는 이유만으로
  상시 활성화하지 않고, MCP server 작성·개선 task에서만 trigger한다. 현재 workspace 수요는 낮음
- overlap: 낮음
- adaptation: 높음(초판 "중간"에서 상향). scripts/requirements 제외 + SKILL.md 본문의 WebFetch
  지시 구간을 task 시점 network opt-in으로 명시 재작성(미고정 main 참조 경고 포함). network 요구를
  유지하므로 product preset이 아니라 `mcp-authoring` overlay에만 단일 배정한다. 미충족 시 미설치
- verification: static-verified @ `9d2f1ae` (본문 표면 재검증 2026-07-12)

#### ANT-03 webapp-testing [C]
- source path: `skills/webapp-testing/`
- bundled: `SKILL.md`, `LICENSE.txt`, `scripts/with_server.py`,
  examples py 3(`console_logging.py`, `element_discovery.py`, `static_html_automation.py`)
- 정적 확인: `with_server.py`는 stdlib만 사용(subprocess로 지정 서버 명령 실행, localhost socket 대기).
  외부 endpoint 없음. 단 SKILL.md가 Python Playwright 사용을 지시하므로 **미설치 환경에서는
  playwright 설치(=network) 선행 필요**
- 요구: 설치 시 없음. 실행 시 python3 + playwright(+ 브라우저 바이너리 다운로드는 최초 1회 network)
- activation 범위: preset 후보(web-ui repo). 실제 workspace 수요와 직결
  (예: `workspace-web-platform`의 `.claude/skills/agent-browser` 운용, `docs/testing` 관행.
  alias 해석은 local evidence 문서 1.1절의 결정적 fingerprint를 따른다)
- overlap: `local-reference-catalog` `browser-evidence`/`e2e-testing`(식별자 수준), workspace-local `agent-browser`(로컬)
- adaptation: 중간(Claude Code 가정 중립화, worktree-tooling rule과 연결)
- verification: static-verified @ `9d2f1ae`

#### ANT-04 frontend-design [E]
- source path: `skills/frontend-design/`
- bundled: `SKILL.md`, `LICENSE.txt`만(순수 문서형)
- 요구: 없음
- activation 범위: overlay 후보(YARD-005 정정). pinned description 원문이 "when building new UI
  or reshaping an existing one"으로 task 시점 trigger를 명시하므로, 초판의 "preset 후보(repo
  수명)" 표기는 실제 trigger와 불일치했다(YARD-004 F-004). web-ui로 분류된 repo의 UI 신규
  구축/개편 task에서만 활성화하는 task-triggered overlay가 맞다
- overlap: `local-reference-catalog` `ui-design-system`/`ui-ux-pro-max`(식별자 수준, 내용 미비교)
- adaptation: 낮음
- verification: static-verified @ `9d2f1ae` (frontmatter 재검증 2026-07-12)

#### ANT-05 claude-api [C]
- source path: `skills/claude-api/`
- bundled: `SKILL.md`, `LICENSE.txt` + 언어별 reference 문서 60+ (curl/go/java/php/python/ruby/
  typescript/csharp + `shared/` 26종). script 없음
- 요구: 문서 자체는 없음(내용이 Claude API 사용을 다루므로 실제 작업 시 API key는 사용자 소관)
- activation 범위: preset 후보(AI-agent app repo). 현 workspace에서는 yard 자체가 worker CLI 기반이라 수요 제한적
- overlap: 낮음
- adaptation: 중간. 전량 번들은 과대(60+ 파일). 채택 시 shared 핵심만 발췌하거나 on-demand로 유보
- verification: static-verified @ `9d2f1ae` (파일 inventory 기준, 본문 전수 열람 아님)

### 4.4 저장소 단위 참고 원천 (built-in 비채택)

#### GGL-01 google/skills [X: 수요 무관]
- upstream: `google/skills` @ `b1287583ccfaa32e65b34f274e62ebdab4cb35eb`, Apache-2.0, 72 skills
- 구조 특이점: `skills/<category>/<name>/SKILL.md` 2단 배치(ads, cloud 등 카테고리 상위 디렉토리)
- 판정: 전부 Google 제품 특화(Google Ads API, Mobile Ads, IMA SDK 등). 현재 workspace의
  repo archetype(Rust CLI, React web)과 무관하여 built-in 후보 없음. on-demand research 원천으로 유효

#### GHC-01 github/awesome-copilot [X: per-skill provenance 이질]
- upstream: `github/awesome-copilot` @ `30472ecf0fe34cc561df958c08501ecc5ca80ea4`, MIT,
  pinned recursive tree의 `skills/**/SKILL.md` 386개(`truncated=false`)
- 판정: org는 공식이나 내용물은 다수 기여자의 community curation이라 skill 단위 품질/provenance가
  균질하지 않음. 386개 전수 정적 검증 없이는 built-in 번들 불가. 개별 skill을 on-demand
  research(discovery -> 검증 -> 격리 생성) 경로로만 인용

## 5. 제외 목록 (exclusion reasons)

| ID | 대상 | 제외 사유 |
|---|---|---|
| ANT-07 | doc-coauthoring | **license 불명**: skill 디렉토리에 LICENSE.txt 없음 + repo-level license null. 재배포 가능성 판정 불가 |
| ANT-08..11 | docx/pdf/pptx/xlsx | **재배포 불가 license**: blob `c55ab42` 전문이 Anthropic 약관 종속을 명시(source-available). fresh install 번들 = 재배포에 해당 |
| ANT-06 | web-artifacts-builder | **용도 비적합 + 실행 시 network 과다**: claude.ai artifact 전용, `init-artifact.sh`가 npm/pnpm 전역 설치와 다수 패키지 다운로드 수행 |
| ANT-12 | algorithmic-art, brand-guidelines, canvas-design, internal-comms, slack-gif-creator, theme-factory | **수요 무관**: Apache-2.0로 license는 적격이나 현 workspace repo archetype에 대응 수요 없음. 필요 시 on-demand 재평가 |
| SPW-11 | dispatching-parallel-agents | **아키텍처 충돌**: Claude Code subagent 모델 전제. Yardlet의 queue-vs-subagent 경계(docs/parallel-queue.md)와 상충, 오작동 지시 위험 |
| SPW-12 | subagent-driven-development | 동일 충돌 + bundled bash 3종이 subagent 세션 구조에 종속 |
| SPW-14 | using-superpowers | **주입 모델 충돌**: 자체 skill 탐색/강제 활성화 메타 지시. Yardlet은 packet catalog 주입(H1)이 담당하므로 이중 dispatcher가 됨 |
| KDS-01 | K-Dense-AI/scientific-agent-skills | **도메인 무관**: 과학 연구 특화 140종. 현 workspace 수요 없음(MIT, 유지 상태는 양호). 조사 시점 pin `4d97e29`(3절) |
| HDN-01 | hoodini/ai-agents-skills | **license 없음(null) + 개인 AI 생성 curation**: provenance 신뢰 근거 부족. 조사 시점 pin `f7a43d8`(3절) |
| (비대상) | openai/codex, anthropics/claude-code | skill 소비 harness이지 skill library가 아님 |

초판의 AGG-01(디렉토리형 aggregator)은 이 표에서 제거했다. commit 고정이 원천적으로 불가능해
candidate ID 체계와 어울리지 않는다는 지적(YARD-004 F-003)에 따라 5.1절의 discovery source로 분리했다.

### 5.1 Discovery source 목록 (candidate 아님)

| ID | 대상 | 상태 | 사유 |
|---|---|---|---|
| DS-01 (구 AGG-01) | skills.sh, openagentskills.dev, skillsmp.com, skills.rest 등 디렉토리형 aggregator | not-a-candidate | 원출처가 아닌 색인/미러. commit 고정과 provenance anchor가 원천적으로 불가능하므로 후보 원장 등재 대상이 아니다(1절 기준 5 위배). on-demand research의 discovery 단계 출발점으로만 쓴다(결정 문서 7절 1단계) |

candidate ID(SPW/ANT/GGL/GHC/KDS/HDN)는 전부 commit 고정 가능한 git 원출처만 가리키고,
DS 계열은 검증 상태 `not-a-candidate`로 어떤 계층에도 배정될 수 없다.

## 6. Overlap 및 로컬 비교 근거

### 6.1 로컬 yard `.agents/skills` (11종 설치)와의 겹침
- `planning-gate` vs SPW-04/05: 계획 산출 절차 중복. Yardlet planner가 상위에 있으므로 외부 후보는 재범위화 필수
- `git-finish`, `git-finish-4`, `process-git-finish(-fixture)` vs SPW-08: 로컬 학습 자산이 더 구체적(증거 독립 검증 절차 포함). SPW-08 채택 시 보완 관계로만
- `golden-failed-check-repair` vs SPW-02: 특정 실패 재현 vs 일반 디버깅 방법론, 보완 관계
- `trust-autonomy`, `tui`, `v09-audit-evidence-map`, `i18n-leak-audit`, `mirror-readme-*`: 외부 후보와 겹침 없음(repo 고유)

### 6.2 `local-reference-catalog` 비교 (읽기 전용, 비복제 원칙)
- 참고 범위: `catalog/skills.tsv`(91행, 컬럼 `name/tier/presets/description/triggers`)와
  `presets/*.skills` 22종의 **식별자와 구조 관찰만** 기록했다. skill 본문, preset 정의 전문,
  디렉토리 구조는 이 원장에 복제하지 않으며 정답 원장으로 채택하지 않는다.
- 관찰 사실(식별자 수준): tier 체계(core/preset/opt_in/internal)와 core preset 7종
  (`session-start`, `session-end`, `planning-gate`, `review-pr`, `reflection`, `delivery-cycle`,
  `autonomous-work-loop`) 구성이 존재. 외부 후보와 이름이 유사한 항목(planning-gate, review-pr,
  browser-evidence, e2e-testing, ui-design-system 등)이 있으나 **내용 비교는 수행하지 않음**
- 시사점(비복제 관찰): "7개 이하 core + repo-type preset + opt_in overlay"라는 계층 자체는
  본 intent의 요구 구조와 부합함을 확인. 구체 구성은 YARD-001 로컬 수요 근거와 이 원장에서 독립 도출해야 함

### 6.3 후보 간 겹침
- SPW-13(writing-skills)과 ANT-01(skill-creator): 동일 목적(skill 작성). 동시 채택 금지 권고,
  Yardlet skill_author의 참고 문헌으로 택1
- SPW-04/05(writing/executing-plans)와 Yardlet planner/queue: 구조적 중복, 재범위화 없이 동시 사용 불가
- SPW-08과 SPW-03: 종결 검증 절차 일부 중복(verification 우선, finishing은 git 흐름 특화)

## 7. Yardlet adaptation 공통 노트

- 주입 경로: 채택 skill은 `.agents/skills/<name>/SKILL.md`로 배치되어 packet catalog(H1)로
  progressive load된다(docs/skills.md). name은 spec 2.1의 디렉토리 일치 규칙을 지켜야 함
- 권한 모델: Yardlet worker env는 기본 sanitized(billing 스크럽, `src/guard.rs` + `.agents/billing-policy.yaml`).
  ANT-02 eval처럼 API key를 요구하는 script는 번들에서 제외하거나 opt-in(`invocation.pass_env`) 문서화 필요.
  script 제외로 요구가 사라지지 않는 경우도 있다: ANT-02는 SKILL.md 본문이 WebFetch를, SPW-02는
  본문 예시가 env/keychain/codesign을, SPW-13은 본문과 포함 예정 참고문이 external URL,
  API/subagent 반복 비용, graphviz·package·MCP·push/PR 표면을 지시하므로 본문 수정과 참고문 제외까지가
  adaptation 범위다(각 후보 상세 참조)
- 용어 중립화: superpowers 계열의 "subagent/dispatch" 표현은 Yardlet의 task queue 용어로 재작성
  (queue-vs-subagent 경계: docs/parallel-queue.md)
- 단일 작성자 원칙: 어떤 후보도 worker가 직접 설치하지 않는다. 설치는 향후 구현(out of scope)에서
  `src/state.rs` 경유로만(본 intent에서는 파일 배치 자체가 범위 밖)

## 8. Verification status 요약과 재현 방법

| 상태 | 대상 |
|---|---|
| static-verified (commit 고정 + license 전문 + 파일 inventory + script 정적 열람) | SPW-01..10, SPW-13, ANT-01..05 |
| static-verified + 본문 표면 재검증 (YARD-005/YARD-008, 2026-07-12: secret·network·tool·subagent·비용 지시 확인) | SPW-02, SPW-04, SPW-07, SPW-08, SPW-13, ANT-02, ANT-04 |
| static-verified (inventory 수준, 본문 전수 미열람) | ANT-05 reference 문서군, ANT-12 묶음, GGL-01, GHC-01 |
| excluded (근거는 5절; KDS/HDN은 조사 시점 commit pin 포함) | ANT-06..12, SPW-11/12/14, GGL-01, GHC-01, KDS-01, HDN-01 |
| not-a-candidate (5.1절, commit 고정 원천 불가) | DS-01 |

재현 명령(읽기 전용):
```bash
# repo 유지/공식성
gh api repos/<org>/<repo> --jq '{archived, pushed_at, license: .license.spdx_id}'
# pinned tree와 inventory
gh api "repos/anthropics/skills/git/trees/9d2f1ae187231d8199c64b5b762e1bdf2244733d?recursive=1"
gh api "repos/obra/superpowers/git/trees/d884ae04edebef577e82ff7c4e143debd0bbec99?recursive=1"
# immutable inventory 수치(YARD-008): 각각 4와 386, 두 tree 모두 truncated=false
gh api "repos/obra/superpowers/git/trees/d884ae04edebef577e82ff7c4e143debd0bbec99?recursive=1" \
  --jq '[.tree[].path | select(test("^skills/systematic-debugging/test-.*\\.md$"))] | length'
gh api "repos/github/awesome-copilot/git/trees/30472ecf0fe34cc561df958c08501ecc5ca80ea4?recursive=1" \
  --jq '[.tree[].path | select(test("^skills/.*/SKILL\\.md$"))] | length'
# license 전문 (blob SHA는 4.3절)
gh api repos/anthropics/skills/git/blobs/c55ab42224874608473643de0a85736b7fec0730 --jq .content | base64 -d
# 파일 본문 정적 열람
curl -s https://raw.githubusercontent.com/<org>/<repo>/<commit>/<path>
# 제외 후보의 조사 시점 HEAD pin (YARD-005)
gh api repos/K-Dense-AI/scientific-agent-skills/commits/HEAD --jq .sha   # 4d97e293dc6f604fb6b63dcd49b9028df413d65b
gh api repos/hoodini/ai-agents-skills/commits/HEAD --jq .sha             # f7a43d8f852550a4f834240dc874cf9f56e7eec7
```

## 9. 한계와 후속 입력

- ANT-05, ANT-12, GGL-01, GHC-01은 파일 inventory와 표본 열람까지만 수행했다(전수 본문 열람 아님).
  최종 채택 시(YARD-003) 채택 대상에 한해 본문 전수 열람을 조건으로 붙인다
- superpowers는 단일 maintainer 저장소다. 유지 증거는 현재 양호하나, built-in 채택 시
  commit 고정 + 로컬 fork 보관(원문 보존) 전략이 필요하다는 점을 YARD-003 정책 입력으로 남긴다
- 이 원장은 후보의 "무엇을"만 확정한다. 7개 이하 core workflow 선별, preset/overlay 계층 구성,
  deterministic classification, on-demand 확장 정책은 YARD-003의 산출물이다
- workspace 경로 alias(`workspace-web-platform` 등)의 실제 경로 해석은 local evidence 문서
  1.1절 mapping이 단일 근거다(YARD-005)
