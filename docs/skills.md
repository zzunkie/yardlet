# Skill Lifecycle — research, create, equip, manage

> Status: plan (S1–S4 not yet implemented). Companion: [harness.md](harness.md)
> (H1 already injects an installed skill catalog into every packet),
> [absorption.md](absorption.md) (A1 already discovers a repo's existing
> assets), [identity.md](identity.md).
>
> Source studied: internal-tool (`catalog/skills.tsv`, `presets/*.skills`,
> 90 skills), Hermes (skills as progressively-loaded procedural memory,
> agent-created via `skill_manage`).

## What exists vs what's missing

Already shipped:
- **Catalog injection (H1):** installed `.agents/skills/*/SKILL.md` ride in
  every packet as a progressively-loaded catalog; the planner can set
  `task.skills`.
- **Asset discovery (A1):** a repo's `.claude/skills`, `CLAUDE.md`, etc. fold
  in worker-aware.

Missing — this plan:
- A repo gets the *right* skills with **no manual linking** (today: hand-run
  symlinks).
- Skills can be **researched** (find/identify what's needed) and **created**
  (authored as SKILL.md) on demand.
- The set is **managed over time**: usage is observed, weak/unused skills
  surface for pruning, useful patterns get promoted — every cycle the
  harness gets sharper.

## Identity check (from identity.md / absorption.md)

| invariant | how this plan honors it |
|---|---|
| Deterministic core; generative behind the contract (I1) | Classification, equip, usage stats, dedup = deterministic Rust. **Researching and writing a skill's prose is a worker task** (researcher role), never the core. |
| Packet is the only shared injection point (I2) | Equipped skills live in `.agents/skills/` and reach every worker through the existing catalog. |
| `.agents/` canonical; sessions disposable (I3) | Equip writes real files Yard owns. A central library is read-only discovery; created skills are written through `state.rs`. |
| Policy vs mechanism (I4) | Detection, suggestion, usage telemetry, candidate collection = mechanism. **Equipping, promoting, and deprecating are human-gated** (a key, not an automatic write). |
| Explicit over magic (I5) | `yard skill ...` are visible commands; the planner *suggests* `task.skills`, it doesn't silently inject hidden modes. |
| Bring-your-own / reduce setup (I6) | Auto-classification means a fresh repo is equipped in one keystroke, not a manual hunt. |

## Asset model

```
~/.yard/skills/            optional central library (config: skill_library)
  <name>/SKILL.md          source skills, shared across repos
  catalog.tsv              name · tier · presets · description · triggers
  presets/<kind>.skills    preset -> skill-name list (game, web-ui, ...)

.agents/
  skills/<name>/           EQUIPPED skills (real dir or symlink into library)
  skills/<name>/SKILL.md   frontmatter: name, description [, source: learned]
  telemetry/skills.jsonl   per-run skill usage + candidate signals (mechanism)
```

A skill is portable Markdown (agentskills.io / Claude-Code compatible), so the
same files work as Yard skills, `.claude/skills`, or library entries.

## S1 — Classify & equip (the toolbox) · size M

Deterministic. Turns "what is this repo" into "these skills".

- **Repo classification** from the existing `inspect::RepoSummary` (top-level
  files, package managers): `project.godot` → `game`; `package.json` +
  react/next → `web-ui`; `Cargo.toml` → `rust`/`cli-tool`; `pyproject.toml` +
  ml deps → `ai-ml`; etc. A small, auditable signal→preset table; multiple
  presets may match. `core` always applies.
- **`yard skill list`** — equipped skills, plus library skills available to
  equip (greyed), plus the detected preset(s).
- **`yard skill suggest`** — detected presets → skills not yet equipped, as a
  proposal. Surfaced as a one-line nudge in `yard status` / the TUI, and at
  first plan: *"game repo detected — equip 4 skills? (e)"*. Mechanism
  proposes; the human equips (I4). Optional `auto_equip: true` opts into
  applying the core+detected set automatically on first plan.
- **`yard skill equip <preset|name>...`** — link/copy the named skills (or a
  whole preset) from the library into `.agents/skills/`. `unequip` removes.
- **Config:** `skill_library: <path>` (empty = none; just the in-repo and A1
  sources). Library is read-only.

Tests: classification table per fixture; preset expansion; equip idempotence;
suggest = detected − equipped.

## S2 — Research (find what's needed) · size M

Identify and source skills the repo wants but doesn't have.

- **Gap detection (mechanism):** a detected preset names a skill absent from
  both the library and `.agents/skills` → a gap candidate. Repeated
  validation failures / NeedsUser themes (from telemetry) → capability-gap
  candidates ("3 runs stalled on browser screenshots → maybe a
  browser-evidence skill").
- **`yard skill research "<topic>"`** — a researcher-role worker task (so the
  generative work is behind the contract, I1): it studies the topic (repo
  conventions + optionally the web) and writes a *candidate* SKILL.md draft
  to a run dir, plus a short rationale. Nothing is installed yet.
- Output is a reviewable draft, not an auto-equipped skill (I4).

## S3 — Create (author the skill) · size M

- **`yard skill create <name>`** (optionally from a research draft) — a worker
  authors a proper SKILL.md (frontmatter + procedure) which Yard writes,
  through `state.rs`, to `.agents/skills/<name>/` (in-repo) or, with
  `--library`, to the central library for reuse. Marked `source: learned`.
- **From a run (the Hermes move, human-gated):** the result contract already
  has `harness_suggestions` (designed in H4). A worker that discovers a
  reusable procedure proposes it; `yard skill review` lists such candidates;
  `apply` runs create. The worker proposes, the human promotes — never a
  silent self-write (contrast Hermes `skill_manage` auto-write).

## S4 — Manage over time (the lifecycle) · size L — this is H4

Lifecycle (spec §13.2): observe → candidate → review → promote → deprecate.

- **Observe (mechanism, every run):** record which equipped skills a task
  declared (`task.skills`) and whether the run succeeded, to
  `telemetry/skills.jsonl`. No tokens, no behavior change.
- **`yard skill review`** — one screen: candidates (gaps, run-proposed,
  research drafts) to promote; equipped skills that are stale (never
  declared in N intents) or correlated with failures, to prune. Same UX as
  `yard routing review`; a status nudge when items pend.
- **Promote / deprecate (human gate):** `yard skill apply <n>` /
  `yard skill deprecate <name>`. Promotion writes/equips; deprecation
  unequips (and, for a library skill, marks it deprecated, never deletes
  someone else's file).
- **Versioning:** a created/edited skill bumps a `version:` in frontmatter and
  keeps prior text in git — skills improve in place, auditably.

## Sequence

```
S1 classify+equip ──► S2 research ──► S3 create ──► S4 manage (=H4)
   (toolbox)            (find gaps)     (author)       (lifecycle loop)
```

S1 first — it makes every later phase land somewhere (research/created skills
get equipped; S4 observes equipped usage). S2 and S3 share the worker-task
machinery (`plan_goal`-style: a bounded task whose output is a SKILL.md). S4
is H4 from the harness plan, now concretely about skills.

## CLI surface (target)

```
yard skill list                      equipped + available + detected presets
yard skill suggest                   propose skills for this repo
yard skill equip <preset|name>...    install from the library
yard skill unequip <name>...
yard skill research "<topic>"        worker drafts a candidate SKILL.md
yard skill create <name> [--library] worker authors and installs a skill
yard skill review                    candidates to promote / stale to prune
yard skill apply <n> | deprecate <name>
```

## Explicitly out of scope (for now)

- Auto-equipping without a prompt by default (opt-in `auto_equip` only — I4).
- Pulling skills from arbitrary remote registries (library is local; web
  research informs a *draft* a human reviews, not a silent install).
- Auto-editing an existing skill from a run without review (I4).
