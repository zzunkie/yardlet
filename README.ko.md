# Yardlet

[![crates.io](https://img.shields.io/crates/v/yardlet.svg)](https://crates.io/crates/yardlet)
[![CI](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml/badge.svg)](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml)
[![downloads](https://img.shields.io/crates/d/yardlet.svg)](https://crates.io/crates/yardlet)
[![license: MIT](https://img.shields.io/crates/l/yardlet.svg)](LICENSE)

[English](README.md) | **한국어**

> **Rent the intelligence. Own the work.** (지능은 빌리고, 작업은 소유한다.)
> Yardlet은 몇 문장의 의도를 검증되고 지속되는 작업으로 바꾸는 루프를
> 직접 엔지니어링하는 로컬 콘솔입니다. 이미 설치된 코딩 에이전트를
> 교체 가능한 워커로 사용합니다.

![Yardlet terminal UI demo](docs/assets/yardlet-demo.gif)

*"저는 더 이상 Claude에게 프롬프트를 쓰지 않습니다. Claude에게 프롬프트를 던지고
무엇을 할지 판단하는 루프들을 돌릴 뿐이고, 제 일은 그 루프를 작성하는 것입니다."*
Anthropic의 Claude Code 리드가 자신의 워크플로를 이렇게 설명합니다. 그리고 이
실천에는 **loop engineering(루프 엔지니어링)** 이라는 이름이 붙었습니다. Yardlet은
그 실천을 모두를 위한 제품으로 만든 것입니다.

- **프롬프트는 작성하는 것이 아니라 컴파일됩니다.** 의도는 한 번만 진술합니다.
  모든 워커 프롬프트는 당신이 소유한 계약, 규칙, 스킬, 역할 규율, 체크포인트로부터
  빌드됩니다. 이 입력을 개선하면 미래의 모든 프롬프트가 함께 개선됩니다.
- **루프는 벤더의 것이 아니라 당신의 것입니다.** 워커 중립(Claude Code, Codex,
  또는 하나의 계약 뒤에 있는 모든 CLI), 로컬(상태는 당신의 저장소에 존재),
  그리고 크래시, 재시작, 워커 교체에도 살아남습니다.
- **검증자는 결코 실행자가 아닙니다.** 결정론적 평가기가 모든 실행을 계약과
  대조해 검사하고, 위험한 계획에는 리뷰어 역할의 검증 작업이 붙습니다.
  "완료"는 스스로 보고하는 것이 아니라 획득하는 것입니다.

전체 정체성: [docs/identity.md](docs/identity.md).

```
사용자 의도 (몇 문장)
  -> planning gate            인텐트 / 스코프 / 수용 계약
  -> work queue               경계가 명확한 작업, 의존성, 병렬 준비됨
  -> packet compiler          당신이 소유한 상태로부터 빌드된 프롬프트
      -> hidden workers       claude / codex / 모든 CLI, 샌드박스, 라우팅 가능
  -> deterministic evaluator  완료는 선언이 아니라 검사됨
  -> checkpoint / handoff     지속되는 산출물, 영원히 재개 가능
```

## 설치

```bash
cargo install yardlet
```

macOS와 Linux용 사전 빌드 바이너리가 각
[GitHub 릴리스](https://github.com/zzunkie/yardlet/releases)에 첨부되어 있습니다.
[`cargo-binstall`](https://github.com/cargo-bins/cargo-binstall)이 설치되어 있으면
`cargo binstall yardlet`이 컴파일 대신 바이너리를 받아옵니다.

## 당신의 Claude Code와 Codex를, 있는 그대로

`claude` 또는 `codex`가 당신의 머신에서 실행된다면 Yardlet이 그것을 구동할 수
있습니다. 새 계정도, 추가 설정도, 별도의 셋업 단계도 없습니다. Yardlet은 설치된
CLI를 발견하고, 준비 상태를 점검하고, 당신이 이미 결제한 그대로 일을 시킵니다.
다른 모든 에이전트 CLI는 설정만으로 추가할 수 있으며("워커 추가하기" 참고),
워커별 `invocation.pass_env` 옵트인을 통한 API 기반 도구도 포함됩니다.

워커가 당신의 프로젝트 안에서 실행되기 때문에, 기존 셋업이 각 작업 안에서 그대로
동작합니다. `CLAUDE.md`, skills, hooks, MCP 서버, subagents가 전부 적용됩니다.
Yardlet은 당신의 하네스를 대체하는 게 아니라 그 위에 오케스트레이션과 검증을
얹습니다. LLM 레이어에서 영리해지려 하지 않고, 그 레이어를 이미 잘하는 하네스들을
교체 가능한 워커로 돌리며, 정작 노력은 모델 없이 결정론적으로 풀 수 있는 부분
(라우팅·평가·상태·머지·복구·핸드오프)에 씁니다.

이미 결제 중인 구독 안에서 돌도록 만들었지, 토큰당 API 비용을 쌓으려고 만든 게
아닙니다. 빌링 키(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` 등)는 워커를 띄우기 전에
환경에서 스크럽되므로, 무인 auto-drain이 구독 대신 API 키로 조용히 과금되는 일이
없습니다. 특정 변수는 `pass_env`로만 다시 통과시킬 수 있습니다.

## 루프

```bash
cd your-project
yardlet new "add admin order search with status, email, and date filters"
yardlet queue                      # 계획된 작업 검토
yardlet run --auto                 # 큐를 비움, 사람 게이트에서만 멈춤
yardlet handoff                    # 동료가 읽을 수 있는 요약 읽기
yardlet                            # 또는 터미널 UI에서 전부 처리
```

워커 CLI와 마찬가지로 `yardlet`은 어떤 디렉터리에서든 바로 동작합니다. 첫 명령이
`.agents/` 상태를 필요 시점에 생성합니다. `yardlet init`은 스크립팅이나 재스캐폴딩을
위해 존재하지만, 먼저 실행할 필요는 없습니다.

한 문장의 요청이 인텐트 계약과 명시적 의존성을 가진 경계가 명확한 작업 큐가 됩니다.
각 작업은 숨은 워커를 거쳐 실행되고, 결정론적 평가기로 검사되며, `.agents/runs/`
아래에 체크포인트와 핸드오프를 남깁니다.

## 터미널 UI 단축키

터미널 UI(`yardlet`를 서브명령 없이 실행)가 세션을 다루는 주된 방법입니다. Home
화면에서:

| 키 | 동작 |
| --- | --- |
| `n` | 새 작업: 요청 입력 (idle일 때). |
| `r` | 다음 작업 실행. |
| `A` | 큐 자동 비우기(auto-drain). |
| `p` | 다음 작업 승인. 드레인 중에는 graceful pause 요청. |
| `a` | 사용자를 기다리는 작업(NeedsUser)에 답하기. |
| `Esc` | 실행 중인 워커 중지. |
| `↑` / `↓` | 큐 탐색, 끝을 지나면 워커 패널. |
| `Enter` | 선택한 작업의 handoff 열기. |
| `Space` / `Enter` | (워커 패널에서) 선택한 워커 on/off 토글. |
| `i` | intent 계약 보기. |
| `h` | 최신 handoff 보기. |
| `R` | 리포트/히스토리 브라우저. |
| `m` | 워커 실시간 출력(Monitor). |
| `s` | 설정 (실행 중에도 열 수 있음). |
| `g` | 새로고침, 워커 readiness 재probe. |
| `l` | 언어 토글. |
| `f` | 접근 수준 토글 (sandboxed / full). |
| `u` | 설치된 업데이트본으로 재시작 (가능할 때). |
| `q` / `Ctrl+C` | 종료. |

한글 자판에서도 영어로 바꾸지 않고 그대로 동작합니다: 한글 자모가 같은 단축키에
매핑됩니다.

## 명령어

| 명령어 | 용도 |
| --- | --- |
| `yardlet` | 터미널 UI 열기 (최초 사용 시 자동 초기화). |
| `yardlet init [--force]` | `.agents/` 상태를 명시적으로 스캐폴딩 (선택). |
| `yardlet new "<request>" [--worker <id>]` | 요청을 인텐트 계약 + 큐로 계획. |
| `yardlet goal "<goal>" [--verify "..."]` | 익스프레스 레인: 계획을 건너뛰고 하나의 목표를 검증 조건까지 실행. |
| `yardlet new "..." --image <path>` | 로컬 이미지를 목표에 첨부 (요청에서 자동 감지도 됨). |
| `yardlet queue` | 작업 큐 나열. |
| `yardlet status [--json]` | 워크스페이스, 인텐트, 큐, 워커 요약. |
| `yardlet worker status` | 워커 준비 상태 및 빌링-env 안전성. |
| `yardlet inspect repo [--json]` | 저렴한 결정론적 로컬 증거. |
| `yardlet packet --task <id> --worker <id> [--dry-run]` | 워커 패킷 컴파일. |
| `yardlet run --next [--execute] [--worker <id>]` | 다음 작업 준비(기본) 또는 실행. |
| `yardlet run --auto [--parallel N]` | 큐를 자율적으로 비움; 선택적으로 N개 동시 실행. |
| `yardlet answer "<reply>"` | 사용자를 기다리는 작업(NeedsUser)에 답하고 재개. |
| `yardlet handoff` | 최신 실행의 핸드오프 출력. |
| `yardlet report` | 인텐트의 최종 리포트 출력 (모든 작업의 집계). |
| `yardlet recover` | 중단된 세션에서 상태 복구 (고아 실행, 미확인 계획). |
| `yardlet skill list / suggest / equip <preset> / unequip / research / create / apply / review` | 스킬 분류, 장착, 작성, 점수화. |
| `yardlet harness review` | 자동 학습된 규칙과 스킬을 eval 점수와 함께 표시. |
| `yardlet routing review` | 작업 종류별 워커 성공 통계 + 제안 선호도. |
| `yardlet routing apply --kind K --worker W` | 작업 종류에 워커 고정 (사람 승인). |

워커가 입력이 필요할 때 작업을 질문과 함께 **NeedsUser** 상태로 남깁니다.
`yardlet status`(및 TUI)가 질문을 보여주며, `yardlet answer "..."`(또는 TUI에서 `a`)로
답하면 Yardlet이 당신의 답을 반영해 작업을 다시 실행합니다.

## 언어

워커가 작성하는 내용(계획 요약, 작업 제목, 핸드오프, 질문)은 당신의 언어를 따릅니다.
기본적으로 Yardlet은 요청에서 언어를 자동 감지하므로, 한국어 요청에는 한국어 계획과
핸드오프가 나오고 코드와 식별자는 영어로 유지됩니다. 하나로 강제하려면
`.agents/yardlet.yaml`의 `language:`를 `ko`/`en` 등으로 설정하세요.

## 권한

워커는 기본적으로 경계가 있는 샌드박스에서 실행됩니다(로컬 파일과 테스트만,
네트워크 없음). 이는 계층적으로 구성됩니다.

1. **기본이 안전**: codex `workspace-write`, claude `acceptEdits`.
2. **우회가 아니라 보고**: 워커가 네트워크, 설치, 프로덕션, 또는 파괴적 동작이
   필요하면 조용히 실패하지 않고 **NeedsUser**로 멈추고 묻습니다. 당신이 접근을
   허용하고 재개합니다.
3. **명시적 에스컬레이션**: `yardlet run --next --execute --full-access`(또는
   `yardlet answer --full-access`)는 그 실행에 한해 샌드박스를 해제합니다. 기본은
   꺼져 있으며, 자동이 아니라 사람이 부여하는 권한입니다.

## 워커 라우팅

플래너는 `.agents/workers.yaml`의 편집 가능한 루브릭(각 워커의 `best_for` +
`cost_bias` 다이얼)에 따라 작업별 워커를 고릅니다. 실행 시점의 선택은 결정론적입니다.
선호 워커 -> 준비 상태 점검 -> 준비된 다음 워커로 폴백. 모든 실행은 결과를
`.agents/telemetry/runs.jsonl`에 기록하며, `yardlet routing review`가 이를 집계해
프로필 변경을 *제안*합니다(예: "claude-code가 리팩터에서 이긴다"). 이를
`yardlet routing apply`로 적용합니다. 텔레메트리는 스스로 라우팅을 바꾸지 않습니다.
설계: [docs/routing-and-telemetry.md](docs/routing-and-telemetry.md).

`run --next`는 실행을 준비하고 기본적으로 워커를 호출하기 *전에* 멈춥니다. 구독
기반 워커를 띄우면 사용량이 소비되기 때문입니다. 실제로 실행하려면 `--execute`를
전달하세요.

워커는 Home 워커 패널에서 켜고 끌 수 있습니다(큐를 지나 화살표 키, 그다음
Enter/Space). 비활성화된 워커는 라우팅과 계획에서 건너뜁니다.

### 워커 추가하기

Codex와 Claude Code는 내장 어댑터를 가집니다. 다른 모든 구독 기반 CLI는
`.agents/workers.yaml`만으로 추가할 수 있습니다. 호출 템플릿을 주면 Yardlet이 동일한
계약(stdin으로 패킷 -> 결과 파일 출력)을 통해 그것을 구동합니다. 플레이스홀더:
`{run_dir}`, `{model}`, `{effort}`, `{image}`.

```yaml
- id: mytool
  best_for: "..."            # 플래너 루브릭
  invocation:
    command: mytool          # --version 지원 필요 (준비 상태 프로브)
    supports_noninteractive: true
    args: ["run", "--json", "--out", "{run_dir}"]
    sandbox_args: ["--sandbox"]        # 기본 접근 수준
    full_access_args: ["--yolo"]       # 풀 액세스가 허용될 때만
    model_args: ["--model", "{model}"] # 모델이 설정되면 추가됨
    effort_args: ["--effort", "{effort}"]
    image_args: ["-i", "{image}"]      # 첨부 이미지마다 반복됨
```

워커는 워크스페이스에 파일을 쓸 수 있어야 합니다(그것이 결과가 돌아오는
방식입니다). 그 서브프로세스 env는 프로필이 `pass_env`로 변수를 다시 옵트인하지
않는 한 정화됩니다.

생태계의 에이전트들이 Yardlet의 공급 측입니다.
[oh-my-pi](https://github.com/can1357/oh-my-pi)(`omp`), OpenCode, Gemini CLI,
또는 당신이 만든 API 기반 CLI 같은 터미널 에이전트 모두가 같은 템플릿에 맞습니다.
승자를 등록하고, 작업별로 교체하고, 기록을 유지하세요.

## 역할 프로필

각 작업은 역할 아래에서 실행됩니다. 작업 종류에서 파생된, 워커 위에 얹는 프롬프트
모드입니다. `implementation` -> **builder**, `review` -> **reviewer**,
`research` -> **researcher**, `safety` -> **security**. 같은 Codex/Claude 세션이
역할별 작업 규칙을 받습니다(리뷰어는 file:line 증거를 인용하고 코드를 다시 쓰지
않으며, 리서처는 코드를 변경하지 않고, 보안은 적대적으로 감사하며 비밀 값을 결코
출력하지 않습니다). 워크스페이스별로 역할을 확장하려면 `.agents/agents/<role>.md`를
작성하세요. 해당 역할의 패킷에 덧붙여집니다.

## 병렬 실행

플래너는 어떤 작업이 진짜로 서로 의존하는지(`depends_on`) 표시하고, 나머지는 모두
독립적입니다. 병렬을 켜면 자동 드레인이 독립 작업을 최대 N개까지 동시에 실행하며,
각각 `yard/<task-id>` 브랜치의 자체 git worktree에서, 서로 다른 워커에서 실행될 수도
있습니다. 워커는 병렬로 실행되지만 큐 상태는 단일 작성자를 유지하고 결과는 순차적으로
머지됩니다. 머지 충돌은 절대 자동 해결되지 않습니다(작업은 Partial로 떨어지고
worktree는 검사를 위해 보존됩니다). 기본은 꺼져 있고, Settings("Parallel tasks"),
`.agents/yardlet.yaml`의 `max_parallel`, 또는 `yardlet run --auto --parallel 3`으로
옵트인합니다. 깨끗한 git 트리가 필요하며, 그렇지 않으면 Yardlet은 순차 실행으로
폴백합니다.

작업 내부에서 워커는 자유롭게 자신의 서브에이전트를 사용할 수 있습니다. Yardlet의
큐 병렬성은 세션을 넘어 살아남고, 워커를 가로지르고, 사람 게이트를 통과해야 하는
작업을 위한 것입니다. 설계: [docs/parallel-queue.md](docs/parallel-queue.md).

## 크래시 안전성

Yardlet 상태는 재시작에도 살아남습니다. 시작 시(그리고 `yardlet recover`를 통해)
중단된 세션을 복구합니다. 이전 세션이 비용을 치렀지만 읽지 않은 계획 결과는 큐로
흡수되고, 완료된 고아 실행은 평가되어 머지되며(worktree 실행 포함), 끝나지 않은 것은
다시 큐에 들어갑니다.

## 빌드

```bash
cargo build
cargo test
cargo run -- init
```

기여: 빌드/테스트, 핵심 불변식, PR 절차는 [CONTRIBUTING.md](CONTRIBUTING.md) 참고.
다른 워커 추가는 설정만으로 됩니다("워커 추가하기" 참고). 새 워커를 붙이는 PR은
환영합니다.

## 정규 상태

Yardlet이 상태를 소유하며, 워커는 그러지 않습니다. 정규 상태는 대상 저장소의
`.agents/` 아래에 존재합니다.

```
.agents/
  yardlet.yaml              워크스페이스 설정
  intent-contract.yaml   현재 목표 / 스코프 / 수용 조건
  work-queue.yaml         작업
  *-policy.yaml           도구 / 승인 / 상호작용 / 리서치 / 빌링 정책
  workers.yaml            워커 프로필 + 라우팅
  runs/<run-id>/          실행별 산출물 (결과, 검증, 체크포인트, 핸드오프)
  checkpoints/            최신 컴팩트 재개 지점
  handoffs/               동료가 읽을 수 있는 요약
```

사용자 수준의 비밀이 아닌 설정은 `~/.yardlet/` 아래에 존재합니다.

## 라이선스

MIT
