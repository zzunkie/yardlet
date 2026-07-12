# Built-in skill library: local workspace evidence map

조사 기준일: 2026-07-12

## 1. 목적과 판정 규칙

이 문서는 Yardlet fresh install의 built-in skill library를 결정하기 위한 **로컬 수요 근거**만 정리한다. 외부 후보의 적격성, upstream commit, license와 provenance 검증은 별도 후보 원장의 책임이다. 여기서 `local-reference-catalog`는 기존 분류 체계와 실제 사용 흔적을 확인하는 비교 자료일 뿐, 복제하거나 정답 원장으로 채택하지 않는다.

조사 규칙은 다음과 같다.

- `<workspace>` 바로 아래 Git repo를 대상으로 tracked manifest, README, AGENTS, docs, source, tests, templates, CI 파일만 확인했다.
- `.agents/runs/**`, `worker-output.log`, checkpoints, handoffs, telemetry, archived intents는 조사하지 않았다. 지정된 `repo-summary.md`는 시작 시 repo 경계를 확인하는 anchor로만 사용했고, 반복 수요 판정에는 사용하지 않았다.
- secret의 이름이나 존재 경계는 tracked 문서에서만 확인했고 값은 읽지 않았다.
- 동일 수요가 2개 이상의 repo에서 나타나거나, 한 repo 안에서 manifest와 runbook, test, template처럼 서로 다른 안정적 근거가 함께 있을 때만 반복 수요로 판정했다.
- repo 하나에만 있는 전문 수요는 core가 아니라 product preset 또는 task-triggered overlay 후보로 제한했다.
- manifest가 없거나 README가 scaffold 기본문인 repo는 강한 분류 근거로 쓰지 않았다.

아래 표에서 `관찰 사실`은 파일에서 직접 확인한 사실이고 `inferred need`는 built-in library에 대한 해석이다. 둘을 같은 문장에 섞지 않는다.

## 2. Workspace repo 유형 지도

| Evidence ID | Repo / path | 관찰 사실 | Inferred need | 강도와 제한 |
|---|---|---|---|---|
| LE-001 | `yard/Cargo.toml`, `yard/src/`, `yard/tests/`, `yard/templates/agents/`, `yard/.github/workflows/ci.yml` | `yardlet`은 Rust 2021 CLI/TUI이고, Rust source와 integration tests, agent-state templates, CI를 함께 가진다. | CLI/runtime preset, deterministic test workflow, harness-state-aware repo orientation 수요 | 강함. 현재 task의 기준 repo이기도 하다. |
| LE-002 | `workspace-erp-monorepo/package.json`, `workspace-erp-monorepo/pnpm-workspace.yaml`, `workspace-erp-monorepo/AGENTS.md`, `workspace-erp-monorepo/docs/erp-rebuild/` | pnpm workspace 아래 TypeScript frontend, NestJS backend, Go backend, Electron, 여러 D2C 앱이 공존한다. 공용 package 선행 build와 package별 test 명령이 문서화돼 있다. | web/fullstack monorepo preset, package-boundary validation, UI parity overlay 수요 | 강함. 한 repo가 여러 preset과 overlay를 동시에 요구한다. |
| LE-003 | `workspace-secondary-monorepo/package.json`, `workspace-secondary-monorepo/pnpm-workspace.yaml`, `workspace-secondary-monorepo/packages/server/test/app.e2e-spec.ts`, `workspace-secondary-monorepo/packages/erp/src/tests/App.test.tsx` | `workspace-secondary-monorepo`도 pnpm monorepo이며 frontend와 backend test가 함께 tracked되어 있다. | LE-002의 monorepo, cross-package test 수요를 독립적으로 보강 | 중간. README와 package name이 `workspace-erp-monorepo`여서 현재 제품 정체성은 확정하지 않는다. |
| LE-004 | `workspace-agent-runtime/pyproject.toml`, `workspace-agent-runtime/AGENTS.md`, `workspace-agent-runtime/app/`, `workspace-agent-runtime/tests/`, `workspace-agent-runtime/docs/map/` | Python/FastAPI 기반 agent runtime이며 Slack, web, trigger, CLI surface와 pytest map, security guardrail, repo map을 가진다. | agent/backend preset, repo-map orientation, tool/security review overlay 수요 | 강함. runtime log나 conversation 기록은 이 조사에 사용하지 않았다. |
| LE-005 | `brain/go.mod`, `brain/README.md`, `brain/internal/core/engine_test.go`, `brain/internal/memory/file_test.go` | messenger-neutral team agent core를 Go module과 unit tests로 구현한다. | Go backend/runtime preset과 agent-contract overlay 수요 | 강함. LE-004와 구현 언어가 달라 preset을 제품명보다 manifest로 분류해야 한다. |
| LE-006 | `workspace-backend-builder/package.json`, `workspace-backend-builder/AGENTS.md`, `workspace-backend-builder/apps/api/__tests__/`, `workspace-backend-builder/apps/executor/`, `workspace-backend-builder/docker-compose.e2e.yml` | TypeScript workspace와 Go executor, Postgres, Docker E2E, auth/RBAC/safety/workspace-isolation tests가 공존한다. | fullstack/backend preset, DB overlay, security overlay, E2E overlay 수요 | 강함. 정책과 실행 contract 검증이 일반 lint보다 중요하다. |
| LE-007 | `workspace-service/package.json`, `workspace-service/AGENTS.md`, `workspace-service/src/domains/`, `workspace-service/test/app.e2e-spec.ts` | NestJS, TypeORM, PostgreSQL, Redis, JWT backend이며 DTO와 entity 변경의 호환성, migration 계획, secret 경계가 문서화돼 있다. | backend/API preset, schema migration, auth, compatibility overlay 수요 | 강함. production 연결은 없다고 AGENTS가 명시한다. |
| LE-008 | `workspace-content-pipeline/package.json`, `workspace-content-pipeline/AGENTS.md`, `workspace-content-pipeline/docs/operator-guide.md`, `workspace-content-pipeline/docs/cardnews-image-pipeline.md` | Bun/Hono/React/Drizzle/Postgres/Redis worker 구조이며 content generation, approval queue, dry-run과 manual export 경계가 있다. | fullstack/content preset, DB/queue overlay, media-generation overlay, external-publish approval overlay 수요 | 강함. 외부 게시와 credential 사용은 core 기본 동작이 될 수 없다. |
| LE-009 | `workspace-quant-system/pyproject.toml`, `workspace-quant-system/AGENTS.md`, `workspace-quant-system/docs/runbooks/paper-bot-operations.md`, `workspace-quant-system/tests/backtest/` | Python quant/data repo이고 backtest, data adapter, dashboard, paper execution, risk monitor tests와 fail-closed dry-run runbook을 가진다. | data/ML preset, data-quality and reproducibility overlay, safety-gated operations overlay 수요 | 강함. live trading이나 live order 수요로 확대하지 않는다. |
| LE-010 | `workspace-gitops/AGENTS.md`, `workspace-gitops/charts/app-template/Chart.yaml`, `workspace-gitops/charts/app-template/templates/` | Argo CD와 Helm 기반 GitOps repo이며 live cluster mutation을 금지하고 declarative manifest 변경과 read-only 관찰만 허용한다. | infra/GitOps preset, deployment-diff overlay, dangerous-command guard 수요 | 강함. 일반 backend preset으로 흡수하면 권한 경계가 사라진다. |
| LE-011 | `workspace-knowledge-base/README.md`, `workspace-knowledge-base/CONVENTIONS.md`, `workspace-knowledge-base/templates/docs/`, `workspace-knowledge-base/templates/linear/` | Markdown 지식 SOT이며 문서 type, frontmatter, lifecycle, code pairing과 PRD/spec/ADR/decision/issue templates가 명시돼 있다. | docs/knowledge preset, structured authoring and lifecycle overlay 수요 | 강함. code implementation workflow와 분리해야 한다. |
| LE-012 | `workspace-book-publisher/README.md`, `workspace-book-publisher/main/package.json`, `workspace-book-publisher/main/renderer/README.md`, `workspace-book-publisher/main/skills/book-builder/README.md` | 원고, assets, 공용 renderer, HTML/PDF/EPUB export와 검증 도구를 관리하는 출판 작업대다. PDF export는 로컬 Chrome/Chromium을 요구한다. | content/artifact preset, document rendering and visual QA overlay 수요 | 강함. 브라우저 요구는 task-triggered tool requirement다. |
| LE-013 | `workspace-desktop-media/go.mod`, `workspace-desktop-media/README.md`, `workspace-desktop-media/internal/sprite/*_test.go`, `workspace-desktop-media/frontend/package.json` | Go 기반 AI sprite studio이며 frontend, sprite pipeline, provider, preset, scoring tests를 가진다. | desktop/media preset, image generation and asset inspection overlay 수요 | 강함. image provider와 생성 도구는 core에 상시 활성화하지 않는다. |
| LE-014 | `workspace-mobile-companion/package.json`, `workspace-mobile-companion/README.md`, `workspace-mobile-companion/apps/relay/src/ws/`, `workspace-mobile-companion/apps/pwa/src/*.test.ts*` | TypeScript workspace에 PWA, Mac companion, relay와 WebSocket/auth tests가 있다. | web/mobile companion preset, realtime/auth/browser overlay 수요 | 강함. 이름의 `mobile`만으로 React Native preset을 선택하면 오분류된다. |
| LE-015 | `sumcar-app/package.json`, `sumcar-app/README.md`, `sure-app/package.json`, `sure-app/README.md` | 두 repo 모두 React Native Android/iOS 앱이고 build, lint, test, native setup script가 있다. | native mobile preset, platform build/release overlay 수요 | 강함. release나 signing은 approval과 secret이 필요한 별도 overlay다. |
| LE-016 | `workspace-game/project.godot`, `workspace-game/docs/asset-production-spec-20260622.md`, `workspace-game/docs/design/` | Godot project와 game world, character, cutscene, asset pipeline spec이 tracked되어 있다. | game preset, engine-specific validation, visual asset overlay 수요 | 강함. `.agents` 운영 기록은 사용하지 않았다. |
| LE-017 | `workspace-mcp-server/package.json`, `workspace-mcp-server/README.md`, `workspace-mcp-server/docs/verify-connection.png` | TypeScript MCP server이고 CLI/HTTP start, type-check, lint, build script와 connection guide를 가진다. | MCP/tool-server preset 또는 agent-tool overlay, connection verification 수요 | 중간. README의 원격 링크나 service 상태는 현재성 검증을 하지 않았다. |
| LE-018 | `workspace-next-app/package.json`, `workspace-vite-app/package.json` | 각각 Next.js와 Vite React 앱이며 build/dev/lint script를 가진다. 후자는 i18n dependencies가 있다. | 경량 web-ui preset과 i18n overlay 수요 | 중간. scaffold README만으로 제품 workflow를 추론하지 않는다. |
| LE-019 | `brain-poc-kit/README.md`, `brain-poc-kit/docs/bootstrap.md`, `brain-poc-kit/docs/connectors.md`, `brain-poc-kit/docs/secrets.md` | runtime code를 복제하지 않는 배포 scaffold이며 bootstrap, connector, hosting, secret 문서를 가진다. | deployment scaffold preset, connector and secret-boundary overlay 수요 | 강함. 실제 customer runtime으로 분류하지 않는다. |
| LE-020 | `workspace-interactive-web/docs/data-sources.md`, `workspace-interactive-web/docs/data-model.md`, `workspace-interactive-web/docs/tactics-and-simulation.md`, `workspace-interactive-web/docs/tech-stack.md` | 코드 manifest 없이 product/data/simulation research 문서가 중심이다. | research/planning preset, source evaluation overlay 수요 | 제한적. 구현 stack은 확정할 수 없다. |
| LE-021 | `workspace-client-app/docs/adapter-strategy.md`, `workspace-client-app/docs/platform-research.md` | 코드 manifest 없이 adapter와 platform research 문서가 중심이다. | research/planning preset 수요 | 제한적. 두 문서만으로 product preset을 자동 선택하면 안 된다. |

`workspace-game`, `workspace-interactive-web`, `workspace-client-app`에서 tracked `.agents` 파일도 확인됐지만, 운영 상태나 대화 이력은 근거에서 제외했다. `workspace-vite-app`와 `workspace-next-app`의 scaffold성 README도 반복 workflow 근거로 사용하지 않았다.

## 3. 반복 작업 수요

| Evidence ID | Repo / path | 관찰 사실 | Inferred need | 계층 |
|---|---|---|---|---|
| WF-001 | `yard/templates/agents/skills/planning-gate/SKILL.md`, `workspace-agent-runtime/AGENTS.md`, `workspace-quant-system/AGENTS.md`, `workspace-knowledge-base/templates/linear/research-shaping.md` | 작업 전 scope, SOT, acceptance, 추적 대상을 먼저 고정하는 절차가 서로 다른 repo에 존재한다. | bounded planning과 intent adherence는 stack 무관 core workflow 후보 | Core |
| WF-002 | `workspace-agent-runtime/docs/map/README.md`, `workspace-agent-runtime/docs/map/testing.md`, `workspace-service/docs/codebase-map.ko.md`, `workspace-erp-monorepo/AGENTS.md` | 수정 전에 repo map, package-level AGENTS, domain map과 test strategy를 먼저 읽도록 한다. | repo orientation과 최소 context pack은 core workflow 후보 | Core |
| WF-003 | `yard/.github/workflows/ci.yml`, `workspace-erp-monorepo/AGENTS.md`, `workspace-backend-builder/package.json`, `workspace-service/package.json`, `workspace-mobile-companion/package.json` | Rust, pnpm, Bun, Yarn repo 모두 build, lint/typecheck, unit/E2E 검증을 명시한다. | 변경 범위에 맞는 narrow-first validation과 전체 gate 확인은 core workflow 후보 | Core |
| WF-004 | `workspace-erp-monorepo/AGENTS.md`, `workspace-backend-builder/AGENTS.md`, `workspace-service/AGENTS.md` | shared package 선행 build, DTO/entity 영향, TypeScript와 Go의 복수 validation처럼 변경 영향이 package 경계를 넘는다. | manifest와 dependency boundary를 읽는 product preset 수요 | Product preset |
| WF-005 | `workspace-agent-runtime/.agents/rules/debugging.md`, `workspace-agent-runtime/docs/map/gotchas.md`, `workspace-backend-builder/apps/api/__tests__/`, `workspace-desktop-media/internal/sprite/*_test.go` | 실패 시 원인 경로를 먼저 찾고, domain별 regression test로 계약을 고정하는 패턴이 있다. | evidence-first diagnosis와 regression proof는 core workflow 후보 | Core |
| WF-006 | `.agents/rules/multi-session-safety.md`, `.agents/rules/worktree-tooling.md`, `workspace-agent-runtime/AGENTS.md`, `workspace-gitops/AGENTS.md` | worktree ownership, selective staging, tracker 연결, shared-state mutation 금지 같은 delivery 경계가 반복된다. | safe git delivery와 session boundary는 core workflow 후보 | Core |
| WF-007 | `workspace-knowledge-base/CONVENTIONS.md`, `workspace-knowledge-base/templates/docs/`, `workspace-book-publisher/README.md`, `yard/README.md`, `yard/README.ko.md` | 문서 type/lifecycle/template, 출판 산출물, 다국어 mirror처럼 문서 자체가 검증 대상인 repo가 있다. | documentation, handoff, artifact verification은 core workflow 후보이며 형식별 동작은 overlay | Core + overlay |
| WF-008 | `workspace-agent-runtime/AGENTS.md`, `workspace-service/AGENTS.md`, `workspace-quant-system/docs/runbooks/paper-bot-operations.md`, `workspace-gitops/AGENTS.md` | secret 차단, human approval, dry-run, live mutation 금지와 fail-closed 정책이 반복된다. | permission preflight와 dangerous-action gate는 core review의 필수 단계 | Core |
| WF-009 | `workspace-erp-monorepo/docs/erp-rebuild/PARITY_CHECKLIST.md`, `workspace-backend-builder/package.json`, `workspace-backend-builder/apps/web/`, `workspace-game/docs/asset-production-spec-20260622.md` | UI parity, Playwright E2E, visual asset 규격처럼 화면 또는 렌더 결과를 봐야 하는 검증이 있다. | browser/visual evidence는 task-triggered overlay | Overlay |
| WF-010 | `workspace-content-pipeline/package.json`, `workspace-backend-builder/package.json`, `workspace-service/AGENTS.md` | migration script, DB lifecycle, TypeORM entity rollout과 transaction contract가 명시된다. | database schema/migration overlay | Overlay |
| WF-011 | `workspace-gitops/charts/app-template/`, `workspace-service/Dockerfile`, `workspace-content-pipeline/docker-compose.yml`, `workspace-backend-builder/.github/workflows/cd.yml` | Helm, Docker, CI/CD와 environment-specific delivery 파일이 여러 repo에 있다. | infra/deploy overlay, read-only inspect와 mutation approval 분리 | Overlay |
| WF-012 | `workspace-quant-system/docs/decisions/2026-06-16-adjusted-close-audit.md`, `workspace-quant-system/tests/backtest/`, `workspace-quant-system/docs/runbooks/paper-bot-operations.md` | source data 보정, backtest 비용/달력, dry-run ledger와 risk guard를 함께 검증한다. | data-quality, benchmark, reproducibility overlay | Overlay |
| WF-013 | `workspace-content-pipeline/docs/cardnews-image-pipeline.md`, `workspace-book-publisher/main/renderer/README.md`, `workspace-desktop-media/internal/sprite/`, `workspace-game/docs/design/` | image, book, sprite, game asset은 code test 외에 생성물 규격과 시각 검증을 요구한다. | media/artifact overlay와 optional generation tool capability | Overlay |
| WF-014 | `sumcar-app/package.json`, `sure-app/package.json`, `workspace-mobile-companion/apps/relay/src/ws/` | native platform build, device permissions, realtime relay가 일반 web build와 다른 검증을 요구한다. | native-mobile 또는 realtime overlay | Product preset + overlay |
| WF-015 | `yard/docs/skills.md`, `workspace-agent-runtime/app/agent/`, `brain/internal/core/`, `workspace-mcp-server/package.json` | worker contract, agent runtime, messenger abstraction, MCP tool server처럼 AI/tool boundary를 구현하는 repo가 여럿이다. | agent/LLM/tool-contract preset 또는 overlay | Product preset + overlay |

## 4. 수요 계층 제안

이 절은 upstream skill 채택안을 확정하지 않는다. 후속 연구가 후보를 매핑할 수 있도록 **무엇이 필요한지**만 고정한다.

### 4.1 Core workflow 후보 수요

Fresh install의 core는 다음 7개 이하 workflow로 수렴할 근거가 있다.

| Core demand ID | Workflow 수요 | 근거 | 기본 권한 경계 |
|---|---|---|---|
| CORE-D1 | Intent와 acceptance를 고정하는 bounded planning | WF-001 | local read와 계획 문서만. 외부 mutation 없음. |
| CORE-D2 | Manifest, repo map, AGENTS와 변경 surface를 읽는 orientation | WF-002, LE-001부터 LE-021 | local read only. secret과 운영 이력 제외. |
| CORE-D3 | 실제 code path와 재현 근거부터 찾는 diagnosis/research | WF-005 | local read와 승인된 read-only network. script 실행은 별도 gate. |
| CORE-D4 | Scope에 맞는 구현과 narrow-first validation | WF-003, WF-004 | repo가 제공한 local commands만. deploy와 publish 제외. |
| CORE-D5 | Acceptance, regression, security를 독립적으로 검토하는 review | WF-005, WF-008 | 검토는 기본 read-only. 위험 발견을 자동 수정이나 외부 mutation으로 확대하지 않음. |
| CORE-D6 | Worktree, selective staging, handoff를 지키는 safe delivery | WF-006 | commit/push/release는 사용자 및 repo 정책을 따름. fresh core가 자동 push하지 않음. |
| CORE-D7 | 결정, 변경, 검증을 재현 가능한 문서와 handoff로 남기는 documentation | WF-007 | repo의 SOT와 template을 우선. secret, PII 제외. |

`browser-evidence`, `database-migration`, `image-generation`, `deploy`, `mobile-release`를 core에 넣을 근거는 없다. 해당 기능은 특정 manifest, path 또는 task intent가 있을 때만 활성화해야 하고 network, secret, native toolchain, browser, external mutation 권한을 core 전체에 전파해서는 안 된다.

### 4.2 Product preset 수요

| Preset demand ID | Archetype signal 예시 | Workspace evidence | 포함할 전문 수요 | 제한 |
|---|---|---|---|---|
| PRESET-D1 | `Cargo.toml`, CLI entrypoint, Ratatui 또는 clap | LE-001 | CLI design, deterministic state, Rust test/build | `Cargo.toml`만으로 CLI라고 단정하지 말고 bin/source signal을 함께 본다. |
| PRESET-D2 | `package.json` + workspace + frontend/backend packages | LE-002, LE-003, LE-006, LE-014 | monorepo dependency order, filtered validation, web/backend boundary | hybrid repo이므로 복수 preset 허용이 필요하다. |
| PRESET-D3 | backend framework + domain/DTO/entity paths | LE-004, LE-005, LE-007 | API contract, domain navigation, service tests | DB, auth, deploy는 task overlay로 분리한다. |
| PRESET-D4 | data/ML dependencies + backtest/data tests | LE-009 | data quality, reproducibility, benchmark discipline | finance live action은 포함하지 않는다. |
| PRESET-D5 | Helm/Kubernetes/GitOps paths | LE-010 | declarative diff, values/chart validation, read-only cluster posture | cluster mutation은 기본 금지다. |
| PRESET-D6 | docs/templates/manuscript/renderer 중심 | LE-011, LE-012, LE-020, LE-021 | structured authoring, citation, artifact packaging | manifest가 없으면 구현 preset을 추정하지 않는다. |
| PRESET-D7 | React Native, Godot, Wails/media pipeline | LE-013, LE-015, LE-016 | native/game/desktop build and asset conventions | 서로 같은 preset으로 뭉치기보다 공통 core + 작은 product-specific additions가 안전하다. |
| PRESET-D8 | agent runtime, MCP server, tool/worker contract | LE-001, LE-004, LE-005, LE-017 | tool contract, capability boundary, deterministic adapter tests | provider credential이나 network access를 자동 부여하지 않는다. |

PRESET-D6의 `workspace-interactive-web`와 `workspace-client-app`은 research 문서 중심이라는 사실까지만 강하다. 이 두 repo를 특정 구현 stack으로 분류할 근거는 없다. PRESET-D7은 workspace에서 수요가 분명하지만 Godot, React Native, Wails의 toolchain이 크게 다르므로 하나의 거대한 preset보다 별도 소형 preset이 적합하다는 제한을 둔다.

### 4.3 Task-triggered overlay 수요

| Overlay demand ID | Overlay 수요 | Positive signal | Negative / stop signal | Evidence |
|---|---|---|---|---|
| OVERLAY-D1 | Browser and visual evidence | UI path, Playwright, screenshot, parity, rendered artifact task | backend-only change, browser가 없는 환경 | WF-009, LE-012 |
| OVERLAY-D2 | Database and migration | entity/schema/migration path, DB task intent | read-only query 설명, schema 무관 작업 | WF-010 |
| OVERLAY-D3 | Security, auth and secret boundary | auth/RBAC/guardrail/secret path 또는 security review intent | secret 값을 읽거나 출력해야만 진행되는 작업은 stop | WF-008, LE-006, LE-007 |
| OVERLAY-D4 | CI, deploy and GitOps | workflow, Dockerfile, chart, deployment task | publish, deploy, cluster mutation은 승인 없이는 stop | WF-011, LE-010 |
| OVERLAY-D5 | Data quality and benchmark | data adapter, backtest, benchmark, statistical task | live order, production mutation | WF-012 |
| OVERLAY-D6 | Media and artifact production | image, sprite, book, PDF, video, game asset task | 생성 도구나 license가 검증되지 않음 | WF-013 |
| OVERLAY-D7 | Native mobile and realtime | React Native, Android/iOS, WebSocket, relay path | 단순 responsive web task | WF-014 |
| OVERLAY-D8 | External integration and publishing | connector, social adapter, MCP connection, explicit publish task | credential 부재, dry-run 요구, 사용자 승인 부재 | LE-008, LE-017, LE-019 |
| OVERLAY-D9 | Research and citation | source comparison, research ledger, docs-only repo | local code diagnosis만 필요한 작업 | LE-020, LE-021, `workspace-book-publisher/main/books/ai-token-to-agent/docs/research-ledger.md` |
| OVERLAY-D10 | Agent and LLM tool contract | worker, agent, prompt, MCP, provider adapter path | 일반 application feature | WF-015 |

Overlay는 task 수명 동안만 활성화해야 한다. repo에 `Dockerfile`이 있다는 이유만으로 deploy overlay를, image dependency가 있다는 이유만으로 image generation overlay를 상시 넣지 않는다.

## 5. `local-reference-catalog` 비교 증거

이 절은 metadata 수준의 관찰만 기록한다. catalog 행의 설명과 trigger, preset member 목록, SKILL.md 전문이나 디렉터리 구조를 복사하지 않는다.

| Evidence ID | 경로 / identifier | 관찰 차이 | 이 연구에서의 처리 |
|---|---|---|---|
| OC-001 | `<workspace>/local-reference-catalog/catalog/skills.tsv` | header는 `name`, `tier`, `presets`, `description`, `triggers`이고 identifier 행은 90개다. 같은 위치의 `skills/`에도 90개 identifier directory가 있어 이름 집합 차이는 발견되지 않았다. | taxonomy 규모와 catalog 필드가 존재한다는 비교 근거만 사용. 내용은 후보 원장으로 복제하지 않음. |
| OC-002 | `<workspace>/local-reference-catalog/presets/*.skills` | preset identifier는 `ai-ml`, `all`, `backend-api`, `cli-tool`, `cms`, `commerce`, `content-studio`, `core`, `data-engineering`, `data-science`, `desktop`, `game`, `infra`, `library-package`, `media-studio`, `mobile`, `ops`, `qa`, `research`, `security`, `video`, `web-ui`의 22개다. member 수는 1개부터 39개까지이며 `core`는 7개다. | identifier와 규모만 비교. member 정의는 기록하거나 채택하지 않음. |
| OC-003 | `workspace-quant-system/.agents/skills/*`, `workspace-content-pipeline/.agents/skills/*`, `workspace-mobile-companion/.agents/skills/*` symlink metadata | 세 repo의 tracked harness 설명은 workspace 공용 asset 사용을 명시하고, 실제 local symlink 일부가 `../../../local-reference-catalog/skills/<identifier>`를 가리킨다. | workspace에서 이 catalog가 사용된 흔적만 증명. 사용 효과나 품질을 증명하지는 않음. |
| OC-004 | `<workspace>/local-reference-catalog/` root metadata | 이 directory 자체에서 Git `HEAD`를 확인할 수 없었고, root와 2-depth metadata scan에서 LICENSE, README, source commit, provenance 또는 version 문서를 찾지 못했다. 파일 수정 시각은 provenance가 아니다. | source commit과 license를 고정할 수 없으므로 fresh install 재배포 원장이나 upstream 적격 후보로 사용 금지. |
| OC-005 | `yard/docs/skills.md` | Yardlet 문서는 기존 90-skill catalog와 preset library를 연구 입력으로 언급하지만, 동시에 library를 read-only discovery 대상으로 두고 worker authoring과 deterministic recording을 분리한다. | 기존 메커니즘 비교에는 사용하되, 이번 fresh library의 후보 선정은 별도 upstream 검증을 거쳐야 함. |

### 비복제 판정

- `local-reference-catalog`의 90개 이름이 많다는 사실은 built-in 90개가 필요하다는 근거가 아니다.
- workspace에서 symlink로 사용됐다는 사실은 license, provenance, 유지 상태, 안전성 또는 효과를 증명하지 않는다.
- `core` preset이 7개라는 숫자는 이번 core workflow 상한과 우연히 같지만, member 구성은 비교하거나 채택하지 않았다.
- workspace에는 hybrid monorepo, docs-only repo, 이름과 실제 stack이 어긋나는 `workspace-mobile-companion` 사례가 있다. 따라서 preset name 하나나 directory name 하나만으로 활성화하면 안 된다.

## 6. Deterministic classification에 넘길 로컬 결론

후속 정책 문서는 이 근거에서 다음 분류 요구를 가져가야 한다.

1. **Manifest 우선**: `Cargo.toml`, `pyproject.toml`, `go.mod`, `package.json`, `project.godot`, Helm chart 같은 tracked manifest를 첫 신호로 사용한다.
2. **Path와 script 교차 확인**: package name이나 repo name만 보지 말고 bin/source path, workspace packages, test script, framework dependency를 함께 본다. LE-014는 `mobile`이라는 이름만으로 native mobile로 분류하면 실패하는 반례다.
3. **Task intent로 overlay 제한**: deploy, browser, DB, media, external publish는 repo에 관련 파일이 있어도 task가 요구할 때만 활성화한다.
4. **Explicit user signal 우선**: user가 특정 tool, preset 또는 금지 범위를 명시하면 추론보다 우선한다.
5. **Negative signal과 no-match 보존**: docs-only repo, scaffold README, provenance 없는 local catalog는 억지 분류하지 않는다. core만 적용하고 research 또는 사용자 선택으로 확장할 수 있어야 한다.
6. **복수 preset 허용**: LE-002와 LE-006처럼 web, backend, Go runtime, DB가 공존할 수 있다. 단, overlay까지 repo 수명으로 승격하지 않는다.
7. **권한은 별도 판정**: 분류 결과가 network, secret, browser, native toolchain, deploy 또는 external mutation 권한을 자동 부여하지 않는다.

## 7. 한계와 후속 원장에 대한 요구

- 이 조사는 local checkout snapshot이다. remote 최신성, 유지 상태, 외부 source와 license는 검증하지 않았다.
- 실제 빈도는 telemetry나 run history를 보지 않았으므로 측정하지 않았다. 여기서 반복은 안정적 tracked evidence의 repo 간 반복을 뜻한다.
- local `local-reference-catalog`의 provenance가 없으므로 어떤 identifier도 upstream 후보 ID로 승격하지 않았다.
- package manifest는 capability 존재를 보여주지만 성공한 workflow를 증명하지 않는다. tests, runbook, template과 함께 있는 경우에만 근거 강도를 높였다.
- 후속 후보 원장은 CORE-D1부터 CORE-D7, PRESET-D1부터 PRESET-D8, OVERLAY-D1부터 OVERLAY-D10을 upstream candidate ID에 연결하고, immutable commit, license, bundled scripts/assets, network, secret, tool 요구와 Yardlet adaptation을 독립적으로 검증해야 한다.

## 8. Acceptance 자체 점검

| Criterion | 판정 | 근거 |
|---|---|---|
| Repo 유형과 반복 작업을 evidence ID, path, 관찰 사실, inferred need로 분리 | Pass | LE-001부터 LE-021, WF-001부터 WF-015 |
| 반복 작업을 tracked 안정 근거로 입증하고 운영 이력 mining 제외 | Pass | 1절 조사 규칙과 각 WF path. run/telemetry/conversation 내용은 사용하지 않음 |
| `local-reference-catalog`를 비복제 비교 증거로만 사용 | Pass | OC-001부터 OC-005와 비복제 판정 |
| Core, product preset, overlay 수요를 구분하고 약한 추론 제한 | Pass | 4.1부터 4.3, LE-018부터 LE-021의 제한, 7절 |
| 허용된 연구 문서 외 workspace 파일 무변경 | Pass | Git diff validation으로 별도 확인 |
