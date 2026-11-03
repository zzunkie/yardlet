import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// The desktop remote drawn offscreen (never shown) in both appearances into `.build/remote-qa`, on loopback:
/// nothing runs a provider, and nothing is paired but the test's own hosts.
///
/// Against the app's own model as the host (`AppModelRemoteBridge`), so cards carry exactly what the host's
/// own cards offer, with the same conversation drawn by the local timeline beside it:
/// - `remote-host-approval-*.png` and `local-approval-*.png`: a Claude Code task waiting on a Bash approval,
///   with Claude Code's own three answers.
/// - `remote-host-question-*.png` and `local-question-*.png`: a question with its options.
/// - `remote-host-lines-*.png` and `local-lines-*.png`: the same turn with its Read and Edit lines opened.
/// - `remote-host-suggestion-*.png` and `local-suggestion-*.png`: a finished task with a suggested task's chip.
/// - `remote-host-outputs-*.png` and `local-outputs-*.png`: a task that wrote a report and a chart, with the
///   session rail's Outputs card beside it.
/// - `remote-host-schedules-*.png` and `local-schedules-*.png`: the scheduled tasks list beside a schedule.
/// - `remote-form-*.png` and `local-form-*.png`: a Codex MCP form's card, the remote one read from what the host
///   sends for it.
///
/// Against the fixture host (`RemoteFixtureBridge`), which streams and answers:
/// - `remote-connect-*.png`: File › Connect to Mac… with one paired Mac.
/// - `remote-host-running-*.png`: a turn running after its approval was answered, with a queued message.
/// - `remote-host-answered-*.png`: a finished task's turns, each folded under its answer.
/// - `remote-host-new-*.png`: a new task with the host's project, harness and model menus.
/// - `remote-host-form-*.png`: an MCP form waiting in the host window.
/// - `remote-host-offline-*.png`: the host gone, its list and conversation kept under the banner.
///
/// A task's controls (§15.23), against the app's own model as the host, beside the local conversation and composer:
/// - `remote-controls-codex-*.png` and `local-controls-codex-*.png`: a Codex task's bottom row and its turns' Edit
///   message and Fork from here.
/// - `remote-controls-edit-*.png` and `local-controls-edit-*.png`: the same task editing its latest request.
/// - `remote-controls-claude-*.png` and `local-controls-claude-*.png`: a Claude Code task in Bypass permissions.
@MainActor
final class RemoteHostWindowRenderingTests: XCTestCase {
    func testTheConnectWindowAndAHostWindowDraw() async throws {
        let directory = try WindowlessRender.directory("remote-qa")
        // At its own pace, so a turn still runs when a message is queued behind it.
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: RemoteFixtureBridge(speed: 1))
        var stopped = false
        defer { if !stopped { stack.stop() } }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let host = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: host.id))
        try await waitUntil { model.hasSnapshot }

        try await render("remote-connect", size: NSSize(width: 540, height: 420), titled: false) {
            RemoteConnectWindow(directory: hosts)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Connection link") }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == L10n.format("Open %@", "Mac Studio") }, elements.description)
        }

        let size = NSSize(width: 1280, height: 820)
        model.select(.task(RemoteFixtureBridge.ID.approval))
        let approval = try XCTUnwrap(model.conversations[RemoteFixtureBridge.ID.approval])
        try await waitUntil { approval.isLoaded }

        let request = try XCTUnwrap(approval.presentation.turns.last?.requests.first)
        model.respond(taskID: RemoteFixtureBridge.ID.approval, requestID: request.id,
                      route: try XCTUnwrap(request.responses.last?.route))
        // While the answer streams, a message sent now waits in the host's queue.
        try await waitUntil { approval.presentation.turns.last?.requests.isEmpty == true }
        _ = await model.perform(.sendMessage(taskID: RemoteFixtureBridge.ID.approval, text: "Then update the changelog",
                                             followUp: .queue))
        try await waitUntil { !approval.queued.isEmpty }
        try await render("remote-host-running", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Interrupt") }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Queue or steer") }, elements.description)
        }
        model.select(.task(RemoteFixtureBridge.ID.history))
        try await waitUntil { model.conversations[RemoteFixtureBridge.ID.history]?.isLoaded == true }
        try await render("remote-host-answered", size: size, model: model, hosts: hosts)

        model.select(.newTask)
        try await render("remote-host-new", size: size, model: model, hosts: hosts)

        model.select(.task(RemoteFixtureBridge.ID.form))
        try await waitUntil { model.conversations[RemoteFixtureBridge.ID.form]?.isLoaded == true }
        try await render("remote-host-form", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == "Repository" }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == "Submit" }, elements.description)
        }

        model.select(.task(RemoteFixtureBridge.ID.approval))
        await stack.server.shutdown(reason: "quitting")
        stack.stop()
        stopped = true
        try await waitUntil { if case .unreachable = model.connection { true } else { false } }
        try await render("remote-host-offline", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Try Again") }, elements.description)
        }
        hosts.close(host.id)
    }

    func testAHostsOwnCardsDrawAsTheLocalOnesDo() async throws {
        let folder = URL(filePath: "/tmp/remote-render/yardlet", directoryHint: .isDirectory)
        let claude = URL(filePath: "/tmp/claude")
        let now = Date()
        let migrate = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: claude,
                                    title: "Migrate the session index", status: .waitingForApproval, updatedAt: now)
        let release = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: claude,
                                    title: "Pick the release name", status: .waitingForApproval,
                                    updatedAt: now.addingTimeInterval(-60))
        let bundle = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: claude,
                                   title: "Build the release bundle", status: .completed,
                                   updatedAt: now.addingTimeInterval(-600), hasUnreadUpdate: true, completionState: .completed)
        let child = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: claude,
                                  title: "Check the bundle's signature", updatedAt: now.addingTimeInterval(-900),
                                  parentTaskID: bundle.id)
        // Claude Code's own answers for a Bash call it offers to allow for good (`ClaudePermissionSuggestions`).
        let offer = ClaudePermissionSuggestionOffer(
            action: PermissionRequestAction(id: ClaudePermissionSuggestions.ActionID.allowAlways,
                                            label: L10n.format("Always allow in this project (saved to %@)", ".claude/settings.local.json"),
                                            decision: .allow, kind: ClaudePermissionSuggestions.ActionID.allowAlways),
            updates: [])
        let bash = PermissionRequest(id: "toolu-bash", title: "Bash", detail: "Run the migration tests",
                                     command: "swift test --filter Migration", actions: ClaudePermissionSuggestions.actions(for: offer),
                                     toolCallID: "toolu-bash")
        let patch = "@@ -12,7 +12,9 @@ struct SessionRepository {\n-    let schema = 3\n+    let schema = 4\n+    let compatibility = CompatibilityView()\n"
        let migrateEntries = [
            TranscriptEntry(content: .user(text: "Migrate the index to the new schema and run the migration tests")),
            TranscriptEntry(content: .assistant(text: "I'll read the repository first, then run the tests.", isStreaming: false)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu-read", kind: "Read", title: "Read",
                input: #"{"file_path":"/tmp/remote-render/yardlet/Sources/SessionRepository.swift"}"#,
                output: "struct SessionRepository {\n    let schema = 3\n}"), state: .completed)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu-edit", kind: "Edit", title: "Edit",
                input: #"{"file_path":"/tmp/remote-render/yardlet/Sources/SessionRepository.swift","old_string":"let schema = 3","new_string":"let schema = 4"}"#,
                diff: HarnessActivityDiff(path: "/tmp/remote-render/yardlet/Sources/SessionRepository.swift", unified: patch)),
                state: .completed)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu-bash", kind: "Bash", title: "Bash",
                input: #"{"command":"swift test --filter Migration","description":"Run the migration tests"}"#), state: .running)),
            TranscriptEntry(content: .permission(bash, state: .pending))
        ]
        let question = PermissionRequest(
            id: "toolu-ask", title: "Question", detail: nil, command: nil,
            structured: .questions([PermissionQuestion(question: "Which name should the release use?", header: "Name", options: [
                .init(label: "Juniper", description: "Short and easy to say"), .init(label: "Larch", description: "Keeps the tree names"),
                .init(label: "Hornbeam")], allowsCustomAnswer: true)]))
        let releaseEntries = [TranscriptEntry(content: .user(text: "Pick a name for the 1.0 release")),
                              TranscriptEntry(content: .permission(question, state: .pending))]
        let bundleEntries = [TranscriptEntry(content: .user(text: "Build the release bundle")),
                             TranscriptEntry(content: .assistant(text: "The bundle is built and signed.", isStreaming: false))]
        let transcripts = [migrate.id: migrateEntries, release.id: releaseEntries, bundle.id: bundleEntries]
        let sessions = [migrate, release, bundle, child]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostWindowRenderingTests")))
        let host = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), initialTranscripts: transcripts,
                            restoresIndexOnLaunch: false)
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot }
        let size = NSSize(width: 1280, height: 820)
        // The local conversation in the width the host window's conversation takes.
        let column = NSSize(width: size.width - ParityTheme.sidebarWidth - 21, height: size.height - ParityTheme.paneToolbarHeight)

        for (session, entries, name) in [(migrate, migrateEntries, "approval"), (release, releaseEntries, "question")] {
            model.select(.task(session.id.uuidString))
            let conversation = try XCTUnwrap(model.conversations[session.id.uuidString])
            try await waitUntil { conversation.isLoaded && conversation.presentation.turns.last?.requests.isEmpty == false }
            // The card offers what the host's own card offers, in its order and its words.
            let local = TranscriptConversationProjection.presentation(from: entries, harness: .claudeCode, status: .waitingForApproval,
                                                                      latestTurnIsComplete: false)
            let localRequest = try XCTUnwrap(local.turns.last?.requests.first)
            let remoteRequest = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
            XCTAssertEqual(remoteRequest.responses.map(\.title), localRequest.responses.map(\.title))
            XCTAssertEqual(remoteRequest.responses.map(\.role), localRequest.responses.map(\.role))
            XCTAssertEqual(remoteRequest.command, localRequest.command)
            XCTAssertEqual(remoteRequest.form?.questionSteps.map(\.text), localRequest.form?.questionSteps.map(\.text))
            try await render("remote-host-\(name)", size: size, model: model, hosts: hosts)
            try await render("local-\(name)", size: column, titled: false) {
                localTimeline(entries, folder: folder)
            }
        }

        // The same turn's lines opened: the Read's output and the Edit's diff, read from the host as they open.
        model.select(.task(migrate.id.uuidString))
        let conversation = try XCTUnwrap(model.conversations[migrate.id.uuidString])
        let lines = try XCTUnwrap(conversation.presentation.turns.last).work.filter { item in
            if case let .tool(tool) = item.kind { return tool.loadsDetailOnOpen }
            return false
        }
        XCTAssertEqual(lines.count, 2)
        for line in lines { model.loadDetail(migrate.id.uuidString, itemID: line.id) }
        try await waitUntil { lines.allSatisfy { conversation.details[$0.id] != nil } }
        // The waiting turn folds its calls into one line, here as there; it is opened as the person would.
        let folded = { (label: String) in label.contains(L10n.string("Awaiting approval")) }
        try await render("remote-host-lines", size: size, model: model, hosts: hosts, opensDetails: true, check: { _ in },
                         press: folded)
        try await render("local-lines", size: column, titled: false, press: folded) {
            localTimeline(migrateEntries, folder: folder).environment(\.opensDetailsForReview, true)
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    /// A suggested task's chip, a task's outputs on the session rail and the scheduled tasks list, each drawn in
    /// the host window from what the host (the app's own model) sends, and by the local views from the same state.
    func testSuggestionsOutputsAndSchedulesDrawAsTheLocalOnesDo() async throws {
        let website = URL(filePath: "/tmp/remote-render/website", directoryHint: .isDirectory)
        let claude = URL(filePath: "/tmp/claude")
        let now = Date()
        let footer = SessionRecord(harness: .claudeCode, workspaceURL: website, runtimeExecutableURL: claude,
                                   title: "Fix the footer links", status: .completed, updatedAt: now.addingTimeInterval(-60),
                                   completionState: .completed)
        let crash = SessionRecord(harness: .claudeCode, workspaceURL: website, runtimeExecutableURL: claude,
                                  title: "Summarize the crash reports", status: .completed, updatedAt: now,
                                  completionState: .completed)
        let suggestion = ConversationTaskSuggestion(
            id: "task_00000001", title: "Add a link checker to CI",
            tldr: "Run a link check on every pull request so footer links cannot break again.",
            prompt: "Add a CI job that checks every link in the footer.", startsInNewWorktree: false)
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds - 600) }
        let footerEntries = [
            TranscriptEntry(createdAt: at(0), content: .user(text: "Find the footer links that 404")),
            TranscriptEntry(createdAt: at(6), content: .activity(HarnessActivity(
                id: "toolu_read", kind: "Read", title: "Read", input: #"{"file_path":"/tmp/remote-render/website/Footer.tsx"}"#,
                output: "export function Footer() {}"), state: .completed)),
            TranscriptEntry(createdAt: at(12), content: .activity(HarnessActivity(
                id: "toolu_spawn", kind: "mcp__yardlet__spawn_task", title: "mcp__yardlet__spawn_task",
                input: JSONValue.object(["title": .string(suggestion.title ?? ""), "tldr": .string(suggestion.tldr ?? ""),
                                         "prompt": .string(suggestion.prompt)]).readableText,
                output: TaskSuggestionToolCatalog.notedResult(taskID: suggestion.id)), state: .completed)),
            TranscriptEntry(createdAt: at(18), content: .assistant(
                text: "Two links pointed at pages that moved; both now point at their new paths.", isStreaming: false))
        ]
        func written(_ path: String, _ seconds: TimeInterval) -> TranscriptEntry {
            TranscriptEntry(createdAt: at(seconds), content: .activity(HarnessActivity(
                id: "write-\(Int(seconds))", kind: "Write", title: "Write", diff: HarnessActivityDiff(path: path, newText: "x")),
                state: .completed))
        }
        let crashEntries = [
            TranscriptEntry(createdAt: at(0), content: .user(text: "Summarize last week's crash reports")),
            written("/tmp/remote-render/Desktop/crash-summary.pdf", 30),
            written("reports/crash-chart.png", 60),
            TranscriptEntry(createdAt: at(90), content: .assistant(
                text: "The summary is on the Desktop and the chart is in `reports/crash-chart.png`.", isStreaming: false))
        ]
        func run(_ outcome: ScheduledTaskRun.Outcome, hoursAgo: Double, task: UUID? = nil, failure: String? = nil) -> ScheduledTaskRun {
            ScheduledTaskRun(at: now.addingTimeInterval(-hoursAgo * 3_600), trigger: .scheduled, outcome: outcome,
                             failure: failure, taskID: task)
        }
        var morning = ScheduledTask(name: "Summarize new crash reports", prompt: "Summarize the new crash reports",
                                    trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                    destination: ScheduleDestination(harness: .claudeCode, workspacePath: website.path(percentEncoded: false)),
                                    createdAt: now)
        morning.state.runs = [run(.started, hoursAgo: 1, task: crash.id)]
        var weekly = ScheduledTask(name: "Check the footer links", prompt: "Check the footer links",
                                   trigger: .weekly(days: [.monday], time: ScheduleTime(hour: 10, minute: 0)),
                                   destination: ScheduleDestination(mode: .continueTask, harness: .claudeCode, targetTaskID: footer.id),
                                   isEnabled: false, createdAt: now)
        weekly.state.runs = [run(.started, hoursAgo: 26, task: footer.id)]
        var nightly = ScheduledTask(name: "Nightly screenshots", prompt: "Shoot", trigger: .daily(ScheduleTime(hour: 2, minute: 0)),
                                    destination: ScheduleDestination(harness: .codex, workspacePath: website.path(percentEncoded: false)),
                                    isEnabled: false, createdAt: now)
        nightly.state.stopReason = .repeatedFailures
        nightly.state.consecutiveFailures = 3
        nightly.state.runs = [run(.failed, hoursAgo: 3, failure: "No simulator")]
        let schedules = [morning, weekly, nightly]

        let sessions = [crash, footer]
        let transcripts = [footer.id: footerEntries, crash.id: crashEntries]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostWindowRenderingTests.parity")))
        let host = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), initialTranscripts: transcripts,
                            scheduleRepository: InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: schedules)),
                            restoresIndexOnLaunch: false)
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot }
        XCTAssertTrue(model.offersSchedules)
        XCTAssertTrue(model.offersTaskFiles)
        let size = NSSize(width: 1280, height: 820)
        let column = NSSize(width: size.width - ParityTheme.sidebarWidth - 21, height: size.height - ParityTheme.paneToolbarHeight)

        // The chip: Start, Do it here and ✕ as on the Mac; Options is the host's.
        model.select(.task(footer.id.uuidString))
        let conversation = try XCTUnwrap(model.conversations[footer.id.uuidString])
        try await waitUntil { conversation.isLoaded && conversation.suggestions[suggestion.id] != nil }
        try await render("remote-host-suggestion", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == "Add a link checker to CI" }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Do it here") }, elements.description)
        }
        try await render("local-suggestion", size: column, titled: false) {
            localTimeline(footerEntries, folder: website, status: .completed)
                .environment(\.taskSuggestionActions, localSuggestionActions(host, session: footer))
        }

        // The rail's Outputs card: the host's card's files, newest first.
        model.select(.task(crash.id.uuidString))
        try await waitUntil { model.conversations[crash.id.uuidString]?.isLoaded == true }
        model.files.loadOutputs(crash.id.uuidString)
        try await waitUntil { model.files.outputs[crash.id.uuidString]?.count == 2 }
        let card = SessionRailContent.outputs(entries: crashEntries, codexChanges: [], workspaceURL: website)
        XCTAssertEqual(RemoteTaskRail.rows(model.files.outputs[crash.id.uuidString] ?? []).map(\.url), card.map(\.url))
        try await render("remote-host-outputs", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Outputs") }, elements.description)
            XCTAssertTrue(elements.contains { $0.label.contains("crash-summary.pdf") }, elements.description)
        }
        let rail = SessionRailContent.make(
            session: crash, projectName: "website", instructionSources: TaskInstructionSources(origin: .detected, paths: []),
            git: nil, options: ComposerSessionOptionsProjection.make(harness: .claudeCode, session: crash, providerCapabilities: nil,
                                                                     providerUsage: nil, entries: crashEntries, isAttached: false),
            connectors: nil, account: nil, entries: crashEntries, codexPlan: nil, pullRequest: nil, pullRequestState: nil)
        var folds = SessionRailFolds()
        folds.setAll(folded: false)
        try await render("local-outputs", size: NSSize(width: column.width, height: size.height), titled: false) {
            HStack(spacing: 0) {
                localTimeline(crashEntries, folder: website, status: .completed)
                Divider()
                SessionRailView(content: rail, folds: .constant(folds),
                                preferences: SessionRailPreferenceStore(defaults: defaults))
            }
        }

        // The scheduled tasks list beside the chosen schedule, in the host's words.
        model.showsSchedules = true
        model.schedules.load()
        try await waitUntil { model.schedules.list?.count == 3 }
        model.select(.schedule(morning.id.uuidString))
        try await render("remote-host-schedules", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == "Summarize new crash reports" }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Run now") }, elements.description)
        }
        let state = ScheduledTasksWindowState()
        state.isShowing = true
        state.selection = morning.id
        try await render("local-schedules", size: size, titled: false) {
            HStack(spacing: 0) {
                ScheduledTasksSidebar(model: host, state: state, onBack: {}, actions: ScheduledTaskActions())
                    .frame(width: ParityTheme.sidebarWidth + 20)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                ScheduledTasksMain(model: host, state: state, actions: ScheduledTaskActions(), projectName: { _ in "website" })
            }
            .background(ParityTheme.canvas)
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    /// A Codex MCP form as the host's card has it, sent as the host sends it (its projection, through JSON) and
    /// drawn by the remote window's card, beside the local card: the same fields, checks and answers.
    func testAnMCPFormDrawsAsTheLocalCardDoes() async throws {
        let local = CodexRequestFormRestorationTests.form([
            "repo": .object(["type": .string("string"), "title": .string("Repository"), "description": .string("owner/name"),
                             "maxLength": .integer(100)]),
            "private": .object(["type": .string("boolean"), "title": .string("Private"), "default": .bool(true)]),
            "team": .object(["type": .string("string"), "title": .string("Team"),
                             "oneOf": .array([.object(["const": .string("web"), "title": .string("Web")]),
                                              .object(["const": .string("ios"), "title": .string("iOS")])])])
        ], required: ["repo"], message: "Create a repository for the new service.")
        var user = RemoteItem(id: "u1", turnId: "t1", kind: .user)
        user.text = "Create a GitHub repository for the billing service"
        let sent = RemoteConversationProjection.request(local, turnID: "t1", inWork: false)
        let wire = try JSONDecoder().decode(RemoteItem.self, from: JSONEncoder().encode(sent))
        let conversation = RemoteConversationModel(taskID: "T", harness: .codex, hostName: "Mac Studio")
        conversation.load([user, wire], cursor: nil, hasOlder: false)
        let remote = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
        guard case let .mcpForm(localForm)? = local.form, case let .mcpForm(remoteForm)? = remote.form else {
            return XCTFail("No form: \(String(describing: remote.form))")
        }
        XCTAssertEqual(remoteForm, localForm)
        XCTAssertEqual(remote.responses.map(\.title), local.responses.map(\.title))
        XCTAssertEqual(remote.responses.map(\.role), local.responses.map(\.role))
        // What Submit sends once filled in is what the host's card would send.
        var input = ConversationRequestFormInput()
        input.fields = ["repo": .text("acme/billing"), "team": .picked(["web"])]
        let submit = try XCTUnwrap(remote.responses.last)
        guard case let .codex(.mcpElicitation(_, content?, _))? = remote.route(for: submit, input: input) else {
            return XCTFail("Submit sends no content")
        }
        XCTAssertEqual(try AppModelRemoteBridge.fieldValues(RemoteTurnProjection.formValues(content), for: localForm).get(),
                       ["repo": .text("acme/billing"), "private": .flag(true), "team": .picked(["web"])])

        var actions = ConversationActions()
        actions.chooseOption = { _, _ in }
        let width = NSSize(width: 760, height: 560)
        try await render("remote-form", size: width, titled: false) {
            ConversationTimeline(source: .presented(conversation.presentation), actions: actions)
                .background(ParityTheme.canvas)
        }
        var turn = ConversationTurn(id: "t1", status: .running, timing: ConversationTurnTiming())
        turn.prompt = [ConversationItem(id: "u1", kind: .userMessage(text: user.text ?? "", images: []), phase: .completed,
                                        source: .transcript(TranscriptEntry(content: .user(text: user.text ?? ""))))]
        turn.requests = [local]
        var presentation = ConversationPresentation(harness: .codex, turns: [turn])
        presentation.pendingRequestIDs = [local.id]
        try await render("local-form", size: width, titled: false) {
            ConversationTimeline(source: .presented(presentation), actions: actions)
                .background(ParityTheme.canvas)
        }
    }

    /// The chips' actions as the local window gives them, with where and with what Start starts each.
    private func localSuggestionActions(_ model: AppModel, session: SessionRecord) -> TaskSuggestionActions {
        TaskSuggestionActions(
            resolution: { model.taskSuggestions.resolution(of: $0, in: session.id) },
            start: { _ in },
            startPlace: { suggestion in
                guard case let .success(start) = model.suggestedTaskStart(for: suggestion, from: session) else {
                    return TaskSuggestionStartPlace(startsInWorktree: false)
                }
                let choice = model.suggestedTaskChoice(for: suggestion, start: start, in: session.id)
                return TaskSuggestionStartPlace(
                    label: model.suggestedTaskPlaceLabel(for: suggestion, start: start, choice: choice, from: session),
                    startsInWorktree: choice.place.folder != nil && choice.place.startsInNewWorktree,
                    settings: model.suggestedTaskSettingsLabel(choice, for: suggestion))
            },
            dismiss: { _ in })
    }

    /// The local timeline of a Claude Code task waiting on the person, whose cards can answer as the window's do.
    private func localTimeline(_ entries: [TranscriptEntry], folder: URL,
                               status: SessionStatus = .waitingForApproval) -> some View {
        var actions = ConversationActions()
        actions.chooseOption = { _, _ in }
        actions.answer = { _, _ in }
        return ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: status,
                                                        latestTurnIsComplete: status != .waitingForApproval), actions: actions)
            .environment(\.transcriptWorkspaceURL, folder)
            .background(ParityTheme.canvas)
    }

    /// A task's controls (§15.23) against the app's own model as the host, beside the same task drawn by the local
    /// conversation and composer: a Codex task's turns with Edit message and Fork from here and its bottom row once the
    /// model menu read its list, the same task editing its latest message, and a Claude Code task in Bypass permissions.
    func testATasksControlsDrawAsTheLocalComposerAndTurnsDo() async throws {
        let folder = URL(filePath: "/tmp/remote-render/yardlet", directoryHint: .isDirectory)
        let codexAdapter = FakeHarnessAdapter(kind: .codex)
        let claudeAdapter = FakeHarnessAdapter(kind: .claudeCode)
        var thread = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"),
            "turns": .array([RemoteTaskControlsTests.codexTurn(1), RemoteTaskControlsTests.codexTurn(2)])
        ]), to: &thread))
        let parser = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                   title: "Tidy the parser", providerSessionID: "provider-thread")
        let guide = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Write the migration guide", status: .completed,
                                  updatedAt: Date().addingTimeInterval(-60), providerSessionID: "claude-session",
                                  completionState: .completed)
        let guideEntries = [TranscriptEntry(content: .user(text: "Write a migration guide for the new session index")),
                            TranscriptEntry(content: .assistant(text: "The guide is in docs/MIGRATION.md.", isStreaming: false))]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostWindowRenderingTests.controls")))
        let host = AppModel(store: SessionStore(sessions: [parser, guide], repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                            registry: HarnessRegistry { kind, _ in kind == .codex ? codexAdapter : claudeAdapter },
                            initialTranscripts: [guide.id: guideEntries], initialCodexPresentation: [parser.id: thread],
                            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
        await codexAdapter.emitPresentation(thread, for: parser.id)
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.taskControls }
        let size = NSSize(width: 1280, height: 820)
        let column = NSSize(width: size.width - ParityTheme.sidebarWidth - 21, height: size.height - ParityTheme.paneToolbarHeight)

        // A Codex task once its model menu read the list: the same row, and the same edit and fork on its turns.
        let parserID = parser.id.uuidString
        model.select(.task(parserID))
        try await waitUntil { model.conversations[parserID]?.isLoaded == true && model.taskSettings[parserID] != nil }
        await model.readTaskSettings(parserID, prepare: true)
        try await waitUntil { model.taskSettings[parserID]?.contains { $0.role == "model" && $0.prepare == nil } == true }
        try await render("remote-controls-codex", size: size, titled: true, title: model.name) {
            RemoteHostView(model: model, directory: hosts).environment(\.revealsSentMessageActions, true)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Permissions") }, elements.description)
        }
        let localDraft = TaskComposerDraft()
        try await render("local-controls-codex", size: column, titled: false) {
            localTask(host, parser, draft: localDraft).environment(\.revealsSentMessageActions, true)
        }

        // Editing the latest request: the banner and the request's words in the composer, here and there.
        let request = try XCTUnwrap(model.conversations[parserID]?.presentation.turns.last?.actions.editLatest)
        let drafts = RemoteComposerDrafts()
        drafts.draft(for: parserID).text = request.text
        drafts.edits[parserID] = RemoteMessageEdit(turnID: "turn-2", previousText: "", previousAttachments: [])
        try await render("remote-controls-edit", size: size, titled: true, title: model.name) {
            RemoteHostView(model: model, directory: hosts, drafts: drafts)
        }
        localDraft.text = request.text
        try await render("local-controls-edit", size: column, titled: false) {
            localTask(host, parser, draft: localDraft, editing: true)
        }

        // A Claude Code task in Bypass permissions, asked about once on each side, drawn in orange.
        let guideID = guide.id.uuidString
        model.select(.task(guideID))
        try await waitUntil { model.conversations[guideID]?.isLoaded == true && model.taskSettings[guideID] != nil }
        await model.readTaskSettings(guideID, prepare: true)
        model.setTaskSetting(guideID, id: ClaudeLaunchOption.permissionMode, value: ClaudePermissionMode.bypassPermissions,
                             confirmed: true)
        try await waitUntil { model.taskSettings[guideID]?.first { $0.role == "permission" }?.elevated == true }
        try await render("remote-controls-claude", size: size, titled: true, title: model.name) {
            RemoteHostView(model: model, directory: hosts).environment(\.revealsSentMessageActions, true)
        }
        let guideNow = try XCTUnwrap(host.store.sessions.first { $0.id == guide.id })
        try await render("local-controls-claude", size: column, titled: false) {
            localTask(host, guideNow, draft: TaskComposerDraft()).environment(\.revealsSentMessageActions, true)
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    /// The local task as the window draws it from the host's own model: its conversation, then its composer with the
    /// bottom row its menus read.
    private func localTask(_ host: AppModel, _ session: SessionRecord, draft: TaskComposerDraft,
                           editing: Bool = false) -> some View {
        // As the window offers them: Codex forks a turn, any other harness where its adapter forks.
        var actions = ConversationActions()
        actions.forkCodexTurn = { _ in }
        actions.branch = host.canBranch(session) ? { _ in } : nil
        actions.rewind = ConversationRewindActions(beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {},
                                                   loadFilePoints: { [] }, previewFiles: { _ in throw CancellationError() },
                                                   restoreFiles: { _ in throw CancellationError() })
        let codex = host.composerCodexCapabilities(for: session)
        let source: ConversationSource = session.harness == .codex
            ? .codex(host.codexPresentationBySessionID[session.id] ?? .empty, workspaceURL: session.workspaceURL, historySelection: nil)
            : .transcript(entries: host.transcriptBySessionID[session.id] ?? [], harness: session.harness, status: session.status,
                          latestTurnIsComplete: session.completionState == .completed)
        return VStack(spacing: 0) {
            ConversationTimeline(source: source, actions: actions)
                .environment(\.transcriptWorkspaceURL, session.workspaceURL)
            if editing { ConversationEditBanner(canCancel: true, onCancel: {}) }
            PromptComposer(
                harness: session.harness, composerDraft: draft, modes: codex.modes, selectedModeID: codex.selectedModeID,
                modelCatalog: codex.modelCatalog, runLocation: codex.selectedRunLocation, providerSession: session,
                providerCapabilities: host.composerProviderCapabilities(for: session), isProviderAttached: host.isAttached(session.id),
                isRunning: false, codexHasThread: session.providerSessionID != nil, workspaceURL: session.workspaceURL,
                actions: ComposerActions(runCodexCommand: session.harness == .codex ? { _ in } : nil))
        }
        .background(ParityTheme.canvas)
    }

    // MARK: - Helpers

    private func render(_ name: String, size: NSSize, model: RemoteHostModel, hosts: RemoteHostDirectory,
                        opensDetails: Bool = false,
                        check: ([WindowlessRender.AccessibilityElement]) -> Void = { _ in },
                        press: ((String) -> Bool)? = nil) async throws {
        try await render(name, size: size, titled: true, title: model.name, subtitle: RemoteConnectionText.line(model.connection),
                         press: press) {
            RemoteHostView(model: model, directory: hosts)
                .environment(\.opensDetailsForReview, opensDetails)
        } check: { check($0) }
    }

    /// Draws the view in an unshown window of `size`, in both appearances; a titled window draws its title
    /// bar too, as the host's window shows its name and connection there.
    private func render<Content: View>(_ name: String, size: NSSize, titled: Bool, title: String = "", subtitle: String = "",
                                       press: ((String) -> Bool)? = nil,
                                       @ViewBuilder content: () -> Content,
                                       check: ([WindowlessRender.AccessibilityElement]) -> Void = { _ in }) async throws {
        let directory = try WindowlessRender.directory("remote-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let hosting = NSHostingView(rootView: content().environment(\.colorScheme, appearance.colorScheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance.appKitName)
            window.title = title
            window.subtitle = subtitle
            window.contentView = hosting
            defer {
                window.contentView = nil
                window.close()
            }
            // The main actor is given back between passes, so the views' tasks (a new task's menus) finish.
            for _ in 0..<20 {
                Self.turnRunLoop(hosting)
                await Task.yield()
                try await Task.sleep(for: .milliseconds(15))
            }
            // A folded line opened as the person would, through the accessibility tree.
            if let press {
                XCTAssertTrue(hosting.pressAccessibilityElement(where: press), "Nothing to open in \(name)")
                for _ in 0..<10 {
                    Self.turnRunLoop(hosting)
                    await Task.yield()
                    try await Task.sleep(for: .milliseconds(15))
                }
            }
            let frame = titled ? (hosting.superview ?? hosting) : hosting
            let bitmap = try WindowlessRender.capture(frame)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 6))
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            if appearance == .light { check(WindowlessRender.accessibilityElements(in: hosting)) }
        }
    }

    /// Lays the view out and turns the main run loop once, as `WindowlessRender.Host.settle` does.
    private static func turnRunLoop(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
