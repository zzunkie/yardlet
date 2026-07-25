# Yardlet Governance

Yardlet is currently a maintainer-led open source project. This document says
who makes decisions, which files are authoritative, and how contributions move
from proposal to release.

## Stewardship

The repository owner, [@zzunkie](https://github.com/zzunkie), is the current
maintainer and final steward for:

- product direction and public contracts;
- repository access and contributor roles;
- security triage and coordinated disclosure;
- pull request acceptance and releases to GitHub and crates.io.

Maintainer authority does not make every maintainer-authored change correct.
The same protected branch, CI checks, review conversation, and documented
invariants apply to maintainer changes.

The operational access baseline and recurring audit are documented in
[docs/maintainer-playbook.md](docs/maintainer-playbook.md).

## Contribution lanes

Yardlet uses two contribution lanes:

1. **Direct pull request:** clear bug fixes, documentation, tests, typos, and
   small internal cleanups with no new public behavior.
2. **Issue before implementation:** new features, new CLI or configuration
   behavior, architecture, file-format or schema changes, worker-contract
   changes, and changes to security or approval boundaries.

The maintainer confirms issue-first scope before implementation. Agreement is
specific to that scope; adjacent work returns to the issue process.

Security reports use the private process in [SECURITY.md](SECURITY.md), never a
public issue.

## Sources of truth

- Product identity and non-negotiable principles: `docs/identity.md` and
  `AGENTS.md`.
- Product behavior: typed code in `src/` plus executable tests.
- Public usage: `README.md`; `README.ko.md` mirrors its user-facing meaning.
- Contributor process: `CONTRIBUTING.md`, this file, and `.github/` templates.
- Release history: `CHANGELOG.md`, package version, signed-off release commit,
  version tag, GitHub Release, and crates.io.
- Reusable agent harness: `.agents/rules/`, `.agents/skills/`, and
  `.agents/agents/`.
- Generated workspace state: Yardlet's typed state mechanism, never a
  hand-edited `.agents/` instance.

Compatibility mirrors such as `CLAUDE.md` and `.claude/` are not independent
sources of truth. Update their canonical `.agents/` or `AGENTS.md` target.

## Decisions and reviews

Decisions favor, in order:

1. user-owned state and deterministic, inspectable behavior;
2. security, billing, approval, and canonical-state boundaries;
3. compatibility with documented public contracts;
4. a small implementation that matches the existing code;
5. contributor effort and maintainability.

Substantial decisions should be recorded in the issue or pull request that
adopts them and reflected in the relevant source-of-truth document. Rejected or
deferred proposals should receive a short reason so future contributors do not
repeat the same investigation.

## Merge policy

`main` is protected. Changes reach it through pull requests that:

- are up to date with `main`;
- pass formatting, Clippy, Ubuntu, and macOS checks;
- resolve review conversations;
- stay within the accepted contribution scope.

The repository currently has one maintainer, so a numeric approval requirement
is not used; the maintainer's merge action is the acceptance decision. This can
change when a second maintainer can provide independent approval.

## Releases

Yardlet follows Semantic Versioning. Before 1.0, a minor release may include a
breaking public-contract change when it is explicitly documented.

A release updates the package version and lockfile, records user-visible
changes in `CHANGELOG.md`, creates a `v<version>` tag, publishes the GitHub
Release and its supported binaries, and publishes the crate. Only the
maintainer performs release publication.

Version tags are immutable release records. Corrections use a new version
rather than moving or recreating a published tag.

## Contributor roles

Anyone may report issues, propose changes, review public work, and submit pull
requests. Triage or write access may be offered after a sustained record of
constructive, technically sound contributions and responsible handling of
project boundaries. Access is least-privilege and may be removed when it is no
longer needed.

Changes to this governance model require an issue-first proposal and a pull
request.
