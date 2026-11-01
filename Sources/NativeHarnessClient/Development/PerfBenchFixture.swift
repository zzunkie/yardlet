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
        /// A Claude Code answer streaming at the end of a 60-turn conversation.
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
        for folder in projects { try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true) }
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

        func claudeTask(_ id: UUID, title: String, runtime: URL, sessionID: String, turns: Int) -> SessionRecord {
            transcripts[id] = LongConversationFixture.claude(turns: turns, seed: "perf-\(id.uuidString.prefix(4))")
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
        case .streamClaude:
            shown = [claudeTask(shownTaskID, title: "Fix the parser's empty input", runtime: claude,
                                sessionID: claudeSessionID, turns: 60)]
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
        case .browserTabs:
            shown = [claudeTask(shownTaskID, title: "Check the pages", runtime: none, sessionID: claudeSessionID, turns: 5)]
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
        case .streamClaude, .streamCodex:
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
        }
        finish()
    }

    // MARK: Scenes

    private func stream(into task: UUID, seconds: Double, beforeMeasuring: (() async -> Void)? = nil) async {
        let published = model.publicationCounts
        await send("perf stream \(Int(seconds) + 20)", to: task)
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

    // MARK: Phases

    /// Writes `<n>-<name>.ready` for the script, waits for its `.go` (it starts its sampler then), and
    /// measures for `seconds`.
    private func phase(_ name: String, seconds: Double, frames: Bool = false,
                       onFrame: ((CADisplayLink) -> Void)? = nil) async {
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
        let started = ContinuousClock.now
        let cpu = ProcessClock.threadCPUSeconds()
        probe?.start()
        try? await Task.sleep(for: .seconds(seconds))
        probe?.stop()
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        let threadCPU = ProcessClock.threadCPUSeconds() - cpu
        var entry: [String: Any] = [
            "name": name, "seconds": elapsed, "sampled": sampled,
            "mainThread": steps.summary(seconds: elapsed, cpuSeconds: threadCPU),
            "published": [
                "transcripts": model.publicationCounts.transcripts - counts.transcripts,
                "codexStates": model.publicationCounts.codexStates - counts.codexStates
            ],
            "shownTaskItems": ["before": shownItems, "after": shownItemCount()],
            "shownTaskRunning": isRunning(PerfBenchFixture.shownTaskID),
            "events": EventCostLog.summary()
        ]
        if let probe { entry["frames"] = probe.summary(seconds: elapsed) }
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
}
#endif
