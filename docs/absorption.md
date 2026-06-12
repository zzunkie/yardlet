# Absorption Plan — taking what's good without becoming what they are

> Status: plan (A1–A4 not yet implemented). Companion: [harness.md](harness.md)
> (H3 hooks / H4 learning loop continue after this plan's A-phases).
>
> Sources studied: oh-my-pi (can1357), oh-my-openagent / oh-my-claudecode
> (code-yeongyu, Yeachan-Heo), internal-system (Q00), Hermes (NousResearch),
> internal-tool (internal predecessor).

## Identity invariants (what absorption may NOT bend)

| # | invariant | the line it draws |
|---|---|---|
| I1 | **Yard is the operating console, never the worker.** | Tool surfaces (LSP, debuggers, kernels, browser control) belong to workers. Yard absorbs *operating* patterns only. If a feature makes Yard smarter at *doing* the work rather than *running* it, it is out. |
| I2 | **The packet is the only shared injection point.** | Anything absorbed must reach codex, claude, and custom workers identically — never via one CLI's plugin system. |
| I3 | **`.agents/` is canonical; sessions are disposable.** | Discovered/borrowed assets are read at compile time, not copied into state. Yard remains the sole writer of its files. |
| I4 | **Policy vs mechanism.** | Mechanisms detect and suggest; humans promote. Nothing self-patches the harness, routing, or specs. |
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
  magic keywords rejected (I5) — Yard's planning gate IS the explicit
  version of that UX.**
- **Hermes** — skills as procedural memory, progressive loading (absorbed in
  H1), agent-created skills via `skill_manage` → **H4 keeps the human gate
  (I4) instead of self-write.**

## A1 — Harness asset discovery (oh-my-pi's onboarding, Yard-shaped) · size M

**Goal**: a repo that already has agent assets gets them as a shared harness
the moment Yard runs — zero setup, all workers.

Discovery sources, in precedence order (later never overrides earlier):

1. `.agents/rules/*.md`, `.agents/skills/*/SKILL.md` — Yard-native (exists, H1)
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
yard.yaml for repos where the borrowed assets are noise.

Tests: per-source discovery; precedence/dedup (same skill name in `.agents`
and `.claude` → ours wins); projection matrix per worker; cap interaction.

## A2 — Ambiguity gate (internal-system's "don't build while guessing") · size S

The planning schema already returns `ambiguity.score` (low|medium|high) and
`questions_for_user` — today they are always non-blocking. Change:

- Persist `ambiguity` + open questions into the intent contract.
- `score: high` ⇒ the intent starts **gated**: `run --auto`/`r`/`A` refuse
  with "the plan is still guessing — answer its questions first"; the TUI
  pending slot shows the questions; `a` answers (existing flow) and the
  answer triggers a re-plan (amend) that re-scores ambiguity.
- Explicit override (I5 — the human can always decide): `yard run --auto
  --accept-ambiguity`, or `ambiguity_gate: off` in yard.yaml.
  medium/low: unchanged (non-blocking, assumptions recorded).

No new scoring math (internal-system's weighted-clarity formula stays theirs); we
gate on the planner's own self-report, which we already collect. Mechanism =
deterministic gate; policy = the user's answer. (I4, I5)

## A3 — Semantic verification rung (internal-system's ladder, bounded) · size S

Yard's evaluator is the Mechanical rung (schema, ids, drift, forbidden
paths). Add the Semantic rung as a *task*, not a smarter evaluator (I1):

- Deterministic rule at queue derivation: if any task has `risk: high` (or
  the intent has 3+ tasks) and the plan contains no `review`-kind task,
  Yard appends one final `Acceptance review` task (reviewer role,
  `depends_on` = all prior tasks) that verifies the intent's acceptance
  criteria against the actual workspace and reports per-criterion pass/fail.
- The planner prompt also asks for it, but the deterministic append is the
  guarantee — planner forgetfulness can't skip verification.

Consensus rung (multi-worker vote): deferred — it doubles spend; revisit
when routing telemetry can justify it per task kind.

## A4 — Workers from the ecosystem (docs only) · size XS

README "Adding a worker" gains real examples: oh-my-pi (`omp`) and other
agent CLIs as generic-adapter profiles — the ecosystem's *workers* are
Yard's supply side, not competition. No code.

## Sequence & where this meets the harness plan

```
A1 discovery ──► A2 ambiguity gate ──► A3 semantic rung ──► (A4 docs, anytime)
        └─► then back to harness.md: H3 hooks ──► H4 learning loop
```

A1 first: it multiplies the value of every later phase (H4's promoted
lessons, A3's review tasks all ride the same discovery-fed packet). A2/A3
are small and independent. H3/H4 resume after, unchanged.

## Explicitly rejected (and why)

- **Magic keywords / hidden modes** — I5. The planning gate is Yard's
  explicit answer to the same need.
- **Worker-grade tool surface** (LSP, debugger, kernels, browser) — I1.
  That race is for workers; Yard benefits by *registering* the winners.
- **Self-patching harness/specs** (Hermes skill_manage auto-write,
  internal-system generational self-rewrite) — I4. H4 keeps the human gate.
- **Consensus voting** — cost without telemetry-backed justification yet.
- **Curated mega-bundles** (19 agents / 39 skills) — H5 central-core
  territory; premature before the in-repo loop proves itself.
