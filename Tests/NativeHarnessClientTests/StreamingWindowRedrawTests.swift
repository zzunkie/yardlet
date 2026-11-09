import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What a Claude Code task streaming tool calls costs the window around its conversation, counted
/// as body evaluations of the window, its sidebar rows and the composer (`ViewBodyCensus`) in the
/// real window drawn in an unshown window. The fake CLI speaks Claude Code's stream-json as it
/// streams a turn that calls tools: each API call's partial-message events, the finished blocks, the
/// plan-limit report after each call, the tool results, and a background agent's progress. No model
/// is asked anything.
///
/// Before (2026-10-22, 12 tasks, 12 tool calls): every sidebar row was drawn again whenever the
/// window was (24), the composer once per published fragment (52), and each resource sample drew
/// every row (120 for 10 samples).
@MainActor
final class StreamingWindowRedrawTests: XCTestCase {
    func testAStreamingTaskRedrawsItsConversationAndNotTheWindowAroundIt() async throws {
        let window = try await makeWindow(tasks: 12)
        defer { window.close() }
        let model = window.model, shown = window.tasks[0], other = window.tasks[5]
        let transport = try XCTUnwrap(window.fixture.transport(shown.id))

        // Streaming: the shown task calls twelve tools, one of them a background agent.
        let streaming = await window.measure("12 tool calls") {
            await ClaudeToolCallStream(emit: { await transport.emit($0) },
                                       pause: { window.host.settle(passes: 1, interval: 0.004) }).run(calls: 12)
        }
        XCTAssertGreaterThan(model.transcriptBySessionID[shown.id]?.count ?? 0, 12, "The fixture streamed the shown task")
        // The task's own status reports may redraw the window; its fragments may not.
        XCTAssertLessThanOrEqual(streaming[.mainWindow], 2, "Streaming redrew the window")
        XCTAssertLessThanOrEqual(streaming[.sidebarRow], 2, "Streaming redrew sidebar rows that show nothing new")
        XCTAssertLessThanOrEqual(streaming[.composer], 4, "The composer was drawn again for streamed fragments")

        // Another task changes: the window lists it anew, and only its row is drawn again.
        let unread = await window.measure("another task marked unread") {
            await model.store.markUnread(id: other.id)
        }
        XCTAssertGreaterThanOrEqual(unread[.mainWindow], 1, "The window lists the change")
        XCTAssertLessThanOrEqual(unread[.sidebarRow], 2, "Rows that did not change were drawn again")

        // The resource monitor's samples: the streaming task's CPU changes, the others stay idle.
        let samples = await window.measure("10 resource samples") {
            for sample in 0..<10 {
                model.resourceMonitor.apply([TaskResourceUsage(
                    owner: .task(shown.id), locations: [.yardlet], processCount: 2, memoryBytes: 1 << 26,
                    cpuPercent: Double(40 + sample * 7), isBusy: true)])
                window.host.settle(passes: 1, interval: 0.02)
            }
        }
        XCTAssertLessThanOrEqual(samples[.sidebarRow], 11, "A sample redrew rows whose CPU did not change")
        XCTAssertEqual(samples[.mainWindow], 0)

        // UserDefaults writes of state the window does not show, as saving app state makes them. A view that
        // reads a key with a dot in it with `@AppStorage` was evaluated again on each (`PreferenceKeyCarryOver`).
        // The views that name no store read the standard one, which is `.yardlet` in the app and not in a test.
        let writes = await window.measure("10 unrelated UserDefaults writes") {
            for index in 0..<10 {
                for store in [UserDefaults.yardlet, .standard] { store.set(index, forKey: "StreamingWindowRedraw.unrelated") }
                window.host.settle(passes: 1, interval: 0.02)
            }
            for store in [UserDefaults.yardlet, .standard] { store.removeObject(forKey: "StreamingWindowRedraw.unrelated") }
        }
        XCTAssertEqual(writes[.mainWindow], 0)
        XCTAssertEqual(writes[.sidebarRow], 0)
        XCTAssertEqual(writes[.taskSurface], 0)
        XCTAssertEqual(writes[.sessionRail], 0)
        XCTAssertEqual(writes[.composer], 0)

        // The scene's body runs again, as the app's does whenever something it reads changes. After the first
        // such run, which draws the window once more as a new value, the window is handed the same app-wide
        // actions and is not drawn again. An action made anew each time was a new environment value, and at
        // launch the window published its menu commands twice in one frame.
        window.scene.runs += 1
        let scene = await window.measure("the scene's body run again 5 times") {
            for _ in 0..<5 {
                window.scene.runs += 1
                window.host.settle(passes: 1, interval: 0.02)
            }
        }
        XCTAssertEqual(scene[.mainWindow], 0)

        // A search open in the sidebar while the shown task streams at the end of a long conversation, beside
        // tasks with long conversations of their own. The window lists the tasks the search finds, which the
        // stream leaves as they were, and is not drawn again for it (`ConversationSearchMemo`). Before, searching
        // the conversations made the window observe every task's, so each publication drew the window again and
        // searched the streaming task's whole conversation once more.
        model.mutateTranscript(for: shown.id, publishImmediately: true) {
            $0 = TranscriptBuilder(entries: LongConversationFixture.claude(turns: 1_000, seed: "shown"))
        }
        for (index, task) in window.tasks.enumerated().dropFirst() {
            model.transcripts[task.id] = LongConversationFixture.claude(
                turns: 100, seed: "task-\(index)", tag: index.isMultiple(of: 2) ? "ledger " : "")
        }
        window.search("ledger")
        XCTAssertTrue(window.lists(window.tasks[2]), "The search finds a task by its conversation")
        XCTAssertFalse(window.lists(shown), "The shown task's conversation does not hold the search")
        let searching = await window.measure("12 tool calls with a search open") {
            await ClaudeToolCallStream(emit: { await transport.emit($0) },
                                       pause: { window.host.settle(passes: 1, interval: 0.004) }).run(calls: 12)
        }
        XCTAssertLessThanOrEqual(searching[.mainWindow], 2, "Streaming redrew the window while the sidebar searches")
        // The shown task's conversation comes to hold the search: the window lists it.
        let found = await window.measure("the shown task's answer comes to hold the search") {
            model.mutateTranscript(for: shown.id, publishImmediately: true) { $0.apply(.assistantDelta(" The ledger")) }
        }
        XCTAssertGreaterThanOrEqual(found[.mainWindow], 1, "The window lists the task the search now finds")
        XCTAssertTrue(window.lists(shown), "The search finds what streamed")
    }

    /// A task the window showed keeps its views out of the window while another task shows
    /// (`TaskSurfaceHost`). SwiftUI updates views out of a window when what they read changes, so
    /// before, an answer streaming into such a task projected its conversation and its rail on every
    /// publication, as if it were shown. It now draws nothing until it is shown again, and then shows
    /// everything that streamed.
    func testATaskStreamingOutOfTheWindowIsDrawnOnlyWhenItIsShownAgain() async throws {
        let window = try await makeWindow(tasks: 3)
        defer { window.close() }
        let model = window.model, streaming = window.tasks[0]
        let transport = try XCTUnwrap(window.fixture.transport(streaming.id))
        let projection = model.taskWorkspaces.state(for: streaming.id, initialSurface: model.initialTaskSurface)
            .conversationRender.projection
        model.splits.activate(.session(window.tasks[1].id))
        window.host.settle(passes: 20)

        let projected = projection.counts
        var text = ""
        _ = await window.measure("an answer out of the window") {
            text = await ClaudeAnswerStream(emit: { await transport.emit($0) },
                                            pause: { window.host.settle(passes: 1, interval: 0.01) }).run(fragments: 40)
        }
        XCTAssertTrue((model.transcriptBySessionID[streaming.id] ?? []).contains { entry in
            if case let .assistant(answer, _) = entry.content { return answer == text }
            return false
        }, "The answer streamed")
        XCTAssertEqual(projection.counts, projected, "A conversation out of the window was projected again")

        model.splits.activate(.session(streaming.id))
        window.host.settle(passes: 20)
        XCTAssertGreaterThan(projection.counts.projected, projected.projected)
        XCTAssertTrue(Self.draws("word39", in: window.host.hosting), "Shown again, the task shows what streamed")
    }

    /// A Codex task's turn publishes its thread's state a few times a second. Each state updates the
    /// conversation, which draws it, and not the task's views around it (`TaskDetail`): the composer
    /// and the rail read the state in views of their own. Before, every state drew the task's views
    /// again, and with them every view of the task the window handed new values. The rail reads only
    /// its part of the state (`CodexRailStates`), which commands and an answer streaming leave as it
    /// was, so its cards are not drawn again either.
    func testACodexTaskStreamingRedrawsItsConversationAndNotTheTaskAroundIt() throws {
        let window = try ConversationBlankFrameTests.makeWindow([.codex("Codex", turns: 60)], for: self)
        defer { window.close() }
        window.show(0)
        let request = "Please fix the next parser case."
        func streamed(calls: Int, paragraphs: Int) -> CodexTaskState {
            var turns = (57..<60).map { LongConversationFixture.codexTurn($0, tag: "Codex ") }
            turns.append(LongConversationFixture.runningCodexTurn(60, request: request, calls: calls, paragraphs: paragraphs))
            return LongConversationFixture.codex(threadID: "thread-0", turns: turns)
        }
        window.emitCodex(0, streamed(calls: 0, paragraphs: 0))
        window.send(0, request)
        window.emitCodex(0, streamed(calls: 0, paragraphs: 1))
        window.probe.run("settle", for: 0.5)
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
        }
        for step in 1...12 { window.emitCodex(0, streamed(calls: min(step, 6), paragraphs: step + 1)) }
        XCTAssertEqual(window.model.codexPresentationBySessionID[window.tasks[0].id]?.thread?.turns.last?.items.count, 8,
                       "The states streamed")
        XCTAssertGreaterThan(ViewBodyCensus[.conversationTimeline], 0, "The conversation drew the states")
        XCTAssertEqual(ViewBodyCensus[.taskSurface], 0, "A state drew the task's views around its conversation")
        XCTAssertEqual(ViewBodyCensus[.sessionRail], 0, "A state drew the rail's cards, which show nothing new")
        XCTAssertEqual(ViewBodyCensus[.mainWindow], 0)
    }

    private static func draws(_ text: String, in view: NSView) -> Bool {
        (view as? NSTextView)?.string.contains(text) == true || view.subviews.contains { draws(text, in: $0) }
    }

    /// A sidebar of forty tasks with nothing running: a task's CPU sample or unread mark redraws its
    /// own row, not every row on screen.
    func testASidebarRowIsDrawnAgainOnlyForItsOwnChange() async throws {
        let fixture = try await makeFixture(tasks: 40)
        let model = fixture.model
        model.splits.activate(.session(fixture.tasks[0].id))
        let window = Window(fixture: fixture, height: 1_200)
        defer { window.close() }
        window.host.settle(passes: 20)
        let samples = await window.measure("20 resource samples of one task") {
            for sample in 0..<20 {
                model.resourceMonitor.apply([TaskResourceUsage(
                    owner: .task(fixture.tasks[39].id), locations: [.yardlet], processCount: 2, memoryBytes: 1 << 26,
                    cpuPercent: Double(40 + sample * 7), isBusy: true)])
                window.host.settle(passes: 1, interval: 0.005)
            }
        }
        let unread = await window.measure("10 tasks marked unread in turn") {
            for task in fixture.tasks[30...39] {
                await model.store.markUnread(id: task.id)
                window.host.settle(passes: 1, interval: 0.005)
            }
        }
        XCTAssertLessThanOrEqual(samples[.sidebarRow], 21)
        XCTAssertLessThanOrEqual(unread[.sidebarRow], 12)
    }

    /// The composer, its bash-mode actions and its connectors are made afresh each time the task's
    /// conversation publishes; made again for the same task they are equal, and a change in what
    /// they show makes them unequal.
    func testWhatTheTaskSurfaceMakesAgainForTheSameTaskIsEqual() {
        let draft = TaskComposerDraft()
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/equal"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Equal")
        func composer(isRunning: Bool = true, entries: [TranscriptEntry] = []) -> PromptComposer {
            PromptComposer(harness: .claudeCode, composerDraft: draft, providerSession: session, providerEntries: entries,
                           isRunning: isRunning, actions: ComposerActions(send: { _ in }, submitFollowUp: { _, _ in }))
        }
        XCTAssertEqual(composer(), composer(), "Fresh actions for the same task")
        XCTAssertNotEqual(composer(), composer(isRunning: false))
        XCTAssertNotEqual(composer(), PromptComposer(harness: .claudeCode, composerDraft: draft, providerSession: session,
                                                     isRunning: true, actions: ComposerActions(send: { _ in })),
                          "An action the composer offers went away")
        XCTAssertNotEqual(composer(), PromptComposer(harness: .claudeCode, composerDraft: TaskComposerDraft(),
                                                     providerSession: session, isRunning: true,
                                                     actions: ComposerActions(send: { _ in }, submitFollowUp: { _, _ in })))
        var renamed = session
        renamed.title = "Renamed"
        func shell(_ task: SessionRecord, running: Bool = false) -> ClaudeShellCommandActions {
            ClaudeShellCommandActions(isRunning: running, run: { _ in }, stop: {}, runForEntry: { _ in nil }, task: task)
        }
        XCTAssertEqual(shell(session), shell(session))
        XCTAssertNotEqual(shell(session), shell(session, running: true))
        XCTAssertNotEqual(shell(session), shell(renamed))
        let scope = ConnectorTaskScope(harness: .claudeCode)
        func connectors(_ id: UUID) -> ComposerConnectorEnvironment {
            ComposerConnectorEnvironment(records: [], taskState: { _ in .on }, setOn: { _, _ in }, openSettings: {},
                                         target: .init(center: nil, taskID: id, scope: scope))
        }
        XCTAssertEqual(connectors(session.id), connectors(session.id))
        XCTAssertNotEqual(connectors(session.id), connectors(UUID()))
    }


    /// A long answer streamed for two seconds, as a model writes one: the conversation is published
    /// on the publication cadence (`AppModel.scheduleTranscriptPublication`), not once per fragment.
    /// Each publication lays the whole window out again, in the window's display cycle.
    ///
    /// The cadence is a time, so the publications are counted against the time the fragments took:
    /// on a Mac 200 fragments take two to four seconds, on CI, where each pause lays the window out
    /// again, over ten.
    func testALongAnswerIsPublishedOnTheCadenceNotPerFragment() async throws {
        let window = try await makeWindow(tasks: 12)
        defer { window.close() }
        let model = window.model, shown = window.tasks[0]
        let transport = try XCTUnwrap(window.fixture.transport(shown.id))
        let fragments = 200
        let clock = ContinuousClock()
        /// At most one publication per interval of `elapsed`, and `extra` besides.
        func cadence(over elapsed: Duration, extra: Int) -> Int {
            Int((elapsed / AppModel.transcriptPublicationInterval).rounded(.up)) + extra
        }
        let published = model.publicationCounts.transcripts
        var text = ""
        let streamStart = clock.now
        let streaming = await window.measure("\(fragments) answer fragments 10 ms apart") {
            text = await ClaudeAnswerStream(emit: { await transport.emit($0) },
                                            pause: { window.host.settle(passes: 1, interval: 0.01) }).run(fragments: fragments)
        }
        let streamTime = clock.now - streamStart
        let publications = model.publicationCounts.transcripts - published
        print("[redraw] \(fragments) answer fragments in \(streamTime): \(publications) publications")
        let answers = (model.transcriptBySessionID[shown.id] ?? []).compactMap { entry -> String? in
            if case let .assistant(text, _) = entry.content { return text }
            return nil
        }
        XCTAssertTrue(answers.contains(text), "The whole answer arrived")
        XCTAssertLessThanOrEqual(streaming[.mainWindow], 2, "Streaming redrew the window")
        // Ten publications a second for the fragments, and the finished message's frames. The bound tells
        // the cadence from a publication per fragment only while it is under one per fragment.
        let fragmentBound = cadence(over: streamTime, extra: 8)
        XCTAssertLessThan(fragmentBound, fragments, "The fragments came too slowly to tell")
        XCTAssertLessThanOrEqual(publications, fragmentBound, "Fragments were published faster than the cadence")

        // A background agent reports its progress as often, and is published at the same cadence.
        let reports = 200
        let beforeReports = model.publicationCounts.transcripts
        let reportStart = clock.now
        await transport.emit(json(["type": "system", "subtype": "task_started", "task_id": "task-agent",
                                   "tool_use_id": "toolu_agent", "description": "Survey the sources",
                                   "task_type": "local_agent", "prompt": "Look around", "session_id": "s"]))
        for report in 1...reports {
            await transport.emit(json(["type": "system", "subtype": "task_progress", "task_id": "task-agent",
                                       "tool_use_id": "toolu_agent", "description": "Survey the sources",
                                       "last_tool_name": "Read", "session_id": "s",
                                       "usage": ["tool_uses": report, "total_tokens": report * 100, "duration_ms": report * 10]]))
            window.host.settle(passes: 1, interval: 0.01)
        }
        window.host.settle(passes: 20, interval: 0.01)
        let reportTime = clock.now - reportStart
        let reportPublications = model.publicationCounts.transcripts - beforeReports
        print("[redraw] \(reports) progress reports in \(reportTime): \(reportPublications) publications")
        let reportBound = cadence(over: reportTime, extra: 8)
        XCTAssertLessThan(reportBound, reports, "The reports came too slowly to tell")
        XCTAssertLessThanOrEqual(reportPublications, reportBound, "Progress was published faster than the cadence")
    }

    // MARK: - Window

    @MainActor
    private final class Window {
        let fixture: Fixture
        let host: WindowlessRender.Host<AnyView>
        let scene = SceneRuns()
        var model: AppModel { fixture.model }
        var tasks: [SessionRecord] { fixture.tasks }

        init(fixture: Fixture, height: CGFloat = 820) {
            self.fixture = fixture
            host = WindowlessRender.Host(AnyView(SceneRoot(model: fixture.model, runs: scene)),
                                         size: NSSize(width: 1_280, height: height))
            ViewBodyCensus.isEnabled = true
        }

        /// The body evaluations `work` caused, and the main thread's time for it, printed.
        func measure(_ name: String, _ work: () async -> Void) async -> Counts {
            host.settle(passes: 6, interval: 0.01)
            ViewBodyCensus.reset()
            let start = MainThreadClock.now()
            await work()
            host.settle(passes: 20, interval: 0.01)
            let counts = Counts(values: ViewBodyCensus.counts)
            print("[redraw] \(name): window \(counts[.mainWindow]), rows \(counts[.sidebarRow]), "
                  + "composer \(counts[.composer]), surface \(counts[.taskSurface]), rail \(counts[.sessionRail]), "
                  + "main thread \(MainThreadClock.since(start))")
            return counts
        }

        /// Types `text` into the sidebar's search field, as the person does.
        func search(_ text: String) {
            guard let field = Self.textFields(in: host.hosting)
                .first(where: { $0.placeholderString == L10n.string("Search tasks") }) else {
                return XCTFail("The sidebar shows no search field")
            }
            field.stringValue = text
            (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            host.settle(passes: 10)
        }

        /// Whether the sidebar lists `task`: its row is labelled with its title and harness.
        func lists(_ task: SessionRecord) -> Bool {
            let row = "\(task.title), \(task.harness.displayName)"
            return host.accessibilityElements().contains { $0.label == row }
        }

        private static func textFields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
        }

        func close() {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
            host.close()
        }
    }

    struct Counts {
        let values: [ViewBodyCensus.Body: Int]
        subscript(body: ViewBodyCensus.Body) -> Int { values[body] ?? 0 }
    }

    private func makeWindow(tasks count: Int) async throws -> Window {
        let fixture = try await makeFixture(tasks: count)
        let model = fixture.model, shown = fixture.tasks[0]
        model.splits.activate(.session(shown.id))
        let window = Window(fixture: fixture)
        window.host.settle(passes: 20)
        await model.send(HarnessUserInput(text: "Start"), to: shown)
        try await waitUntil { model.store.sessions.first { $0.id == shown.id }?.status == .running }
        window.host.settle(passes: 20)
        return window
    }

    // MARK: - Fixture

    struct Fixture {
        let model: AppModel
        let tasks: [SessionRecord]
        let book: TransportBook
        func transport(_ id: UUID) -> FakeClaudeTransport? { book.transport(for: id) }
    }

    final class TransportBook: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [UUID: FakeClaudeTransport] = [:]
        func make(for id: UUID) -> FakeClaudeTransport {
            let transport = FakeClaudeTransport()
            lock.withLock { transports[id] = transport }
            return transport
        }
        func transport(for id: UUID) -> FakeClaudeTransport? { lock.withLock { transports[id] } }
    }

    private func makeFixture(tasks count: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-redraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi\n".utf8)
            .write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = testDefaultsSuite("StreamingWindowRedraw")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let book = TransportBook()
        // The signed-in Claude account the app has read, whose plan usage each plan-limit report updates.
        let connections = ProviderConnectionStore()
        connections.publishDefaults([HarnessAccountSnapshot(
            id: "claude:qa", harness: .claudeCode, providerID: "anthropic", state: .signedIn, accountLabel: "qa@example.test",
            detail: "", credentialOwner: "Claude Code", checkedAt: Date(),
            usage: [AccountUsageMetric(id: "claude:session:", label: "5 hour limit", usedFraction: 0.1, detail: "",
                                       resetsAt: Date(timeIntervalSince1970: 1_900_000_000), evidence: .exactQuota)],
            canLogin: false, canLogout: false)])
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { book.make(for: $0) }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            connections: connections,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        var tasks: [SessionRecord] = []
        for index in 0..<count {
            let folder = root.appending(path: "project-\(index % 4)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = await model.createSession(harness: .claudeCode, workspaceURL: folder,
                                                    runtimeExecutableURL: cli, title: "Task \(index)")
            tasks.append(try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Task did not start"))
        }
        return Fixture(model: model, tasks: tasks, book: book)
    }
}

/// The main window as `NativeHarnessClientApp`'s window group shows it: the appearance and size
/// preferences read from UserDefaults around it, and the app-wide update actions it hands down.
private struct SceneRoot: View {
    /// Made once, as the window's content is; the scene's body hands it its values again each time it runs.
    let window: MainWindow
    /// Read by the body, so a test runs it again as the app's runs again whenever what it reads changes.
    let runs: SceneRuns
    @AppStorage(YardletPreferenceKeys.appearance) private var appearanceRawValue =
        YardletAppearancePreference.system.rawValue
    @AppStorage(YardletPreferenceKeys.interfaceSize) private var interfaceSizeRawValue =
        YardletInterfaceSizePreference.standard.rawValue
    private let updateWait = YardletUpdateWait()

    init(model: AppModel, runs: SceneRuns) {
        window = MainWindow(model: model)
        self.runs = runs
    }

    var body: some View {
        let _ = runs.runs
        window
            .environment(\.yardletInterfaceScale, 1)
            .environment(\.yardletInstallUpdate, YardletInstallUpdateAction { [updateWait] in _ = updateWait })
            .environment(\.yardletUpdateWait, updateWait)
    }
}

/// How many times a test ran the scene's body again (`SceneRoot`).
@MainActor @Observable
private final class SceneRuns {
    var runs = 0
}

/// The main thread's CPU time.
private enum MainThreadClock {
    static func now() -> Int64 {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return Int64(info.user_time.seconds + info.system_time.seconds) * 1_000_000
            + Int64(info.user_time.microseconds + info.system_time.microseconds)
    }

    static func since(_ start: Int64) -> Duration { .microseconds(now() - start) }
}

/// Claude Code's stream-json for a turn that calls tools, as `--include-partial-messages` streams
/// it: for each API call, `message_start`, a text block and a tool-use block with their deltas, the
/// finished blocks as `assistant` frames, `message_delta`/`message_stop`, the plan-limit report,
/// then the tool's result. The third call starts a background agent whose progress and nested
/// frames arrive while the main turn goes on.
@MainActor
struct ClaudeToolCallStream {
    let emit: @Sendable (JSONValue) async -> Void
    /// Between fragments, as the CLI streams them a few milliseconds apart.
    var pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(4)) }

    func run(calls: Int) async {
        for call in 0..<calls {
            await emit(event(["type": "message_start", "message": [
                "id": "msg_\(call)", "type": "message", "role": "assistant", "model": "claude-fable-5",
                "content": [Any](), "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000 + call * 900,
                                              "output_tokens": 1]]]))
            await emit(event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))
            var text = ""
            for word in 0..<12 {
                let fragment = "word\(call)-\(word) "
                text += fragment
                await emit(event(["type": "content_block_delta", "index": 0,
                                  "delta": ["type": "text_delta", "text": fragment]]))
                await pause()
            }
            await emit(event(["type": "content_block_stop", "index": 0]))
            await emit(assistant(call: call, [["type": "text", "text": text]]))
            let toolID = "toolu_\(call)"
            let isAgent = call == 2
            let name = isAgent ? "Agent" : (call.isMultiple(of: 3) ? "Read" : "Bash")
            let input: [String: Any] = isAgent
                ? ["description": "Survey the sources", "prompt": "Look around", "subagent_type": "general-purpose",
                   "run_in_background": true]
                : name == "Read" ? ["file_path": "/tmp/project/Sources/File\(call).swift"]
                : ["command": "rg -n thing Sources/\(call)", "description": "Search the sources"]
            await emit(event(["type": "content_block_start", "index": 1, "content_block": [
                "type": "tool_use", "id": toolID, "name": name, "input": [String: Any]()]]))
            for part in 0..<6 {
                await emit(event(["type": "content_block_delta", "index": 1,
                                  "delta": ["type": "input_json_delta", "partial_json": "{\"p\(part)\":"]]))
                await pause()
            }
            await emit(event(["type": "content_block_stop", "index": 1]))
            await emit(assistant(call: call, [["type": "tool_use", "id": toolID, "name": name, "input": input]]))
            await emit(event(["type": "message_delta", "delta": ["stop_reason": "tool_use", "stop_sequence": NSNull()],
                              "usage": ["output_tokens": 80 + call]]))
            await emit(event(["type": "message_stop"]))
            await emit(json(["type": "rate_limit_event", "session_id": "s", "rate_limit_info": [
                "status": "allowed", "resetsAt": 1_900_000_000, "rateLimitType": "five_hour",
                "utilization": 0.2 + Double(call) / 100, "isUsingOverage": false]]))
            if isAgent {
                await emit(json(["type": "system", "subtype": "task_started", "task_id": "task-agent", "tool_use_id": toolID,
                                 "description": "Survey the sources", "task_type": "local_agent", "prompt": "Look around",
                                 "session_id": "s"]))
                await emit(json(["type": "user", "session_id": "s", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": toolID,
                     "content": "Async agent launched successfully. agentId: a1"]]]]))
            } else {
                await emit(json(["type": "user", "session_id": "s", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": toolID, "content": "Sources/A.swift:\(call): thing"]]]]))
            }
            if call > 2 {
                // The background agent works while the main turn goes on.
                await emit(json(["type": "assistant", "parent_tool_use_id": "toolu_2", "session_id": "s",
                                 "message": ["role": "assistant", "content": [
                                    ["type": "tool_use", "id": "child-\(call)", "name": "Read",
                                     "input": ["file_path": "/tmp/project/Sources/Child\(call).swift"]]]]]))
                await emit(json(["type": "system", "subtype": "task_progress", "task_id": "task-agent",
                                 "tool_use_id": "toolu_2", "description": "Survey the sources", "last_tool_name": "Read",
                                 "session_id": "s",
                                 "usage": ["tool_uses": call, "total_tokens": call * 1_000, "duration_ms": call * 700]]))
            }
        }
    }

    private func event(_ event: [String: Any]) -> JSONValue {
        json(["type": "stream_event", "session_id": "s", "event": event])
    }

    private func assistant(call: Int, _ content: [[String: Any]]) -> JSONValue {
        json(["type": "assistant", "session_id": "s", "message": [
            "id": "msg_\(call)", "type": "message", "role": "assistant", "model": "claude-fable-5", "content": content,
            "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000 + call * 900, "output_tokens": 80 + call]]])
    }
}

/// Claude Code's stream-json for a turn that answers in text alone: `message_start`, the text block
/// and its deltas, the finished block as an `assistant` frame, `message_delta`/`message_stop`.
@MainActor
struct ClaudeAnswerStream {
    let emit: @Sendable (JSONValue) async -> Void
    var pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(10)) }

    /// Streams `fragments` words and returns the whole answer.
    func run(fragments: Int) async -> String {
        await emit(event(["type": "message_start", "message": [
            "id": "msg_answer", "type": "message", "role": "assistant", "model": "claude-fable-5",
            "content": [Any](), "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000, "output_tokens": 1]]]))
        await emit(event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))
        var text = ""
        for index in 0..<fragments {
            let fragment = "word\(index) "
            text += fragment
            await emit(event(["type": "content_block_delta", "index": 0,
                              "delta": ["type": "text_delta", "text": fragment]]))
            await pause()
        }
        await emit(event(["type": "content_block_stop", "index": 0]))
        await emit(json(["type": "assistant", "session_id": "s", "message": [
            "id": "msg_answer", "type": "message", "role": "assistant", "model": "claude-fable-5",
            "content": [["type": "text", "text": text]],
            "usage": ["input_tokens": 3, "cache_read_input_tokens": 40_000, "output_tokens": fragments]]]))
        await emit(event(["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                          "usage": ["output_tokens": fragments]]))
        await emit(event(["type": "message_stop"]))
        return text
    }

    private func event(_ event: [String: Any]) -> JSONValue {
        json(["type": "stream_event", "session_id": "s", "event": event])
    }
}

private func json(_ object: [String: Any]) -> JSONValue {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(JSONValue.self, from: data)
}
