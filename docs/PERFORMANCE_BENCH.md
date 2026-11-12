# Performance bench

Yardlet's performance bench runs fixed scenes of the whole app and the in-process benchmarks of the
test suite, writes one JSON result, compares it with an earlier result, and fails when a number is over
its budget. It exists so that a change that slows the app down shows up as a number before anyone feels
it, and so that a fix can show what it changed. It is not part of CI: the numbers depend on the Mac and on
what else runs on it, so they are compared between runs on the same Mac.

## 1. Running it

```bash
./scripts/perf-bench/run.sh --build          # build a debug bundle, then every scene and benchmark
./scripts/perf-bench/run.sh --no-micro       # the app's scenes only (about 10 minutes)
./scripts/perf-bench/run.sh --scenes "codex-history subagent" --repeat 3 --compare main
./scripts/perf-bench/run.sh --micro-only     # the in-process benchmarks only
./scripts/perf-bench/run.sh --scenes memory-cycle --cycle-seconds 1800 --no-micro
./scripts/perf-bench/run.sh --scenes memory-cycle --cycle-seconds 300 --cycle-rest-seconds 300 --memory-census --no-micro
```

- Build it first with `--build`. It needs a debug bundle of the checkout. Release builds do
  not contain the bench's fixture. The `browser-tabs` scene needs a bundle with the browser engine (CEF);
  without it the scene records a problem and the other scenes still run.
- `--build` records the executable SHA-256, commit, diff digest and a digest of the checkout's non-ignored inputs
  (including untracked sources) in `<app>.perf-bench.json` beside the bundle. Reusing a bundle, including
  with `--app`, requires that its executable and the current inputs still match that record; otherwise
  run `--build` again. The result keeps this identity and the SHA-256 of the QA executable after signing.
  A checkout commit by itself is not treated as proof of what a reused binary contains.
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
- `--app-arguments "<argument> ..."` adds arguments to every launch of the app, such as a setting to measure
  with (`--app-arguments "-Yardlet.conversationTableTimeline YES"`); the result keeps them as `appArguments`.
- The command exits with status 1 when a number is over its budget, a planned result is missing, or a
  benchmark could not complete (§4). `contract.json` lists the scenes' required phases and the exact
  in-process tests and measurements; the selected plan is saved in every new result.

## 2. Scenes

Each scene is a fresh launch of the QA copy with `--ui-fixture=perf --ui-fixture-perf-scene=<scene>`
(`PerfBenchFixture`). The window is 1440 × 900 points. The sidebar holds 40 finished tasks in eight
projects unless the scene says otherwise. Phases are measured after the scene has settled.

| Scene | What the window holds | Phases (seconds) |
|---|---|---|
| `launch` | 200 tasks; a 60-turn Claude Code conversation shown | launch timings, `settled` (10) |
| `idle-running` | a 20-turn Claude Code task shown; a Codex task in the sidebar | `idle` (15), then both start a turn that keeps running: `idle-running` (15) |
| `stream-claude` | a Claude Code answer streaming at the end of a 60-turn conversation: thinking, text and a Bash call with output, over and over | `streaming` (20), then with the window showing another task's 20-turn conversation while the answer streams on: `streaming-elsewhere` (10) |
| `stream-codex` | a Codex answer streaming in a 60-turn thread (the App Server's resume window loads its newest turns): reasoning, commands with output and answers | `streaming` (20) |
| `codex-history` | a Codex task whose 500 saved cards (two turns of builds, 5,000 characters of output each) every streamed state merges, with an answer streaming | `streaming` (20) |
| `subagent` | the shown Claude Code task's turn waits on a Codex subagent (`run_agent`) whose turn already holds 400 finished commands with output, and which streams on | `streaming` (20) |
| `sidebar` | 400 tasks in 40 projects and 400 archived tasks (every fifth task's parent is archived); the sidebar scrolled down to its end and back at 1,200 points a second | `scroll` (10), then with a Codex answer streaming in the shown task: `scroll-streaming` (10) |
| `browser-tabs` | six local pages open in the shown task's browser panel | `tabs-shown` (15), then with the panel closed: `tabs-hidden` (10) |
| `codex-switch` | ten Codex tasks, each a turn of 400 finished commands with output followed by the reasoning, commands and answers of a 400-second stream (about 540 items, 1.4 MB) | `switch` (30): another task opened every 1.5 seconds, each after the four the window keeps; then `stream-switch` (120): three tasks at a time stream an answer for 30 seconds while another task opens every 2 seconds |
| `memory-cycle` | the same ten long Codex tasks, loaded once; history stays fixed while views are repeatedly opened and let go | `warm` (30), `revisit` (60 by default, `--cycle-seconds` changes it), `recovered` (15 at rest) |
| `composer-input` | a 60-turn Claude task streaming while its actual field editor receives alternating plain text and marked-text commits | `typing` (20): application-side dispatch, edit and layout latency, without sending the draft |
| `conversation-scroll` | a 60-turn Claude Code conversation whose answers hold long paragraphs, code blocks, tables, a Markdown link and a bare address, between Read, Grep, Bash and Edit calls with output. A scroll wheel event of 20 points a frame (1,200 points a second), in a trackpad gesture's phases, goes to the conversation's scroll view, up toward the top (bringing earlier turns in) and back down at either end. The result's `conversation` says how far the view moved a frame at a time, how often turns arriving above moved it, how far from the end it got and how near the top | `scroll` (10), then with a message streaming an answer into its last turn, which brings the view back to the end first: `scroll-streaming` (10) |

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
  `passesOver50MsCount` count long processing intervals that could delay an input event. They do not
  establish a perceived freeze; the bench has no hardware input or visible presentation timing.
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

The process sampler reads every half second, identifies processes by PID and start time, and uses the
actual elapsed time for CPU. Endpoint footprint stays comparable with older results. The new
`appPeakFootprintMiB`, `browserPeakFootprintMiB` and `yardletPeakFootprintMiB` are maxima of simultaneous
samples; they can see an allocation that was released before the endpoint. Processes that end during
the phase retain their observed CPU contribution, with zero endpoint memory. Very short-lived processes
between samples can still be missed.

**Bodies** (counted by the app, `bodies.*Count`): how often the window's widest views worked out their
bodies over the phase (`ViewBodyCensus`): the window itself (`mainWindowCount`), the task's views around its
conversation (`taskSurfaceCount`), the session rail's cards, the composer and the sidebar's rows; and the
conversation's timeline (`conversationTimelineCount`), its turns drawn whole (`conversationTurnCount`), the
rows it laid out anew to measure their heights (`conversationRowLaidOutCount`) and the turns' hosting views it
made (`conversationTurnHostingCount`). A streamed state is drawn in one evaluation of the timeline, so a
timeline count well over the states published, or a window drawn while a task streams or the sidebar
scrolls, is work an update did beyond what it changed.

**Memory** (measured by the app, `memory.*`): its footprint as the phase starts and ends, and how much
it grew over the phase (`footprintGrowthMiB`). Growth can include live turn data, caches and temporary
allocations; use a fixed working set and recovery interval to investigate what remains afterward.

**Switches** (measured by the app in `codex-switch/switch`, `switches.*`): for each task opened, the main
thread's time in the 1.5 seconds after it (`busyMedianMs`, `busyMaxMs`) and its longest pass then
(`longestPassMedianMs`, `longestPassMaxMs`). These are processing intervals in the synthetic scene, not
measurements of a visible window freezing.

**Input** (`composer-input/typing`, `input.*`): an edit is queued from a background queue, then applied to
the actual composer's AppKit field editor while the fake answer streams. The probe records queue delay,
edit plus synchronous layout time, and the total request-to-layout median, p95 and maximum. It alternates
plain text with marked text followed by a Korean-text commit and checks that edits really happened.
The window remains off screen. These are application-side costs, not hardware keyboard, input-method
service, WindowServer or display-presentation latency. No draft is submitted to a provider.

**Recovery** (`memory-cycle/recovered`, `memory.retainedGrowthMiB`): footprint after returning to the same
task and resting for 15 seconds (`--cycle-rest-seconds` changes it), minus the footprint after warming the same fixed set of ten tasks.
The scene checks that the items in each history did not change. `memoryCycle.samples` in each round's
extra data records footprint about every 30 revisits. Longer runs use the same process rather than
restarting it; `--repeat` still starts a new process for each independent run. A rise is evidence to
investigate, not by itself proof of a leak. The new input and recovery measures initially establish a
baseline; they do not invent accepted performance budgets from their first run.

The memory cycle posts process-local `applicationDefined` events after its programmatic interactions
and waits for its baseline and recovery boundaries to be consumed. AppKit normally releases temporary
objects at event-loop boundaries ([Apple's memory management guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html)).
An offscreen driver with no input events can otherwise retain autoreleased text drawing objects while
the views and layout managers themselves have already been released. Posted and received event counts
are recorded and must agree. These events are only inside the QA app; no keyboard, mouse, or system-wide
event is generated, and the window remains off screen. `--no-event-pulse` retains the old driver as a
diagnostic control, not a comparable performance baseline.

`--hang-log off` disables the main-thread diagnostic watcher in the QA process only. `--memory-census`
records cumulative creations, live objects and releases for task/turn hostings and prose/TextKit objects.
It keeps only weak references and discards dead entries at coarse checkpoints. Both settings and the
actual diagnostic state are included in the result. Census and heap-inspection runs are diagnostic
profiles; use the same settings for comparisons and keep them separate from normal baseline runs.

**Launch** (`launch.*`, from the kernel's start time of the process): to the model being made
(`processStartToModelMs`), to the app finishing launching (`processStartToFinishedLaunchingMs`), to the
window's first task (`processStartToWindowMs`), to the first frame the main thread served after laying the
window out (`processStartToFirstFrameMs`), and to a main thread quiet for a second, with no pass over 16 ms
(`processStartToSettledMs`). A QA copy launched in the background makes its window only when opened
again, so the script opens it as soon as the app has finished launching; the window timings include that
round trip. A fresh QA copy's first launch reads and checks its code for the first time and takes two to
three times as long, so the script launches it once before the scenes and does not measure that launch.
The `launch` scene is the one with a full sidebar and a long conversation.

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
- Opening a long Codex task the window let go stops it for under half a second
  (`codex-switch/switch`, `switches.longestPassMedianMs`): the conversation builds the latest rows of
  the long turn, not all of it, which took 0.9 seconds.
- Nine streamed turns in long Codex tasks, opened and let go again and again, grow the app by under
  250 MiB (`codex-switch/stream-switch`); what a task let go of when its views went was kept before,
  and the same phase grew by 550 MiB.
- An idle window, with or without running tasks, stays under 1% and 3% of a core; scrolling the long
  sidebar keeps its 95th percentile pass under a 60 Hz frame and no pass over 50 ms.
- Neither a Codex task streaming nor the sidebar scrolling evaluates the window (`bodies.mainWindowCount`
  0 in `stream-codex/streaming`, `sidebar/scroll` and `sidebar/scroll-streaming`): the window lists every task,
  and one evaluation of it with the long sidebar held the main thread for over 50 ms.
- The limits are for a debug build on an Apple silicon Mac at the load a working day leaves (load
  average up to about 25 on 12 cores). Change a limit only with a reason in the commit that changes it:
  a scene that does more, or a cost that was found and accepted.

A budget can fail on the main branch: then the bench has found a cost to fix, and the fix is the change
that brings the number under its limit. The result of the fix's branch compared with the main branch's
(`--compare main`) shows what it changed.

Every planned round and phase must have a result and a process sample, and every budgeted metric must
be finite in every round. A missing round cannot disappear into the median of the other rounds. The
in-process test command must exit successfully, each selected test must report that it passed, and
each required measurement must be recorded. Skips, stale test selectors, missing records and malformed
measurements fail the run. These outcome contracts can be checked without running the app:
`python3 -B scripts/perf-bench/test_report.py`.

## 5. Reading a result

The summary prints, for every phase, Yardlet's CPU, the app's footprint, the main thread's CPU and long
passes, frames and the events' CPU time, beside the earlier result, and marks a number **worse** when it
grew by more than the tolerance and by more than its unit's floor: 2 ms, 1 percentage point, 15 MiB, 20
a second, 2 for a count, and 50 ms for launch timings. Every compared number is in the result's
`comparison`, the summary lists the worse ones it did not show, and `better` lists numbers that shrank as
much.

New results retain each scene's `roundData`, including its numeric values, process samples and load,
beside the median summary. Inspect those rounds for outliers; the budget itself still applies to the
median. Old result JSON files remain usable as comparisons. Collecting old raw folders without a run
plan cannot establish that every intended check ran and therefore reports a failed validity check.
Compare the same phase durations, especially `parameters.memoryCycleSeconds`; a 30-minute cycle is not
equivalent to the default one-minute cycle. Phase pictures are retained beside every round's result
when `--keep` is used.



- Compare runs on the same Mac, with the same build configuration, at a similar load; the summary says
  when the two runs' load differed much. A debug build is slower than a release build; the bench is for
  finding what changed, not for absolute speed.
- A single run can move by 10% or more. Before calling a number a regression, run the scene again with
  `--repeat 3` (each number is then the median of the rounds) on both commits.
- A scene with `problems`, or a phase whose `published` count is near zero while it should stream,
  measured something other than what it says; fix the scene before reading its numbers.
- Each phase leaves a picture of the window at its end, `<n>-<phase>.png`, in the scene's folder under
  `.build/perf-bench/run/browser-host-qa/bench/scenes/` (kept with `--keep`). AppKit draws it, the
  browser's pages included, so it needs no screen recording; it shows what a phase measured.

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
numbers to the file as a JSON line (`PerfBenchRecord`). The bench runs the ones `contract.json` lists under `micro` and
collects their records; `TranscriptProseResizePerformanceTests` and `ScrollFrameCostTests` are not in that list and
run by hand:

| Benchmark | Measures |
|---|---|
| `CodexTimelineMergeCostTests` | merging 500 saved Codex cards into one streamed state |
| `ConcurrentStreamingPerformanceTests/testBenchmarkTenConcurrentStreamingTasks` | ten tasks streaming at once through the adapters, one shown |
| `LongCodexThreadPerformanceTests/testBenchmarkLongCodexThreadStreaming` | one Codex update against a 300-turn thread, by route, and on the app's route the provider events that wake the main actor each second |
| `ConversationStreamingCostTests` | a Codex fragment in a turn of 3 and of 72 calls, and beside a scrolling list |
| `ConversationBlankFrameTests/testBenchmarkSwitchingToALongConversation` | opening a 20- and a 300-turn task |
| `ConversationBlankFrameTests/testBenchmarkStreamingInTheWholeWindow` | what drawing one publication costs the window under 1, 9 and 300 turns |
| `ConversationBlankFrameTests/testBenchmarkLargeToolCallsStreamingInTheWholeWindow` | a turn of six tool calls after 300 turns, from its message to its end, with short calls and with 10,000 to 60,000 characters in and out of each, a plan limit reported close after every call; the passes over 250 ms and over a second |
| `ConversationBlankFrameTests/testBenchmarkHoverReadsArrivingWhileTheSidebarScrolls` | saved conversations read ahead while a sidebar of 828 tasks scrolls |
| `ConversationBlankFrameTests/testBenchmarkAnEarlierPageArriving` | an earlier page of a 60-turn Codex task arriving at the top |
| `ConversationReopenGapRenderingTests/testBenchmarkOpeningATaskWhoseTurnsWereLetGo` | reopening a task after four others were opened |
| `LongTranscriptRenderPerformanceTests` | laying out and streaming a 400-turn Claude Code transcript |
| `TranscriptProseResizePerformanceTests` | eleven width changes of a 1,000-paragraph message and an 11,086-item conversation, with and without live-resize deferral; exact final heights, middle/end reading positions and light/dark renders |
| `StreamingTurnRenderPerformanceTests` | a Claude Code fragment after 120 calls in its turn, which fails over 15 ms of the main thread's time |
| `WindowStructureQATests/testBenchmarkTheSidebarCrossingItsTop` | the sidebar of 828 tasks crossing its top |
| `WindowStructureQATests/testBenchmarkAStateChangeInASidebarOfThousands` | a task starting or ending a turn in a sidebar of 3,000 tasks in 30 projects, grouped by project and by state |
| `ScrollFrameCostTests/testBenchmarkScrollingALongConversation` | a reader's scroll through 60 drawn turns of a 200-turn conversation: the turns that report their place each step, the timeline's evaluations and the main thread's time |
| `ScrollFrameCostTests/testBenchmarkScrollingTheSidebarUnderARestingPointer` | a reader's scroll of a sidebar of 400 tasks, with no pointer and with the pointer resting on the list: the rows drawn again and the rows that report their place each step, and the main thread's time |
| `SubagentStatePerformanceTests` | a long Codex subagent's state handled by the app, beside three others (also a check that runs with every `swift test`) |

`ScrollFrameCostTests` is run by hand and is not in the bench's plan. The bench's `sidebar` scene scrolls a
window no pointer is over, so it does not see what rows passing under a resting pointer cost; this
benchmark hands the unshown window a pointer event at the same place after each step, where SwiftUI
works hover out again by itself after each layout of a window on screen. SwiftUI takes no hover while
the system hides the pointer, as it does while someone types, and the benchmark then skips.

`NHC_PERF_BENCH_SECONDS` shortens the streaming benchmarks; the bench sets it to 20. A new benchmark
skips without `NHC_PERF_BENCH=1`, prints what it measured, and calls `PerfBenchRecord.write` with numbers
named by their unit, so the bench compares them too. A scene of the whole app goes in `PerfBenchFixture`
instead, when the cost needs the real window, adapters and processes; give it budgets in `budgets.json`.

`TranscriptProseResizePerformanceTests` invokes AppKit's live-resize start and end hooks in both
variants, in an unshown window. The control switches off only the new deferral policy through a
DEBUG measurement flag; it still performs AppKit's inherited lifecycle work. Set
`NHC_PERF_BENCH_REPEATS=3` for repeated pairs, `NHC_PERF_BENCH_ORDER=reverse` to put the candidate
first, or `NHC_PERF_BENCH_MODE=baseline` / `candidate` to run one variant when alternating separately
built test binaries. These measurements do not synthesize a physical window drag.

Each case allows main-actor geometry tasks to settle before measurement. After release, the active
interval probe stays on while scheduled geometry work completes. After closing the case, the fixture
waits for its host, view and window to be released, clears its explicitly owned conversation row cache,
and waits for all prose views and layout managers to be released before starting another case. This
keeps the renderer's cache of recent conversations from transferring teardown work to a later case.
It publishes no provider events; it measures synchronous resize wall/CPU time, width reflows,
row measurements and body reevaluations. Its finish time includes eight 30 ms run-loop windows while settling the window.
Release measurements separate callback work, each layout pass, and each run-loop window, including
thread CPU time. A run-loop observer records continuous active intervals ending at `beforeWaiting`
and starting at `afterWaiting`, including direct callback/layout work before the first wait and
between run-loop entries. `releaseMaxActiveMs` excludes observed waiting; `finishWallMs` does not.
The final images are written to
`.build/prose-width/`. This isolates the layout policy.

During native window live resize, visible prose keeps its last exact layout, clipped to its offered
bounds. Visibility is intersection with the enclosing scroll viewport; a retained turn's `visibleRect`
can include offscreen text. Hidden views and views without a window or enclosing scroll view do not
defer layout. Offscreen prose keeps measuring normally so release does not reflow all retained turns
at once.
The final width is measured after tracking ends. A content change ends deferral immediately,
so streamed text stays current. Sidebar and split-divider drags do not invoke this AppKit lifecycle
and still measure their intermediate widths. Exact final layout and measurement of many retained
turns can still block the main thread.

Batching offscreen reflow would require coordinating changing row heights with the reading anchor
across every batch. This path keeps its existing exact synchronous sizing; the optimization does not
remove the cost of measuring many retained turns during a drag.

## 8. Observing a running app

`swiftc -O scripts/perf-bench/observe.swift -o .build/perf-observe` builds a separate read-only sampler.
`.build/perf-observe /Applications/Yardlet.app 3600 5 > observation.jsonl` observes for one wall-clock
hour at a five-second interval, without starting, restarting or operating the app. It writes process
group totals and a per-process breakdown every twelfth sample; command arguments and conversation
contents are never written. CPU time units are checked against `getrusage` at startup. Each snapshot
drains its autorelease pool and only live identities and previous counters are kept, so Foundation's
temporary bridge objects cannot accumulate over a long command-line loop.

Observer cost is reported separately. Treat a growing observer, missing samples, app restarts or changed
builds as measurement limitations. This resource sampler alone does not collect the app's main-thread
diagnostic log. Those busy intervals must remain distinct from perceived freezes.
