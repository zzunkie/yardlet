# Maintainer Playbook

This is the repository-side baseline for access, review, automation, and
release administration. GitHub settings live outside Git, so re-check them
against this document after access changes and before a release-policy change.

## Access model

- **Anonymous visitor:** read, clone, and inspect the public repository.
- **External contributor:** fork, open issues and pull requests, and run
  approved fork CI; no upstream push.
- **Triage collaborator:** classify and close issues without code or settings
  access.
- **Maintainer:** administer settings, review and merge PRs, triage security
  reports, and publish releases.
- **CI `GITHUB_TOKEN`:** read repository contents; cannot approve or create
  pull requests.
- **Release `GITHUB_TOKEN`:** `contents: write` only inside the version-tag
  release workflow.
- **Dependabot:** open dependency pull requests; no repository secret is
  configured.

Use least privilege. Do not grant write access merely to let someone review or
triage. Record why access was granted and remove it when the role ends.

## Default branch baseline

`main` must:

- require a pull request, including for administrators;
- require the formatting/Clippy, Rust 1.82 MSRV, Ubuntu, and macOS checks;
- require the branch to be current with `main`;
- require review conversations to be resolved;
- reject force pushes and deletion;
- have no user, team, or app bypass that silently restores direct push.

The project currently has one maintainer, so the required approving-review count
is zero. The maintainer's merge is the acceptance decision. Raise the count to
one when a second maintainer can independently approve changes.

Yardlet's current `git_finish` mechanism assumes a direct push. Until it supports
a protected-branch PR delivery mode, maintainer and Yardlet-authored changes
must push a feature branch and open a normal pull request. Do not weaken `main`
protection to accommodate the old delivery assumption.

## Tags and releases

Release tags match `v*`. Repository rules must block deletion and non-fast-
forward updates to those tags. A correction receives a new version and tag.

The release workflow is the only workflow with write permission. It runs from a
version-tag event, creates or reuses the matching GitHub Release, builds the
supported binaries, and uploads them. Crates.io publication remains a
maintainer action.

Before publishing, verify the tag points to the intended protected-main commit
and that the release version, `Cargo.lock`, `CHANGELOG.md`, GitHub assets, and
crate version agree.

## Actions baseline

- Default workflow token permission: `contents: read`.
- Workflows cannot create or approve pull requests.
- First-time external contributors require workflow approval.
- Only GitHub-owned actions plus explicitly selected third-party actions run.
- Every action reference uses a full 40-character commit SHA.
- Dependabot tracks both Cargo and GitHub Actions references.
- Secrets are not available to workflows triggered from public forks.

Pinning protects against a moved tag. The human-readable version comment next to
each SHA and Dependabot preserve update visibility.

## Security baseline

Keep these repository features enabled:

- dependency graph, vulnerability alerts, and Dependabot security updates;
- automated security fixes;
- secret scanning and push protection;
- private vulnerability reporting;
- CodeQL default setup for supported repository languages.

New vulnerabilities follow `SECURITY.md`. Do not copy a private report into a
public issue before coordinated disclosure.

## Recurring audit

Review the following at least before granting access, after installing an app,
and before changing release automation:

1. collaborators and pending invitations;
2. teams, GitHub Apps, deploy keys, webhooks, and environments;
3. branch protection, rulesets, and bypass actors;
4. Actions allow-list, SHA-pinning, workflow token, and fork approval policy;
5. Actions, Dependabot, and environment secret names;
6. private vulnerability reporting, secret scanning, Dependabot, and CodeQL;
7. stale remote branches and unexpected open pull requests.
8. new and unresolved code-scanning alerts; a successful CodeQL workflow means
   the analysis completed, not that the result is alert-free.

Useful read-only checks:

```bash
gh api repos/zzunkie/yardlet/collaborators
gh api repos/zzunkie/yardlet/branches/main/protection
gh api repos/zzunkie/yardlet/rulesets
gh api repos/zzunkie/yardlet/actions/permissions
gh api repos/zzunkie/yardlet/actions/permissions/workflow
gh api repos/zzunkie/yardlet/actions/permissions/fork-pr-contributor-approval
gh api repos/zzunkie/yardlet/keys
gh api repos/zzunkie/yardlet/hooks
gh api repos/zzunkie/yardlet/environments
```

Never print secret values. Repository APIs expose secret names and timestamps,
not values; treat even names as operational metadata.
