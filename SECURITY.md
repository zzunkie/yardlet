# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**
([direct link](https://github.com/zzunkie/yardlet/security/advisories/new)). Do not open a public issue or pull
request for them.

Include what is affected, how to reproduce it, and what an attacker could do with it. You should get a first reply
within a week. Yardlet is maintained by one person, so a fix may take longer; you will hear how it is going.

## What is in scope

- The Yardlet app for macOS, including its built-in MCP server, connectors, built-in browser and update path
  (Sparkle, `https://yardlet.app/appcast.xml` and, for Intel Macs, `https://yardlet.app/appcast-x86_64.xml`).
- The phone remote's relay at `relay.yardlet.app` (source in [`relay/`](relay/)).
- The release artifacts on [GitHub Releases](https://github.com/zzunkie/yardlet/releases) and the
  [Homebrew cask](https://github.com/zzunkie/homebrew-tap).

Problems in the agent CLIs themselves (Codex, Claude Code and the others) belong to their own projects. If Yardlet
makes such a problem worse, for example by passing something to an agent that it should not, that is in scope.

## Supported versions

Only the latest release receives fixes. Yardlet updates itself, so a fix reaches installed copies through the
normal update.
