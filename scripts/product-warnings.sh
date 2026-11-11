#!/bin/zsh
# Fails when a build log holds a compiler warning for a file under Sources/: the product targets build
# without warnings, and CI keeps it so (.github/workflows/ci.yml). The tests' warnings and the warnings
# of packages Yardlet depends on are not counted. The compiler prints a file's warnings only when it
# compiles the file, so check the log of a build from a clean checkout, or of the files just changed:
#
#   swift build --build-system native 2>&1 | tee build.log; scripts/product-warnings.sh build.log
set -euo pipefail
(( $# == 1 )) || { print -u2 "usage: product-warnings.sh <build log>"; exit 2 }
# One line for each warning: the compiler can print one both as it emits a module and as it compiles the file.
warnings=$(perl -ne 's/\e\[[0-9;]*m//g; print if m{^/(?!.*/\.build/).*/Sources/[^:]+:\d+:\d+: warning:}' "$1" | sort -u)
[[ -n $warnings ]] || { print "No warnings in the product targets."; exit 0 }
lines=("${(@f)warnings}")
print -u2 "${#lines} compiler warning(s) in the product targets, which build with none:"
print -u2 -r -- "$warnings"
exit 1
