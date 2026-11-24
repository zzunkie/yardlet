#!/usr/bin/env python3
"""Runs XCTest tests in a few processes at a time, many tests to a process.

`swift test --parallel` starts one xctest process for every test: some 3,000 for this package, each
loading the whole test bundle, and each one that uses AppKit checking in with the window server,
which works out focus again as it exits. This runs the same tests in batches, each batch in one
xctest process, `--workers` processes at a time. When `--times-file` names a TSV of previous test
durations (`class\\ttest\\tresult\\tseconds`), batches are packed by estimated duration and scheduled
longest-first (LPT) so slow tests never pile into one mega-batch or strand a worker at the tail;
otherwise batches follow the sorted list and shrink from 32 down to 4 tests toward the end. Measured
durations are merged back into `--times-file` when the run finishes.

A batch whose process crashes or ends before its last test reports the test it was in as failed and
runs the rest of its tests again in a new process, so every test still gets a result of its own, as
it would in a process of its own. A process that ends badly between tests or after its last one
fails the run too. A batch that prints nothing for STALL_WARNING seconds is named, with the test it
is in, every STALL_WARNING seconds; one that prints nothing for STALL_LIMIT seconds is ended the
same way, so a test that hangs fails with its name rather than running out the CI job's time.

Each xctest process starts in a session of its own, away from the terminal, so a subprocess a test
starts (a shell script, for instance) cannot stop the whole run by reading from or writing to the
terminal, and ending a batch ends what its tests started too.

The tests come from `swift test list --disable-swift-testing`, one `Target.Class/test` per line, and
`--filter` and `--skip` select from them as they do for `swift test`. Each process gets the
environment `swift test` gives xctest. Prints a line as each batch ends, the output of each failed
test, and a summary; with `-v`, each batch's whole XCTest output in one piece as the batch ends
(scripts/test-report.py reads it). Exits 1 when a test failed, or a process ended badly.

usage: xctest-batches.py --bundle PATH.xctest --tests FILE [--workers N] [--times-file FILE] [--filter RE]... [--skip RE]... [-v]
"""
import argparse
import collections
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

CASE_START = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' started\.")
CASE_END = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)\.")
RUN_END = re.compile(r"^Test Suite 'Selected tests' (passed|failed) at ")
# Without prior timing data, batches start at a quarter of a worker's share and shrink from
# COLD_LARGEST_BATCH down to SMALLEST_BATCH. Capping cold batches at 32 prevents adjacent slow
# classes (such as Conversation*) from piling into a multi-minute batch that starves workers.
COLD_LARGEST_BATCH = 32
# With timing data (LPT mode), fast tests can pack up to LPT_LARGEST_BATCH per process because
# each batch is also bounded by target duration.
LPT_LARGEST_BATCH = 64
SMALLEST_BATCH = 4
LPT_BATCHES_PER_WORKER = 12
LPT_MIN_TARGET_SECONDS = 10.0
# A test prints a line as it starts and ends, and the slowest take well under a minute on CI.
STALL_WARNING = 120.0
STALL_LIMIT = 300.0


def test_key(test_id):
    """Maps `Target.Class/method` (or `Class/method`) to `(Class, method)`."""
    cls_part, method = test_id.split("/", 1)
    return cls_part.split(".")[-1], method


def read_times(path):
    """Reads prior `(class, test) -> seconds` timings from a TSV file if present."""
    times = {}
    if not path or not os.path.exists(path):
        return times
    try:
        with open(path, encoding="utf-8", errors="replace") as file:
            for line in file:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 4 or parts[0] == "class":
                    continue
                try:
                    seconds = float(parts[3])
                except ValueError:
                    continue
                if math.isfinite(seconds) and seconds >= 0.0:
                    times[(parts[0], parts[1])] = seconds
    except OSError:
        return {}
    return times


def write_times(path, results):
    """Atomically merges measured test durations into `path` in `test-report.py` TSV format."""
    if not path or not results:
        return
    merged = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8", errors="replace") as file:
                for line in file:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) < 4 or parts[0] == "class":
                        continue
                    try:
                        seconds = float(parts[3])
                    except ValueError:
                        continue
                    if math.isfinite(seconds) and seconds >= 0.0:
                        merged[(parts[0], parts[1])] = (parts[2], seconds)
        except OSError:
            pass
    for test_id, (result, seconds) in results.items():
        if "/" not in test_id or not (math.isfinite(seconds) and seconds >= 0.0):
            continue
        key = test_key(test_id)
        # Keep an earlier valid duration if this run crashed before completing the test.
        if result != "passed" and seconds == 0.0 and key in merged:
            continue
        merged[key] = (result, seconds)
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".xctest-times-", suffix=".tsv", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write("class\ttest\tresult\tseconds\n")
            for (cls, method), (result, seconds) in sorted(merged.items(), key=lambda item: (-item[1][1], item[0])):
                file.write(f"{cls}\t{method}\t{result}\t{seconds:.3f}\n")
        os.replace(tmp_path, path)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def plan_batches(selected, workers, times=None):
    """Plans ordered test batches for `workers` concurrent xctest processes."""
    workers = max(1, workers)
    if not selected:
        return []
    known = [times[test_key(test)] for test in selected if times and test_key(test) in times]
    if not known:
        batches = []
        position = 0
        while position < len(selected):
            share = math.ceil((len(selected) - position) / (4 * workers))
            size = min(COLD_LARGEST_BATCH, max(SMALLEST_BATCH, share))
            batches.append(selected[position:position + size])
            position += size
        return batches

    fallback = sum(known) / len(known)

    def estimate(test):
        return times.get(test_key(test), fallback)

    total_estimate = sum(estimate(test) for test in selected)
    target = max(LPT_MIN_TARGET_SECONDS, total_estimate / (workers * LPT_BATCHES_PER_WORKER))

    by_class = collections.defaultdict(list)
    for test in selected:
        by_class[test.split("/")[0]].append(test)

    chunks = []
    for cls in sorted(by_class):
        current = []
        current_duration = 0.0
        for test in by_class[cls]:
            duration = estimate(test)
            if current and (len(current) >= LPT_LARGEST_BATCH or current_duration + duration > target):
                chunks.append((current_duration, current))
                current = []
                current_duration = 0.0
            current.append(test)
            current_duration += duration
        if current:
            chunks.append((current_duration, current))

    chunks.sort(key=lambda item: (-item[0], item[1][0]))
    packed = []
    small = []
    small_duration = 0.0
    for duration, tests in chunks:
        if duration >= target * 0.5 or len(tests) >= LPT_LARGEST_BATCH:
            packed.append((duration, tests))
        else:
            if small and (len(small) + len(tests) > LPT_LARGEST_BATCH or small_duration + duration > target):
                packed.append((small_duration, small))
                small = []
                small_duration = 0.0
            small.extend(tests)
            small_duration += duration
    if small:
        packed.append((small_duration, small))

    packed.sort(key=lambda item: (-item[0], item[1][0]))
    return [tests for _, tests in packed]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--tests", required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--times-file", default="")
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
        self.times_file = arguments.times_file
        self.total = len(selected)
        self.class_sizes = class_sizes
        times = read_times(self.times_file)
        self.queue = collections.deque(plan_batches(selected, self.workers, times))
        self.planned = len(self.queue)
        self.condition = threading.Condition()
        self.active = 0
        self.results = {}  # test -> (result, seconds)
        self.failures = []  # (what, why, output lines)
        self.processes = 0
        self.children = set()
        self.running = {}  # batch number -> Batch while its process runs
        self.stopping = False
        self.xctest = xcrun("--find", "xctest")
        # The macOS SDK's platform by name: an SDKROOT that names Command Line Tools' SDK, as some CI
        # runners have, is no SDK of the selected Xcode and has no platform path.
        platform = xcrun("--sdk", "macosx", "--show-sdk-platform-path")
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
        threading.Thread(target=self.watch, daemon=True).start()
        for thread in threads:
            while thread.is_alive():
                thread.join(0.5)
        if self.stopping:
            return 130
        if self.times_file:
            write_times(self.times_file, self.results)
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
            end_session(child, signal.SIGTERM)
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

    def watch(self):
        """Names each batch that has printed nothing for a while, and ends one that has for too long."""
        while True:
            time.sleep(min(STALL_WARNING, STALL_LIMIT) / 8)
            now = time.monotonic()
            with self.condition:
                if self.stopping:
                    return
                for number, batch in self.running.items():
                    quiet = now - batch.last_output
                    if quiet >= STALL_LIMIT and not batch.stalled:
                        batch.stalled = True
                        print(f"batch {number} ({batch.span}) printed nothing for {quiet:.0f} s"
                              f"{f' in {batch.current}' if batch.current else ''}; ending it.", flush=True)
                        end_session(batch.process, signal.SIGKILL)
                    elif quiet >= STALL_WARNING and now - batch.last_warning >= STALL_WARNING:
                        batch.last_warning = now
                        print(f"batch {number} ({batch.span}) has printed nothing for {quiet:.0f} s"
                              f"{f'; still in {batch.current}' if batch.current else ''}.", flush=True)

    def run_batch(self, batch, number):
        began = time.monotonic()
        process = subprocess.Popen([self.xctest, "-XCTest", self.selector(batch), self.bundle],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env=self.environment, text=True, errors="replace", start_new_session=True)
        watched = Batch(process, span_of(batch), began)
        with self.condition:
            self.children.add(process)
            self.running[number] = watched
            print(f"batch {number} started ({len(batch)} tests, {watched.span})", flush=True)
        lines = []
        spans = {}  # test -> [first line, last line]
        finished = {}  # test -> (result, seconds)
        current = None
        ended = False
        for line in process.stdout:
            lines.append(line)
            watched.last_output = time.monotonic()
            match = CASE_START.match(line)
            if match:
                current = f"{match.group(1)}/{match.group(2)}"
                watched.current = current
                spans[current] = [len(lines) - 1, len(lines)]
                continue
            match = CASE_END.match(line)
            if match:
                test = f"{match.group(1)}/{match.group(2)}"
                finished[test] = (match.group(3), float(match.group(4)))
                if test in spans:
                    spans[test][1] = len(lines)
                current = None
                watched.current = None
                continue
            if RUN_END.match(line):
                ended = True
            if current:
                spans[current][1] = len(lines)
        status = process.wait()
        with self.condition:
            self.children.discard(process)
            del self.running[number]
            if self.stopping:
                return
        failures = []
        for test, (result, _) in finished.items():
            if result == "failed":
                failures.append((test, "", lines[slice(*spans.get(test, (0, 0)))]))
        remaining = [test for test in batch if test not in finished and test != current]
        retry = []
        ending = f"signal {-status}" if status < 0 else f"exit status {status}"
        if watched.stalled:
            ending = f"no output for {STALL_LIMIT:.0f} s"
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
            note = f"; {len(retry)} tests left run again in a new process" if retry else ""
            if self.verbose:
                sys.stdout.writelines(lines)
            else:
                for test, why, output in failures:
                    sys.stdout.writelines(output)
            failed = sum(1 for test, _, _ in failures)
            print(f"[{done}/{self.total}] batch {number} ({len(batch)} tests, {watched.span}) took {seconds:.1f} s: "
                  f"{failed} failed{note}", flush=True)

    def selector(self, batch):
        # A whole class goes by its name, keeping the command line short; part of one, test by test.
        counts = collections.Counter(test.split("/")[0] for test in batch)
        named = []
        seen_classes = set()
        for test in batch:
            cls = test.split("/")[0]
            if counts[cls] == self.class_sizes[cls]:
                if cls not in seen_classes:
                    seen_classes.add(cls)
                    named.append(cls)
            else:
                named.append(test)
        return ",".join(named)


class Batch:
    """A batch's process while it runs, and what the watch needs to know about it."""

    def __init__(self, process, span, began):
        self.process = process
        self.span = span
        self.last_output = began
        self.last_warning = began
        self.current = None
        self.stalled = False


def span_of(batch):
    classes = sorted({test.split("/")[0].split(".")[-1] for test in batch})
    return classes[0] if len(classes) == 1 else f"{classes[0]} … {classes[-1]}"


def end_session(process, signal_number):
    """Ends an xctest process and whatever its tests started: everything in the session it leads.

    A test's subprocess may have a process group of its own (Foundation's `Process` gives it one), so
    the session is what holds them all, even after their parent has ended. A session's ID is not
    reused while anything is in it.
    """
    listing = subprocess.run(["ps", "-ax", "-o", "pid="], capture_output=True, text=True).stdout
    for pid in (int(field) for field in listing.split()):
        try:
            if os.getsid(pid) == process.pid:
                os.kill(pid, signal_number)
        except (ProcessLookupError, PermissionError):
            pass


def xcrun(*arguments):
    """What `xcrun` answers; when it fails, what it said goes to the log before the run ends."""
    result = subprocess.run(["xcrun", *arguments], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"xcrun {' '.join(arguments)} failed ({result.returncode}): {result.stderr.strip()}", file=sys.stderr)
    result.check_returncode()
    return result.stdout.strip()


def prepend(environment, key, *paths):
    environment[key] = ":".join([*paths, *([environment[key]] if environment.get(key) else [])])


if __name__ == "__main__":
    sys.exit(main())
