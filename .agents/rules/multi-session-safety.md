# Multi-Session Safety

Before any commit:
- Run `git status`.
- Check for staged files you did not stage.
- Stage only the files you changed.
- Prefer `git worktree` for parallel work.

Never:
- Commit files staged by another session.
- Use `git add .` or `git add -A` blindly.
- Reset or force push without explicit approval.
