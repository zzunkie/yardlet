# Worker Routing Research Notes

Updated: 2026-06-18

## Current read

Public benchmarks do not justify a permanent "Claude over Codex" or "Codex
over Claude" rule. The useful routing split is:

- Use telemetry and human-reviewed rubric updates for normal work.
- Use hard capability rules for tasks one worker can satisfy and the other
  cannot, such as image/asset generation.
- Keep `best_for` vocabulary benchmark-shaped: concrete task families, not
  broad claims like "frontend", "backend", "writing", or "research" unless the
  task surface is also named.

## Domain Registry for Routing Surfaces

This registry is intentionally broader than coding. Yardlet should route by the
work product the user wants, then by implementation surface. Coding benchmarks
are one family inside this table, not the center of the taxonomy.

Evidence quality varies by domain. Mature public benchmarks should seed
`best_for` vocabulary directly; newer or vendor-specific benchmarks should be
treated as candidate vocabulary until Yardlet telemetry confirms them locally.

| Product / work domain | Representative benchmarks | Useful routing vocabulary |
| --- | --- | --- |
| General assistant research | [GAIA](https://huggingface.co/gaia-benchmark), [HAL GAIA leaderboard](https://hal.cs.princeton.edu/gaia) | web research, multimodal evidence gathering, tool-use reasoning, multi-step factual answer |
| Instruction following / formatting | [IFEval](https://arxiv.org/abs/2311.07911), [M-IFEval](https://aclanthology.org/2025.findings-naacl.344/) | verifiable instruction following, format constraints, structured output, multilingual instruction adherence |
| Generative writing | [WritingBench](https://github.com/X-PLUG/WritingBench), [WritingBench paper](https://arxiv.org/html/2503.05244v2) | academic writing, business document, creative writing, technical documentation, persuasive/informative writing |
| Long-form writing | [LongBench-Write / LongWriter](https://openreview.net/forum?id=kQ5s9Yh0WI), [LongWriter repo](https://github.com/THUDM/LongWriter) | long-form generation, chapter/section planning, length-constrained writing, coherence over long output |
| Creative writing | [EQ-Bench creative writing](https://eqbench.com/creative_writing.html), [WritingBench](https://github.com/X-PLUG/WritingBench) | story/dialogue/worldbuilding, style control, repetition avoidance, voice consistency |
| Editing / rewriting | [WritingBench](https://github.com/X-PLUG/WritingBench), [IFEval](https://arxiv.org/abs/2311.07911) | tone-preserving rewrite, clarity edit, compression, style-guide compliance, constrained rewrite |
| Summarization / briefing | [SummEval](https://github.com/Yale-LILY/SummEval), [SummEval paper](https://arxiv.org/abs/2007.12626) | faithful summary, evidence-preserving synthesis, long-document briefing, consistency and coverage |
| Translation / localization | [WMT shared tasks](https://machinetranslate.org/wmt), [WMT translation task](https://www2.statmt.org/wmt26/translation-task.html) | machine translation, document-level translation, localization, terminology consistency, multilingual QA |
| Education / tutoring | [TutorBench](https://labs.scale.com/leaderboard/tutorbench), [MathTutorBench](https://eth-lre.github.io/mathtutorbench/) | adaptive explanation, actionable feedback, hint generation, active-learning tutoring |
| Math / scientific reasoning | [GPQA](https://arxiv.org/abs/2311.12022), [SciBench](https://scibench-ucla.github.io/), [MathVista](https://github.com/lupantech/MathVista) | graduate-level science QA, college scientific problem solving, visual math reasoning, derivation checking |
| Multimodal document/image reasoning | [MMMU](https://mmmu-benchmark.github.io/), [MMMU-Pro](https://aclanthology.org/2025.acl-long.736/) | chart/diagram/table reasoning, domain image understanding, multimodal expert QA |
| Video understanding | [Video-MME](https://video-mme.github.io/home_page.html), [Video-MME v2](https://video-mme-v2.netlify.app/) | video QA, temporal reasoning, long-video understanding, multimodal video evidence |
| Audio / speech understanding | [AudioBench](https://aclanthology.org/2025.naacl-long.218/), [AudioBench repo](https://github.com/audiollms/audiobench) | speech understanding, audio scene understanding, paralinguistic voice cues, audio-conditioned instruction following |
| Image generation / visual assets | [GenAI-Bench](https://linzhiqiu.github.io/papers/genai_bench/), [T2I-CompBench](https://karine-h.github.io/T2I-CompBench/), [ImageReward](https://github.com/zai-org/ImageReward) | text-to-image generation, compositional visual prompt, asset generation, semantic/aesthetic alignment |
| Video generation | [VBench](https://vchitect.github.io/VBench-project/), [VBench repo](https://github.com/Vchitect/VBench) | text-to-video generation, motion smoothness, temporal consistency, subject identity, prompt faithfulness |
| Computer / desktop operation | [OSWorld](https://os-world.github.io/) | desktop app workflow, GUI grounding, file/app operation, multi-application workflow |
| Browser / website operation | [WebArena](https://webarena.dev/), [VisualWebArena](https://github.com/web-arena-x/visualwebarena) | browser task execution, web form/navigation workflow, visually grounded web task |
| Live web navigation / consumer workflow | [Mind2Web](https://osu-nlp-group.github.io/Mind2Web/), [Online-Mind2Web](https://leaderboard.steel.dev/leaderboards/online-mind2web/) | live website task, shopping/finance/travel/government web workflow, form completion, navigation recovery |
| Enterprise SaaS workflow | [WorkArena](https://servicenow.github.io/WorkArena/), [WorkArena++](https://openreview.net/forum?id=PCjK8dqrWW&noteId=nIdhK4PhIJ) | enterprise SaaS workflow, ticket/update/retrieval flow, multi-step browser workflow |
| Workplace digital-worker tasks | [TheAgentCompany](https://arxiv.org/html/2412.14161v2), [AgentBench](https://github.com/THUDM/AgentBench) | office workflow, coworker communication, file/code/web mixed task, simulated company task |
| Customer support / policy-bound conversation | [tau-bench](https://taubench.com/), [tau-bench repo](https://github.com/sierra-research/tau-bench) | customer-service dialogue, policy following, tool-backed support action, airline/retail/banking workflow |
| App ecosystem / personal ops | [AppWorld](https://appworld.dev/) | calendar/email/people app workflow, multi-app API task, stateful personal operations |
| Personal assistant / scheduling | [LiveClawBench](https://arxiv.org/html/2604.13072v1), [PersonaLens](https://aclanthology.org/2025.findings-acl.927/) | calendar/email assistant, ambiguous real-world request, personalized task completion, memory-aware assistant flow |
| Travel planning | [TravelPlanner](https://osu-nlp-group.github.io/TravelPlanner/), [ChinaTravel](https://openreview.net/forum?id=0YRVlxY9BH) | constraint-satisfying itinerary, tool-backed travel plan, multi-day plan, budget/time/preference tradeoff |
| E-commerce / shopping | [WebMall](https://arxiv.org/html/2508.13024v3), [WebShop](https://webshop-pnlp.github.io/), [Mind2Web](https://osu-nlp-group.github.io/Mind2Web/) | product search, offer comparison, purchase workflow, intent-grounded shopping, multi-shop browsing |
| Product / business planning | [WritingBench](https://github.com/X-PLUG/WritingBench), [GAIA](https://huggingface.co/gaia-benchmark) | PRD, strategy memo, requirements synthesis, roadmap narrative, decision brief |
| Marketing / sales content | [WritingBench](https://github.com/X-PLUG/WritingBench), [IFEval](https://arxiv.org/abs/2311.07911) | landing-page copy, sales email, campaign concept, audience/tone adaptation, constrained copywriting |
| Social media / community work | [SoMe](https://github.com/LivXue/SoMe), [WritingBench](https://github.com/X-PLUG/WritingBench) | social data analysis, post/thread drafting, audience/personality inference, community response planning |
| Recruiting / HR screening | [RecruitBench](https://cs191w.stanford.edu/projects/Winter2026/_Aditya___Sood_.pdf), resume-screening research such as [LLM-agent resume screening](https://arxiv.org/html/2401.08315v2) | resume-job matching, candidate summary, interview-advancement prediction, structured hiring rationale |
| Spreadsheet work | [SpreadsheetBench](https://spreadsheetbench.github.io/) | spreadsheet manipulation, formula repair, workbook analysis, business spreadsheet workflow |
| Data visualization | [VisEval](https://github.com/microsoft/VisEval), [ChartMimic](https://chartmimic.github.io/) | natural-language-to-chart, chart code generation, visual chart reproduction, dashboard chart repair |
| Document reading / extraction | [DocBench](https://github.com/Anni-Zou/DocBench), [DocVQA](https://www.docvqa.org/) | PDF/document QA, OCR-backed document reading, metadata extraction, long-document evidence |
| Finance analysis | [FinanceBench](https://github.com/patronus-ai/financebench) | SEC filing QA, financial evidence retrieval, numerical financial reasoning, earnings/10-K analysis |
| Legal reasoning | [LegalBench](https://www.legalbench.ai/), [LegalBench paper](https://arxiv.org/abs/2308.11462) | rule application, statutory interpretation, case comparison, legal classification |
| Healthcare / clinical response | [HealthBench](https://openai.com/index/healthbench/) | realistic health conversation, care guidance, clinician documentation, medical research support |
| Cybersecurity | [Cybench](https://cybench.github.io/), [CyberSecEval 4](https://meta-llama.github.io/PurpleLlama/CyberSecEval/docs/intro), [CyberSOCEval](https://ai.meta.com/research/publications/cybersoceval-benchmarking-llms-capabilities-for-malware-analysis-and-threat-intelligence-reasoning/) | CTF-style security task, defensive SOC analysis, malware/threat-intel reasoning, security-risk review |
| Research replication | [PaperBench](https://openai.com/index/paperbench/) | paper replication, experiment reproduction, research codebase buildout, rubric-scored subtask |
| Data analysis | [InfiAgent-DABench](https://infiagent.github.io/), [DA-bench](https://dabench.com/) | CSV/data analysis, closed-form analytic answer, chart/table reasoning, reproducible analysis |
| ML engineering | [MLE-bench](https://github.com/openai/mle-bench) | Kaggle-style ML pipeline, dataset prep, training/evaluation loop, experiment iteration |
| SQL/database workflow | [Spider 2.0](https://spider2-sql.github.io/), [Spider](https://yale-lily.github.io/spider) | enterprise text-to-SQL, metadata search, dialect-specific SQL, dbt/warehouse workflow |
| API/integration workflow | [Live API Bench](https://arxiv.org/html/2506.11266v2), [APIBench](https://zenodo.org/records/10066550) | API parameter mapping, multi-step tool/API call, integration wiring, response parsing |
| Supply chain / demand planning | [M5 forecasting competition](https://www.manh.com/solutions/supply-chain-planning-software/m5-benchmark), supply-chain LLM decision benchmarks such as [this 2025 study](https://link.springer.com/article/10.1007/s11761-025-00474-7) | demand forecasting, inventory/planning scenario, supply-chain risk identification, operations decision support |
| Embodied / robotics planning | [EmbodiedBench](https://arxiv.org/html/2502.09560v3), [ALFWorld](https://alfworld.github.io/) | embodied task planning, household/robot manipulation plan, multimodal action grounding, dynamic environment adaptation |
| Safety / harmful agent requests | [AgentHarm](https://openreview.net/forum?id=AC5n7xHuR1) | safety-sensitive agent action, harmful-task refusal, tool-use safety review |
| Software engineering / coding | See detailed coding registry below | issue repair, code generation, cross-file edit, visual UI bugfix, game development |

### Coverage tiers

- **Stronger seeds:** SWE-bench, Terminal-Bench, GAIA, IFEval, WMT,
  MMMU, OSWorld, WebArena, WorkArena, tau-bench, AppWorld, FinanceBench,
  LegalBench, HealthBench, MLE-bench, Spider, TravelPlanner, Cybench, and
  PaperBench have clearer task definitions, public artifacts, or active
  leaderboards. Their vocabulary is reasonable to use in `best_for`.
- **Useful but still candidate vocabulary:** TheAgentCompany, LiveClawBench,
  SoMe, WebMall, RecruitBench, CR-Bench, VisEval, ChartMimic, supply-chain LLM
  studies, and many UI/design benchmarks are newer, less standardized, or less
  universally adopted. Use their task surfaces as labels for telemetry, not as
  permanent worker preferences without local evidence.
- **Domain KPI benchmarks are not model-routing benchmarks:** social engagement
  reports, supply-chain KPI studies, marketing performance benchmarks, and UX
  benchmark methods can describe the product domain, but they do not prove one
  worker should own that task. They can inform evaluation criteria, not routing
  preference by themselves.

## Coding Subregistry for `best_for`

| Yardlet task surface | Representative benchmarks | Useful routing vocabulary |
| --- | --- | --- |
| Repository issue repair | [SWE-bench](https://github.com/swe-bench/SWE-bench), [SWE-bench Verified](https://www.swebench.com/) | issue-to-patch, test-driven bugfix, regression repair, repository-local diagnosis |
| Visual/front-end bug repair | [SWE-bench Multimodal](https://www.swebench.com/multimodal.html) | visual UI bugfix, screenshot-backed issue repair, JavaScript UI libraries, visual regression reasoning |
| UI design to code | [Design2Code](https://salt-nlp.github.io/Design2Code/), [FullFront](https://openreview.net/forum?id=K7UfQFegK5) | screenshot-to-HTML/CSS, mockup-to-component, visual fidelity, layout implementation |
| Code review | [CR-Bench](https://openreview.net/forum?id=6RmpFMEeOX), [Code Review Bench](https://codereview.withmartian.com/) | pull-request review, issue finding, severity triage, false-positive control, review-comment precision |
| Terminal/devops workflow | [Terminal-Bench](https://www.tbench.ai/) | shell-heavy task, environment setup, build/test/debug loop, terminal tool orchestration |
| Cross-file code context | [CrossCodeEval](https://crosscodeeval.github.io/) | cross-file symbol reasoning, repository context retrieval, Python/Java/TypeScript/C# completion |
| Multi-language code generation | [MultiPL-E](https://nuprl.github.io/MultiPL-E/), [MBXP / Multilingual HumanEval](https://openreview.net/forum?id=Bo7eeXm6An8) | language-specific implementation, translated unit-test task, polyglot code generation |
| Practical library/API coding | [BigCodeBench](https://bigcode-bench.github.io/) | library-heavy function implementation, API composition, multi-call Python utility |
| Game development | [GameDevBench](https://arxiv.org/html/2602.11103v1) | game mechanic implementation, asset-aware game task, engine/project multi-file edit, playable behavior validation |
| Competitive programming / algorithmic reasoning | [LiveCodeBench](https://livecodebench.github.io/) | algorithmic code generation, self-repair, test-output prediction, contest-style reasoning |

## Profile Implications

- `best_for` should use these concrete surfaces: "visual UI bugfix",
  "cross-file TypeScript repair", "faithful long-document briefing",
  "style-guide rewrite", "adaptive tutoring feedback", "enterprise text-to-SQL",
  "Kaggle-style ML pipeline", "constraint-satisfying itinerary",
  "resume-job matching", "defensive SOC analysis", "office workflow",
  "product search and offer comparison", "natural-language-to-chart",
  "game mechanic implementation".
- Avoid unsupported broad labels: "frontend", "backend", "good at Python",
  "good at writing", "good at research", "good at architecture",
  "good at business", "good at HR", "good at marketing", "good at ops", or
  "good at security" unless paired with a benchmark-shaped task surface.
- Product categories are only the first split. Route "shopping" differently
  depending on whether it means product-copy writing, web-agent checkout,
  market research, spreadsheet price comparison, or asset generation.
- Language names are useful only when the surface matters. Example:
  "cross-file TypeScript/Java context" is better than "TypeScript"; "Python
  library-heavy data science task" is better than "Python".
- UI/asset work splits three ways:
  - Generate raster image/asset: hard-route to Codex.
  - Implement UI from a screenshot/mockup: benchmark-shaped `best_for` signal.
  - Diagnose visual UI bugs from screenshots: multimodal bugfix signal.

## Applied Worker Profile

Applied on 2026-06-18 to `.agents/workers.yaml` and
`templates/agents/workers.yaml`.

No meaningful local telemetry sample was available in `.agents/telemetry/` or
`.agents/runs/` during this pass, so this is a seeded profile. Treat it as
policy to validate through future Yardlet telemetry, not as a final benchmark
claim.

| Worker | Assigned surfaces | Reasoning |
| --- | --- | --- |
| Codex | image/asset generation; issue-to-patch implementation; test-driven bugfixes; shell-heavy build/test/debug loops; screenshot/mockup-to-code UI implementation; visual UI bugfixes with concrete evidence; mechanical transforms; schema/format constrained output; routine document/spreadsheet/code edits with clear acceptance criteria | Codex has documented local repo editing, command execution, screenshots, direct image generation/editing, local code review, and non-interactive automation. These surfaces also map to SWE-bench, SWE-bench Multimodal, Terminal-Bench, Design2Code, IFEval, and similar concrete-output benchmarks. |
| Claude Code | ambiguity reduction; acceptance criteria; PRDs, roadmap and decision briefs; faithful long-document briefing; evidence synthesis; style-sensitive writing/editing; broad codebase exploration; architecture and cross-cutting refactor planning; safety/legal/finance/healthcare/HR/customer-support/tutoring policy-bound reasoning | Claude Code is documented as a codebase-aware agentic coding tool. Its profile should spend the higher-cost worker on unclear scope, long-context synthesis, policy/tradeoff reasoning, and planning/review surfaces rather than routine implementation. These surfaces map to WritingBench, LongWriter, GAIA, LegalBench, FinanceBench, HealthBench, TutorBench, tau-bench, and architecture/review workflows. |

## Benchmarks Checked So Far

- [SWE-bench official leaderboard](https://www.swebench.com/) reports a
  `% Resolved` metric over real GitHub issue instances and lets results vary by
  agent scaffold and model. This is useful for broad software-engineering
  capability, but it is not a direct Yardlet worker-routing policy.
- [Terminal-Bench 2.1](https://snorkel.ai/leaderboard/terminal-bench-2-1/)
  ranks terminal agents on command-line tasks. The 2026-05 leaderboard has
  Codex CLI + GPT-5.5 above Claude Code + Claude Opus 4.8, but it is still a
  benchmark snapshot, not a durable profile rule.
- [Auggie on SWE-bench Pro](https://www.augmentcode.com/blog/auggie-tops-swe-bench-pro)
  is a useful caution: multiple agents using the same underlying model can get
  different results. Agent wrapper, tools, context strategy, and workflow matter
  enough that model-only claims should not drive Yardlet routing.

## Capability Evidence

- [Codex CLI features](https://developers.openai.com/codex/cli/features)
  documents direct image generation and editing in Codex CLI, including assets
  such as icons, banners, illustrations, sprite sheets, and placeholder art.
- [Claude Code common workflows](https://docs.anthropic.com/en/docs/claude-code/common-workflows)
  documents image workflows as image analysis and code suggestions from visual
  input, not native image generation.
- [Claude Code overview](https://docs.anthropic.com/en/docs/claude-code/overview)
  describes Claude Code as an agentic coding tool that reads a codebase, edits
  files, runs commands, and integrates with development tools.
- Local handoff evidence in `.agents/handoffs/2026-06-11-session.md` recorded
  the same operational conclusion: Codex has subscription-backed image
  generation available, while Claude produced procedural PNGs rather than using
  an Anthropic image model.

## Routing Decision

Image/asset generation is a hard capability rule:

1. An explicit user run override still wins.
2. Otherwise, image/asset generation routes to `codex`.
3. The rule is strict: if `codex` is not ready, Yardlet should stop instead of
   falling back to `claude-code`.

Normal implementation, research, review, and safety tasks remain planner-rubric
decisions refined by Yardlet telemetry.

## Open Questions

- Whether to keep one `best_for` string per worker or move to structured
  weighted tags such as `surfaces: [visual-ui-bugfix, shell-heavy-debug]`.
- Whether Yardlet telemetry should aggregate by benchmark-shaped surface instead
  of only `task.kind` (`implementation`, `research`, `review`, `safety`).
- Whether planner output should include `task.surface` separately from
  `task.kind`, so routing review can learn from more precise categories.
- Whether the registry should live in machine-readable config
  (`.agents/routing-surfaces.yaml`) so new surfaces can be added without code
  changes.
