# Skill Lifecycle — research, create, equip, manage

> Status: S1–S4 implemented; explicit `yardlet skill research`/`create`/`apply`
> (S2/S3 on-demand authoring) implemented. Companion: [harness.md](harness.md)
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
| `.agents/` canonical; sessions disposable (I3) | Equip writes real files Yardlet owns. A central library is read-only discovery; created skills are written through `state.rs`. |
| Minimize intervention; safety from determinism+eval+reversibility (I4) | Classify/equip/research/create/score/prune all run **automatically**. Safety: Yardlet (not the worker) writes every skill, the eval score self-corrects bad ones, git/`.agents` make it reversible. No human gate on skills — opt-outs (`auto_skill: false`) exist for the cautious. |
| Explicit over magic (I5) | `yardlet skill ...` are visible commands; the planner *suggests* `task.skills`, it doesn't silently inject hidden modes. |
| Bring-your-own / reduce setup (I6) | Auto-classification means a fresh repo is equipped in one keystroke, not a manual hunt. |

## Who generates vs who records (Yardlet has no LLM)

Yardlet's core has no model. "Yardlet writes the skill" never means Yardlet *authors*
prose — it means:

- **A worker generates the content.** A skill's text (frontmatter +
  procedure) is produced by a worker run, exactly like any other deliverable:
  a packet goes in (researcher role: "write a SKILL.md for X"), the worker
  writes the file into its run dir.
- **Yardlet records it deterministically.** Yardlet reads that run output,
  validates the frontmatter, places it at `.agents/skills/<name>/` (the
  canonical location), updates the catalog, dedups, and commits. No model,
  no judgment — file plumbing.

So "the deterministic core is the sole writer" means: the worker can't drop
files into canonical state itself; it proposes via its run output, and Yardlet's
single writer (`state.rs`) is the only hand that places them. Equip (S1) needs
no LLM at all — it's pure file work. Only research/create (S2/S3) run a worker,
and only to get *content*; placement and scoring stay deterministic.

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
same files work as Yardlet skills, `.claude/skills`, or library entries.

## S1 — Classify & equip (the toolbox) · size M

Deterministic. Turns "what is this repo" into "these skills".

- **Repo classification** from the existing `inspect::RepoSummary` (top-level
  files, package managers): `project.godot` → `game`; `package.json` +
  react/next → `web-ui`; `Cargo.toml` → `rust`/`cli-tool`; `pyproject.toml` +
  ml deps → `ai-ml`; etc. A small, auditable signal→preset table; multiple
  presets may match. `core` always applies.
- **`yardlet skill list`** — equipped skills, plus library skills available to
  equip (greyed), plus the detected preset(s).
- **Auto-equip (default):** on first plan (and `new`/`goal`), Yardlet equips
  the core + detected presets automatically and reports what it did. No
  prompt — the human steps back (I4). `auto_equip: false` switches to a
  suggestion nudge (*"game repo detected — equip 4 skills? (e)"*) for the
  cautious. `yardlet skill suggest` always shows detected − equipped on demand.
- **`yardlet skill equip <preset|name>...`** — link/copy the named skills (or a
  whole preset) from the library into `.agents/skills/`. `unequip` removes.
- **Config:** `skill_library: <path>` (empty = none; just the in-repo and A1
  sources). Library is read-only.

Tests: classification table per fixture; preset expansion; equip idempotence;
suggest = detected − equipped.

## S2 — Research (find what's needed) · size M — implemented

Identify and source skills the repo wants but doesn't have.

- **Gap detection (mechanism):** a detected preset names a skill absent from
  both the library and `.agents/skills` → a gap candidate. Repeated
  validation failures / NeedsUser themes (from telemetry) → capability-gap
  candidates ("3 runs stalled on browser screenshots → maybe a
  browser-evidence skill").
- **`yardlet skill research "<topic>"`** *(implemented)* — a researcher-role
  worker task (so the generative work is behind the contract, I1): it studies
  the topic (repo conventions; the web when access is `full`) and writes a
  *candidate* SKILL.md draft to a run dir, plus a short rationale. **Nothing
  is installed yet** — the draft lands at `.agents/runs/<id>/SKILL.md`.
- **`yardlet skill apply <run-id>`** *(implemented)* installs that draft: Yardlet
  reads the run's `skill-result.json` and writes the canonical skill (the
  worker proposed, the deterministic core writes — I1/I3). The eval score
  later judges whether it earned its place (I4).
- The run is **queue-isolated**: like the planner it spawns one worker, but it
  derives no `intent-contract.yaml` / `work-queue.yaml`, so researching a skill
  never disturbs the live intent (`src/skill_author.rs`).

## S3 — Create (author the skill) · size M — auto-record implemented

- **From a run (auto, implemented):** a run's `harness_suggestions` of kind
  "skill" are recorded automatically as `.agents/skills/<slug>/SKILL.md`
  (`source: learned`) when `auto_skill` is on — the worker authored the
  content during its task, Yardlet slugifies + writes it, no clobber of an
  existing skill. The eval score (S4) later prunes weak ones.
- **`yardlet skill create <name> [--from "<topic>"]` (explicit, implemented):**
  authors a *new* skill on demand and installs it. It runs a queue-isolated
  worker (`src/skill_author.rs`) that writes the SKILL.md content to a run
  dir; Yardlet installs it tagged `source: created` — user-chosen, so unlike a
  `learned` skill it is never auto-pruned (kept like a library equip until
  `unequip`). The auto path above is the cycle-strengthening loop; explicit
  create/research is a convenience on top.
- **From a run (auto by default):** the result contract has
  `harness_suggestions` (H4). A worker that discovers a reusable procedure
  proposes it; **Yardlet records it automatically** as a skill (the worker
  proposes, the deterministic core writes — I1/I3). The eval score then
  decides whether it survives. `auto_skill: false` routes proposals to
  `yardlet skill review` for manual promotion instead.
  - *Versus Hermes:* both auto-write by default. The difference is the
    writer and the safety model: Hermes lets the agent write its own files;
    Yardlet's core is the sole writer and an eval loop prunes what doesn't work,
    so autonomy doesn't require trusting each write.

## S4 — Manage over time (the lifecycle) · size L — implemented

Lifecycle (spec §13.2): observe → candidate → review → promote → deprecate.
The hard part is not collecting usage — it is **judging whether a skill
actually helped**. Usage counts are a weak signal (declared-often ≠ good); a
bad skill that gets injected a lot is worse, not better. So S4's core is a
skill *eval*, and that eval must obey the same rule as everything else:
**the verifier is never the doer** — a skill's worth is not the self-report
of the worker that used it.

- **Observe (mechanism, every run):** to `telemetry/skills.jsonl`, per task,
  record the declared `task.skills` alongside signals Yardlet already produces
  deterministically — `eval_state` (Done/Partial/Failed), retry count,
  wall_seconds, and whether a downstream **review task** (A3 / `yardlet goal
  --verify`) that depended on this task passed. No tokens, no behavior change.
- **Skill score (deterministic, auditable):** per skill, aggregate across the
  runs that declared it: pass-through rate of dependent review tasks,
  first-try Done rate, retry tax. A skill that rides many runs but whose
  work keeps failing review scores *down*, not up. The score is evidence for
  a human, never an automatic promote/prune (I4) — same posture as
  routing telemetry.
- **`yardlet skill review`** — one screen driven by that score: candidates
  (gaps, run-proposed, research drafts) and equipped skills that score
  poorly. **Auto-prune (default):** a skill whose score stays below a floor
  across N intents is automatically deprecated (unequipped, kept in git);
  `yardlet skill review` is for *seeing* and overriding, not for routine
  approval. `auto_prune: false` makes pruning a review action instead.
- **Manual override (always available):** `yardlet skill equip/unequip` and
  `yardlet skill deprecate <name>` let a human step in; for a library skill,
  deprecate marks it, never deletes someone else's file.
- **Versioning:** a created/edited skill bumps a `version:` in frontmatter and
  keeps prior text in git — skills improve in place, auditably; the score
  resets on a version bump so an edit is re-judged, not coasting on old
  evidence.

### Why this also sharpens Yardlet's core eval

This phase exposes that today's evaluator only checks floor conditions
(schema, ids, forbidden paths) and trusts the worker's `status` for "good".
The skill score leans on the **review-task verdict** as the real quality
signal — which means S4 only works well if review tasks produce a structured,
machine-readable pass/fail per acceptance criterion (not just prose). That
is a concrete upgrade to the reviewer-role output contract (A3): each review
task should emit `verdict: { criterion_id, pass, evidence }[]` that the
evaluator records. The same verdict feeds: task done/partial decisions,
skill scores, and routing telemetry. One verifier, many consumers.

## Sequence

```
S1 classify+equip ──► S2 research ──► S3 create ──► S4 manage (=H4)
   (toolbox)            (find gaps)     (author)       (lifecycle loop)
                                                        └─ needs: structured
                                                           review verdicts
```

A prerequisite for S4's eval (callable independently, useful on its own):
**structured review verdicts** — *implemented*. Reviewer/safety tasks now
write `verdict: [{criterion_id, pass, evidence}]` into result.json; the
evaluator requires it for those tasks (empty verdict or a done-claim with a
failed criterion blocks Done), and reviewers are told to set `status:
needs_user` when a criterion fails (so a real defect routes to the user, not
a review retry loop). Per-run verdict pass/total and declared skills are
recorded in telemetry — the data S4's skill score reads. The single quality
signal now feeds task state, telemetry, and (next) skill scores.

S1 first — it makes every later phase land somewhere (research/created skills
get equipped; S4 observes equipped usage). S2 and S3 share the worker-task
machinery (`plan_goal`-style: a bounded task whose output is a SKILL.md). S4
is H4 from the harness plan, now concretely about skills.

## CLI surface (target)

```
yardlet skill list                      equipped + available + detected presets
yardlet skill suggest                   propose skills for this repo
yardlet skill equip <preset|name>...    install from the library
yardlet skill unequip <name>...
yardlet skill research "<topic>"        worker drafts a candidate SKILL.md
yardlet skill create <name> [--library] worker authors and installs a skill
yardlet skill review                    candidates to promote / stale to prune
yardlet skill apply <n> | deprecate <name>
```

## Explicitly out of scope (for now)

- Workers writing skill files directly — they propose, the deterministic
  core writes (I3). Auto-application is fine; bypassing the single writer is not.
- Pulling skills from arbitrary remote registries (the library is local; web
  research informs a draft Yardlet writes locally, not a silent remote install).
- Self-rewriting the intent contract — skills/rules self-improve, the user's
  contract does not.
