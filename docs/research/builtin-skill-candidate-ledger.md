# Built-in Skill Candidate Ledger (YARD-002)

> Yardlet fresh install에 번들할 built-in skill 후보의 외부 원출처 원장.
> 최소 세트 확정(YARD-003)과 독립 검증(YARD-004)의 입력 문서이며, 이 문서 자체는
> 어떤 skill 파일도 생성/복사/설치하지 않는다.

## 0. 조사 메타

| 항목 | 값 |
|---|---|
| 조사 기준일 | 2026-07-12 (Asia/Seoul) |
| 조사 주체 | Yardlet run `run-20260712-151807-yard-002` (task YARD-002, researcher) |
| 조사 방법 | GitHub REST API(`gh api`)로 repo metadata, git tree, blob을 commit 고정 상태로 조회. 파일 본문은 `raw.githubusercontent.com/<org>/<repo>/<commit>/<path>` 정적 열람 |
| 실행 안전성 | 후보 저장소 clone 없음, bundled script 실행 0회, 로그인/쓰기 작업 0회, secret 제공 0회. 모든 network 접근은 읽기 전용 GET |
| license 판별 | repo-level license API + skill별 LICENSE 파일 blob SHA 비교(동일 SHA = 동일 전문) 후 blob 본문 확인 |

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
원출처가 아니라 색인이므로 provenance anchor로 쓰지 않는다(8절 AGG-01).

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
| `google/skills` | Google 공식 (Cloud Next 2026 발표) | false | 2026-07-10 | `b128758` | Apache-2.0 | 14.5k | 원천 유효, 현 수요와 무관(8절 GGL-01) |
| `github/awesome-copilot` | GitHub org 공식 curation | false | 2026-07-11 | `30472ec` | MIT | 36.5k | on-demand research 원천만(8절 GHC-01) |
| `K-Dense-AI/scientific-agent-skills` | 기업 org, 과학 도메인 특화 | false | 2026-07-08 | (미고정) | MIT | 30.7k | 제외, 도메인 무관(8절 KDS-01) |
| `hoodini/ai-agents-skills` | 개인 curation, AI 생성 명시 | false | 2026-07-11 | (미고정) | 없음(null) | 246 | 제외, license 불명(8절 HDN-01) |
| `openai/codex` | OpenAI 공식 | false | 2026-07-11 | (미고정) | Apache-2.0 | 97.3k | skill 소비자(harness)이며 skill library 아님, 원장 비대상 |
| `anthropics/claude-code` | Anthropic 공식 | false | 2026-07-11 | (미고정) | repo license null | 137.5k | 동일, harness repo로 비대상 |

pinned commit 전체 SHA:
- `anthropics/skills@9d2f1ae187231d8199c64b5b762e1bdf2244733d` (2026-07-01)
- `obra/superpowers@d884ae04edebef577e82ff7c4e143debd0bbec99` (2026-07-02)
- `agentskills/agentskills@38a2ff82958afee88dadf4831509e6f7e9d8ef4e` (2026-07-10)
- `google/skills@b1287583ccfaa32e65b34f274e62ebdab4cb35eb` (2026-07-10)
- `github/awesome-copilot@30472ecf0fe34cc561df958c08501ecc5ca80ea4` (2026-07-10)

## 4. 후보 원장

상태 코드: **E**(eligible, 정적 검증 완료) / **C**(conditional, adaptation 전제 eligible) /
**X**(excluded, 8절에 사유). "실행 시 요구"는 skill이 지시하는 작업을 worker가 수행할 때
필요한 권한이고, "설치 시 요구"는 파일 번들 자체를 배치할 때 필요한 것(모든 후보 공통: 없음,
정적 파일 복사만)이다. bundled script는 전부 미실행 정적 목록화다.

### 4.1 요약표

| ID | skill | upstream | license | scripts | 실행 시 network | 상태 |
|---|---|---|---|---|---|---|
| SPW-01 | test-driven-development | obra/superpowers | MIT | 없음 | 불필요 | E |
| SPW-02 | systematic-debugging | obra/superpowers | MIT | sh 1 | 불필요 | E |
| SPW-03 | verification-before-completion | obra/superpowers | MIT | 없음 | 불필요 | E |
| SPW-04 | writing-plans | obra/superpowers | MIT | 없음 | 불필요 | C |
| SPW-05 | executing-plans | obra/superpowers | MIT | 없음 | 불필요 | C |
| SPW-06 | requesting-code-review | obra/superpowers | MIT | 없음 | 불필요 | C |
| SPW-07 | receiving-code-review | obra/superpowers | MIT | 없음 | 불필요 | E |
| SPW-08 | finishing-a-development-branch | obra/superpowers | MIT | 없음 | 불필요 | C |
| SPW-09 | using-git-worktrees | obra/superpowers | MIT | 없음 | 불필요 | C |
| SPW-10 | brainstorming | obra/superpowers | MIT | js/sh 4 + html 1 | 선택(로컬 서버 + 외부 이미지 1) | C |
| SPW-11 | dispatching-parallel-agents | obra/superpowers | MIT | 없음 | 불필요 | X |
| SPW-12 | subagent-driven-development | obra/superpowers | MIT | bash 3 | 불필요 | X |
| SPW-13 | writing-skills | obra/superpowers | MIT | js 1 | 불필요 | C |
| SPW-14 | using-superpowers | obra/superpowers | MIT | 없음 | 불필요 | X |
| ANT-01 | skill-creator | anthropics/skills | Apache-2.0 | py 9 + eval-viewer | 불필요(eval은 로컬 `claude -p` 구동) | C |
| ANT-02 | mcp-builder | anthropics/skills | Apache-2.0 | py 2 + requirements | eval 실행 시 필요(API key) | C |
| ANT-03 | webapp-testing | anthropics/skills | Apache-2.0 | py 4 | 설치성 의존(playwright) 시 필요 | C |
| ANT-04 | frontend-design | anthropics/skills | Apache-2.0 | 없음 | 불필요 | E |
| ANT-05 | claude-api | anthropics/skills | Apache-2.0 | 없음(md 60+) | 불필요(내용상 API 사용 안내) | C |
| ANT-06 | web-artifacts-builder | anthropics/skills | Apache-2.0 | sh 2 + tar.gz | 필요(npm/pnpm 설치) | X |
| ANT-07 | doc-coauthoring | anthropics/skills | **불명** | 없음 | 불필요 | X |
| ANT-08 | docx | anthropics/skills | 독점(source-available) | 다수 | (미평가) | X |
| ANT-09 | pdf | anthropics/skills | 독점(source-available) | 다수 | (미평가) | X |
| ANT-10 | pptx | anthropics/skills | 독점(source-available) | 다수 | (미평가) | X |
| ANT-11 | xlsx | anthropics/skills | 독점(source-available) | 다수 | (미평가) | X |
| ANT-12 | 창작/기업용 6종 묶음 | anthropics/skills | Apache-2.0 | 일부 | 일부 필요 | X |
| GGL-01 | google/skills 전체(72) | google/skills | Apache-2.0 | 일부 | skill별 상이 | X |
| GHC-01 | awesome-copilot skills(371) | github/awesome-copilot | MIT | skill별 상이 | skill별 상이 | X |

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
  로컬 테스트 이분탐색, network 호출 없음), skill 자체 테스트용 fixture 5(`CREATION-LOG.md`, `test-*.md`)
- 요구: 로컬 테스트 실행 권한만. network/secret 없음
- activation 범위: core 후보. 버그/테스트 실패 시 trigger
- overlap: 로컬 yard `golden-failed-check-repair`(범위 좁음, 보완 관계)
- adaptation: 중간. fixture 문서(test-*.md)는 번들에서 제외 권장, `find-polluter.sh`는 선택 동봉
- verification: static-verified @ `d884ae0`

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
- 요구: 없음
- activation 범위: core 후보이나 조건부. Yardlet은 planner가 intent/queue를 이미 생성하므로
  이 skill은 "task 내부 구현 계획" 용도로 재범위화해야 함
- overlap: **높음**. Yardlet planner(`src/planner.rs`), 로컬 yard `planning-gate`,
  `local-reference-catalog` `planning-gate`(식별자 수준)
- adaptation: 높음(범위 재정의 없이는 planner와 이중 계획 충돌)
- verification: static-verified @ `d884ae0`

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
- activation 범위: overlay 후보. review feedback 수신/반영 시 trigger
- overlap: 낮음
- adaptation: 낮음
- verification: static-verified @ `d884ae0`

#### SPW-08 finishing-a-development-branch [C]
- source path: `skills/finishing-a-development-branch/`, bundled: `SKILL.md` 단일, 요구: git 로컬 작업만
- activation 범위: core 또는 overlay 후보. 브랜치 종결 시 trigger
- overlap: **높음**. 로컬 yard `git-finish`, `git-finish-4`, `process-git-finish`(이미 학습된 자산이 더 구체적)
- adaptation: 중간. merge/PR 선택지 제시 부분은 Yardlet NeedsUser 결정 흐름과 연결 필요
- verification: static-verified @ `d884ae0`

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
- 요구: 실행 시 graphviz(선택). network/secret 불요
- activation 범위: overlay 후보. skill 작성/개선 시 trigger
- overlap: **높음**. Yardlet S2/S3 `skill_author`(docs/skills.md), ANT-01 skill-creator
- adaptation: 중간. Yardlet에서는 skill_author worker prompt의 참고 문헌 역할이 적합
- verification: static-verified @ `d884ae0`

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
- 요구: 설치 시 없음. eval 실행 시 pip install + ANTHROPIC_API_KEY + network
- activation 범위: preset 후보(ai-agent/MCP 개발 repo). 현재 workspace 수요는 낮음
- overlap: 낮음
- adaptation: 중간(eval script 제외 또는 opt-in 표기)
- verification: static-verified @ `9d2f1ae`

#### ANT-03 webapp-testing [C]
- source path: `skills/webapp-testing/`
- bundled: `SKILL.md`, `LICENSE.txt`, `scripts/with_server.py`,
  examples py 3(`console_logging.py`, `element_discovery.py`, `static_html_automation.py`)
- 정적 확인: `with_server.py`는 stdlib만 사용(subprocess로 지정 서버 명령 실행, localhost socket 대기).
  외부 endpoint 없음. 단 SKILL.md가 Python Playwright 사용을 지시하므로 **미설치 환경에서는
  playwright 설치(=network) 선행 필요**
- 요구: 설치 시 없음. 실행 시 python3 + playwright(+ 브라우저 바이너리 다운로드는 최초 1회 network)
- activation 범위: preset 후보(web-ui repo). 실제 workspace 수요와 직결
  (예: `workspace-web-platform`의 `.claude/skills/agent-browser` 운용, `docs/testing` 관행)
- overlap: `local-reference-catalog` `browser-evidence`/`e2e-testing`(식별자 수준), workspace-local `agent-browser`(로컬)
- adaptation: 중간(Claude Code 가정 중립화, worktree-tooling rule과 연결)
- verification: static-verified @ `9d2f1ae`

#### ANT-04 frontend-design [E]
- source path: `skills/frontend-design/`
- bundled: `SKILL.md`, `LICENSE.txt`만(순수 문서형)
- 요구: 없음
- activation 범위: preset 후보(web-ui repo의 UI 신규/개편 task trigger)
- overlap: `local-reference-catalog` `ui-design-system`/`ui-ux-pro-max`(식별자 수준, 내용 미비교)
- adaptation: 낮음
- verification: static-verified @ `9d2f1ae`

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
- upstream: `github/awesome-copilot` @ `30472ecf0fe34cc561df958c08501ecc5ca80ea4`, MIT, `skills/` 371개
- 판정: org는 공식이나 내용물은 다수 기여자의 community curation이라 skill 단위 품질/provenance가
  균질하지 않음. 371개 전수 정적 검증 없이는 built-in 번들 불가. 개별 skill을 on-demand
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
| KDS-01 | K-Dense-AI/scientific-agent-skills | **도메인 무관**: 과학 연구 특화 140종. 현 workspace 수요 없음(MIT, 유지 상태는 양호) |
| HDN-01 | hoodini/ai-agents-skills | **license 없음(null) + 개인 AI 생성 curation**: provenance 신뢰 근거 부족 |
| AGG-01 | skills.sh, openagentskills.dev, skillsmp.com, skills.rest 등 | **원출처 아님**: 색인/미러. commit 고정 불가, provenance anchor 부적격. discovery 용도로만 |
| (비대상) | openai/codex, anthropics/claude-code | skill 소비 harness이지 skill library가 아님 |

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
  ANT-02 eval처럼 API key를 요구하는 script는 번들에서 제외하거나 opt-in(`invocation.pass_env`) 문서화 필요
- 용어 중립화: superpowers 계열의 "subagent/dispatch" 표현은 Yardlet의 task queue 용어로 재작성
  (queue-vs-subagent 경계: docs/parallel-queue.md)
- 단일 작성자 원칙: 어떤 후보도 worker가 직접 설치하지 않는다. 설치는 향후 구현(out of scope)에서
  `src/state.rs` 경유로만(본 intent에서는 파일 배치 자체가 범위 밖)

## 8. Verification status 요약과 재현 방법

| 상태 | 대상 |
|---|---|
| static-verified (commit 고정 + license 전문 + 파일 inventory + script 정적 열람) | SPW-01..10, SPW-13, ANT-01..05 |
| static-verified (inventory 수준, 본문 전수 미열람) | ANT-05 reference 문서군, ANT-12 묶음, GGL-01, GHC-01 |
| excluded (근거는 5절) | ANT-06..12, SPW-11/12/14, GGL-01, GHC-01, KDS-01, HDN-01, AGG-01 |

재현 명령(읽기 전용):
```bash
# repo 유지/공식성
gh api repos/<org>/<repo> --jq '{archived, pushed_at, license: .license.spdx_id}'
# pinned tree와 inventory
gh api "repos/anthropics/skills/git/trees/9d2f1ae187231d8199c64b5b762e1bdf2244733d?recursive=1"
gh api "repos/obra/superpowers/git/trees/d884ae04edebef577e82ff7c4e143debd0bbec99?recursive=1"
# license 전문 (blob SHA는 4.3절)
gh api repos/anthropics/skills/git/blobs/c55ab42224874608473643de0a85736b7fec0730 --jq .content | base64 -d
# 파일 본문 정적 열람
curl -s https://raw.githubusercontent.com/<org>/<repo>/<commit>/<path>
```

## 9. 한계와 후속 입력

- ANT-05, ANT-12, GGL-01, GHC-01은 파일 inventory와 표본 열람까지만 수행했다(전수 본문 열람 아님).
  최종 채택 시(YARD-003) 채택 대상에 한해 본문 전수 열람을 조건으로 붙인다
- superpowers는 단일 maintainer 저장소다. 유지 증거는 현재 양호하나, built-in 채택 시
  commit 고정 + 로컬 fork 보관(원문 보존) 전략이 필요하다는 점을 YARD-003 정책 입력으로 남긴다
- 이 원장은 후보의 "무엇을"만 확정한다. 7개 이하 core workflow 선별, preset/overlay 계층 구성,
  deterministic classification, on-demand 확장 정책은 YARD-003의 산출물이다
