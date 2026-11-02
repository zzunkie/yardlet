#if DEBUG
import AppKit
import Foundation

/// DEBUG-only playback for recording (`--ui-fixture=showcase --ui-fixture-playback`): beside the
/// running Claude Code task, the dark mode task is started in the split's empty pane. Its request is
/// typed, the composer's account list opens on the work login with 6% of its five-hour limit left,
/// and the personal account with 88% is chosen; the task starts there, the commentary streams, the
/// exploring commands run and fold, the file changes and the tests land and the answer streams,
/// while the Claude Code task's fifty runs pass and it answers. It then holds, 17 seconds from the
/// start, and sets the scene again, drawn before the next round starts; a recording of those 17
/// seconds loops, its last frame, the finished tasks, cutting back to its first.
///
/// The Codex task's frames are App Server notifications through `CodexTaskReducer` and the Claude
/// Code task's are stream-json lines through `ClaudeSessionProjection`, as a real turn arrives. The
/// account control and the account are pressed through the accessibility tree of the windows on
/// screen, as an assistive app presses them: no event is posted and no menu is tracked. At the
/// start of each round it posts the distributed notification `loopNotification` with the round's
/// length in seconds (`seconds`), which scripts/showcase/record-window.swift waits for.
@MainActor
final class ShowcasePlayback {
    static let loopNotification = Notification.Name("Yardlet.showcase.loopStarted")
    /// How long a round shows, from its start to the finished tasks' last frame.
    static let roundSeconds = 17.0
    /// How long the scene then takes to be set and drawn again before the next round starts.
    private static let resetSeconds = 1.5

    private static var current: ShowcasePlayback?

    private let model: AppModel
    private let sessionID = ShowcaseFixture.darkModeTaskID
    private let claudeID = ShowcaseFixture.flakyCheckoutTaskID
    private let workspace: URL
    private let reducer = CodexTaskReducer()
    private var state = CodexTaskState.empty
    private var sequence: UInt64 = 1_000
    private var roundStart = ContinuousClock.now

    private var workspacePath: String { workspace.path(percentEncoded: false) }

    private init(model: AppModel) {
        self.model = model
        workspace = ShowcaseFixture.projects(root: ShowcaseFixture.root()).web
    }

    static func start(model: AppModel) {
        guard current == nil else { return }
        let playback = ShowcasePlayback(model: model)
        current = playback
        // The task the playback starts has no pull request yet.
        model.pullRequests.setPullRequest(nil, for: ShowcaseFixture.darkModeTaskID)
        model.pullRequestDetails.forget(ShowcaseFixture.darkModeTaskID)
        Task { @MainActor in
            // Let the window lay out, then set the scene, which each round leaves set for the next.
            try? await Task.sleep(for: .seconds(1))
            await playback.reset()
            try? await Task.sleep(for: .seconds(1.5))
            while true { await playback.playRound() }
        }
    }

    // MARK: A round

    private func playRound() async {
        roundStart = .now
        DistributedNotificationCenter.default().postNotificationName(
            Self.loopNotification, object: nil, userInfo: ["seconds": Self.roundSeconds], deliverImmediately: true)
        // Meanwhile the Claude Code task's fifty runs pass, before the Codex task answers.
        let claude = Task { await finishClaudeTask(at: 13.4) }

        // The request, typed into the new task's composer.
        await wait(until: 0.9)
        let draft = model.composerDrafts.home
        let request = ShowcaseFixture.latestRequest
        for (index, _) in request.enumerated() where index.isMultiple(of: 2) || index == request.count - 1 {
            draft.text = String(request.prefix(index + 1))
            try? await Task.sleep(for: .milliseconds(36))
        }
        draft.text = request

        // The account list, and the account with room left in it.
        await wait(until: 3.3)
        let isChoosingAccount = { $0 == L10n.string("Choose account") }
        let opened = Self.press(where: isChoosingAccount)
        await wait(until: 3.5)
        // The account list's window lets clicks through too (`ShowcaseFixture.install`).
        if CommandLine.arguments.contains("--ui-fixture-ignore-pointer") {
            for window in NSApp.windows { window.ignoresMouseEvents = true }
        }
        await wait(until: 4.7)
        if !Self.press(where: { $0.hasPrefix("jpark@example.net") }) {
            model.connections.selection[.codex] = ShowcaseFixture.Accounts.codexPersonal.id
            if opened { Self.press(where: isChoosingAccount) }
        }

        // Sent: the task starts on that account and fills the empty pane.
        let sent = 5.8
        await wait(until: sent)
        _ = try? await model.store.unarchiveSession(id: sessionID)
        try? await model.store.updateSession(id: sessionID, status: .running, completionState: SessionCompletionState.none,
                                             updatesRecency: true)
        focusEmptyPane()
        model.splits.activate(.session(sessionID))
        draft.text = ""
        // Its running time counts from 4 seconds, so it ends at the 14 the still shows.
        notify("turn/started", ["turn": .object([
            "id": .string(ShowcaseFixture.latestTurnID), "status": .string("inProgress"),
            "startedAt": .integer(Int64(Date().addingTimeInterval(-4).timeIntervalSince1970)), "items": .array([])
        ])])
        complete(ShowcaseFixture.userMessage("user-dark-mode", request))
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 0)])

        let items = ShowcaseFixture.latestTurnItems(workspacePath: workspacePath, answer: ShowcaseFixture.newTaskAnswer)
        func item(_ id: String) -> JSONValue { items.first { $0["id"]?.stringValue == id }! }

        await stream(item("note-dark-mode-1"), from: sent + 0.4, over: 0.8)
        await run(item("cmd-dark-mode-1"), from: sent + 1.4, for: 0.3)
        await run(item("cmd-dark-mode-2"), from: sent + 1.85, for: 0.25)
        await run(item("cmd-dark-mode-3"), from: sent + 2.2, for: 0.25)
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 1)])
        await stream(item("note-dark-mode-2"), from: sent + 2.6, over: 1.2)

        // The patch is written, then lands.
        await wait(until: sent + 4.0)
        started(ShowcaseFixture.fileChange("patch-dark-mode", workspacePath: workspacePath, status: "inProgress"))
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 2)])
        await wait(until: sent + 4.8)
        complete(item("patch-dark-mode"))
        notify("turn/diff/updated", ["diff": .string(ShowcaseFixture.latestTurnDiff)])
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 3)])

        // The tests print as they run.
        await wait(until: sent + 5.1)
        let tests = item("cmd-dark-mode-4")
        started(running(tests))
        for line in ShowcaseFixture.testOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            notify("item/commandExecution/outputDelta", ["itemId": .string("cmd-dark-mode-4"), "delta": .string(line + "\n")])
            try? await Task.sleep(for: .milliseconds(80))
        }
        complete(tests)
        await run(item("cmd-dark-mode-5"), from: sent + 6.3, for: 0.4)
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 4)])

        await stream(item("answer-dark-mode"), from: sent + 6.9, over: 2.4)
        await wait(until: sent + 9.5)
        notify("turn/completed", ["turn": .object([
            "id": .string(ShowcaseFixture.latestTurnID), "status": .string("completed"),
            "durationMs": .integer(Int64(ShowcaseFixture.latestTurnDurationMs))
        ])])
        await setStatus(.completed, of: sessionID)

        await claude.value
        // The next round's scene, drawn by the time it starts.
        await wait(until: Self.roundSeconds)
        await reset()
        await wait(until: Self.roundSeconds + Self.resetSeconds)
    }

    /// The Claude Code task running its fifty runs beside an empty pane, which shows the new task's
    /// screen on the work login; the dark mode task not started yet.
    private func reset() async {
        model.showVisualFixtureTranscript(ShowcaseFixture.flakyCheckoutTranscript(worktree: claudeWorktree), for: claudeID)
        await setStatus(.running, of: claudeID)
        if model.store.sessions.contains(where: { $0.id == sessionID }) {
            model.splits.removeSession(sessionID)
            try? await model.store.archiveSession(id: sessionID)
        }
        state = ShowcaseFixture.newTaskState(workspacePath: workspacePath)
        sequence = 1_000
        model.showVisualFixtureCodexState(state, for: sessionID)
        model.splits.activate(.session(claudeID))
        if model.splits.activeSplit == nil { model.splits.split(.right) }
        focusEmptyPane()
        let draft = model.composerDrafts.home
        draft.text = ""
        draft.harness = .codex
        draft.workspaceURL = workspace
        draft.projectID = model.projects.project(containingRoot: workspace)?.id
        model.connections.selection[.codex] = nil
    }

    /// The empty pane has the focus, as the person's click into its composer leaves it, so the
    /// task started there fills it.
    private func focusEmptyPane() {
        guard let pane = model.splits.activeSplit?.panes.first(where: { $0.sessionID == nil }) else { return }
        model.splits.focusPane(pane.id)
    }

    private var claudeWorktree: URL {
        model.store.sessions.first { $0.id == claudeID }?.workspaceURL ?? workspace
    }

    private func finishClaudeTask(at seconds: Double) async {
        await wait(until: seconds)
        model.showVisualFixtureTranscript(ShowcaseFixture.flakyCheckoutTranscript(worktree: claudeWorktree, finished: true),
                                          for: claudeID)
        await setStatus(.completed, of: claudeID)
    }

    // MARK: Frames

    private func wait(until seconds: Double) async {
        let deadline = roundStart + .milliseconds(Int(seconds * 1_000))
        if deadline > .now { try? await Task.sleep(until: deadline, clock: .continuous) }
    }

    private func notify(_ method: String, _ params: [String: JSONValue]) {
        sequence += 1
        var params = params
        params["threadId"] = .string(ShowcaseFixture.codexThreadID)
        if params["turnId"] == nil, !method.hasPrefix("turn/started"), !method.hasPrefix("turn/completed") {
            params["turnId"] = .string(ShowcaseFixture.latestTurnID)
        }
        _ = reducer.applyNotification(method: method, params: .object(params), sequence: sequence, to: &state)
        model.showVisualFixtureCodexState(state, for: sessionID)
    }

    private func started(_ item: JSONValue) { notify("item/started", ["item": item]) }
    private func complete(_ item: JSONValue) { notify("item/completed", ["item": item]) }

    private func running(_ item: JSONValue) -> JSONValue {
        guard case var .object(fields) = item else { return item }
        fields["status"] = .string("inProgress")
        fields["aggregatedOutput"] = .null
        fields["exitCode"] = nil
        fields["durationMs"] = nil
        return .object(fields)
    }

    /// A command that starts at `start` and finishes `duration` later.
    private func run(_ item: JSONValue, from start: Double, for duration: Double) async {
        await wait(until: start)
        started(running(item))
        await wait(until: start + duration)
        complete(item)
    }

    /// A message that starts empty at `start` and arrives word by word over `duration`.
    private func stream(_ item: JSONValue, from start: Double, over duration: Double) async {
        guard let id = item["id"]?.stringValue, let text = item["text"]?.stringValue,
              case var .object(empty) = item else { return }
        await wait(until: start)
        empty["text"] = .string("")
        started(.object(empty))
        var pieces: [String] = []
        var piece = ""
        for character in text {
            piece.append(character)
            if character == " " || character == "\n" { pieces.append(piece); piece = "" }
        }
        if !piece.isEmpty { pieces.append(piece) }
        let chunk = max(1, pieces.count / max(1, Int(duration / 0.05)))
        for index in stride(from: 0, to: pieces.count, by: chunk) {
            notify("item/agentMessage/delta", ["itemId": .string(id),
                                               "delta": .string(pieces[index..<min(index + chunk, pieces.count)].joined())])
            await wait(until: start + duration * Double(index + chunk) / Double(pieces.count))
        }
        complete(item)
    }

    private func setStatus(_ status: SessionStatus, of id: UUID) async {
        try? await model.store.updateSession(id: id, status: status,
                                             completionState: status == .completed ? .completed : SessionCompletionState.none,
                                             updatesRecency: false)
    }

    // MARK: Pressing controls

    /// Presses the first element whose accessibility label `matches` in the app's windows on
    /// screen, as an assistive app presses it: through the accessibility tree, with no event
    /// posted, so a popover opens as from a click and no menu is tracked. A window that is not on
    /// screen, such as a test's, has nothing to press. Returns whether one was pressed.
    @discardableResult
    private static func press(where matches: (String) -> Bool) -> Bool {
        withAccessibilityTree {
            func find(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if let label = child.accessibilityLabel?() ?? nil, matches(label) { return child }
                    if let found = find(child) { return found }
                }
                return nil
            }
            for window in NSApp.windows where window.isVisible {
                if let view = window.contentView, let element = find(view) {
                    return element.accessibilityPerformPress?() ?? false
                }
            }
            return false
        }
    }

    /// SwiftUI builds its accessibility tree only after an assistive app sets
    /// `AXEnhancedUserInterface` on the application, as VoiceOver does. The setting is put back
    /// afterwards. It is reached by selector because the attribute API that names it is deprecated.
    private static func withAccessibilityTree<T>(_ body: () -> T) -> T {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let wasOn = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        let set = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        _ = app.perform(set, with: NSNumber(value: true), with: attribute)
        defer { _ = app.perform(set, with: NSNumber(value: wasOn), with: attribute) }
        return body()
    }
}
#endif
