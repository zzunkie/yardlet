import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The quit confirmation that says which tasks continue after the restart, and Install Update…'s
/// "Restart When Tasks Finish" (the Claude app's wait for running work): its decision, its menu
/// state in the app menu and the account menu, its cancel, and the quit it starts, which still
/// refuses while a task runs.
///
/// Review images in `.build/followups-qa/`: `quit-confirmation-*` (one task continues, one stops),
/// `quit-continue-*` (all continue), `update-offer-*` (the three choices), `update-menu-*` (the app
/// menu's and the account menu's lines while an update waits).
@MainActor
final class QuitAndUpdateWaitTests: XCTestCase {
    // MARK: - The quit confirmation

    func testTheQuitConfirmationSaysWhichTasksContinueWhenYardletOpensAgain() {
        let claude = session(.claudeCode, title: "Release notes")
        let cursor = session(.cursorAgent, title: "Lint pass")
        let codex = session(.codex, title: "Upload queue")
        func line(_ session: SessionRecord) -> String { "• \(session.title) (\(session.harness.displayName))" }

        let stops = QuitConfirmation(active: [claude, cursor], continuing: [])
        XCTAssertEqual(stops.title, L10n.string("Active tasks are still running"))
        XCTAssertEqual(stops.message, L10n.format("Quitting will stop these local tasks:\n%@",
                                                  [line(claude), line(cursor)].joined(separator: "\n")))
        XCTAssertEqual(stops.quitButton, L10n.string("Quit and stop active work"), "Unchanged with nothing to continue")

        let continues = QuitConfirmation(active: [claude, codex], continuing: [claude.id, codex.id])
        XCTAssertEqual(continues.message, L10n.format(
            "Quitting pauses these tasks. They continue where they left off when Yardlet opens again:\n%@",
            [line(claude), line(codex)].joined(separator: "\n")))
        XCTAssertEqual(continues.quitButton, L10n.string("Quit and continue later"))

        let mixed = QuitConfirmation(active: [claude, cursor, codex], continuing: [claude.id, codex.id])
        XCTAssertEqual(mixed.message,
            L10n.format("Quitting will stop these local tasks:\n%@", line(cursor)) + "\n\n"
            + L10n.format("These continue where they left off when Yardlet opens again:\n%@",
                          [line(claude), line(codex)].joined(separator: "\n")))
        XCTAssertEqual(mixed.quitButton, L10n.string("Quit and stop active work"))

        let alert = mixed.alert()
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.buttons.map(\.title), [mixed.quitButton, L10n.string("Cancel")])

        for key in ["Quitting pauses these tasks. They continue where they left off when Yardlet opens again:\n%@",
                    "These continue where they left off when Yardlet opens again:\n%@", "Quit and continue later",
                    "Restart When Tasks Finish", "Waiting to Update", "Cancel Update",
                    "Tasks are still running. Yardlet can wait until they finish, then install and restart on its own.",
                    "Yardlet installs the update and restarts once no task is running."] {
            XCTAssertNotEqual(L10n.string(key, languageCode: "ko"), key, "Korean for \(key)")
            XCTAssertEqual(L10n.string(key, languageCode: "en"), key)
        }
        XCTAssertEqual(L10n.string("Waiting to Update", languageCode: "ko"), "업데이트 대기 중")
        XCTAssertEqual(L10n.string("Restart When Tasks Finish", languageCode: "ko"), "작업이 끝나면 재시작")
        XCTAssertTrue(L10n.string("These continue where they left off when Yardlet opens again:\n%@", languageCode: "ko")
            .contains("Yardlet을 다시 열면"))
    }

    func testTheAppModelNamesTheTasksItWouldContinueOnlyWithTheSettingOn() throws {
        let name = testDefaultsSuite("QuitAndUpdateWaitTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let claude = session(.claudeCode, title: "Release notes", providerSessionID: "claude-1")
        let codex = session(.codex, title: "Upload queue", providerSessionID: "codex-1")
        let cursor = session(.cursorAgent, title: "Lint pass", providerSessionID: "cursor-1")
        let sessions = [claude, codex, cursor]
        let model = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                             runtimeSelections: RuntimeSelectionStore(), preferences: defaults,
                             restoresIndexOnLaunch: false)
        XCTAssertEqual(model.tasksContinuingAfterRestart(), [claude.id, codex.id])
        let confirmation = QuitConfirmation(active: model.activeLocalSessions, continuing: model.tasksContinuingAfterRestart())
        XCTAssertTrue(confirmation.message.contains(L10n.format("These continue where they left off when Yardlet opens again:\n%@", "")
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        defaults.set(false, forKey: RestartResumePreference.key)
        XCTAssertTrue(model.tasksContinuingAfterRestart().isEmpty)
        let off = QuitConfirmation(active: model.activeLocalSessions, continuing: model.tasksContinuingAfterRestart())
        XCTAssertEqual(off.quitButton, L10n.string("Quit and stop active work"))
        XCTAssertFalse(off.message.contains("\n\n"), "With the setting off the confirmation is as it was")
    }

    // MARK: - Waiting for tasks to finish

    func testTheWaitInstallsOnlyAfterNoTaskHasRunForTheQuietPeriod() {
        let start = Date(timeIntervalSince1970: 1_000)
        typealias Policy = YardletUpdateWaitPolicy
        XCTAssertEqual(Policy.step(activeTasks: 2, quietSince: nil, now: start), .wait(quietSince: nil))
        XCTAssertEqual(Policy.step(activeTasks: 0, quietSince: nil, now: start), .wait(quietSince: start),
                       "The first quiet moment starts the count")
        XCTAssertEqual(Policy.step(activeTasks: 0, quietSince: start, now: start.addingTimeInterval(4)),
                       .wait(quietSince: start))
        XCTAssertEqual(Policy.step(activeTasks: 1, quietSince: start, now: start.addingTimeInterval(4)),
                       .wait(quietSince: nil), "A task that starts again resets it, as a queued follow-up would")
        XCTAssertEqual(Policy.step(activeTasks: 0, quietSince: start, now: start.addingTimeInterval(Policy.quietPeriod)),
                       .install)
        XCTAssertEqual(Policy.quietPeriod, 5)

        let chosen = candidate(digest: "a")
        XCTAssertTrue(Policy.isStillChosen(chosen, staged: candidate(digest: "a")))
        XCTAssertFalse(Policy.isStillChosen(chosen, staged: candidate(digest: "b")), "Another build staged meanwhile")
        XCTAssertFalse(Policy.isStillChosen(chosen, staged: nil), "Nothing staged any more, or already installed")
    }

    func testTheOfferPutsWaitingFirstOnlyWhileTasksRun() {
        XCTAssertEqual(YardletUpdateOffer.choices(hasRunningTasks: false), [.installNow, .cancel])
        XCTAssertEqual(YardletUpdateOffer.choices(hasRunningTasks: true), [.waitForTasks, .installNow, .cancel])
        XCTAssertEqual(YardletUpdateOffer.choice(for: .alertFirstButtonReturn, hasRunningTasks: true), .waitForTasks)
        XCTAssertEqual(YardletUpdateOffer.choice(for: .alertSecondButtonReturn, hasRunningTasks: true), .installNow)
        XCTAssertEqual(YardletUpdateOffer.choice(for: .alertThirdButtonReturn, hasRunningTasks: true), .cancel)
        XCTAssertEqual(YardletUpdateOffer.choice(for: .alertFirstButtonReturn, hasRunningTasks: false), .installNow)
        XCTAssertEqual(YardletUpdateOffer.choice(for: .alertSecondButtonReturn, hasRunningTasks: false), .cancel)
        XCTAssertEqual(YardletUpdateOffer.choice(for: .abort, hasRunningTasks: true), .cancel)

        let running = YardletUpdateOffer.alert(build: "abc1234", date: "Oct 16", hasRunningTasks: true)
        XCTAssertEqual(running.buttons.map(\.title), [L10n.string("Restart When Tasks Finish"),
                                                     L10n.string("Install and Restart"), L10n.string("Cancel")])
        XCTAssertTrue(running.informativeText.hasSuffix(L10n.string(
            "Tasks are still running. Yardlet can wait until they finish, then install and restart on its own.")))
        let idle = YardletUpdateOffer.alert(build: "abc1234", date: "Oct 16", hasRunningTasks: false)
        XCTAssertEqual(idle.buttons.map(\.title), [L10n.string("Install and Restart"), L10n.string("Cancel")])
        XCTAssertFalse(idle.informativeText.contains("\n\n"))
    }

    func testTheWaitWatchesTasksGoesOnWhenOneStartsAgainAndCanBeCancelled() async throws {
        let wait = YardletUpdateWait()
        let box = Box()
        box.active = 1
        box.outcomes = [.keepWaiting, .quitting]
        wait.start(.staged(candidate(digest: "a")), activeTasks: { box.active }, install: { chosen in
            box.installs.append(chosen)
            return box.outcomes.removeFirst()
        }, interval: .milliseconds(5), quietPeriod: 0.03)
        XCTAssertTrue(wait.isWaiting)
        XCTAssertEqual(YardletUpdateMenu.items(isWaiting: wait.isWaiting), [.waiting, .cancelWaiting])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(box.installs.isEmpty, "Nothing while a task runs")

        box.active = 0
        try await waitUntil { box.installs.count == 2 }
        XCTAssertEqual(box.installs, [.staged(candidate(digest: "a")), .staged(candidate(digest: "a"))],
                       "A task that started at the last moment made it wait once more")
        XCTAssertTrue(wait.isWaiting, "Still shown as waiting while Yardlet quits")

        // The quit was refused (a task started): it waits again, and Cancel Update ends it.
        box.active = 1
        wait.keepWaiting()
        wait.cancel()
        XCTAssertFalse(wait.isWaiting)
        XCTAssertEqual(YardletUpdateMenu.items(isWaiting: wait.isWaiting), [.install])
        box.active = 0
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(box.installs.count, 2, "A cancelled wait installs nothing")
    }

    func testAnotherStagedBuildEndsTheWait() async throws {
        let wait = YardletUpdateWait()
        let box = Box()
        wait.start(.staged(candidate(digest: "a")), activeTasks: { 0 }, install: { chosen in
            box.installs.append(chosen)
            return .stop
        }, interval: .milliseconds(5), quietPeriod: 0)
        try await waitUntil { !wait.isWaiting }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(box.installs, [.staged(candidate(digest: "a"))])
    }

    func testTheWaitedQuitRefusesWhileATaskRunsAndAPlainQuitStillAsks() async throws {
        let task = session(.claudeCode, title: "Release notes", providerSessionID: "claude-1")
        let model = AppModel(store: SessionStore(sessions: [task], repository: InMemorySessionRepository(sessions: [task])),
                             runtimeSelections: RuntimeSelectionStore(), restoresIndexOnLaunch: false)
        let delegate = NativeHarnessClientAppDelegate()
        delegate.model = model
        let box = Box()
        delegate.requestTermination = { box.terminationRequests += 1 }
        delegate.terminationPrompt = { _ in box.prompts += 1; return false }

        XCTAssertEqual(delegate.quitForWaitedUpdate(.staged(candidate(digest: "a"))), .keepWaiting)
        XCTAssertEqual(box.terminationRequests, 0, "No quit while the task runs")

        // Its turn ended while a subagent it started works on, which the quit would cut off as well
        // (2026-10-31: an update installed under a working Codex subagent).
        try await model.store.updateSession(id: task.id, status: .ready)
        let subagent = AgentRun(callerID: task.id, hostTaskID: task.id, harness: .codex, prompt: "Rate the app",
                                workspaceURL: task.workspaceURL, depth: 1)
        subagent.state = .running
        model.sessionTools.add(subagent)
        XCTAssertEqual(model.activeLocalSessions.map(\.id), [task.id])
        XCTAssertEqual(delegate.quitForWaitedUpdate(.staged(candidate(digest: "a"))), .keepWaiting)
        XCTAssertEqual(box.terminationRequests, 0, "No quit while its subagent works")

        subagent.state = .completed
        XCTAssertEqual(delegate.quitForWaitedUpdate(.staged(candidate(digest: "a"))), .quitting)
        XCTAssertEqual(box.terminationRequests, 1)

        // A task started between the wait's last look and the quit: the quit is refused without
        // asking anyone, and nothing is installed.
        try await model.store.updateSession(id: task.id, status: .running)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(box.prompts, 0, "The wait never offers to stop a task")

        // The person's own quit still asks, as always.
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(box.prompts, 1)

        // Sparkle's Install and Relaunch asks to quit the same way; its quit waits for the task
        // instead of asking, and the wait quits on its own once the task is done.
        delegate.sparkleWillRelaunch()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(box.prompts, 1, "Sparkle's quit never offers to stop a task")
        XCTAssertEqual(delegate.updateWait.update, .sparkle)
        XCTAssertEqual(delegate.quitForWaitedUpdate(.sparkle), .keepWaiting)
        try await model.store.updateSession(id: task.id, status: .ready)
        XCTAssertEqual(delegate.quitForWaitedUpdate(.sparkle), .quitting)
        XCTAssertEqual(box.terminationRequests, 2)
        delegate.updateWait.cancel()
        await model.shutdown()
    }

    func testTheAccountMenuShowsTheWaitAndCancelsIt() throws {
        let identity = SidebarAccountIdentity(fullName: "Alex Kim", userName: "alex")
        let sections = SettingsSection.available(hasAccounts: true, hasConnectors: false)
        let idle = SidebarAccountMenu.make(identity: identity, settingsSections: sections)
        XCTAssertEqual(idle.sections.last?.items.map(\.destination), [.installUpdate])
        XCTAssertEqual(SidebarAccountMenu.make(identity: identity, settingsSections: sections, checksForUpdates: true)
            .sections.last?.items.map(\.destination), [.checkForUpdates], "A build that updates with Sparkle")

        let waiting = SidebarAccountMenu.make(identity: identity, settingsSections: sections, updateIsWaiting: true)
        let lines = try XCTUnwrap(waiting.sections.last?.items)
        XCTAssertEqual(lines.map(\.destination), [.updateWaiting, .cancelUpdateWait])
        XCTAssertEqual(lines.map(\.title), [L10n.string("Waiting to Update"), L10n.string("Cancel Update")])
        XCTAssertEqual(lines.map(\.isEnabled), [false, true])
        XCTAssertEqual(lines.first?.help, L10n.string("Yardlet installs the update and restarts once no task is running."))
        XCTAssertEqual(Array(waiting.items.dropLast(2)), Array(idle.items.dropLast()), "Everything else is the same")

        let box = Box()
        let controller = SidebarAccountMenuController(content: waiting) { box.chosen.append($0) }
        let items = controller.menu.items.suffix(2)
        XCTAssertEqual(items.map(\.title), lines.map(\.title))
        XCTAssertEqual(items.map(\.isEnabled), [false, true])
        controller.choose(try XCTUnwrap(items.last))
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while box.chosen.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(box.chosen, [.cancelUpdateWait])

        let context = SidebarAccountMenuContext(identity: identity, settingsSections: sections, updateIsWaiting: { true })
        XCTAssertEqual(context.menu().sections.last?.items.map(\.destination), [.updateWaiting, .cancelUpdateWait])
    }

    // MARK: - Review images

    func testTheConfirmationsAndTheWaitingMenuRender() throws {
        let directory = try WindowlessRender.directory("followups-qa")
        let claude = session(.claudeCode, title: "Tidy the release notes")
        let codex = session(.codex, title: "Rewrite the upload queue")
        let cursor = session(.cursorAgent, title: "Clean up lint")
        let mixed = QuitConfirmation(active: [claude, cursor, codex], continuing: [claude.id, codex.id])
        let all = QuitConfirmation(active: [claude, codex], continuing: [claude.id, codex.id])
        let alerts: [(String, () -> NSAlert)] = [
            ("quit-confirmation", { mixed.alert() }),
            ("quit-continue", { all.alert() }),
            ("update-offer", { YardletUpdateOffer.alert(build: "68650b4", date: "Oct 16, 2026 at 9:40 PM",
                                                       hasRunningTasks: true) }),
        ]
        for (name, make) in alerts {
            for appearance in WindowlessRender.Appearance.allCases {
                let alert = make()
                alert.window.appearance = NSAppearance(named: appearance.appKitName)
                alert.layout()
                let frame = try XCTUnwrap(alert.window.contentView?.superview ?? alert.window.contentView)
                let bitmap = try WindowlessRender.capture(frame)
                XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 6), name)
                try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            }
        }

        let identity = SidebarAccountIdentity(fullName: "Alex Kim", userName: "alex")
        let account = SidebarAccountMenu.make(identity: identity, settingsSections:
            SettingsSection.available(hasAccounts: true, hasConnectors: true), updateIsWaiting: true)
        let appMenu = YardletUpdateMenu.items(isWaiting: true)
        try WindowlessRender.hostedInBothAppearances("update-menu", in: directory, size: NSSize(width: 640, height: 250)) { appearance in
            WaitingMenus(appMenu: appMenu, account: account)
                .environment(\.colorScheme, appearance.colorScheme)
        }
    }

    // MARK: - Fixtures

    private func session(_ harness: HarnessKind, title: String, providerSessionID: String? = nil) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: URL(filePath: "/tmp/quit-update"),
                      runtimeExecutableURL: URL(filePath: "/tmp/agent"), title: title, status: .running,
                      providerSessionID: providerSessionID)
    }

    private func candidate(digest: String) -> YardletUpdater.Candidate {
        YardletUpdater.Candidate(bundleURL: URL(filePath: "/tmp/Pending/Yardlet.app"), commit: "68650b4",
                                 hasUncommittedChanges: false, builtAt: nil, executableDigest: digest)
    }

    /// What the closures under test count, on the main actor with the test.
    private final class Box {
        var active = 0
        var installs: [YardletUpdateWait.Update] = []
        var outcomes: [YardletUpdateWait.Outcome] = []
        var terminationRequests = 0
        var prompts = 0
        var chosen: [SidebarAccountMenu.Destination] = []
    }
}

/// The app menu's Yardlet items and the account menu while an update waits, drawn as the system
/// menu lays them out (an `NSMenu` draws only while open on screen).
private struct WaitingMenus: View {
    let appMenu: [YardletUpdateMenu]
    let account: SidebarAccountMenu
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            panel(header: "Yardlet", lines: appMenu.map { Line(title: $0.title, symbol: nil, enabled: $0.isEnabled) }
                  + [Line(title: L10n.string("Settings…"), symbol: nil, enabled: true)])
            panel(header: account.identity.name, lines: account.sections.suffix(3).flatMap { section in
                section.items.map { Line(title: $0.title, symbol: $0.systemName, enabled: $0.isEnabled) }
            })
        }
        .padding(28)
        .frame(width: 640, height: 250, alignment: .topLeading)
        .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.86))
    }

    private struct Line: Hashable {
        let title: String
        let symbol: String?
        let enabled: Bool
    }

    private func panel(header: String, lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 22)
            ForEach(lines, id: \.self) { line in
                HStack(spacing: 7) {
                    if let symbol = line.symbol {
                        Image(systemName: symbol).frame(width: 16)
                    }
                    Text(line.title)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .foregroundStyle(line.enabled ? Color.primary : Color.secondary.opacity(0.7))
                .padding(.horizontal, 12)
                .frame(height: 22)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 270, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.965),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 12, y: 6)
    }
}
