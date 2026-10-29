# Performance bench

Yardlet's performance bench runs fixed scenes of the whole app and the in-process benchmarks of the
test suite, writes one JSON result, compares it with an earlier result, and fails when a number is over
its budget. It exists so that a change that slows the app down shows up as a number before anyone feels
it, and so that a fix can show what it changed. It is not part of CI: the numbers depend on the Mac and on
what else runs on it, so they are compared between runs on the same Mac.

## 1. Running it

```bash
./scripts/perf-bench/run.sh --build          # build a debug bundle, then every scene and benchmark
./scripts/perf-bench/run.sh --no-micro       # the app's scenes only (about 6 minutes)
./scripts/perf-bench/run.sh --scenes "codex-history subagent" --repeat 3 --compare main
./scripts/perf-bench/run.sh --micro-only     # the in-process benchmarks only
```

- It needs a debug bundle of the checkout (`scripts/build-app.sh debug`, or `--build`). Release builds do
  not contain the bench's fixture. The `browser-tabs` scene needs a bundle with the browser engine (CEF);
  without it the scene records a problem and the other scenes still run.
- It waits for the shared heavy-build lock (`~/Library/Caches/yardlet-heavy-build.lock`), so builds and
  test runs started the same way do not run beside it. Other work on the Mac still shows in the numbers:
  the result records the load average when the run and each scene started.
- It never takes the screen or the keyboard. The app runs as a QA copy with its own bundle identifier
  (`com.zzunkie.yardletqa.perf`), a temporary home, and windows off every screen that are never active
  (`QABackground`). No installed app, account, network service or model is used: tasks that stream talk
  to fake Codex and Claude Code CLIs (`scripts/perf-bench/fake-codex.py`, `fake-claude.py`).
- Results go to `~/Library/Caches/Yardlet/perf-bench/results/<time>-<commit>.json` (or
  `$YARDLET_PERF_RESULTS`), with the in-process benchmarks' log beside them. Every checkout and worktree on
  the Mac shares the folder, so a branch compares with another. The QA copy, its home and the logs are
  removed afterwards unless `--keep`.
- `--compare` takes a result file or a commit (`--compare main`, `--compare 1a2b3c4d`), whose newest result
  it compares with; by default it is the newest earlier result. `--tolerance` sets how much worse a number
  must be to be marked (default 15%). `scripts/perf-bench/report.py compare <earlier.json> <later.json>`
  compares two results again.
- The command exits with status 1 when a number is over its budget or a scene could not be set up (§4).

## 2. Scenes

Each scene is a fresh launch of the QA copy with `--ui-fixture=perf --ui-fixture-perf-scene=<scene>`
(`PerfBenchFixture`). The window is 1440 × 900 points. The sidebar holds 40 finished tasks in eight
projects unless the scene says otherwise. Phases are measured after the scene has settled.

| Scene | What the window holds | Phases (seconds) |
|---|---|---|
| `launch` | 200 tasks; a 60-turn Claude Code conversation shown | launch timings, `settled` (10) |
| `idle-running` | a 20-turn Claude Code task shown; a Codex task in the sidebar | `idle` (15), then both start a turn that keeps running: `idle-running` (15) |
| `stream-claude` | a Claude Code answer streaming at the end of a 60-turn conversation: thinking, text and a Bash call with output, over and over | `streaming` (20) |
| `stream-codex` | a Codex answer streaming in a 60-turn thread (the App Server's resume window loads its newest turns): reasoning, commands with output and answers | `streaming` (20) |
| `codex-history` | a Codex task whose 500 saved cards (two turns of builds, 5,000 characters of output each) every streamed state merges, with an answer streaming | `streaming` (20) |
| `subagent` | the shown Claude Code task's turn waits on a Codex subagent (`run_agent`) whose turn already holds 400 finished commands with output, and which streams on | `streaming` (20) |
| `sidebar` | 400 tasks in 40 projects and 400 archived tasks (every fifth task's parent is archived); the sidebar scrolled down to its end and back at 1,200 points a second | `scroll` (10), then with a Codex answer streaming in the shown task: `scroll-streaming` (10) |
| `browser-tabs` | six local pages open in the shown task's browser panel | `tabs-shown` (15), then with the panel closed: `tabs-hidden` (10) |

The fakes stream about 30 fragments a second, the rate of a working agent, in the providers' own frame
shapes: Claude Code's `stream-json` with partial messages, and Codex App Server notifications. A message
`perf stream <seconds> [n]` streams for that long (with `n`, the Codex turn first holds `n` finished
commands), and `perf hold` starts a turn that keeps running; the fixture sends these through the app as
the composer and `run_agent` would.

## 3. What the numbers mean

Every number is a cost, so a larger value is worse. Its name ends in its unit.

**Events** (measured by the app, `events.<kind>.*`): the main thread's time for each provider event it
handles, by kind (`EventCostLog`): `codexState` (a Codex task's streamed state: merging saved cards and
requests, settling cards, publishing, saving), `transcriptPublication` (a Claude Code task's transcript
published to its views), `agentRunState` and `agentRunEvent` (a subagent's Codex state and event). Each
has `cpuMedianMs`, `cpuP95Ms` and `cpuMaxMs`, the main thread's own CPU time for one event, and
`medianMs`, `p95Ms` and `maxMs`, the wall-clock time, which also counts waiting for a busy Mac's cores.
Budgets use the CPU time, which load moves less. Drawing what an event changed comes after, in the frame,
and shows under the main thread's passes and frames.

**Main thread** (measured by the app, `mainThread.*`):
- A *pass* is one turn of the main run loop from waking to going back to sleep: everything the thread
  did for one event, timer, frame or block before it could take the next. `passMedianMs` and
  `passP95Ms` are its median and 95th percentile; `passMaxMs` the longest. `passesOver16MsCount` and
  `passesOver50MsCount` count passes long enough to miss a 60 Hz frame and to feel stuck: a key pressed
  then waits that long.
- `busyPercent` is the share of the phase spent in passes; `cpuPercent` is the main thread's CPU time
  over the phase (100% is one core).

**Frames** (measured by the app in the phases where frames matter, `frames.*`): a 60 Hz display link on
the main run loop. `latenessMedianMs` and `latenessP95Ms` say how long after each frame's time the main
thread got to it, and `missedPercent` how many frames it missed altogether. This is the main thread's
side of a frame; the bench does not measure WindowServer's compositing, since the windows are off screen.

**Process** (sampled by the script over the same phase, `process.*`, from `proc_pid_rusage`):
- `appCPUPercent`, `appFootprintMiB`, `appResidentMiB`, `appWakeupsPerSecond`: Yardlet's own process.
  Footprint is what Activity Monitor calls Memory; resident is RSS.
- `browserCPUPercent`, `browserFootprintMiB`: the browser engine's processes (the host and its helpers).
- `yardletCPUPercent`, `yardletFootprintMiB`: both together, what Yardlet itself costs.
- `agentCPUPercent`: the agent CLIs Yardlet runs, here the fakes. It is reported apart and is not
  Yardlet's cost.

**Launch** (`launch.*`, from the kernel's start time of the process): to the model being made
(`processStartToModelMs`), to the app finishing launching (`processStartToFinishedLaunchingMs`), to the
window's first task (`processStartToWindowMs`), to the first frame the main thread served after laying the
window out (`processStartToFirstFrameMs`), and to a main thread quiet for a second, with no pass over 16 ms
(`processStartToSettledMs`). A QA copy launched in the background makes its window only when opened
again, so the script opens it as soon as the app has finished launching; the window timings include that
round trip. The `launch` scene is the one with a full sidebar and a long conversation.

Each phase also notes what flowed through it (`published`: transcript and Codex states the model
published; `shownTaskItems`), so a run whose fake did not stream is visible as such, and a scene that
could not be set up lists its `problems` in the result and the summary.

## 4. Budgets

`scripts/perf-bench/budgets.json` gives each phase the largest value some of its numbers may have, as
`"<scene>/<phase>": {"<number>": <limit>}`. A number over its limit, a limited number the run did not
measure, or a scene's problem fails the run: the summary prints each one as `FAILED`, the result keeps
them under `budgets`, and the command exits with status 1.

- One event of a large scene (a Codex state of a task with 500 saved cards, a subagent's state of a
  400-item turn) gets 2 ms of the main thread's CPU, a subagent's event 1 ms, a transcript publication
  2 ms. At 30 fragments a second, 2 ms an event leaves the main thread most of every frame for typing and
  scrolling.
- An idle window, with or without running tasks, stays under 1% and 3% of a core; scrolling the long
  sidebar keeps its 95th percentile pass under a 60 Hz frame and no pass over 50 ms.
- The limits are for a debug build on an Apple silicon Mac at the load a working day leaves (load
  average up to about 25 on 12 cores). Change a limit only with a reason in the commit that changes it:
  a scene that does more, or a cost that was found and accepted.

A budget can fail on the main branch: then the bench has found a cost to fix, and the fix is the change
that brings the number under its limit. The result of the fix's branch compared with the main branch's
(`--compare main`) shows what it changed.

## 5. Reading a result

The summary prints, for every phase, Yardlet's CPU, the app's footprint, the main thread's CPU and long
passes, frames and the events' CPU time, beside the earlier result, and marks a number **worse** when it
grew by more than the tolerance and by more than its unit's floor: 2 ms, 1 percentage point, 15 MiB, 20
a second, 2 for a count, and 50 ms for launch timings. Every compared number is in the result's
`comparison`, the summary lists the worse ones it did not show, and `better` lists numbers that shrank as
much.

- Compare runs on the same Mac, with the same build configuration, at a similar load. A debug build is
  slower than a release build; the bench is for finding what changed, not for absolute speed.
- A single run can move by 10% or more. Before calling a number a regression, run the scene again with
  `--repeat 3` (each number is then the median of the rounds) on both commits.
- A scene with `problems`, or a phase whose `published` count is near zero while it should stream,
  measured something other than what it says; fix the scene before reading its numbers.

The bench measures the app with the fixture's model: an in-memory task index, no account checks,
pull request lookups, network watch or task resource sampling, which the live app runs besides. Those
are measured, where they matter, by their own tests.

## 6. Before a release

Before the release build is made, on the commit to release:

1. Let the Mac settle: no other build, test run or bench (the lock sees to the ones started with it).
2. `./scripts/perf-bench/run.sh --build --repeat 3 --compare <the previous release's tag>` (or the newest
   result of a commit near it, if that tag has none on this Mac).
3. No budget may fail. A number marked worse than the previous release needs a reason: a scene that now
   does more, or a regression to fix before the release. Run the scene alone again first; one run can
   move.
4. Keep the result: it is the next release's comparison.

## 7. In-process benchmarks

The test suite's benchmarks run only with `NHC_PERF_BENCH=1` and are skipped otherwise, including in
`scripts/test-fast.sh` and CI (except where the table says a check runs always). They isolate one cost in a windowless window, so they are the place to
look once a scene shows a number got worse. With `NHC_PERF_BENCH_OUTPUT=<file>` each one appends its
numbers to the file as a JSON line (`PerfBenchRecord`), which the bench collects under `micro`:

| Benchmark | Measures |
|---|---|
| `CodexTimelineMergeCostTests` | merging 500 saved Codex cards into one streamed state |
| `ConcurrentStreamingPerformanceTests/testBenchmarkTenConcurrentStreamingTasks` | ten tasks streaming at once through the adapters, one shown |
| `LongCodexThreadPerformanceTests/testBenchmarkLongCodexThreadStreaming` | one Codex update against a 300-turn thread, by route |
| `ConversationStreamingCostTests` | a Codex fragment in a turn of 3 and of 72 calls, and beside a scrolling list |
| `ConversationBlankFrameTests/testBenchmarkSwitchingToALongConversation` | opening a 20- and a 300-turn task |
| `ConversationBlankFrameTests/testBenchmarkStreamingInTheWholeWindow` | what drawing one publication costs the window under 1, 9 and 300 turns |
| `ConversationReopenGapWindowTests/testBenchmarkOpeningATaskWhoseTurnsWereLetGo` | reopening a task after four others were opened |
| `LongTranscriptRenderPerformanceTests` | laying out and streaming a 400-turn Claude Code transcript |
| `WindowStructureQATests/testBenchmarkTheSidebarCrossingItsTop` | the sidebar of 828 tasks crossing its top |
| `SubagentStatePerformanceTests` | a long Codex subagent's state handled by the app, beside three others (also a check that runs with every `swift test`) |

`NHC_PERF_BENCH_SECONDS` shortens the streaming benchmarks; the bench sets it to 20. A new benchmark
skips without `NHC_PERF_BENCH=1`, prints what it measured, and calls `PerfBenchRecord.write` with numbers
named by their unit, so the bench compares them too. A scene of the whole app goes in `PerfBenchFixture`
instead, when the cost needs the real window, adapters and processes; give it budgets in `budgets.json`.
