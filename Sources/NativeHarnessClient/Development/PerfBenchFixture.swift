#if DEBUG
import AppKit
import Darwin
import Foundation
import QuartzCore
import YardletAgentTools

/// DEBUG-only performance bench of the whole app (`--ui-fixture=perf --ui-fixture-perf-scene=<scene>
/// --ui-fixture-perf-dir=<bench folder>`), which `scripts/perf-bench/run.sh` runs in a QA bundle with a
/// temporary home, off every screen. Each scene puts the window in one fixed state and holds it for its
/// phases while the app measures its main thread (each run loop pass from waking to sleeping, and the
/// thread's CPU) and, where frames matter, how late the main thread serves a 60 Hz display link. The
/// script samples the process tree's CPU and memory over the same phases. Tasks that stream talk through
/// the real adapters to the fake CLIs in `<bench folder>/bin` (scripts/perf-bench/fake-codex.py and
/// fake-claude.py); no model is asked anything. See docs/PERFORMANCE_BENCH.md. Product builds never
/// compile it.
enum PerfBenchFixture {
    static let argument = "--ui-fixture=perf"

    enum Scene: String, CaseIterable, Sendable {
        /// Launch to the first frame and to a quiet main thread, then the window at rest: 200 tasks and a
        /// long Claude Code conversation shown.
        case launch
        /// The window at rest, then with a Claude Code task (shown) and a Codex task running a turn
        /// that waits.
        case idleRunning = "idle-running"
        /// A Claude Code answer streaming at the end of a 60-turn conversation, then on while the window
        /// shows another task.
        case streamClaude = "stream-claude"
        /// A Codex answer streaming at the end of a 60-turn thread.
        case streamCodex = "stream-codex"
        /// A Codex answer streaming in a task whose 500 saved cards every streamed state merges.
        case codexHistory = "codex-history"
        /// A Codex subagent (`run_agent`) of the shown Claude Code task, whose turn already holds 400
        /// items, streaming on while the task's own turn waits for it.
        case subagent
        /// A sidebar of 400 tasks in 40 projects, with 400 archived tasks, scrolled up and down, then the
        /// same while a Codex answer streams.
        case sidebar
        /// Six pages open in the task's browser panel, shown and then hidden.
        case browserTabs = "browser-tabs"
        /// Ten Codex tasks, each a turn of 400 finished commands and the work and answers a 400-second
        /// stream left after them, opened one after another; then three of them at a time stream a new
        /// answer while the window goes from task to task.
        case codexSwitch = "codex-switch"
        /// Reopen a fixed set of long tasks, then rest, without adding history during measurement.
        case memoryCycle = "memory-cycle"
        /// Edit the actual composer while a fake Claude answer streams in the same window.
        case composerInput = "composer-input"
        /// A 60-turn Claude Code conversation of long answers, code blocks, tables, links and tool output,
        /// scrolled up to its top and back down as a reader's trackpad does, then the same while its
        /// last turn streams.
        case conversationScroll = "conversation-scroll"
    }

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }
    static var scene: Scene? { value("ui-fixture-perf-scene").flatMap(Scene.init(rawValue:)) }
    static var directory: URL {
        value("ui-fixture-perf-dir").map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "yardlet-perf-bench", directoryHint: .isDirectory)
    }

    static let shownTaskID = UUID(uuidString: "0FA1B2C3-0000-4000-8000-00000000F001")!
    static let otherRunningTaskID = UUID(uuidString: "0FA1B2C3-0000-4000-8000-00000000F002")!
    static let claudeSessionID = "0fa1b2c3-0000-4000-8000-00000000c001"
    static let otherClaudeSessionID = "0fa1b2c3-0000-4000-8000-00000000c002"
    static let codexThreadID = "perf-codex-thread"
    static let otherCodexThreadID = "perf-codex-other"
    static let switchTaskCount = 10
    static var cycleSeconds: Double {
        let value = Double(value("ui-fixture-perf-cycle-seconds") ?? "60") ?? 60
        return value.isFinite ? min(86_400, max(10, value)) : 60
    }
    static var cycleRestSeconds: Double {
        let seconds = Double(value("ui-fixture-perf-cycle-rest-seconds") ?? "15") ?? 15
        return seconds.isFinite ? min(3_600, max(15, seconds)) : 15
    }
    static var hangLogOverride: Bool? {
        switch value("ui-fixture-perf-hang-log") {
        case "on": true
        case "off": false
        default: nil
        }
    }
    static var eventPulseEnabled: Bool { !CommandLine.arguments.contains("--ui-fixture-perf-no-event-pulse") }

    /// The `codex-switch` scene's tasks; the first is the shown task.
    static func switchTaskID(_ index: Int) -> UUID {
        index == 0 ? shownTaskID : NameBasedUUID.make(namespace: shownTaskID, name: "switch|\(index)")
    }

    /// When the scenario was built, as the app made its model, and when the app finished launching.
    nonisolated(unsafe) static var scenarioBuiltAt: Date?
    nonisolated(unsafe) static var finishedLaunchingAt: Date?

    static func output(for scene: Scene) -> URL {
        directory.appending(path: "scenes/\(scene.rawValue)", directoryHint: .isDirectory)
    }

    /// The app finished launching: `launched` tells the script, which then opens the window. In the
    /// background (`open -g`, `QABackground`) the app makes its window only when it is opened again.
    static func applicationDidFinishLaunching() {
        guard isRequested, let scene else { return }
        finishedLaunchingAt = Date()
        let markers = output(for: scene).appending(path: "markers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try? Data().write(to: markers.appending(path: "launched"))
    }

    private static func value(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }

    // MARK: - Scenario

    static func scenario() -> VisualFixtureScenario {
        scenarioBuiltAt = Date()
        let scene = scene ?? .launch
        let fileManager = FileManager.default
        let names = ["parser", "web-app", "api", "design-system", "docs", "mobile", "infra", "data"]
        let projects = (0..<(scene == .sidebar ? 40 : names.count)).map { index in
            directory.appending(path: "projects/\(names[index % names.count])\(index < names.count ? "" : "-\(index / names.count)")",
                                directoryHint: .isDirectory)
        }
        for folder in projects {
            // Keep Git-origin reads inside the fixture. Otherwise a worktree under the checkout can
            // inherit its outer .git file and ask a background QA copy to read the person's repository.
            let git = folder.appending(path: ".git", directoryHint: .isDirectory)
            try? fileManager.createDirectory(at: git.appending(path: "refs/heads"), withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: git.appending(path: "objects"), withIntermediateDirectories: true)
            try? Data("ref: refs/heads/bench\n".utf8).write(to: git.appending(path: "HEAD"))
            try? Data("[core]\nrepositoryformatversion = 0\nbare = false\n".utf8).write(to: git.appending(path: "config"))
        }
        let threads = directory.appending(path: "threads", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: threads, withIntermediateDirectories: true)
        let codex = directory.appending(path: "bin/codex")
        let claude = directory.appending(path: "bin/claude")
        let none = URL(filePath: "/usr/bin/true")
        let now = Date()

        let backgroundCount = switch scene {
        case .sidebar: 400
        case .launch: 200
        default: 40
        }
        // The sidebar scene also has as many archived tasks; every fifth task's parent is one of them.
        let archivedCount = scene == .sidebar ? backgroundCount : 0
        func archivedID(_ index: Int) -> UUID { NameBasedUUID.make(namespace: shownTaskID, name: "archived|\(index)") }
        var sessions: [SessionRecord] = (0..<backgroundCount).map { index in
            SessionRecord(
                id: NameBasedUUID.make(namespace: shownTaskID, name: "background|\(index)"),
                harness: index.isMultiple(of: 3) ? .codex : .claudeCode, workspaceURL: projects[index % projects.count],
                runtimeExecutableURL: none, title: "Task \(index): " + titles[index % titles.count],
                titleOrigin: .automatic, status: .ready,
                createdAt: now.addingTimeInterval(-Double(index + 1) * 420 - 600),
                updatedAt: now.addingTimeInterval(-Double(index + 1) * 420),
                hasUnreadUpdate: index.isMultiple(of: 9), completionState: .completed,
                parentTaskID: archivedCount > 0 && index.isMultiple(of: 5) ? archivedID(index) : nil)
        }
        let archived: [SessionRecord] = (0..<archivedCount).map { index in
            SessionRecord(
                id: archivedID(index), harness: index.isMultiple(of: 2) ? .codex : .claudeCode,
                workspaceURL: projects[index % projects.count], runtimeExecutableURL: none,
                title: "Archived \(index): " + titles[(index + 4) % titles.count], titleOrigin: .automatic, status: .ready,
                createdAt: now.addingTimeInterval(-Double(index + 1) * 3_600 - 86_400),
                updatedAt: now.addingTimeInterval(-Double(index + 1) * 3_600 - 80_000), completionState: .completed)
        }
        var transcripts: [UUID: [TranscriptEntry]] = [:]
        var savedCards: [UUID: [CodexPersistedTimelineItem]] = [:]

        func claudeTask(_ id: UUID, title: String, runtime: URL, sessionID: String, turns: Int,
                        links: Bool = false) -> SessionRecord {
            transcripts[id] = LongConversationFixture.claude(turns: turns, seed: "perf-\(id.uuidString.prefix(4))", links: links)
            return SessionRecord(id: id, harness: .claudeCode, workspaceURL: projects[0], runtimeExecutableURL: runtime,
                                 title: title, titleOrigin: .automatic, status: .ready, createdAt: now.addingTimeInterval(-3_600),
                                 updatedAt: now, providerSessionID: sessionID)
        }
        func codexTask(_ id: UUID, title: String, threadID: String, turns: [JSONValue]) -> SessionRecord {
            if let data = try? JSONEncoder().encode(turns) {
                try? data.write(to: threads.appending(path: "\(threadID).json"))
            }
            return SessionRecord(id: id, harness: .codex, workspaceURL: projects[0], runtimeExecutableURL: codex,
                                 title: title, titleOrigin: .automatic, status: .ready, createdAt: now.addingTimeInterval(-3_600),
                                 updatedAt: now, providerSessionID: threadID)
        }

        let shown: [SessionRecord]
        switch scene {
        case .launch:
            shown = [claudeTask(shownTaskID, title: "Fix the parser's empty input", runtime: none,
                                sessionID: claudeSessionID, turns: 60)]
        case .idleRunning:
            shown = [
                claudeTask(shownTaskID, title: "Fix the parser's empty input", runtime: claude,
                           sessionID: claudeSessionID, turns: 20),
                codexTask(otherRunningTaskID, title: "Tidy the lexer", threadID: otherCodexThreadID,
                          turns: (0..<10).map { LongConversationFixture.codexTurn($0) })
            ]
        case .streamClaude, .composerInput:
            shown = [
                claudeTask(shownTaskID, title: "Fix the parser's empty input", runtime: claude,
                           sessionID: claudeSessionID, turns: 60),
                claudeTask(otherRunningTaskID, title: "Tidy the lexer", runtime: none, sessionID: otherClaudeSessionID,
                           turns: 20)
            ]
        case .streamCodex:
            shown = [codexTask(shownTaskID, title: "Fix the parser's empty input", threadID: codexThreadID,
                               turns: (0..<60).map { LongConversationFixture.codexTurn($0) })]
        case .codexHistory:
            let turns = LongConversationFixture.codexCommandTurns([263, 237], outputLength: 5_000)
            savedCards[shownTaskID] = LongConversationFixture.savedCards(of: turns)
            shown = [codexTask(shownTaskID, title: "Build every module", threadID: codexThreadID, turns: turns)]
        case .subagent:
            shown = [claudeTask(shownTaskID, title: "Review the parser with a subagent", runtime: claude,
                                sessionID: claudeSessionID, turns: 20)]
        case .sidebar:
            shown = [codexTask(shownTaskID, title: "Fix the parser's empty input", threadID: codexThreadID,
                               turns: (0..<4).map { LongConversationFixture.codexTurn($0) })]
        case .conversationScroll:
            shown = [claudeTask(shownTaskID, title: "Fix the parser's empty input", runtime: claude,
                                sessionID: claudeSessionID, turns: 60, links: true)]
        case .browserTabs:
            shown = [claudeTask(shownTaskID, title: "Check the pages", runtime: none, sessionID: claudeSessionID, turns: 5)]
        case .codexSwitch, .memoryCycle:
            shown = (0..<switchTaskCount).map { index in
                let threadID = "\(codexThreadID)-\(index)"
                let turn = LongConversationFixture.streamedCodexTurn(id: "\(threadID)-turn", commands: 400, seconds: 400)
                savedCards[switchTaskID(index)] = LongConversationFixture.savedCards(of: [turn])
                return codexTask(switchTaskID(index), title: "Stream \(index): " + titles[index % titles.count],
                                 threadID: threadID, turns: [turn])
            }
        }
        sessions.insert(contentsOf: shown, at: 0)

        var scenario = VisualFixtureScenario(
            sessions: sessions, transcripts: transcripts, errors: [:], codexPresentation: [:], codexQueues: [:],
            codexCapabilities: [:], providerCapabilities: [:], providerUsage: [:], initialTaskSurface: nil,
            initialCodexCapabilitySection: nil, initialCodexHistoryQuery: nil, initialSettingsSection: nil,
            initialNotificationAuthorization: .authorized)
        scenario.projects = ProjectSnapshot(projects: projects.map { Project(name: $0.lastPathComponent, primaryRoot: $0) },
                                            didImportFolderPreferences: true)
        scenario.codexTimelineItems = savedCards
        scenario.archivedSessions = archived
        return scenario
    }

    private static let titles = [
        "look at the parser module", "fix the flaky checkout test", "document the refunds endpoint",
        "upgrade the Postgres driver", "check color tokens for contrast", "add a tooltip component",
        "rate-limit the search endpoint", "serve product images in AVIF", "split the settings sections"
    ]

    /// Settings for the bench, emptied at every launch, so every run starts from the same ones.
    static func preferences() -> UserDefaults {
        let name = "NativeHarnessClient.PerfBench"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The saved Codex cards, in files as the app keeps them, emptied at every launch.
    static func timelineItemRepository() -> FileCodexTimelineItemRepository {
        let folder = directory.appending(path: "state/codex-timeline-items", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        return FileCodexTimelineItemRepository(directoryURL: folder)
    }

    /// The fake CLIs are the harnesses' runtimes, which a subagent starts on.
    @MainActor
    static func selectRuntimes(in selections: RuntimeSelectionStore) {
        selections.select(directory.appending(path: "bin/codex"), for: .codex)
        selections.select(directory.appending(path: "bin/claude"), for: .claudeCode)
    }

    /// The shown task is open from the first frame, and the archived tasks are read as a launch reads them.
    @MainActor
    static func prepare(_ model: AppModel) {
        model.splits.activate(.session(shownTaskID))
        Task { try? await model.store.loadArchivedSessions() }
        EventCostLog.isEnabled = true
    }

    @MainActor private static var started = false

    @MainActor
    static func install(in model: AppModel) {
        guard isRequested, !started, let scene else { return }
        started = true
        // `--ui-fixture-perf-hold`: the scene's window stays as it was set up, for a person to try, and
        // nothing is measured.
        guard !CommandLine.arguments.contains("--ui-fixture-perf-hold") else { return }
        let runner = PerfBenchRunner(model: model, scene: scene, output: output(for: scene))
        Task { @MainActor in await runner.run() }
    }
}

// MARK: - Runner

@MainActor
private final class PerfBenchRunner {
    let model: AppModel
    let scene: PerfBenchFixture.Scene
    let output: URL
    private var record: [String: Any] = [:]
    private var phases: [[String: Any]] = []
    private var problems: [String] = []
    private let steps = MainThreadSteps()
    private var window: NSWindow?

    init(model: AppModel, scene: PerfBenchFixture.Scene, output: URL) {
        self.model = model
        self.scene = scene
        self.output = output
    }

    func run() async {
        let installedAt = Date()
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? Data().write(to: output.appending(path: "markers/window"))
        note("window task")
        steps.start()
        record["scene"] = scene.rawValue
        record["pid"] = Int(getpid())
        record["diagnostics"] = ["hangLogEnabled": MainThreadHangLog.isEnabled, "memoryCensusEnabled": PerfMemoryCensus.isEnabled,
                                  "eventPulseEnabled": PerfBenchFixture.eventPulseEnabled]
        let processStart = ProcessClock.startDate()
        guard await waitUntil(.seconds(20), { self.mainWindow() != nil }), let window = mainWindow() else {
            problems.append("no window")
            return finish()
        }
        self.window = window
        window.setContentSize(NSSize(width: 1440, height: 900))
        if QABackground.isOn { QABackground.moveOffScreen(window) }
        record["window"] = ["width": 1440, "height": 900]
        if let screen = NSScreen.main {
            record["screen"] = ["name": screen.localizedName, "maximumFramesPerSecond": screen.maximumFramesPerSecond,
                                "scale": screen.backingScaleFactor] as [String: Any]
        }

        // Launch: to the window's first task, to the first frame the main thread served after laying it out,
        // and to a main thread quiet for a second (no pass over 16 ms).
        window.contentView?.layoutSubtreeIfNeeded()
        let firstFrame = FrameProbe()
        firstFrame.start()
        _ = await waitUntil(.seconds(5), poll: .milliseconds(2)) { firstFrame.frames > 0 }
        let firstFrameAt = Date()
        firstFrame.stop()
        _ = await waitUntil(.seconds(30), poll: .milliseconds(50)) { self.steps.quiet(for: 1) }
        let settledAt = Date().addingTimeInterval(-1)
        var launch: [String: Any] = [
            "processStartToWindowMs": milliseconds(installedAt, since: processStart),
            "processStartToFirstFrameMs": milliseconds(firstFrameAt, since: processStart),
            "processStartToSettledMs": milliseconds(settledAt, since: processStart)
        ]
        if let built = PerfBenchFixture.scenarioBuiltAt {
            launch["processStartToModelMs"] = milliseconds(built, since: processStart)
        }
        if let launched = PerfBenchFixture.finishedLaunchingAt {
            launch["processStartToFinishedLaunchingMs"] = milliseconds(launched, since: processStart)
        }
        record["launch"] = launch
        note("launch measured")

        switch scene {
        case .launch:
            await phase("settled", seconds: 10)
        case .idleRunning:
            await phase("idle", seconds: 15)
            await send("perf hold", to: PerfBenchFixture.shownTaskID)
            await send("perf hold", to: PerfBenchFixture.otherRunningTaskID)
            let running = await waitUntil(.seconds(20)) {
                self.isRunning(PerfBenchFixture.shownTaskID) && self.isRunning(PerfBenchFixture.otherRunningTaskID)
            }
            if !running { problems.append("the tasks did not start running") }
            note("tasks running: \(running)")
            try? await Task.sleep(for: .seconds(3))
            await phase("idle-running", seconds: 15)
        case .streamClaude:
            await stream(into: PerfBenchFixture.shownTaskID, seconds: 20, streamingFor: 50)
            // The answer streams on while the window shows another task.
            model.splits.activate(.session(PerfBenchFixture.otherRunningTaskID))
            try? await Task.sleep(for: .seconds(2))
            await phase("streaming-elsewhere", seconds: 10, frames: true)
        case .streamCodex:
            await stream(into: PerfBenchFixture.shownTaskID, seconds: 20)
        case .codexHistory:
            await stream(into: PerfBenchFixture.shownTaskID, seconds: 20) {
                let loaded = await self.waitUntil(.seconds(30)) { self.codexItems(PerfBenchFixture.shownTaskID) >= 500 }
                if !loaded {
                    self.problems.append("the saved thread did not load: \(self.codexItems(PerfBenchFixture.shownTaskID)) items")
                }
                self.note("saved thread loaded: \(loaded)")
            }
        case .subagent:
            await runSubagent()
        case .sidebar:
            await scrollSidebar()
        case .browserTabs:
            await openBrowserTabs()
        case .codexSwitch:
            await switchTasks()
        case .memoryCycle:
            await memoryCycles()
        case .composerInput:
            await composerInput()
        case .conversationScroll:
            await scrollConversation()
        }
        finish()
    }

    // MARK: Scenes

    /// - Parameter streamingFor: how long the fake streams, by default 20 seconds more than the phase.
    private func stream(into task: UUID, seconds: Double, streamingFor: Int? = nil,
                        beforeMeasuring: (() async -> Void)? = nil) async {
        let published = model.publicationCounts
        await send("perf stream \(streamingFor ?? Int(seconds) + 20)", to: task)
        let started = await waitUntil(.seconds(20)) {
            let counts = self.model.publicationCounts
            return counts.transcripts + counts.codexStates > published.transcripts + published.codexStates + 10
        }
        if !started { problems.append("nothing streamed into the task") }
        note("streaming started: \(started)")
        await beforeMeasuring?()
        try? await Task.sleep(for: .seconds(3))
        await phase("streaming", seconds: seconds, frames: true)
    }

    /// The shown task's turn runs (as it would while it waits on `run_agent`) and starts a Codex subagent
    /// whose turn begins with 400 finished items, then streams.
    private func runSubagent() async {
        await send("perf hold", to: PerfBenchFixture.shownTaskID)
        _ = await waitUntil(.seconds(20)) { self.isRunning(PerfBenchFixture.shownTaskID) }
        guard let task = model.store.sessions.first(where: { $0.id == PerfBenchFixture.shownTaskID }) else { return }
        let caller = SessionToolCaller(
            id: task.id, hostTaskID: task.id, harness: task.harness, workspaceURL: task.workspaceURL,
            roots: [task.workspaceURL], projectID: model.projects.project(for: task)?.id, title: task.title, depth: 0,
            permission: .standard, deadline: .now + .seconds(600))
        note("run_agent")
        let answer = await model.runAgent(.object([
            "harness": .string("codex"), "prompt": .string("perf stream 45 400"), "background": .bool(true)
        ]), caller: caller)
        let text = answer.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
        note("run_agent answered: \(text.prefix(160))")
        if answer.isError { problems.append("run_agent: \(text.prefix(160))") }
        let started = await waitUntil(.seconds(30)) {
            (EventCostLog.summary()["agentRunState"] as? [String: Any])?["events"] as? Int ?? 0 > 50
        }
        if !started { problems.append("the subagent sent no states") }
        try? await Task.sleep(for: .seconds(3))
        await phase("streaming", seconds: 20, frames: true)
    }

    private func scrollSidebar() async {
        guard let window, let scroll = sidebarScrollView(in: window) else {
            problems.append("no sidebar scroll view")
            return
        }
        let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        record["sidebar"] = ["listHeight": scroll.documentView?.frame.height ?? 0, "visibleHeight": scroll.contentView.bounds.height]
        if bottom < 2_000 { problems.append("the sidebar scrolls only \(Int(bottom)) pt") }
        var offset: CGFloat = 0
        var direction: CGFloat = 1
        // 1,200 pt a second at 60 Hz, down to the end and back, as a long trackpad swipe moves it.
        let move: (CADisplayLink) -> Void = { _ in
            offset += direction * 20
            if offset >= bottom { offset = bottom; direction = -1 }
            if offset <= 0 { offset = 0; direction = 1 }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await phase("scroll", seconds: 10, frames: true, onFrame: move)
        let published = model.publicationCounts
        await send("perf stream 30", to: PerfBenchFixture.shownTaskID)
        let started = await waitUntil(.seconds(20)) { self.model.publicationCounts.codexStates > published.codexStates + 10 }
        if !started { problems.append("nothing streamed into the task") }
        try? await Task.sleep(for: .seconds(2))
        await phase("scroll-streaming", seconds: 10, frames: true, onFrame: move)
    }

    /// The conversation scrolled as a reader's trackpad scrolls it: a scroll wheel event of 20 points
    /// each frame (1,200 points a second at 60 Hz), with the phases of a gesture, up to the top and back
    /// down to the end, again and again. The events go to the conversation's scroll view as the window
    /// would hand them on, so following lets go, earlier turns come in at the top and the view keeps its
    /// place as they arrive, as for a reader. Then the same while the last turn streams; the message that
    /// starts it brings the view back to the end.
    private func scrollConversation() async {
        guard let window, let scroll = conversationScrollView(in: window) else {
            problems.append("no conversation scroll view")
            return
        }
        func metrics() -> (top: CGFloat, bottom: CGFloat) {
            let visible = scroll.documentVisibleRect
            let height = scroll.documentView?.frame.height ?? 0
            let flipped = scroll.documentView?.isFlipped ?? true
            return flipped ? (visible.minY, height - visible.maxY) : (height - visible.maxY, visible.minY)
        }
        record["conversation"] = ["listHeight": scroll.documentView?.frame.height ?? 0,
                                  "visibleHeight": scroll.contentView.bounds.height]
        if metrics().top < 2_000 { problems.append("the conversation scrolls only \(Int(metrics().top)) pt") }
        var upward = true
        var reversals = 0
        var gesture: CGScrollPhase = .began
        // What the scrolling did, to see that the scene measured what it says: how far the view moved
        // a frame at a time, how often it jumped (earlier turns arriving above the place kept), and how
        // far from the end it got (following that does not let go keeps it there while a turn streams).
        var moved: CGFloat = 0
        var jumps = 0
        var farthestFromEnd: CGFloat = 0
        var nearestToTop = CGFloat.greatestFiniteMagnitude
        var lastTop: CGFloat?
        func traveled(from height: CGFloat) -> [String: Any] {
            // With no frame served (a display asleep stops its display link) nothing moved.
            ["movedPoints": Int(moved), "jumps": jumps, "reversals": reversals,
             "farthestFromEndPoints": Int(farthestFromEnd),
             "nearestToTopPoints": nearestToTop.isFinite && nearestToTop < 1e9 ? Int(nearestToTop) : -1,
             "listHeightStart": Int(height), "listHeightEnd": Int(scroll.documentView?.frame.height ?? 0)]
        }
        func resetTravel() {
            (moved, jumps, farthestFromEnd, nearestToTop, lastTop) = (0, 0, 0, .greatestFiniteMagnitude, nil)
        }
        let move: (CADisplayLink) -> Void = { _ in
            let edges = metrics()
            if let lastTop {
                let step = abs(edges.top - lastTop)
                if step > 100 { jumps += 1 } else { moved += step }
            }
            lastTop = edges.top
            farthestFromEnd = max(farthestFromEnd, edges.bottom)
            nearestToTop = min(nearestToTop, edges.top)
            if upward, edges.top <= 1 {
                upward = false
                reversals += 1
                Self.scrollWheel(scroll, by: 0, phase: .ended)
                gesture = .began
            } else if !upward, edges.bottom <= 1 {
                upward = true
                reversals += 1
                Self.scrollWheel(scroll, by: 0, phase: .ended)
                gesture = .began
            }
            Self.scrollWheel(scroll, by: upward ? 20 : -20, phase: gesture)
            gesture = .changed
        }
        let scrollHeight = scroll.documentView?.frame.height ?? 0
        await phase("scroll", seconds: 10, frames: true, onFrame: move)
        Self.scrollWheel(scroll, by: 0, phase: .ended)
        let scrolled = traveled(from: scrollHeight)
        if moved < 2_000 { problems.append("the conversation scrolled only \(Int(moved)) pt (is the display asleep?)") }
        let published = model.publicationCounts
        await send("perf stream 30", to: PerfBenchFixture.shownTaskID)
        let started = await waitUntil(.seconds(20)) { self.model.publicationCounts.transcripts > published.transcripts + 10 }
        if !started { problems.append("nothing streamed into the task") }
        try? await Task.sleep(for: .seconds(2))
        upward = true
        reversals = 0
        gesture = .began
        resetTravel()
        let streamingHeight = scroll.documentView?.frame.height ?? 0
        await phase("scroll-streaming", seconds: 10, frames: true, onFrame: move)
        Self.scrollWheel(scroll, by: 0, phase: .ended)
        record["conversation"] = ["visibleHeight": scroll.contentView.bounds.height,
                                  "scroll": scrolled, "scroll-streaming": traveled(from: streamingHeight)]
    }

    /// A trackpad's scroll wheel event of `points` (positive moves toward the top) in a gesture's
    /// `phase`, handed to `scroll` as the window hands it on.
    private static func scrollWheel(_ scroll: NSScrollView, by points: Int32, phase: CGScrollPhase) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: points, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(points))
        if let window = scroll.window {
            let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            event.location = window.convertPoint(toScreen: center)
        }
        guard let wheel = NSEvent(cgEvent: event) else { return }
        scroll.scrollWheel(with: wheel)
    }

    private func openBrowserTabs() async {
        guard MacBrowserHost.isAvailable, let base = BrowserHostQAFixture.argument("ui-fixture-browser-url") else {
            problems.append("no browser engine in this build, or no page server")
            return
        }
        let workspace = model.taskWorkspaces.state(for: PerfBenchFixture.shownTaskID)
        var loaded = 0
        for page in ["", "second", "a11y", "large", "tall", "login"] {
            guard let key = workspace.openBrowserTab(address: base + page) else { break }
            let shown = await waitUntil(.seconds(20)) {
                guard let pane = BrowserHostPaneController.current else { return false }
                return pane.key == key && pane.hasTab && !pane.isLoading
            }
            if shown { loaded += 1 }
        }
        record["browser"] = ["pagesLoaded": loaded, "hostTabs": MacBrowserHost.shared.client.openTabCount]
        if loaded < 6 { problems.append("only \(loaded) of 6 pages loaded") }
        try? await Task.sleep(for: .seconds(3))
        await phase("tabs-shown", seconds: 15)
        NotificationCenter.default.post(name: BrowserHostQAFixture.closeBrowserPanel, object: nil)
        try? await Task.sleep(for: .seconds(3))
        await phase("tabs-hidden", seconds: 10)
    }

    /// Each task runs a short turn, as a task a person worked in this launch holds its thread, and is
    /// opened once. Then the window goes from task to task every 1.5 seconds, each opened after the four
    /// the window keeps were opened (`switch`), and the time each opening took of the main thread is
    /// noted; then tasks stream new turns as the window goes on switching (`stream-switch`).
    private func switchTasks() async {
        let tasks = await loadSwitchTasks()
        var opened: [Double] = []
        var longest: [Double] = []
        await phase("switch", seconds: 30, driving: { deadline in
            var index = 0
            while ContinuousClock.now + .milliseconds(1_500) <= deadline {
                let busy = self.steps.busyMilliseconds
                let passes = self.steps.passCount
                self.model.splits.activate(.session(tasks[index % tasks.count]))
                try? await Task.sleep(for: .milliseconds(1_500))
                opened.append(self.steps.busyMilliseconds - busy)
                longest.append(self.steps.longestPass(since: passes))
                index += 1
            }
        })
        if var entry = phases.popLast() {
            entry["switches"] = ["count": opened.count, "busyMedianMs": round2(median(opened)),
                                 "busyMaxMs": round2(opened.max() ?? 0), "longestPassMedianMs": round2(median(longest)),
                                 "longestPassMaxMs": round2(longest.max() ?? 0)]
            phases.append(entry)
        }

        // Three tasks stream each round, while the window keeps switching.
        let rounds = 3
        await phase("stream-switch", seconds: Double(rounds * 40), driving: { deadline in
            var index = 0
            for round in 0..<rounds {
                for slot in 0..<3 { await self.send("perf stream 30", to: tasks[(round * 3 + slot) % tasks.count]) }
                let end = min(deadline, ContinuousClock.now + .seconds(40))
                while ContinuousClock.now + .seconds(2) <= end {
                    self.model.splits.activate(.session(tasks[index % tasks.count]))
                    index += 1
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        })
    }

    private func loadSwitchTasks() async -> [UUID] {
        let tasks = (0..<PerfBenchFixture.switchTaskCount).map(PerfBenchFixture.switchTaskID)
        for task in tasks { await send("perf stream 1", to: task) }
        let loaded = await waitUntil(.seconds(60)) {
            tasks.allSatisfy { self.codexItems($0) > 500 && !self.isRunning($0) }
        }
        if !loaded { problems.append("threads loaded: \(tasks.map(codexItems))") }
        for task in tasks {
            model.splits.activate(.session(task))
            try? await Task.sleep(for: .milliseconds(500))
        }
        note("threads loaded: \(tasks.map(codexItems))")
        try? await Task.sleep(for: .seconds(2))
        return tasks
    }

    private func memoryCycles() async {
        let tasks = await loadSwitchTasks()
        let pulse = PerfBenchFixture.eventPulseEnabled ? BenchEventPulse() : nil
        defer { pulse?.stop() }
        let itemsBefore = tasks.map(codexItems)
        var switches = 0
        var measuredFrom = ContinuousClock.now
        var memoryPoints: [[String: Double]] = []
        var objectPoints: [[String: Any]] = []
        let revisit: (ContinuousClock.Instant) async -> Void = { deadline in
            var index = 0
            while ContinuousClock.now + .seconds(1) <= deadline {
                self.model.splits.activate(.session(tasks[index % tasks.count]))
                try? await Task.sleep(for: .seconds(1))
                pulse?.post()
                index += 1
                switches += 1
                if switches.isMultiple(of: 30) {
                    let elapsed = (ContinuousClock.now - measuredFrom) / .seconds(1)
                    if PerfMemoryCensus.isEnabled {
                        objectPoints.append(["seconds": round2(elapsed), "objects": PerfMemoryCensus.snapshot()])
                    }
                    let footprint = ProcessClock.footprintMiB()
                    memoryPoints.append(["seconds": round2(elapsed), "footprintMiB": round2(footprint)])
                    self.note("memory cycle \(switches) revisits, \(round2(footprint)) MiB")
                }
            }
        }
        await phase("warm", seconds: 30, driving: revisit)
        model.splits.activate(.session(tasks[0]))
        try? await Task.sleep(for: .seconds(3))
        if let pulse {
            pulse.post()
            if !(await waitUntil(.seconds(2), poll: .milliseconds(10), { pulse.received == pulse.posted })) {
                problems.append("AppKit did not consume the baseline event pulse")
            }
            await Task.yield()
        }
        if PerfMemoryCensus.isEnabled { objectPoints = [["seconds": 0, "objects": PerfMemoryCensus.snapshot()]] }
        let baseline = ProcessClock.footprintMiB()
        switches = 0
        measuredFrom = ContinuousClock.now
        memoryPoints = [["seconds": 0, "footprintMiB": round2(baseline)]]
        await phase("revisit", seconds: PerfBenchFixture.cycleSeconds, driving: revisit)
        guard let revisitEnd = (phases.last?["memory"] as? [String: Double])?["footprintEndMiB"],
              let revisitSeconds = phases.last?["seconds"] as? Double else {
            problems.append("memory cycle has no final revisit reading"); return
        }
        memoryPoints.append(["seconds": round2(revisitSeconds), "footprintMiB": revisitEnd])
        model.splits.activate(.session(tasks[0]))
        await phase("recovered", seconds: PerfBenchFixture.cycleRestSeconds, driving: { _ in
            guard let pulse else { return }
            try? await Task.sleep(for: .seconds(1))
            pulse.post()
            if !(await self.waitUntil(.seconds(2), poll: .milliseconds(10), { pulse.received == pulse.posted })) {
                self.problems.append("AppKit did not consume the recovery event pulse")
            }
        })
        guard let recoveredEnd = (phases.last?["memory"] as? [String: Double])?["footprintEndMiB"] else {
            problems.append("memory cycle has no recovered reading"); return
        }
        let retained = recoveredEnd - baseline
        record["memoryCycle"] = ["seconds": PerfBenchFixture.cycleSeconds, "restSeconds": PerfBenchFixture.cycleRestSeconds, "samples": memoryPoints,
                                  "itemsPerTask": itemsBefore, "revisits": switches, "objects": objectPoints,
                                  "eventsPosted": pulse?.posted ?? 0, "eventsReceived": pulse?.received ?? 0] as [String: Any]
        if let pulse, pulse.posted != pulse.received { problems.append("unconsumed AppKit event pulses") }
        if let pulse, pulse.failedPosts > 0 { problems.append("AppKit event pulse creation failed") }
        if var entry = phases.popLast() {
            var memory = entry["memory"] as? [String: Double] ?? [:]
            memory["retainedGrowthMiB"] = round2(retained)
            entry["memory"] = memory
            entry["switches"] = ["completedCount": switches]
            phases.append(entry)
        }
        if itemsBefore != tasks.map(codexItems) { problems.append("history changed during the fixed working-set memory cycle") }
        if switches < 5 { problems.append("too few memory-cycle revisits") }
    }

    /// Application-side dispatch and edit/layout latency. The window stays off screen: this does not
    /// measure hardware input, an input-method service, WindowServer, or display presentation.
    private func composerInput() async {
        guard let window, let content = window.contentView else { problems.append("no composer window"); return }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        guard let field = all(content).compactMap({ $0 as? NSTextField }).filter({
            let frame = $0.convert($0.bounds, to: nil)
            return $0.isEditable && frame.width > 300 && frame.minY < 400
        }).min(by: { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }),
              window.makeFirstResponder(field) else { problems.append("composer field could not take its window's first responder"); return }
        let before = model.publicationCounts.transcripts
        await send("perf stream 50", to: PerfBenchFixture.shownTaskID)
        let running = await waitUntil(.seconds(20)) { self.model.publicationCounts.transcripts > before + 10 }
        if !running { problems.append("composer scene did not start streaming"); return }
        try? await Task.sleep(for: .seconds(2))
        guard let editor = window.firstResponder as? NSTextView, editor.isEditable else {
            problems.append("composer field editor missing"); return
        }
        var queueTimes: [Double] = [], layoutTimes: [Double] = [], responseTimes: [Double] = []
        await phase("typing", seconds: 20, frames: true, driving: { deadline in
            while ContinuousClock.now + .milliseconds(200) <= deadline {
                let useMarkedText = queueTimes.count.isMultiple(of: 2)
                let costs = await withCheckedContinuation { (continuation: CheckedContinuation<(Double, Double, Double), Never>) in
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                        let queued = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        DispatchQueue.main.async {
                            let entered = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                            let range = editor.string.utf16.count > 300 ? NSRange(location: 0, length: editor.string.utf16.count)
                                : NSRange(location: editor.string.utf16.count, length: 0)
                            if useMarkedText {
                                editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: range)
                                editor.insertText("한글 ", replacementRange: NSRange(location: NSNotFound, length: 0))
                            } else {
                                editor.insertText("edit ", replacementRange: range)
                            }
                            content.layoutSubtreeIfNeeded()
                            window.displayIfNeeded()
                            let finished = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                            continuation.resume(returning: (Double(entered - queued) / 1e6, Double(finished - entered) / 1e6,
                                                            Double(finished - queued) / 1e6))
                        }
                    }
                }
                queueTimes.append(costs.0); layoutTimes.append(costs.1); responseTimes.append(costs.2)
            }
        })
        if queueTimes.count < 20 || editor.string.isEmpty { problems.append("composer scene did not apply enough edits") }
        if model.composerDrafts.tasks.draft(for: PerfBenchFixture.shownTaskID).text != editor.string {
            problems.append("composer edits did not reach the task draft")
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : round2(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))])
        }
        if var entry = phases.popLast() {
            if (entry["published"] as? [String: Int])?["transcripts"] ?? 0 <= 0 {
                problems.append("no transcript was published during composer edits")
            }
            entry["input"] = ["editCount": Double(queueTimes.count), "queueP95Ms": percentile(queueTimes, 0.95),
                              "layoutP95Ms": percentile(layoutTimes, 0.95), "responseMedianMs": percentile(responseTimes, 0.5),
                              "responseP95Ms": percentile(responseTimes, 0.95), "responseMaxMs": round2(responseTimes.max() ?? 0)]
            phases.append(entry)
        }
    }

    // MARK: Phases

    /// The views whose bodies a phase counts (`ViewBodyCensus`): the window and the views around the
    /// conversation, and the conversation's timeline, its turns drawn whole, the rows it laid out anew to
    /// measure them, and the turns' hosting views it made.
    private static let countedBodies: [ViewBodyCensus.Body] = [
        .mainWindow, .taskSurface, .sessionRail, .composer, .sidebarRow,
        .conversationTimeline, .conversationTurn, .conversationRowLaidOut, .conversationTurnHosting
    ]

    /// Writes `<n>-<name>.ready` for the script, waits for its `.go` (it starts its sampler then), and
    /// measures for `seconds`.
    private func phase(_ name: String, seconds: Double, frames: Bool = false,
                       onFrame: ((CADisplayLink) -> Void)? = nil,
                       driving: ((ContinuousClock.Instant) async -> Void)? = nil) async {
        let marker = "\(phases.count + 1)-\(name)"
        let markers = output.appending(path: "markers")
        try? JSONSerialization.data(withJSONObject: ["name": name, "seconds": seconds] as [String: Any])
            .write(to: markers.appending(path: "\(marker).ready"), options: .atomic)
        note("phase \(marker) ready")
        let sampled = await waitUntil(.seconds(10), poll: .milliseconds(10)) {
            FileManager.default.fileExists(atPath: markers.appending(path: "\(marker).go").path)
        }
        let probe = frames || onFrame != nil ? FrameProbe() : nil
        probe?.onFrame = onFrame
        let counts = model.publicationCounts
        let shownItems = shownItemCount()
        steps.reset()
        EventCostLog.reset()
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        let objectsAtStart = PerfMemoryCensus.isEnabled ? PerfMemoryCensus.snapshot() : nil
        let started = ContinuousClock.now
        let cpu = ProcessClock.threadCPUSeconds()
        let footprint = ProcessClock.footprintMiB()
        probe?.start()
        await driving?(started + .seconds(seconds))
        if ContinuousClock.now < started + .seconds(seconds) { try? await Task.sleep(until: started + .seconds(seconds)) }
        probe?.stop()
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        let threadCPU = ProcessClock.threadCPUSeconds() - cpu
        let objectsAtEnd = PerfMemoryCensus.isEnabled ? PerfMemoryCensus.snapshot() : nil
        let footprintAtEnd = ProcessClock.footprintMiB()
        var entry: [String: Any] = [
            "name": name, "seconds": elapsed, "sampled": sampled,
            "mainThread": steps.summary(seconds: elapsed, cpuSeconds: threadCPU),
            "published": [
                "transcripts": model.publicationCounts.transcripts - counts.transcripts,
                "codexStates": model.publicationCounts.codexStates - counts.codexStates
            ],
            "shownTaskItems": ["before": shownItems, "after": shownItemCount()],
            "shownTaskRunning": isRunning(PerfBenchFixture.shownTaskID),
            "memory": ["footprintStartMiB": round2(footprint), "footprintEndMiB": round2(footprintAtEnd),
                       "footprintGrowthMiB": round2(footprintAtEnd - footprint)],
            "events": EventCostLog.summary(),
            "bodies": Dictionary(uniqueKeysWithValues: Self.countedBodies.map { ("\($0)Count", ViewBodyCensus[$0]) })
        ]
        if let probe { entry["frames"] = probe.summary(seconds: elapsed) }
        if let objectsAtStart, let objectsAtEnd { entry["objectsAtStart"] = objectsAtStart; entry["objectsAtEnd"] = objectsAtEnd }
        phases.append(entry)
        // What the window held at the phase's end, for a person to look at; AppKit draws it, the browser's
        // pages included, so it needs no screen recording and nothing measured waits for it.
        if let content = window?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: "\(marker).png"))
        }
        try? Data().write(to: markers.appending(path: "\(marker).done"))
    }

    private func finish() {
        note("finished; problems: \(problems.joined(separator: "; "))")
        record["phases"] = phases
        record["problems"] = problems
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appending(path: "scene.json"))
        }
        try? Data().write(to: output.appending(path: "markers/finished"))
        if MacBrowserHost.isAvailable { MacBrowserHost.shared.client.terminateHost() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            _exit(0)
        }
    }

    // MARK: Reading the app

    /// Sends as the composer does; the scene goes on while the task starts its runtime and turn.
    private func send(_ text: String, to task: UUID) async {
        guard let session = model.store.sessions.first(where: { $0.id == task }) else {
            problems.append("no task \(task)")
            return
        }
        note("send \(text) to \(session.title)")
        Task { [model] in await model.send(text, to: session) }
    }

    /// A line in `progress.log`, to see where a scene stopped.
    private func note(_ text: String) {
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + text + "\n"
        let file = output.appending(path: "progress.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    private func isRunning(_ task: UUID) -> Bool {
        model.store.sessions.first { $0.id == task }?.status == .running
    }

    private func codexItems(_ task: UUID) -> Int {
        model.codexPresentationBySessionID[task]?.thread?.turns.reduce(0) { $0 + $1.items.count } ?? 0
    }

    private func shownItemCount() -> Int {
        let task = PerfBenchFixture.shownTaskID
        if model.store.sessions.first(where: { $0.id == task })?.harness == .codex { return codexItems(task) }
        return model.transcriptBySessionID[task]?.count ?? 0
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.sheetParent == nil }
    }

    /// The scroll view at the sidebar's place whose list is longest.
    private func sidebarScrollView(in window: NSWindow) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(window.contentView ?? NSView()).filter { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return frame.minX <= 120 && 120 <= frame.maxX && frame.width <= SidebarWidth.maximum + 1
        }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    /// The scroll view right of the sidebar whose content is tallest: the shown conversation's.
    private func conversationScrollView(in window: NSWindow) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(window.contentView ?? NSView()).filter { scroll in
            scroll.convert(scroll.bounds, to: nil).minX > SidebarWidth.minimum && !scroll.isHidden
        }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func waitUntil(_ timeout: Duration, poll: Duration = .milliseconds(50),
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }

    private func milliseconds(_ date: Date, since start: Date?) -> Double {
        guard let start else { return -1 }
        return (date.timeIntervalSince(start) * 1000).rounded()
    }
}

// MARK: - Probes

/// A process-local application event, never a keyboard, mouse or system-wide event. This diagnostic
/// control lets AppKit finish an event-loop iteration after a programmatic fixture interaction.
@MainActor
private final class BenchEventPulse {
    private static let subtype: Int16 = 0x594C
    private var monitor: Any?
    private(set) var posted = 0
    private(set) var received = 0
    private(set) var failedPosts = 0

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            MainActor.assumeIsolated {
                if event.subtype.rawValue == Self.subtype { self?.received += 1 }
            }
            return event
        }
    }

    func post() {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                            context: nil, subtype: Self.subtype, data1: posted + 1, data2: 0) else {
            failedPosts += 1
            return
        }
        posted += 1
        NSApp.postEvent(event, atStart: false)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Each pass of the main run loop from waking to going back to sleep: what the thread spent on one
/// event, timer, frame or block before it could take the next.
@MainActor
private final class MainThreadSteps {
    private var observers: [CFRunLoopObserver] = []
    private var wokeAt: UInt64 = 0
    private var durations: [Double] = []
    private var lastLongStepAt: UInt64 = 0
    private let startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    func start() {
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wokeAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        }
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.passEnded() }
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private func passEnded() {
        guard wokeAt > 0 else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let milliseconds = Double(now - wokeAt) / 1_000_000
        durations.append(milliseconds)
        if milliseconds > 16 { lastLongStepAt = now }
        wokeAt = 0
    }

    /// No pass over 16 ms in the last `seconds`, since the probe started.
    func quiet(for seconds: Double) -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let window = UInt64(seconds * 1_000_000_000)
        return now - startedAt >= window && now - max(lastLongStepAt, startedAt) >= window
    }

    func reset() {
        durations.removeAll(keepingCapacity: true)
    }

    var passCount: Int { durations.count }
    /// The main thread's time in passes since the last reset, the pass running now included up to now.
    var busyMilliseconds: Double {
        durations.reduce(0, +) + (wokeAt > 0 ? Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wokeAt) / 1_000_000 : 0)
    }

    func longestPass(since count: Int) -> Double { durations.dropFirst(count).max() ?? 0 }

    func summary(seconds: Double, cpuSeconds: Double) -> [String: Any] {
        let sorted = durations.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let busy = durations.reduce(0, +)
        return [
            "passes": sorted.count,
            "passesPerSecond": round2(Double(sorted.count) / max(seconds, 0.001)),
            "passMedianMs": round2(percentile(0.5)), "passP95Ms": round2(percentile(0.95)),
            "passMaxMs": round2(sorted.last ?? 0),
            "passesOver16MsCount": sorted.filter { $0 > 16 }.count, "passesOver50MsCount": sorted.filter { $0 > 50 }.count,
            "busyPercent": round2(busy / (seconds * 1000) * 100),
            "cpuPercent": round2(cpuSeconds / max(seconds, 0.001) * 100)
        ]
    }
}

/// A 60 Hz display link on the main run loop: how late the main thread served each frame, and the
/// frames it missed altogether.
@MainActor
private final class FrameProbe: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var lateness: [Double] = []
    private(set) var frames = 0
    private var missed = 0
    private var longestGap: Double = 0
    var onFrame: ((CADisplayLink) -> Void)?

    func start() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frames += 1
        if let lastTimestamp {
            let gap = link.timestamp - lastTimestamp
            longestGap = max(longestGap, gap)
            missed += max(0, Int((gap * 60).rounded()) - 1)
        }
        lastTimestamp = link.timestamp
        lateness.append(max(0, now - link.timestamp) * 1000)
        onFrame?(link)
    }

    func summary(seconds: Double) -> [String: Any] {
        let sorted = lateness.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let expected = max(1, frames + missed)
        return [
            "frames": frames, "missed": missed,
            "missedPercent": round2(Double(missed) / Double(expected) * 100),
            "latenessMedianMs": round2(percentile(0.5)), "latenessP95Ms": round2(percentile(0.95)),
            "longestGapMs": round2(longestGap * 1000)
        ]
    }
}

private func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

private enum ProcessClock {
    /// When the kernel started this process.
    static func startDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// The calling thread's CPU time.
    static func threadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    /// The process's physical footprint, what Activity Monitor calls its memory.
    static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
