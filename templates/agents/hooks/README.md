# Workspace hooks (Yard H3)

Deterministic guards that bind **every** worker (Codex, Claude Code, any CLI),
not just one tool. They are your own code — Yard runs whatever executables you
drop here and ships none enabled by default.

## Layout

- `pre-run.d/*` — run **before** a worker spawns. A non-zero exit **blocks the
  run** (the task fails with the hook's message; fix the cause and re-run).
  Use for: secret scans, lint/format gates, "don't run while CI is red".
- `post-run.d/*` — run **during evaluation**, after the worker produced its
  result. A non-zero exit is a **fatal check** — the task cannot be marked Done
  past it. Use for: scanning the produced diff, policy checks on the output.

## Contract

- Only **executable** files run (`chmod +x`), in **sorted filename order**
  (e.g. `10-secrets.sh`, `20-lint.sh`). Non-executable files (like this README)
  are ignored — keep disabled examples non-executable.
- Each hook runs in the **workspace root** with these environment variables:
  - `YARD_TASK_ID` — the task being run
  - `YARD_RUN_DIR` — that run's directory (read artifacts, write evidence)
  - `YARD_WORKER` — the worker id (e.g. `codex`, `claude-code`)
- A hook has **30 seconds** wall-clock; longer is killed and counts as a
  failure. Its stdout/stderr are captured to `<run_dir>/hooks/<phase>/<name>`.
- Print the reason to **stderr** and `exit` non-zero to block; the last stderr
  line shows up in the run report.

Turn all hooks off with `hooks: false` in `.agents/yard.yaml`.

## Example (disabled — copy, edit, then `chmod +x`)

`pre-run.d/10-no-secrets.sh.example`:

```sh
#!/bin/sh
# Block the run if obvious secrets are staged in the workspace.
if git -C "$PWD" grep -nE 'AKIA[0-9A-Z]{16}|-----BEGIN.*PRIVATE KEY-----' -- . >&2; then
  echo "pre-run: possible secret in the tree (task $YARD_TASK_ID)" >&2
  exit 1
fi
exit 0
```
