---
name: finishing-a-development-branch
description: Use when implementation and tests are complete and a human must choose how local branch work should be integrated or preserved
---

# Finishing a Development Branch

## Principle

Verify first, preserve workspace ownership, then ask for the integration
decision. Branch completion never grants remote mutation authority.

## 1. Verify

Run the repository's full required test command and inspect the exit status. If
it fails, report the failures and stop the finishing flow.

## 2. Inspect Local State

Read-only checks should establish:

- current branch or detached state;
- base branch evidence;
- changed, staged, and untracked files;
- whether this checkout is a worktree and who appears to own it;
- local commits not contained in the base branch.

Do not clean, reset, delete, merge, or switch branches during inspection.

## 3. Use NeedsUser for the Decision

Present the verified state and ask the human to choose one bounded outcome:

1. integrate locally;
2. request separately approved remote publication;
3. preserve the branch and worktree as-is;
4. discard work after explicit destructive confirmation.

Record this as a NeedsUser decision when the flow is running inside Yardlet.
Do not reinterpret silence or a branch classification as approval.

## 4. Execute Only the Chosen, Authorized Path

Local integration still requires a clean ownership check and verification on
the integrated result. Any remote write or pull-request creation stays behind
the existing explicit approval gate. Destructive cleanup requires an exact,
informed confirmation describing the branch, commits, and worktree affected.

Never remove harness-owned worktrees. Never remove a worktree before successful
integration is verified. Preserve unrelated staged or untracked files.

## Completion Evidence

Report the chosen outcome, commands actually run, fresh validation result, and
the final local branch/worktree state. If authorization was not provided, stop
at NeedsUser without performing the gated action.
