# Worktree Tooling

When using browser automation, screenshots, traces, or generated artifacts from a git worktree:

- Change to the worktree directory first.
- Assume outputs are written relative to the current working directory.
- Re-check the working directory before running Playwright, browser, or capture commands.
