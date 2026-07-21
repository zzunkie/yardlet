---
name: fixture-binary-freshness
description: named fixture 실행 전 Yardlet 바이너리 신선도를 판정하고 clean, rebuild, retry로 복구한다
source: learned
---

# Fixture binary freshness

## 언제 사용하는가

소스에는 named fixture가 있는데 process fixture 또는 `yardlet eval fixtures --fixture <id>`가 해당 id를 지원하지 않거나 fixture capability preflight가 실패할 때 사용한다. 이 절차가 끝나기 전에는 fixture 본문을 실행하지 않는다.

## 절차

1. 실제 실행 대상을 먼저 고정한다. process fixture가 받은 첫 번째 인자를 그대로 사용하고, 직접 실행이라면 `command -v yardlet`과 `type -a yardlet`로 PATH 중복을 확인한다. 경로를 `YARDLET_BIN` 같은 task 전용 변수에 절대 경로로 저장한다.
2. 원래 실행하려던 모든 `--fixture` 값을 required fixture id 목록으로 모은다. 하나만 검사하고 나머지를 본문에서 발견하지 않는다.
3. 대상 바이너리 자체에 `"$YARDLET_BIN" eval fixtures --list --json`을 실행한다. 명령 실패, JSON 파싱 실패, required id 누락 중 하나라도 있으면 본문을 시작하지 않는다. 출력의 `fixture_ids`에 모든 required id가 있는지 기계적으로 비교한다.
4. 대상 경로와 누락 id를 기록한다. 이 증상은 대상 빌드 아티팩트가 현재 소스 fixture registry보다 오래되었거나 다른 worktree/target directory의 바이너리를 가리킬 때 발생할 수 있다.
5. 대상 소스 checkout의 repo root에서 `cargo clean -p yardlet`을 실행하고 `cargo build --bin yardlet`으로 다시 빌드한다. `CARGO_TARGET_DIR`를 사용 중이면 rebuild 결과가 1단계의 대상 경로와 같은 target directory에 놓이는지 확인한다.
6. 같은 절대 경로로 `"$YARDLET_BIN" eval fixtures --list --json`을 다시 실행하고 모든 required id가 나타나는지 확인한다.
7. capability 확인이 통과한 뒤에만 원래의 named fixture 명령을 한 번 재시도한다. 여전히 id가 없으면 다른 checkout 또는 다른 target directory를 빌드한 것이므로 본문을 실행하지 말고 두 경로를 대조한다.

## 검증

- catalog JSON의 `fixture_ids`가 required id를 전부 포함한다.
- preflight 실패 출력에 대상 바이너리 절대 경로, 모든 누락 id, `cargo clean -p yardlet`, `cargo build --bin yardlet`, 재시도 지시가 있다.
- preflight 실패 중 fixture 본문 marker나 본문 evidence가 생성되지 않는다.
- fresh 대조 실행의 report에는 요청한 fixture id만 있고 `passed: true`이다.
