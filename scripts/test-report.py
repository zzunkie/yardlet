#!/usr/bin/env python3
"""Reads `swift test --parallel -v` output on stdin and keeps what a person reads short.

With `-v`, SwiftPM prints the XCTest output of every test, passed ones too, after the progress
lines: how long each test took and why a skipped one was skipped. This passes everything through
except the output of tests that passed or were skipped, and at the end writes

- `--log`: everything it read, and how `-v` compiled the package manifests, which it does not show,
- `--times`: one line per XCTest test case (class, test, result, seconds), slowest first,
- `--summary`: counts, the slowest tests and classes, and every skip with its reason (Markdown,
  for `$GITHUB_STEP_SUMMARY`).

Seconds are the test's own, measured by XCTest in its process; starting each test's process is
not counted.

usage: swift test --parallel -v … 2>&1 | test-report.py [--log FILE] [--times FILE] [--summary FILE]
"""
import argparse
import re
import sys
from collections import defaultdict

CASE = re.compile(r"^Test Case '-\[(\S+)\.(\S+) (\S+)\]' (passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)\.")
SKIP = re.compile(r": -\[(\S+)\.(\S+) (\S+)\] : Test skipped(?: - (.*))?$")
BLOCK_START = "Test Suite 'Selected tests' started at"
BLOCK_END = re.compile(r"^\s*Executed \d+ tests?, .* seconds$")
# `-v` also prints how it compiled each package manifest: kept in the log, not shown.
MANIFEST = re.compile(r"^(warning: '[^']+': /\S+/swift-frontend |/\S+/clang \S+Package-\d+\.o |Apple Swift version |Target: )")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log")
    parser.add_argument("--times")
    parser.add_argument("--summary")
    arguments = parser.parse_args()

    log = open(arguments.log, "w") if arguments.log else None
    cases = []  # (class, test, result, seconds)
    skips = {}  # (class, test) -> reason
    block = None
    closing = False  # the block saw its 'Selected tests' end; its Executed line closes it

    def flush():
        nonlocal block
        if block is None:
            return
        results = [result for line in block for match in [CASE.match(line)] if match for result in [match.group(4)]]
        if not results or any(result == "failed" for result in results):
            sys.stdout.writelines(block)
        block = None

    for line in sys.stdin:
        if log:
            log.write(line)
        if line.startswith(BLOCK_START):
            flush()
            block = []
            closing = False
        if block is None:
            if not MANIFEST.match(line):
                sys.stdout.write(line)
            continue
        block.append(line)
        match = CASE.match(line)
        if match:
            _, cls, test, result, seconds = match.groups()
            cases.append((cls, test, result, float(seconds)))
        skip = SKIP.search(line.rstrip("\n"))
        if skip:
            skips[(skip.group(2), skip.group(3))] = (skip.group(4) or "no reason given").strip()
        if line.startswith("Test Suite 'Selected tests' passed at") or line.startswith("Test Suite 'Selected tests' failed at"):
            closing = True
        elif closing and BLOCK_END.match(line):
            flush()
    flush()
    sys.stdout.flush()
    if log:
        log.close()

    cases.sort(key=lambda case: -case[3])
    if arguments.times:
        with open(arguments.times, "w") as file:
            file.write("class\ttest\tresult\tseconds\n")
            for cls, test, result, seconds in cases:
                file.write(f"{cls}\t{test}\t{result}\t{seconds:.3f}\n")
    if arguments.summary:
        with open(arguments.summary, "a") as file:
            file.write(summary(cases, skips))


def summary(cases, skips):
    if not cases:
        return "### XCTest\n\nNo XCTest results were read (run `swift test` with `--parallel -v`).\n"
    counts = defaultdict(int)
    for case in cases:
        counts[case[2]] += 1
    total = sum(case[3] for case in cases)
    lines = ["### XCTest", "",
             f"{len(cases)} tests: {counts['passed']} passed, {counts['failed']} failed, {counts['skipped']} skipped. "
             f"{total:.0f} s in the tests themselves, across the parallel workers.", ""]
    failed = [case for case in cases if case[2] == "failed"]
    if failed:
        lines += ["#### Failed", ""] + [f"- `{cls}/{test}` ({seconds:.2f} s)" for cls, test, _, seconds in failed] + [""]
    lines += ["#### Slowest tests", "", "| Seconds | Test |", "|---:|---|"]
    lines += [f"| {seconds:.2f} | `{cls}/{test}` |" for cls, test, _, seconds in cases[:20]]
    by_class = defaultdict(lambda: [0.0, 0])
    for cls, _, _, seconds in cases:
        by_class[cls][0] += seconds
        by_class[cls][1] += 1
    lines += ["", "#### Slowest classes", "", "| Seconds | Tests | Class |", "|---:|---:|---|"]
    for cls, (seconds, count) in sorted(by_class.items(), key=lambda item: -item[1][0])[:10]:
        lines.append(f"| {seconds:.1f} | {count} | `{cls}` |")
    skipped = [(cls, test) for cls, test, result, _ in cases if result == "skipped"]
    if skipped:
        by_reason = defaultdict(list)
        for key in skipped:
            by_reason[skips.get(key, "no reason given")].append(f"{key[0]}/{key[1]}")
        lines += ["", f"#### Skipped ({len(skipped)})", "", "| Reason | Tests |", "|---|---|"]
        for reason, tests in sorted(by_reason.items(), key=lambda item: -len(item[1])):
            reason = reason.replace("|", "\\|")
            lines.append(f"| {reason} | {', '.join(f'`{test}`' for test in sorted(tests))} |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
