# Security Policy

## Supported versions

Security fixes target the latest released version of Yardlet and the current
`main` branch. Older releases may be affected and are supported on a best-effort
basis. Reports should identify the exact Yardlet version or commit.

## Report a vulnerability privately

Do not open a public issue or pull request for a suspected vulnerability.

Use GitHub's private vulnerability reporting:

<https://github.com/zzunkie/yardlet/security/advisories/new>

If that form is unavailable, use the contact method listed on the
[@zzunkie GitHub profile](https://github.com/zzunkie) with the subject
`[yardlet security]` and no secrets in the subject line.

Include as much of the following as possible:

- affected version or commit;
- operating system and installation method;
- security impact and the boundary that is crossed;
- minimal reproduction steps or proof of concept;
- whether the issue is already public or being actively exploited;
- relevant logs with tokens, credentials, personal paths, and customer data
  removed;
- a suggested mitigation, if known.

The maintainer aims to acknowledge a report within three business days and
provide an initial assessment within seven business days. These are response
targets, not disclosure deadlines.

## What Yardlet treats as security-sensitive

Yardlet launches installed AI worker CLIs and writes canonical workspace state.
Reports are especially useful when they involve:

- command or argument injection into a worker process;
- sandbox, allowed-scope, approval, or forbidden-path bypass;
- secret, credential, billing-variable, or private-data exposure;
- unauthorized changes to canonical `.agents/` state;
- unsafe cross-worktree or cross-run changes;
- untrusted artifact or dependency execution;
- a denial of service with a practical security impact.

An ordinary functional bug without a security-boundary impact can use the
public bug form. A vulnerability in a third-party worker CLI should also be
reported to that provider; report it to Yardlet when Yardlet causes or worsens
the exposure.

## Coordinated disclosure

Please allow time to reproduce, fix, and release a correction before public
disclosure. The maintainer will keep the reporter informed through the private
advisory, coordinate a disclosure date when practical, and credit the reporter
unless anonymity is requested.
