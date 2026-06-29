---
name: mirror-readme-md-and-readme-ko-md-1-1
description: Mirror README.md and README.ko.md 1:1
source: learned
---
When editing the public README for a release, apply every structural change to BOTH README.md and README.ko.md: same sections in the same order, the same command-table rows in the same order, and the same .agents/ state tree. Korean prose translates the meaning; code, command names, flags, paths, and identifiers stay verbatim English. Before finishing, verify parity: `grep -n '^## '` on both files must list the same headings in the same order; the `yardlet`-command row count must match; and `grep -n '—'` must return nothing in either file (no em dashes, per the avoid-em-dashes rule). Trace every capability claim to CHANGELOG.md or .agents/memory/; do not invent features.
