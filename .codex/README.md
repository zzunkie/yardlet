# Codex adapter

This directory adapts the shared harness for the Codex CLI.

- `rules/`, `skills/`, `agents/` are symlinks into `.agents/` — the source of truth.
- Edit shared assets under `.agents/`, never here.
- Per-machine settings belong in `settings.local.json` (gitignored).

See the root `AGENTS.md` for authoritative guidance.
