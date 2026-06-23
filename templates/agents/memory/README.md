# Project memory (Yardlet)

Durable facts and decisions about *this* workspace — the things a new worker
would otherwise have to rediscover every run. Yardlet discovers every Markdown
doc here and injects it as a short **index** into every worker packet (and the
planner), with the body read on demand. So the always-loaded cost stays tiny
while the knowledge is one anchor away.

These docs are **yours** and meant to be **git-tracked** (shared with the team,
present in every worktree). Yardlet only reads them — it never edits them.

## Layout

- `*.md` — one durable fact or decision per file. The filename is the slug.
- Optional YAML frontmatter sets the index line explicitly:

  ```markdown
  ---
  name: Renderer is Forward+
  description: The game is locked to Godot Forward+; no renderer swap without a decision.
  ---

  # Renderer

  Longer reasoning here. This body is NOT loaded into every packet — a worker
  reads this file only when the task touches rendering.
  ```

- No frontmatter? The index line falls back to the first `# heading` (title)
  and the first prose line (summary).
- Optional `look_at:` lists the code paths a fact depends on. `yardlet memory`
  flags the doc **possibly stale** when a listed path changed in git *after* the
  doc did — your cue to re-check or rewrite it:

  ```yaml
  look_at:
    - src/render/forward_plus.gd
    - project.godot
  ```

## What belongs here

- Architectural invariants ("scores live in the three scenario files; the rest
  is narrative wrapper"), locked decisions, hard-won gotchas, conventions a
  reviewer keeps repeating.

## What does NOT belong here

- Anything the repo already records (code structure, CLAUDE.md / AGENTS.md
  rules, git history). Memory is for what is **not** derivable from the tree.
- Transient run state — that is Yardlet's job (`runs/`, `checkpoints/`).

## Discipline

- One fact per file; keep each index line short (it rides in every packet).
- Delete a doc when it stops being true.
- `yardlet memory` lists the discovered index. The generated `index.yaml`
  (if any) is a cache — keep it out of git.
