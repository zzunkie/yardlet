#!/usr/bin/env python3
"""Runs XCTest tests in a few processes at a time, many tests to a process.

`swift test --parallel` starts one xctest process for every test: some 3,000 for this package, each
loading the whole test bundle, and each one that uses AppKit checking in with the window server,
which works out focus again as it exits. This runs the same tests in batches, each batch in one
xctest process, `--workers` processes at a time. Batches follow the list's order and get smaller
toward the end of the run, so the last ones are short and the workers finish together; a run of
about 3,000 tests takes some 90 processes.

A batch whose process crashes or ends before its last test reports the test it was in as failed and
runs the rest of its tests again in a new process, so every test still gets a result of its own, as
it would in a process of its own. A process that ends badly between tests or after its last one
fails the run too.

The tests come from `swift test list --disable-swift-testing`, one `Target.Class/test` per line, and
`--filter` and `--skip` select from them as they do for `swift test`. Each process gets the
environment `swift test` gives xctest. Prints a line as each batch ends, the output of each failed
test, and a summary; with `-v`, each batch's whole XCTest output in one piece as the batch ends
(scripts/test-report.py reads it). Exits 1 when a test failed, or a process ended badly.

usage: xctest-batches.py --bundle PATH.xctest --tests FILE [--workers N] [--filter RE]... [--skip RE]... [-v]
"""
import argparse
import collections
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

CASE_START = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' started\.")
CASE_END = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)\.")
RUN_END = re.compile(r"^Test Suite 'Selected tests' (passed|failed) at ")
# Batches start at a quarter of a worker's share of the tests and shrink as the run goes on, from
# LARGEST_BATCH tests down to SMALLEST_BATCH. A process keeps some of what each test that draws a
# window leaves behind, so the largest is kept small enough that one process's memory stays near what
# one such test takes alone.
LARGEST_BATCH = 64
SMALLEST_BATCH = 4


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--tests", required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--filter", action="append", default=[])
    parser.add_argument("--skip", action="append", default=[])
    parser.add_argument("-v", "--verbose", action="store_true")
    arguments = parser.parse_args()

    with open(arguments.tests) as file:
        listed = [line.strip() for line in file if re.match(r"^\S+\.\S+/\S+$", line.strip())]
    filters = [re.compile(pattern) for pattern in arguments.filter]
    skips = [re.compile(pattern) for pattern in arguments.skip]
    selected = sorted(test for test in listed
                      if (not filters or any(pattern.search(test) for pattern in filters))
                      and not any(pattern.search(test) for pattern in skips))
    if not selected:
        print("No XCTest tests match.")
        return 0
    run = Run(arguments, selected, collections.Counter(test.split("/")[0] for test in listed))
    return run.start()


class Run:
    def __init__(self, arguments, selected, class_sizes):
        self.verbose = arguments.verbose
        self.bundle = os.path.abspath(arguments.bundle)
        self.workers = max(1, arguments.workers)
        self.total = len(selected)
        self.class_sizes = class_sizes
        self.queue = collections.deque()
        position = 0
        while position < len(selected):
            share = math.ceil((len(selected) - position) / (4 * self.workers))
            size = min(LARGEST_BATCH, max(SMALLEST_BATCH, share))
            self.queue.append(selected[position:position + size])
            position += size
        self.planned = len(self.queue)
        self.condition = threading.Condition()
        self.active = 0
        self.results = {}  # test -> (result, seconds)
        self.failures = []  # (what, why, output lines)
        self.processes = 0
        self.children = set()
        self.stopping = False
        self.xctest = subprocess.run(["xcrun", "--find", "xctest"], check=True, capture_output=True,
                                     text=True).stdout.strip()
        platform = subprocess.run(["xcrun", "--show-sdk-platform-path"], check=True, capture_output=True,
                                  text=True).stdout.strip()
        # What `swift test` adds for xctest on macOS: the build's products and the platform's XCTest
        # and Swift Testing, and Swift Testing switched off inside XCTest's process.
        self.environment = dict(os.environ)
        prepend(self.environment, "DYLD_LIBRARY_PATH", os.path.dirname(self.bundle), f"{platform}/Developer/usr/lib")
        prepend(self.environment, "DYLD_FRAMEWORK_PATH", f"{platform}/Developer/Library/Frameworks",
                f"{platform}/Developer/Library/PrivateFrameworks")
        self.environment["SWIFT_TESTING_ENABLED"] = "0"

    def start(self):
        began = time.monotonic()
        for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signal_number, self.stop)
        threads = [threading.Thread(target=self.work, daemon=True) for _ in range(self.workers)]
        for thread in threads:
            thread.start()
        for thread in threads:
            while thread.is_alive():
                thread.join(0.5)
        if self.stopping:
            return 130
        counts = collections.Counter(result for result, _ in self.results.values())
        minutes, seconds = divmod(round(time.monotonic() - began), 60)
        print(f"Executed {len(self.results)} of {self.total} tests in {self.processes} xctest processes, "
              f"{self.workers} at a time: {counts['passed']} passed, {counts['skipped']} skipped, "
              f"{counts['failed']} failed ({minutes} min {seconds} s).")
        if self.failures:
            print("Failed:")
            for what, why, _ in self.failures:
                print(f"  {what}{f' ({why})' if why else ''}")
        return 1 if self.failures or len(self.results) < self.total else 0

    def stop(self, signal_number, _frame):
        with self.condition:
            self.stopping = True
            self.queue.clear()
            children = list(self.children)
            self.condition.notify_all()
        for child in children:
            try:
                child.terminate()
            except ProcessLookupError:
                pass
        print(f"Stopped by signal {signal_number}; ended {len(children)} xctest processes.", file=sys.stderr)

    def work(self):
        while True:
            with self.condition:
                # A batch still running may hand back the tests a crash left unrun.
                while not self.queue and self.active and not self.stopping:
                    self.condition.wait()
                if not self.queue or self.stopping:
                    self.condition.notify_all()
                    return
                batch = self.queue.popleft()
                self.active += 1
                self.processes += 1
                number = self.processes
            try:
                self.run_batch(batch, number)
            finally:
                with self.condition:
                    self.active -= 1
                    self.condition.notify_all()

    def run_batch(self, batch, number):
        began = time.monotonic()
        process = subprocess.Popen([self.xctest, "-XCTest", self.selector(batch), self.bundle],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env=self.environment, text=True, errors="replace")
        with self.condition:
            self.children.add(process)
        lines = []
        spans = {}  # test -> [first line, last line]
        finished = {}  # test -> (result, seconds)
        current = None
        ended = False
        for line in process.stdout:
            lines.append(line)
            match = CASE_START.match(line)
            if match:
                current = f"{match.group(1)}/{match.group(2)}"
                spans[current] = [len(lines) - 1, len(lines)]
                continue
            match = CASE_END.match(line)
            if match:
                test = f"{match.group(1)}/{match.group(2)}"
                finished[test] = (match.group(3), float(match.group(4)))
                if test in spans:
                    spans[test][1] = len(lines)
                current = None
                continue
            if RUN_END.match(line):
                ended = True
            if current:
                spans[current][1] = len(lines)
        status = process.wait()
        with self.condition:
            self.children.discard(process)
            if self.stopping:
                return
        failures = []
        for test, (result, _) in finished.items():
            if result == "failed":
                failures.append((test, "", lines[slice(*spans.get(test, (0, 0)))]))
        remaining = [test for test in batch if test not in finished and test != current]
        retry = []
        ending = f"signal {-status}" if status < 0 else f"exit status {status}"
        if status in (0, 1) and ended:
            for test in remaining:
                failures.append((test, "listed but not run", []))
            if status == 1 and not failures:
                failures.append((f"xctest batch {number}", "a failure outside its tests",
                                 [line for line in lines if ": error: " in line]))
        elif current:
            failures.append((current, f"xctest ended with {ending} during this test", lines[slice(*spans[current])]))
            retry = remaining
        elif remaining and finished:
            failures.append((f"xctest batch {number}", f"ended with {ending} between tests", lines[-20:]))
            retry = remaining
        elif remaining:
            failures.append((f"xctest batch {number}", f"ended with {ending} before its first test", lines[-20:]))
            for test in remaining:
                failures.append((test, "not run: its xctest process ended before its first test", []))
        else:
            failures.append((f"xctest batch {number}", f"ended with {ending} after its last test", lines[-20:]))
        with self.condition:
            self.results.update(finished)
            for test, why, _ in failures:
                if "/" in test and test not in self.results:
                    self.results[test] = ("failed", 0.0)
            self.failures.extend(failures)
            if retry:
                self.queue.appendleft(retry)
            done = len(self.results)
            seconds = time.monotonic() - began
            classes = sorted({test.split("/")[0].split(".")[-1] for test in batch})
            span = classes[0] if len(classes) == 1 else f"{classes[0]} … {classes[-1]}"
            note = f"; {len(retry)} tests left run again in a new process" if retry else ""
            if self.verbose:
                sys.stdout.writelines(lines)
            else:
                for test, why, output in failures:
                    sys.stdout.writelines(output)
            failed = sum(1 for test, _, _ in failures)
            print(f"[{done}/{self.total}] batch {number} ({len(batch)} tests, {span}) took {seconds:.1f} s: "
                  f"{failed} failed{note}", flush=True)

    def selector(self, batch):
        # A whole class goes by its name, keeping the command line short; part of one, test by test.
        counts = collections.Counter(test.split("/")[0] for test in batch)
        named = []
        for test in batch:
            cls = test.split("/")[0]
            if counts[cls] == self.class_sizes[cls]:
                if not named or named[-1] != cls:
                    named.append(cls)
            else:
                named.append(test)
        return ",".join(named)


def prepend(environment, key, *paths):
    environment[key] = ":".join([*paths, *([environment[key]] if environment.get(key) else [])])


if __name__ == "__main__":
    sys.exit(main())
