# Absorption Plan — taking what's good without becoming what they are

> Status: A1–A4 implemented (discovery, ambiguity gate + interview, semantic rung, ecosystem workers doc). Companion: [harness.md](harness.md)
> (H3 hooks / H4 learning loop continue after this plan's A-phases).
>
> Sources studied: oh-my-pi (can1357), oh-my-openagent / oh-my-claudecode
> (code-yeongyu, Yeachan-Heo), internal-system (Q00), Hermes (NousResearch),
> a presets-and-catalog library.

## Identity invariants (what absorption may NOT bend)

| # | invariant | the line it draws |
|---|---|---|
| I1 | **The core stays deterministic; everything generative sits behind the worker contract.** | "Console vs worker" is a role label and roles blur (Yardlet already merges code, will run hooks, may ship a native API worker). The enforceable line is mechanism: the orchestrator does only deterministic, auditable operations (templating, rule routing, check-based evaluation, git plumbing, hook execution); anything that *generates or judges* work goes through packet → process → result files. A Yardlet-shipped worker (e.g. a native API adapter) is fine **iff** it lives behind that same contract and is routable/swappable like any other worker. Worker-side tool surfaces (LSP, debuggers, kernels) stay with workers — not because tools are forbidden, but because owning them would pull the console into the judgment loop. |
| I2 | **The packet is the only shared injection point.** | Anything absorbed must reach codex, claude, and custom workers identically — never via one CLI's plugin system. |
| I3 | **`.agents/` is canonical; sessions are disposable.** | Discovered/borrowed assets are read at compile time, not copied into state. Yardlet remains the sole writer of its files. |
| I4 | **Minimize human intervention; safety comes from determinism + self-correction + reversibility, not from gates.** | Yardlet's whole point is that the human steps back. Safety is *not* a human approving each change — it is: (a) the deterministic core is the sole writer (LLMs propose, Yardlet writes); (b) an eval feedback loop demotes/prunes what doesn't work (skill scores, routing telemetry); (c) everything is reversible (git, `.agents/`). Reversible, self-correcting assets — skills, learned rules, eventually routing — are applied **automatically**. A human gate is reserved only for the **irreversible or outward-facing**: push, deploy, external sends, secrets, mass deletion. Auto-by-default; opt-outs exist for the cautious. |
| I5 | **Explicit contracts over magic.** | Intent / scope / acceptance / queue are visible artifacts. No keyword-triggered hidden modes. |
| I6 | **Bring-your-own CLI.** | Absorption must reduce setup, not add it. Defaults stay zero-config, zero-new-billing. |

## What each source is, and the one thing worth taking

- **oh-my-pi** — a worker (Pi fork) with an IDE-grade tool surface. Its magic
  moment is onboarding: first run inherits rules/skills/MCP from `.claude`,
  `.cursor`, `.windsurf`, `.gemini`, `.codex`, `.github/copilot`… → **take the
  inheritance idea (A1); register omp itself as a worker (A4); leave the tool
  surface alone (I1).**
- **internal-system** — spec-first Agent OS with *quantified* gates: don't build
  until ambiguity ≤ threshold; verify Mechanical → Semantic → Consensus.
  → **take the ambiguity gate (A2) and the semantic rung (A3); skip the
  evolutionary spec loop and consensus voting for now (cost, I5).**
- **oh-my-openagent / oh-my-claudecode** — keyword-activated orchestration
  ("ultrawork"), idle-pullback "your work will definitely finish", curated
  agent/skill bundles. → **the relentless-completion need is already served
  by auto-drain + partial continuation + adoption; bundles belong to H5;
  magic keywords rejected (I5) — Yardlet's planning gate IS the explicit
  version of that UX.**
- **Hermes** — skills as procedural memory, progressive loading (absorbed in
  H1), agent-created skills via `skill_manage` (auto-write by default) →
  **Yardlet also auto-writes, but the deterministic core is the writer (workers
  propose via the result contract, Yardlet records) and an eval loop self-
  corrects bad skills (I1, I4). See docs/skills.md.**

## A1 — Harness asset discovery (oh-my-pi's onboarding, Yardlet-shaped) · size M — implemented

**Goal**: a repo that already has agent assets gets them as a shared harness
the moment Yardlet runs — zero setup, all workers.

Discovery sources, in precedence order (later never overrides earlier):

1. `.agents/rules/*.md`, `.agents/skills/*/SKILL.md` — Yardlet-native (exists, H1)
2. `AGENTS.md`, `CLAUDE.md` (repo root) — treated as a rules source
3. `.claude/skills/*/SKILL.md` — same format as ours (agentskills.io)
4. `.cursor/rules/*.{md,mdc}` — rules source
5. `.github/copilot-instructions.md` — rules source

**Worker-aware projection** (the part oh-my-pi doesn't need but we do):
a worker that natively consumes a source must not get it twice — token
discipline. Projection matrix in code, adapter-owned:

| source | claude-code | codex | custom |
|---|---|---|---|
| CLAUDE.md | skip (native) | inject | inject |
| AGENTS.md | inject | skip (native) | inject |
| .claude/skills | skip (native) | catalog | catalog |
| .cursor/rules, copilot-instructions | inject | inject | inject |

Mechanics: read-only at packet compile (I3 — nothing copied into `.agents/`);
discovered rules share the existing 4 KB inline cap (overflow → anchors);
discovered skills join the catalog with an origin suffix (e.g.
`pr-review — … (.claude)`); `task.skills` may name them. Parallel worktrees:
these sources are tracked files, so they exist in the worktree checkout —
no copying needed (verify in tests). Opt-out: `harness_discovery: false` in
yardlet.yaml for repos where the borrowed assets are noise.

Tests: per-source discovery; precedence/dedup (same skill name in `.agents`
and `.claude` → ours wins); projection matrix per worker; cap interaction.

## A2 — Ambiguity gate (internal-system's "don't build while guessing") · size S — implemented

The planning schema already returns `ambiguity.score` (low|medium|high) and
`questions_for_user` — today they are always non-blocking. Change:

- Persist `ambiguity` + open questions into the intent contract.
- `score: high` ⇒ the intent starts **gated**: `run --auto`/`r`/`A` refuse
  with "the plan is still guessing — answer its questions first"; the TUI
  pending slot shows the questions; `a` answers (existing flow) and the
  answer triggers a re-plan (amend) that re-scores ambiguity.
- Explicit override (I5 — the human can always decide): `yardlet run --auto
  --accept-ambiguity`, or `ambiguity_gate: off` in yardlet.yaml.
  medium/low: unchanged (non-blocking, assumptions recorded).
- **Interview loop** (owner request): when the request is thin (high
  ambiguity, or a very short raw request), planning becomes a bounded Q&A
  conversation instead of a one-shot guess — the TUI surfaces the planner's
  questions, each answer triggers an amend-style re-plan that re-scores
  ambiguity, and the loop continues until the score drops below high, the
  user says "proceed as is", or a hard cap of **10 turns**. Each turn is a
  planning-worker invocation, so re-plans ride the cheaper amend path with
  the prior plan as context, and the loop only engages when the gate
  triggers (not on every plan).

No new scoring math (internal-system's weighted-clarity formula stays theirs); we
gate on the planner's own self-report, which we already collect. Mechanism =
deterministic gate; policy = the user's answer. (I4, I5)

## A3 — Semantic verification rung (internal-system's ladder, bounded) · size S — implemented

Yardlet's evaluator is the Mechanical rung (schema, ids, drift, forbidden
paths). Add the Semantic rung as a *task*, not a smarter evaluator (I1):

- Deterministic rule at queue derivation: if any task has `risk: high` (or
  the intent has 3+ tasks) and the plan contains no `review`-kind task,
  Yardlet appends one final `Acceptance review` task (reviewer role,
  `depends_on` = all prior tasks) that verifies the intent's acceptance
  criteria against the actual workspace and reports per-criterion pass/fail.
- The planner prompt also asks for it, but the deterministic append is the
  guarantee — planner forgetfulness can't skip verification.

Consensus rung (multi-worker vote): deferred — it doubles spend; revisit
when routing telemetry can justify it per task kind.

## A4 — Workers from the ecosystem (docs only) · size XS — implemented

README "Adding a worker" gains real examples: oh-my-pi (`omp`) and other
agent CLIs as generic-adapter profiles — the ecosystem's *workers* are
Yardlet's supply side, not competition. No code.

## Sequence & where this meets the harness plan

```
A1 discovery ──► A2 ambiguity gate ──► A3 semantic rung ──► (A4 docs, anytime)
        └─► then back to harness.md: H3 hooks ──► H4 learning loop
```

A1 first: it multiplies the value of every later phase (H4's promoted
lessons, A3's review tasks all ride the same discovery-fed packet). A2/A3
are small and independent. H3/H4 resume after, unchanged.

## Explicitly rejected (and why)

- **Magic keywords / hidden modes** — I5. The planning gate is Yardlet's
  explicit answer to the same need.
- **Worker-grade tool surface** (LSP, debugger, kernels, browser) — I1.
  Owning them would pull the deterministic core into the judgment loop;
  Yardlet benefits by *registering* the winners as workers instead.
- **Worker self-writing canonical state directly** — I3. Workers propose
  (result contract); the deterministic core writes. Auto-application is fine;
  bypassing the single writer is not.
- **Unbounded self-rewrite of specs/intent** (internal-system generational
  rewrite) — the intent contract is the user's; skills/rules self-improve,
  the contract does not rewrite itself.
- **Consensus voting** — cost without telemetry-backed justification yet.
- **Curated mega-bundles** (19 agents / 39 skills) — H5 central-core
  territory; premature before the in-repo loop proves itself.
