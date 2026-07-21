#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s <yardlet-bin> <evidence-dir> <scenario>\n' "$0" >&2
  exit 64
fi

YARDLET_BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EVIDENCE_DIR="$2"
SCENARIO="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPPORT_DIR="$(cd "$FIXTURE_ROOT/../support" && pwd)"
mkdir -p "$EVIDENCE_DIR"

source "$SUPPORT_DIR/fixture-binary-preflight.sh"

fail() {
  printf 'fixture failure: %s\n' "$*" >&2
  exit 1
}

write_summary() {
  local evidence="$1"
  cat >"$EVIDENCE_DIR/summary.json" <<EOF
{
  "schema_version": 1,
  "scenario": "$SCENARIO",
  "status": "passed",
  "evidence": "$evidence"
}
EOF
}

prepare_stale_binary() {
  local stale_bin="$EVIDENCE_DIR/stale-yardlet"
  cp "$FIXTURE_ROOT/stale-yardlet.sh" "$stale_bin"
  chmod +x "$stale_bin"
  printf '%s\n' "$stale_bin"
}

assert_actionable_stale_failure() {
  local diagnostic="$1"
  local marker="$2"
  shift 2
  grep -Fq 'fixture capability preflight failed' "$diagnostic" || fail "preflight headline missing"
  grep -Fq 'target binary:' "$diagnostic" || fail "target binary path missing"
  grep -Fq 'older than the source fixture registry' "$diagnostic" || fail "stale artifact cause missing"
  grep -Fq 'cargo clean -p yardlet' "$diagnostic" || fail "clean command missing"
  grep -Fq 'cargo build --bin yardlet' "$diagnostic" || fail "rebuild command missing"
  grep -Fq 'then retry' "$diagnostic" || fail "retry instruction missing"
  ! grep -Fq 'unknown fixture' "$diagnostic" || fail "raw unknown-fixture error leaked"
  [[ ! -e "$marker" ]] || fail "stale fixture body executed despite failed preflight"
  local required_id
  for required_id in "$@"; do
    grep -Fq "$required_id" "$diagnostic" || fail "missing id not reported: $required_id"
  done
}

case "$SCENARIO" in
  stale_single)
    stale_bin="$(prepare_stale_binary)"
    marker="$EVIDENCE_DIR/body-started"
    diagnostic="$EVIDENCE_DIR/stale-single.err"
    export STALE_FIXTURE_BODY_MARKER="$marker"
    if preflight_fixture_binary "$stale_bin" fixture-added-after-build >"$EVIDENCE_DIR/stale-single.out" 2>"$diagnostic"; then
      fail "stale binary passed a missing single fixture id"
    fi
    assert_actionable_stale_failure "$diagnostic" "$marker" fixture-added-after-build
    write_summary "단일 required fixture id 누락을 본문 실행 전에 진단함"
    ;;
  stale_multiple)
    stale_bin="$(prepare_stale_binary)"
    marker="$EVIDENCE_DIR/body-started"
    diagnostic="$EVIDENCE_DIR/stale-multiple.err"
    export STALE_FIXTURE_BODY_MARKER="$marker"
    if preflight_fixture_binary "$stale_bin" fixture-added-after-build-alpha fixture-added-after-build-beta >"$EVIDENCE_DIR/stale-multiple.out" 2>"$diagnostic"; then
      fail "stale binary passed missing multiple fixture ids"
    fi
    assert_actionable_stale_failure "$diagnostic" "$marker" \
      fixture-added-after-build-alpha fixture-added-after-build-beta
    write_summary "복수 required fixture id 누락을 모두 본문 실행 전에 진단함"
    ;;
  fresh)
    preflight_fixture_binary "$YARDLET_BIN" watch-until-path-exists
    "$YARDLET_BIN" eval fixtures --json --fixture watch-until-path-exists \
      >"$EVIDENCE_DIR/fresh-result.json"
    python3 - "$EVIDENCE_DIR/fresh-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["passed"] is True
assert [fixture["id"] for fixture in report["fixtures"]] == ["watch-until-path-exists"]
PY
    write_summary "fresh binary preflight 뒤 기존 named fixture 실행 결과를 보존함"
    ;;
  *)
    fail "unknown scenario: $SCENARIO"
    ;;
esac
