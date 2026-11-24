#!/usr/bin/env python3
"""Unit tests for scripts/xctest-batches.py batch planning and timing persistence."""
import argparse
import collections
import contextlib
import heapq
import io
import importlib.machinery
import importlib.util
import os
import tempfile
import time
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "xctest-batches.py")
loader = importlib.machinery.SourceFileLoader("xctest_batches", SCRIPT_PATH)
spec = importlib.util.spec_from_loader("xctest_batches", loader)
xctest_batches = importlib.util.module_from_spec(spec)
loader.exec_module(xctest_batches)


def simulate(batches, durations, workers):
    heap = [0.0] * workers
    heapq.heapify(heap)
    for batch in batches:
        start = heapq.heappop(heap)
        wall = 0.35 + sum(durations[t] for t in batch)
        heapq.heappush(heap, start + wall)
    return max(heap), min(heap)


class XCTestBatchesTests(unittest.TestCase):
    def test_cold_plan_caps_batch_size_at_32_and_covers_all_tests(self):
        selected = [f"NativeHarnessClientTests.Class{i // 10:02d}Tests/test{i:03d}" for i in range(400)]
        batches = xctest_batches.plan_batches(selected, workers=4, times=None)
        flat = [t for b in batches for t in b]
        self.assertEqual(flat, selected)
        self.assertLessEqual(max(len(b) for b in batches), xctest_batches.COLD_LARGEST_BATCH)
        self.assertGreaterEqual(min(len(b) for b in batches[:-1]), xctest_batches.SMALLEST_BATCH)

    def test_lpt_plan_schedules_slow_batches_first_and_eliminates_straggler_tail(self):
        # Mirror the skewed distribution in CI: slow tests late in the alphabet (`Streaming*`)
        # alongside fast tests and a cluster of slow `Conversation*` tests.
        selected = []
        durations = {}
        times = {}
        for i in range(60):
            t = f"NativeHarnessClientTests.AlphaFastTests/testFast{i:02d}"
            selected.append(t)
            durations[t] = 0.05
            times[("AlphaFastTests", f"testFast{i:02d}")] = 0.05
        for c in range(4):
            for i in range(4):
                cls = f"ConversationSlow{c}Tests"
                method = f"testDraw{i}"
                t = f"NativeHarnessClientTests.{cls}/{method}"
                selected.append(t)
                durations[t] = 15.0
                times[(cls, method)] = 15.0
        for i in range(4):
            t = f"NativeHarnessClientTests.StreamingWindowRedrawTests/testTail{i}"
            selected.append(t)
            durations[t] = 25.0
            times[("StreamingWindowRedrawTests", f"testTail{i}")] = 25.0

        selected.sort()
        cold = xctest_batches.plan_batches(selected, workers=4, times=None)
        lpt = xctest_batches.plan_batches(selected, workers=4, times=times)

        self.assertEqual(sorted(t for b in lpt for t in b), selected)
        cold_max, _ = simulate(cold, durations, workers=4)
        lpt_max, lpt_min = simulate(lpt, durations, workers=4)
        self.assertLess(lpt_max, cold_max)
        self.assertLess(lpt_max - lpt_min, 20.0)
        # Slowest batch must come before tiny fast batches.
        first_dur = sum(durations[t] for t in lpt[0])
        last_dur = sum(durations[t] for t in lpt[-1])
        self.assertGreater(first_dur, last_dur)

    def test_times_file_round_trip_merges_filtered_runs_and_preserves_unrun_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "nested", "xctest-times.tsv")
            xctest_batches.write_times(path, {
                "NativeHarnessClientTests.FirstTests/testA": ("passed", 12.345),
                "NativeHarnessClientTests.SecondTests/testB": ("passed", 0.500),
            })
            # Filtered second run updates testB and crashes testA with 0.0s (should keep prior 12.345s).
            xctest_batches.write_times(path, {
                "NativeHarnessClientTests.FirstTests/testA": ("failed", 0.0),
                "NativeHarnessClientTests.SecondTests/testB": ("passed", 0.750),
                "NativeHarnessClientTests.ThirdTests/testC": ("passed", 3.250),
            })
            loaded = xctest_batches.read_times(path)
            self.assertAlmostEqual(loaded[("FirstTests", "testA")], 12.345, places=3)
            self.assertAlmostEqual(loaded[("SecondTests", "testB")], 0.750, places=3)
            self.assertAlmostEqual(loaded[("ThirdTests", "testC")], 3.250, places=3)

    def test_times_file_ignores_non_finite_and_negative_durations(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "xctest-times.tsv")
            with open(path, "w", encoding="utf-8") as file:
                file.write("class\ttest\tresult\tseconds\n")
                file.write("BadTests\ttestNaN\tpassed\tnan\n")
                file.write("BadTests\ttestInf\tpassed\tinf\n")
                file.write("BadTests\ttestNeg\tpassed\t-1.500\n")
                file.write("GoodTests\ttestOk\tpassed\t2.500\n")
            loaded = xctest_batches.read_times(path)
            self.assertEqual(loaded, {("GoodTests", "testOk"): 2.5})

            xctest_batches.write_times(path, {
                "NativeHarnessClientTests.BadTests/testWriteNaN": ("passed", float("nan")),
                "NativeHarnessClientTests.BadTests/testWriteInf": ("passed", float("inf")),
                "NativeHarnessClientTests.BadTests/testWriteNeg": ("passed", -0.5),
                "NativeHarnessClientTests.GoodTests/testNew": ("passed", 1.25),
            })
            reloaded = xctest_batches.read_times(path)
            self.assertEqual(reloaded, {
                ("GoodTests", "testOk"): 2.5,
                ("GoodTests", "testNew"): 1.25,
            })

    def test_selector_collapses_whole_classes_even_when_non_adjacent(self):
        run = object.__new__(xctest_batches.Run)
        run.class_sizes = collections.Counter({
            "T.WholeA": 2,
            "T.PartialB": 3,
        })
        batch = ["T.WholeA/t1", "T.PartialB/p1", "T.WholeA/t2"]
        self.assertEqual(run.selector(batch), "T.WholeA,T.PartialB/p1")

    def test_a_silent_batch_is_named_then_ended_with_what_its_test_started(self):
        # A fake xctest: a test named `hang…` starts a child in a process group of its own, as
        # Foundation's `Process` does, that holds the output pipe open, so the batch ends only when
        # everything in its session is ended.
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "xctest")
            with open(fake, "w") as file:
                file.write("""#!/bin/sh
IFS=,
for t in $2; do
  echo "Test Case '-[${t%/*} ${t#*/}]' started."
  case ${t#*/} in hang*) set -m; sleep 30 & wait ;; esac
  echo "Test Case '-[${t%/*} ${t#*/}]' passed (0.001 seconds)."
done
echo "Test Suite 'Selected tests' passed at now."
""")
            os.chmod(fake, 0o755)
            tests = ["T.ATests/test1", "T.ATests/hang2", "T.ATests/test3"]
            saved = (xctest_batches.xcrun, xctest_batches.STALL_WARNING, xctest_batches.STALL_LIMIT)
            xctest_batches.xcrun = lambda *arguments: fake if arguments[0] == "--find" else tmp
            xctest_batches.STALL_WARNING, xctest_batches.STALL_LIMIT = 0.4, 2.0
            try:
                arguments = argparse.Namespace(verbose=False, bundle=os.path.join(tmp, "T.xctest"), workers=1,
                                               times_file="")
                run = xctest_batches.Run(arguments, tests, collections.Counter({"T.ATests": 4}))
                output = io.StringIO()
                began = time.monotonic()
                with contextlib.redirect_stdout(output):
                    status = run.start()
                elapsed = time.monotonic() - began
            finally:
                xctest_batches.xcrun, xctest_batches.STALL_WARNING, xctest_batches.STALL_LIMIT = saved
        self.assertEqual(status, 1)
        self.assertLess(elapsed, 10.0)
        self.assertEqual({test: result for test, (result, _) in run.results.items()},
                         {"T.ATests/test1": "passed", "T.ATests/hang2": "failed", "T.ATests/test3": "passed"})
        log = output.getvalue()
        self.assertIn("batch 1 started (3 tests, ATests)", log)
        self.assertIn("has printed nothing for", log)
        self.assertIn("still in T.ATests/hang2", log)
        self.assertIn("T.ATests/hang2 (xctest ended with no output for 2 s during this test)", log)


if __name__ == "__main__":
    unittest.main()
