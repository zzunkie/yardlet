#!/bin/zsh
# The quick check for small changes: every test except the windowless renders, QA fixtures and
# performance runs (about 3 minutes after the build, where the whole suite takes about 15 serially).
# Run the whole suite (`swift test --build-system native`) before a release.
# `--excluded` runs only the tests the quick check leaves out, as the nightly CI run does
# (.github/workflows/full-tests.yml); some of them open windows or menus of their own.
# XCTest tests run in batches, four xctest processes at a time (scripts/xctest-batches.py), rather
# than in a process for each test as `swift test --parallel` runs them; Swift Testing's run after,
# in one process. `-v` prints every test's output, `--filter` and `--skip` select tests as they do
# for `swift test`, and `--num-workers` sets how many processes run at a time.
# On a Mac it first waits for the shared heavy-build lock (scripts/heavy-lock.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
arguments=("$@")
excluded='(Rendering|Render|QA|Snapshot|Visual|Performance|BlankFrame|Hitch|Pixel|MenuWindow|WindowRedraw)Tests'
selection=()
only_excluded=0
verbose=()
workers=4
while (( $# )); do
  case $1 in
    --excluded) only_excluded=1 ;;
    -v|--verbose) verbose=(-v) ;;
    --filter|--skip|--num-workers)
      (( $# >= 2 )) || { print -u2 "test-fast.sh: $1 needs a value"; exit 2; }
      if [[ $1 == --num-workers ]]; then workers=$2; else selection+=("$1" "$2"); fi
      shift ;;
    *) print -u2 "test-fast.sh: unknown option $1 (for others, run swift test --build-system native)"
       exit 2 ;;
  esac
  shift
done
if (( only_excluded )); then selection=(--filter "$excluded" "${selection[@]}"); else selection=(--skip "$excluded" "${selection[@]}"); fi
source scripts/heavy-lock.sh && take_heavy_lock "${0:A}" "${arguments[@]}"

python3 -B scripts/perf-bench/test_report.py

swift build --build-system native --build-tests -j 4
bundles=("$(swift build --build-system native --show-bin-path)"/*PackageTests.xctest(N))
(( ${#bundles} == 1 )) || { print -u2 "test-fast.sh: expected one test bundle, found ${#bundles}"; exit 1; }
tests=$(mktemp -t yardlet-tests)
trap 'rm -f "$tests"' EXIT
swift test --build-system native list --skip-build --disable-swift-testing > "$tests"
xctest_status=0
python3 -I scripts/xctest-batches.py --bundle "$bundles[1]" --tests "$tests" --workers "$workers" \
  "${selection[@]}" "${verbose[@]}" || xctest_status=$?
print "Swift Testing:"
swift test --build-system native --skip-build --disable-xctest "${selection[@]}" "${verbose[@]}"
exit $xctest_status
