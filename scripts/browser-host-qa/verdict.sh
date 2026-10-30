#!/bin/zsh
# Prints the checks a browser QA fixture wrote to <output dir>/result.json and exits 1 unless the
# fixture reached its end (markers/finished) and recorded at least one check, every one of them ok.
# A run that stopped early leaves its last result.json behind, so the checks alone do not show that
# nothing was skipped. run-check.sh judges every run with this.
# usage: verdict.sh <output dir>
set -uo pipefail
out=$1
result="$out/result.json"
failed=0
if ! jq -e '.checks | type == "array"' "$result" >/dev/null 2>&1; then
    echo "FAIL no readable checks in $result" >&2
    exit 1
fi
jq -r '.checks[] | "\(if .ok == true then "ok  " else "FAIL" end) \(.check): \(.detail)"' "$result"
checks=$(jq '.checks | length' "$result")
passed=$(jq '[.checks[] | select(.ok == true)] | length' "$result")
(( checks == 0 )) && { echo "FAIL the fixture recorded no checks" >&2; failed=1; }
(( passed < checks )) && { echo "FAIL $(( checks - passed )) of $checks checks" >&2; failed=1; }
[[ -e "$out/markers/finished" ]] || { echo "FAIL the fixture did not finish; the checks after the last one were not run" >&2; failed=1; }
exit $failed
