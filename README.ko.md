# Yardlet

[![crates.io](https://img.shields.io/crates/v/yardlet.svg)](https://crates.io/crates/yardlet)
[![CI](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml/badge.svg)](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml)
[![downloads](https://img.shields.io/crates/d/yardlet.svg)](https://crates.io/crates/yardlet)
[![license: MIT](https://img.shields.io/crates/l/yardlet.svg)](LICENSE)

[English](README.md) | **한국어**

> **Rent the intelligence. Own the loop.** (지능은 빌리고, 루프는 소유한다.)
> Yardlet은 당신이 이미 사용하는 코딩 에이전트를 둘러싼 루프를 소유합니다. 의도를
> 몇 문장으로 진술하면, Yardlet이 그것을 작업으로 계획하고, Claude Code나 Codex를
> 교체 가능한 워커로 구동하고, 모든 결과를 결정론적으로 검증하며, 계획과 메모리,
> 신뢰 기록, 핸드오프를 당신의 저장소에 보관합니다. 모델은 빌리고, 루프는 당신의
> 것입니다.

![Yardlet terminal UI demo](docs/assets/yardlet-demo.gif)

Yardlet은 코딩 CLI를 얇게 감싼 래퍼가 아닙니다. 워커 CLI는 Yardlet이 처음부터 끝까지
소유하는 루프 안의, 교체 가능한 한 부품일 뿐입니다. 플래닝 게이트, 작업별 라우팅,
결코 실행자가 아닌 결정론적 검증자, 저장소에 사는 지속 상태, 크래시 복구, 프로젝트
메모리, 당신의 실행 이력으로 만든 신뢰 리포트, 그리고 당신의 저장소에서 복리로 쌓이는
학습 루프가 그 루프를 이룹니다. 워커를 바꿔도 루프와 기록, 그리고 당신이 가르친 모든
것은 당신에게 남습니다.

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
  "완료"는 스스로 보고하는 것이 아니라 획득하는 것입니다. 기계적 검사는
  결정론적이고(스키마·ID·스코프 drift·실제 git diff 기반 forbidden path·Yardlet이
  직접 실행하는 validation 명령), 의미적 품질은 별도 리뷰어 역할 태스크가
  판단합니다(체커가 모든 걸 판단하는 척하지 않습니다).

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

작업은 명시적 목표 조건과 피드백 사이클 한도를 가질 수 있습니다. 결정론적 검증이나
수용 조건 검사가 실패하면 Yardlet은 정확한 실패를 기록해 다음 시도에 주입합니다.
저장된 한도를 소진하면 완료로 보고하지 않고 문맥과 함께 NeedsUser에서 멈춥니다.

## 프로젝트 메모리 (Project Memory)

잊어버리는 루프는 래퍼입니다. Yardlet은 지속되는 워크스페이스 지식을 당신의 저장소에
보관하고, 프롬프트를 부풀리지 않으면서 모든 워커에게 그것을 공급합니다.

사실과 결정을 `.agents/memory/` 아래에 일반 Markdown으로 남기세요. 파일 하나에 사실
하나, git으로 추적되며, 선택적으로 `name` / `description` frontmatter를 가집니다.
Yardlet은 이를 발견해 짧은 **인덱스**만 모든 워커 패킷과 플래너에 주입합니다. 각 문서의
제목, 한 줄 요약, 경로 앵커가 그것입니다. 본문은 그것이 필요한 워커가 **필요 시점에**
읽으므로, 아무리 많이 기록해도 항상 로드되는 비용은 작게 유지됩니다. 이것은
prompt-stuffing이 아니라 index-and-anchor입니다. 인덱스는 가리키고, 워커는 자기 작업에
관련된 소수의 메모리만 엽니다.

메모리 문서는 `look_at:` 랜드마크 경로를 선언할 수도 있습니다. `yardlet memory`는
인덱스를 나열하고, 문서가 마지막으로 갱신된 뒤 랜드마크 중 하나가 git에서 변경되면 그
문서를 **possibly stale(오래되었을 수 있음)** 로 표시합니다. 그래서 자기가 설명하는
코드에서 멀어진 메모리가 조용히 신뢰되는 대신 드러납니다. `yardlet init`이 컨벤션
README와 함께 이 폴더를 스캐폴딩합니다.

파일을 직접 손으로 쓰지 않고 워커를 통해 메모리를 뿌리고 유지할 수도 있습니다.
`yardlet memory init`은 워커에게 저장소로부터 메모리 문서 초안을 만들게 한 뒤, Yardlet의
코어가 정본 `.agents/memory/*.md`를 씁니다(워커는 초안, Yardlet이 유일한 기록자).
`yardlet memory refresh`는 기존 문서를 같은 방식으로 다시 초안하고,
`yardlet memory refresh --stale-only`는 possibly stale로 표시된 문서만 손봅니다.

더 넓은 읽기 전용 점검에는 `yardlet memory scout`를 사용합니다. 주제별 scout가 격리된
워크스페이스 복사본을 살피고 보고서를 적용 전 후보로 합칩니다. 실행 산출물을 검토한 뒤
`yardlet memory apply --run <run-id>`로 코어가 후보를 정본 메모리에 쓰게 합니다. scout는
실제 워크스페이스 경로를 받지 않으며 그 정본 상태를 쓰지 않습니다.

작동 방식: [docs/memory-trust-mining.md](docs/memory-trust-mining.md).

## 신뢰 리포트 (Trust Report)

"완료"가 결정론적 게이트로 검사되고, 모든 실행이 결과를 기록하며, 모든 작업 상태 변화가
기록되기 때문에, Yardlet은 당신 자신의 이력으로부터 이 루프를 얼마나 신뢰할지 알려줄 수
있습니다. `yardlet trust`는 실행 텔레메트리와 `.agents/transitions/` 아래의 상태-전이
감사 로그를 읽어 두 계층을 출력합니다.

시도 뷰(attempt view), 실행 텔레메트리 기반, 활성 인텐트로 스코프 한정:

- **first-pass Done vs Done-after-retry vs never-Done.** 작업이 재작업 없이 첫 시도에
  얼마나 자주 안착하는지 볼 수 있습니다.
- **워커별 신뢰도**: done-rate, partial / failed / no-result 횟수, 벽시계 시간, 그리고
  당신이 결과를 override한 횟수.
- Done에 도달하기까지 **가장 많은 시도**가 필요했던 작업들.

자율성 뷰(autonomy view), 전이 감사 로그로부터 접힘:

- **이 Done을 신뢰할 수 있나?** 모든 Done을 기록된 이력으로부터 등급화합니다.
  evidence-backed(깨끗한 Done, 다시 열린 적 없음), recovered(잘못된 전환 뒤의 Done),
  false-done caught(Done 표시 후 다시 열림), 또는 unresolved. 그리고 Done들에 대한
  trustworthy-Done 비율.
- **사람 개입, 결정 vs 잡무(decision vs chore).** 손이 간 단계를, 루프가 당신에게
  정당하게 빚진 결정과, 루프가 스스로 흡수했어야 할 잡무(un-parking, 복구)로 나눕니다.
  잡무 비중이 자율성 목표가 0으로 몰아가는 숫자이며, 인텐트별로 분해됩니다.
- **불필요한 루프 중단.** 진짜 질문이 아니라 승인·일시정지 마찰로 멈춘 것을, 줄일 수
  있는 낭비로 셉니다.

모든 숫자는 기록된 특정 전이나 실행으로 추적되며, (intent, task) 인스턴스별로 키가
매겨져 인텐트를 가로질러 재사용된 task id가 결코 한데 합쳐지지 않습니다.
`yardlet trust --json`은 자율성 지표를 기계 판독 가능한 JSON으로 내보내고, 터미널 UI는
같은 숫자를 **Trust 패널**(`T` 키)에 보여줍니다. 리포트 전체는 읽기 전용입니다. 보고할
뿐, 스스로 라우팅이나 정책을 바꾸지 않습니다.

계산 세부사항: [docs/memory-trust-mining.md](docs/memory-trust-mining.md).

## 결과 마이닝 (Outcome Mining)

같은 텔레메트리가 학습 루프를 먹입니다. `yardlet harness review`는 자동 학습된 규칙과
스킬을 eval 점수와 함께 보여주고, 그 옆에 임계값을 넘은 **마이닝된 관찰**을 드러냅니다.
no-result 비율이 높은 워커(규칙으로 다룰 만한 출력-계약 문제), 또는 Done에 도달하기까지
평균 시도 횟수가 많은 작업 종류(스킬이나 더 날카로운 수용 조건을 원함)가 그것입니다.

이것들은 **제안일 뿐입니다.** 마이닝은 반복되는 결정론적 결과를 가리키며 하네스 개선을
제안하고, 규칙·스킬·스코프 변경은 당신이 적용합니다. 텔레메트리는 스스로 하네스를
다시 쓰지 않습니다. 이것이 루프가 복리로 쌓이는 방식입니다. 한 실행의 결정론적 결과가
다음 실행을 더 날카롭게 만드는 가이드가 됩니다.

임계값: [docs/memory-trust-mining.md](docs/memory-trust-mining.md).

## 터미널 UI 단축키

터미널 UI(`yardlet`를 서브명령 없이 실행)가 세션을 다루는 주된 방법입니다. Home
화면에서:

| 키 | 동작 |
| --- | --- |
| `n` | 새 작업: 요청 입력 (idle일 때). |
| `r` | 다음 작업 실행. |
| `A` | 큐 자동 비우기(auto-drain). |
| `t` | Tidy: 워크스페이스 상태 자가 치유 (오래된 게이트 이관, 실행 불가 작업 defer, 소진된 인텐트 마무리). |
| `p` | 다음 작업 승인. 드레인 중에는 graceful pause 요청. |
| `a` | 사용자를 기다리는 작업(NeedsUser)의 Answer 열기. 워커 출력과 대화 문맥을 함께 표시. |
| `d` | 선택한 작업을 결정으로 defer. |
| `v` | 선택한 Deferred 작업을 revive. |
| `Esc` | 실행 중인 워커 중지. |
| `↑` / `↓` | 큐 탐색, 끝을 지나면 워커 패널. |
| `Enter` | 선택한 작업의 다음 동작 실행 (run / answer / 승인 힌트 / monitor / handoff), 또는 큐를 지나 워커 토글. |
| `Space` / `Enter` | (워커 패널에서) 선택한 워커 on/off 토글. |
| `i` | intent 계약 보기. |
| `h` | 최신 handoff 보기. |
| `T` | 신뢰·자율성 패널 (`yardlet trust`와 같은 숫자). |
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
| `yardlet add "<title>" [--depends-on <id>]` | 재계획 없이 사용자 작성 작업을 현재 큐에 추가. |
| `yardlet queue` | 작업 큐 나열. |
| `yardlet tidy` | 워크스페이스 상태 자가 치유: 오래된 게이트 이관, 실행 불가 작업 defer, 소진된 인텐트 아카이브. |
| `yardlet status [--json]` | 워크스페이스, 인텐트, 큐, 워커 요약. |
| `yardlet worker status` | 워커 준비 상태 및 빌링-env 안전성. |
| `yardlet inspect repo [--json]` | 저렴한 결정론적 로컬 증거. |
| `yardlet packet --task <id> --worker <id> [--dry-run]` | 워커 패킷 컴파일. |
| `yardlet run --next [--execute] [--worker <id>]` | 다음 작업 준비(기본) 또는 실행. |
| `yardlet run --auto [--parallel N]` | 큐를 자율적으로 비움; 선택적으로 N개 동시 실행. |
| `yardlet answer "<reply>"` | 사용자를 기다리는 작업(NeedsUser)에 답하고 재개. |
| `yardlet approve <id>` | 게이트된 작업에 단발성 승인 부여. |
| `yardlet defer <id> [reason]` | 작업 하나를 결정으로 따로 치워둠 (Deferred: 대기도 완료도 아님). |
| `yardlet defer <id> --cascade [reason]` | 그 뒤에 좌초된 queued 작업까지 전이적으로 함께 defer하고 하나의 revive 그룹으로 기록. |
| `yardlet revive <id> [--group]` | Deferred 작업을 Queued로 되살림; `--group`은 함께 기록된 cascade 그룹을 되살림. |
| `yardlet access <sandboxed\|full>` | 기본 워커 권한 수준 설정. |
| `yardlet handoff` | 최신 실행의 핸드오프 출력. |
| `yardlet report` | 인텐트의 최종 리포트 출력 (모든 작업의 집계). |
| `yardlet memory [init \| refresh [--stale-only]]` | 프로젝트 메모리 인덱스 나열(오래되었을 수 있는 문서 표시); `init`/`refresh`는 워커가 초안한 문서를 Yardlet 코어가 기록. |
| `yardlet memory scout` / `yardlet memory apply --run <run-id>` | 격리 복사본을 병렬로 점검해 적용 전 메모리 후보를 만들고 코어 기록자를 통해 적용. |
| `yardlet watch [--interval N] [--until CONDITION] [--max-runs N] [--max-seconds N] [-- <command>]` | 로컬 명령이나 경로를 foreground에서 제한된 조건까지 관찰. |
| `yardlet eval fixtures [--json] [--fixture <id>]` | 격리된 결정론적 메커니즘 fixture 실행. 하나라도 실패하면 non-zero로 종료. |
| `yardlet trust [--json]` | 실행 텔레메트리와 전이 감사 로그 기반 신뢰+자율성 리포트 (읽기 전용); `--json`은 지표를 내보냄. |
| `yardlet recover` | 중단된 세션에서 상태 복구 (고아 실행, 미확인 계획). |
| `yardlet skill list / suggest / equip <preset> / unequip / research / create / apply / review` | 저장소 분류, managed 11-skill catalog 사용, 스킬 장착·작성·점수화. Core skill은 외부 library 없이 설치되고 overlay는 task 범위에서만 활성화. |
| `yardlet harness review` | 자동 학습된 규칙과 스킬을 eval 점수와 함께 표시, 그리고 마이닝된 개선 후보. |
| `yardlet rubric drift / sync [--adopt-text]` | 워크스페이스 루브릭이 템플릿에 얼마나 뒤처졌는지 진단하고 개선을 병합 (비파괴적). |
| `yardlet routing review` | 작업 종류별 워커 성공 통계 + 제안 선호도. |
| `yardlet routing apply --kind K --worker W` | 작업 종류에 워커 고정 (사람 승인). |

워커가 입력이 필요할 때 작업을 질문과 함께 **NeedsUser** 상태로 남깁니다.
`yardlet status`(및 TUI)가 질문을 보여주며, `yardlet answer "..."`(또는 TUI에서 `a`)로
답하면 Yardlet이 당신의 답을 반영해 작업을 다시 실행합니다. TUI Answer 화면은 현재
인텐트의 워커 출력과 관련 대화를 스크롤 가능하게 보여주며, 출력이 없으면 컴팩트 요약을
대신 표시합니다.

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

## 직렬 격리와 소유 변경 통합

직렬 실행 경로에서 선택된 모든 eligible task는 실행 소유 git worktree에서 동작합니다.
dependency scheduling 결과 eligible task가 하나뿐인 경우도 같습니다. 해당 직렬 워커는
worktree 안의 staging run directory에 결과 파일을 작성합니다. main Yardlet process가 그
산출물을 가져오며 canonical queue, conversation, telemetry, `.agents/runs/` state의 유일한
작성자로 남습니다. 이 staging/import 경계는 직렬 경로에만 적용됩니다. 아래에서 설명하는
parallel worker는 canonical run directory를 직접 사용합니다.

직렬 자동 commit과 merge는 계속 기본 비활성입니다.

```yaml
auto_commit: false
```

기본값에서는 변경이 있는 run을 commit하거나 merge하지 않고, 소유 worktree를 검사용으로
보존한 Partial에 둡니다. `auto_commit: true`이면 격리 worktree의 `.agents/` 밖 diff만
commit하고 dependency 순서대로 merge합니다. dirty 또는 동시에 바뀐 main checkout
변경은 stage하거나 해당 run에 귀속하지 않습니다. 안전하지 않은 merge는 worktree와
소유권 기록을 보존한 Partial로 남습니다. 변경이 없는 run은 commit 없이 worktree를
정리합니다.

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

## Git 마무리

자동 push는 사용자가 소유하는 별도의 완료 정책이며 기본은 꺼져 있습니다.
`yardlet init`은 명시적으로 비활성화된 블록을 작성하고, 이 블록이 없는 기존
워크스페이스도 비활성 상태를 유지합니다. 이름이 있는 remote, 완전한 branch ref,
그리고 통과해야 할 순서대로 검사를 설정합니다.

```yaml
git_finish:
  auto_push: false
  remote: safe-remote
  target_ref: refs/heads/main
  pre_push_checks:
    - name: format
      command: cargo fmt --check
    - name: tests
      command: cargo test
```

이 정책을 검토한 뒤 `auto_push: true`로 바꾸면 옵트인됩니다. 그렇다고 임의의 commit이
push 가능한 것은 아닙니다. Yardlet은 worktree 기준점과 해당 run이 만든 정확한 commit
집합을 기록하고, 기준점에서 새로 도달 가능한 commit이 그 소유 집합과 정확히 같을 때만
통합 OID를 인정합니다. remote 대상도 여전히 기준점과 같아야 합니다. 따라서 hook,
다른 세션 또는 로컬 자동화가 출처 불명 commit을 끼워 넣으면 push 전에 fail-closed로
중단합니다.

같은 Git common directory, remote, target ref를 마무리하는 실행은 제한 시간이 있는
로컬 lock으로 직렬화됩니다. lock을 잡은 동안 현재 branch와 `HEAD`가 target 및 소유
OID와 일치하고, push 목적지가 하나이며, `.agents/` 밖에 변경이 없어야 합니다. 그다음
설정 검사를 순서대로 실행합니다. 검사 후에는 `HEAD`, worktree, fetch/push 목적지와
remote target ref를 다시 확인하며, 동시 변경이 하나라도 있으면 push 0회로 멈춥니다.

push는 항상 명시적인 `<expected_oid>:<target_ref>` refspec입니다. force,
force-with-lease, ref 삭제, history rewrite 경로는 없습니다. 그 뒤 Yardlet은 별도의
`git ls-remote --refs` 조회를 실행하고 remote OID가 고정된 예상 OID와 같을 때만 성공을
보고합니다. 같은 마무리를 반복하면 추가 push 없이 `already_applied`로 수렴합니다.

`auto_push: true`일 때는 `pushed`와 독립 검증된 `already_applied`만 작업을 완료합니다.
그 밖의 모든 마무리 상태는 작업, 봉인된 `run.yaml`, telemetry, 최종 리포트와 Trust
집계에서 미완료 `Partial`로 투영됩니다. 기본 비활성 정책에서는 `disabled`가 필수
마무리가 아니므로 일반 작업 완료 방식은 달라지지 않습니다.

| 기록 상태 | 사용자에게 보이는 의미 |
|---|---|
| `pushed` | 정확한 OID가 push되고 독립적으로 검증됐습니다. |
| `already_applied` | remote에 이미 정확한 OID가 있어 push를 실행하지 않았습니다. |
| `prepared` | 내구 pre-push 기록은 있지만 remote 결과가 아직 확정되지 않았으며 `recover`가 대조합니다. |
| `check_blocked` / `safety_blocked` | 설정 검사, 소유권 증명, lock 또는 동시 상태 게이트가 차단했으며 명시적 해결 전까지 Partial입니다. |
| `git_failed` | Git 조회 또는 push 명령이 실패했으며 Partial로 남고 remote 성공을 주장하지 않습니다. |
| `remote_mismatch` | push는 성공을 반환했지만 독립 검증이 불일치하므로 Partial 해결 전에 remote를 확인해야 합니다. |
| `disabled` | 워크스페이스가 옵트인하지 않아 Git 마무리가 일반 완료를 막지 않습니다. |

모든 결과는 `.agents/runs/<run-id>/git-finish.json`에 기록되고 run telemetry와 최종
리포트에 투영됩니다. 기록에는 remote 이름, target ref, 기준점, run 소유 및 예상 OID,
push 전후 remote OID, 검사 결과, push 플래그, 사유, 시각이 포함됩니다. remote URL,
검사 명령문이나 출력, credential, 환경값은 저장하지 않습니다.

Yardlet은 push를 호출하기 전에 `prepared`를 기록합니다. 중단 후 `yardlet recover`는
같은 target lock 아래에서 소유권 기록을 다시 읽고 remote를 확인합니다. remote가 이미
예상 OID라면 추가 push 없이 `already_applied`로 수렴합니다. 아직 기준점과 같다면 같은
exact-OID push를 재시도할 수 있습니다. 그 밖의 remote 또는 로컬 상태는 fail-closed로
중단합니다. remote 검증은 끝났지만 queue, `run.yaml` 또는 telemetry 봉인이 끊겼다면
검증된 결과를 멱등하게 다시 투영합니다. 다른 차단·실패 상태는 조용히 재시도하거나
완료로 승격하지 않고, 사용자가 명시적으로 해결할 때까지 Partial로 남습니다. 프로젝트
도그푸딩과 테스트에는 local bare remote를 사용하세요. 이 계약은 Yardlet이 자신의 공개
`origin`에 push한다고 주장하지 않습니다.

## 크래시 안전성

Yardlet 상태는 재시작에도 살아남습니다. 시작 시(그리고 `yardlet recover`를 통해)
중단된 세션을 복구합니다. 이전 세션이 비용을 치렀지만 읽지 않은 계획 결과는 큐로
흡수되고, 완료된 고아 실행은 평가되어 머지되며(worktree 실행 포함), 끝나지 않은 것은
다시 큐에 들어갑니다. 내구 `prepared` Git 마무리는 소유권 기록과 현재 remote OID로
대조되고, 검증된 결과는 한 번만 투영되며, 모호한 상태는 Partial로 남습니다.

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
  intent-contract.yaml      현재 목표 / 스코프 / 수용 조건
  work-queue.yaml           작업
  *-policy.yaml             도구 / 승인 / 상호작용 / 리서치 / 빌링 정책
  workers.yaml              워커 프로필 + 라우팅
  memory/                   지속되는 워크스페이스 사실 (파일 하나에 사실 하나, git 추적)
  rules/ skills/ agents/    하네스 자산 (규칙, 스킬 카탈로그, 역할 노트)
  runs/<run-id>/            실행별 산출물 (결과, 검증, 체크포인트, 핸드오프, git-finish)
  conversations/<id>.yaml   워커에게 다시 이어지는 needs-user 대화 기록
  checkpoints/              최신 컴팩트 재개 지점
  handoffs/                 동료가 읽을 수 있는 요약
  telemetry/                runs.jsonl: 실행별 결과 (신뢰 + 마이닝의 소스)
  transitions/<task>.yaml   작업별 상태 변화 감사 로그 (자율성 지표의 소스)
  intents/                  아카이브된 소진 인텐트 (작업 이력 보존)
```

사용자 수준의 비밀이 아닌 설정은 `~/.yardlet/` 아래에 존재합니다.

## 라이선스

MIT
