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
/// - `remote-rail-facts-*.png` and `local-rail-facts-*.png`: the host's account, context, limits, plan, child task
///   and pull-request checks on the shared rail; `comparison-rail-facts-*.png` puts them side by side.
/// - `remote-home-facts-*.png` and `local-home-facts-*.png`: the same answer line and finished-today count;
///   `comparison-home-facts-*.png` puts the local home on the left and the remote home on the right.
/// - `remote-form-*.png` and `local-form-*.png`: a Codex MCP form's card, the remote one read from what the host
///   sends for it.
/// - In full detail (§15.24), `remote-full-*.png` and `local-full-*.png`: `answer`, an answer past the phone's 32,000
///   characters; `pictures`, a message's two pictures; `limit`, a plan limit's card with its windows and Auto-continue;
///   `codex`, a Codex turn opened, with a model reroute, a compaction, a subagent and a proposed plan.
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
    func testBankedResetConfirmationMatchesHostOverLoopback() async throws {
        let now = Date()
        let task = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/remote-reset-render"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Continue the migration", completionState: .completed)
        let entries = [TranscriptEntry(content: .user(text: "Continue the migration")),
                       TranscriptEntry(content: .usageLimit(HarnessRateLimit(status: .rejected, window: .session,
                           resetsAt: now.addingTimeInterval(3600), usedFraction: 1)))]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteResetRender")))
        let host = AppModel(store: SessionStore(sessions: [task], repository: InMemorySessionRepository(sessions: [task])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false),
            initialTranscripts: [task.id: entries], restoresIndexOnLaunch: false)
        host.connections.publishDefaults([HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex",
            state: .signedIn, accountLabel: "developer@example.test", detail: "", credentialOwner: "", checkedAt: now,
            usage: [.init(id: "session", label: "5-hour", usedFraction: 1, detail: "100% used",
                resetsAt: now.addingTimeInterval(3600), evidence: .exactQuota)],
            usageResets: AccountUsageResets(availableCount: 2, resets: [.init(id: "private-reset", title: "Full reset",
                expiresAt: now.addingTimeInterval(7200))]), canLogin: false, canLogout: false)])
        let stack = try await LoopbackStack(name: "Host Mac", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop(); Task { await host.shutdown() } }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Host Mac", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "Client Mac", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.bankedResets }
        let response = await model.response(to: .usageReset(taskID: task.id.uuidString))
        let remote = try XCTUnwrap(response.usageReset)
        let choice = host.connections.choice(for: .codex, connection: nil)
        XCTAssertEqual(remote.resets.availableCount, choice.snapshot?.usageResets?.availableCount)
        XCTAssertNil(remote.resets.next?.id, "Provider reset identifiers stay on the host")
        let size = NSSize(width: 380, height: 330)
        try await render("local-banked-reset", size: size, titled: false) {
            UsageResetConfirmation(choice: choice, context: UsageResetContext(store: host.connections,
                runtimeSelections: host.runtimeSelections), close: {})
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.elevated)
        }
        try await render("remote-banked-reset", size: size, titled: false) {
            UsageResetConfirmationContent(title: remote.title, resets: remote.resets, quotas: remote.quotas,
                state: remote.localState, close: {}, use: {})
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.elevated)
        }
    }

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

        // Full subscriptions carry the same Read output and per-file Edit card as the host.
        model.select(.task(migrate.id.uuidString))
        let conversation = try XCTUnwrap(model.conversations[migrate.id.uuidString])
        let lines = try XCTUnwrap(conversation.presentation.turns.last).work
        XCTAssertTrue(lines.contains { if case let .tool(tool) = $0.kind { return tool.output?.isEmpty == false }; return false })
        XCTAssertTrue(lines.contains { if case let .fileChange(change) = $0.kind { return !change.rows.isEmpty }; return false })
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
    /// drawn by the remote window's card, beside the local card: the same message, fields, checks and answers.
    func testAnMCPFormDrawsAsTheLocalCardDoes() async throws {
        let local = CodexRequestFormRestorationTests.form([
            "repo": .object(["type": .string("string"), "title": .string("Repository"), "description": .string("owner/name"),
                             "maxLength": .integer(100)]),
            "private": .object(["type": .string("boolean"), "title": .string("Private"), "default": .bool(true)]),
            "team": .object(["type": .string("string"), "title": .string("Team"),
                             "oneOf": .array([.object(["const": .string("web"), "title": .string("Web")]),
                                              .object(["const": .string("ios"), "title": .string("iOS")])])])
        ], required: ["repo"], message: "Create a repository for the new service.")
        let text = "Create a GitHub repository for the billing service"
        var turn = ConversationTurn(id: "t1", status: .running, timing: ConversationTurnTiming())
        turn.prompt = [ConversationItem(id: "u1", kind: .userMessage(text: text, images: []), phase: .completed,
                                        source: .transcript(TranscriptEntry(content: .user(text: text))))]
        turn.requests = [local]
        var presentation = ConversationPresentation(harness: .codex, turns: [turn])
        presentation.pendingRequestIDs = [local.id]
        // Send the entire host turn, including its running header, just as the real bridge does.
        let sent = RemoteConversationProjection.turn(turn, harness: .codex, workspaceURL: nil, full: .init())
        let wire = try JSONDecoder().decode([RemoteItem].self, from: JSONEncoder().encode(sent.items))
        let conversation = RemoteConversationModel(taskID: "T", harness: .codex, hostName: "Mac Studio")
        conversation.load(wire, cursor: nil, hasOlder: false)
        let remoteTurn = try XCTUnwrap(conversation.presentation.turns.last)
        XCTAssertEqual(remoteTurn.status, turn.status)
        XCTAssertEqual(ConversationLiveWork.make(turn, harness: .codex, workspaceURL: nil)?.activity, .waitingForAnswer)
        XCTAssertEqual(ConversationLiveWork.make(remoteTurn, harness: .codex, workspaceURL: nil)?.activity, .waitingForAnswer)
        let remote = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
        guard case let .mcpForm(localForm)? = local.form, case let .mcpForm(remoteForm)? = remote.form else {
            return XCTFail("No form: \(String(describing: remote.form))")
        }
        XCTAssertEqual(remoteForm, localForm)
        XCTAssertEqual(remote.codexContext?.messages, ["Create a repository for the new service."])
        XCTAssertEqual(remote.codexContext?.messages, local.codexContext?.messages)
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
        try await render("local-form", size: width, titled: false) {
            ConversationTimeline(source: .presented(presentation), actions: actions)
                .background(ParityTheme.canvas)
        }
    }

    /// The chips' actions as the local window gives them, with where and with what Start starts each.
    /// What the host's own cards draw beyond a phone's lines (§15.24), in the same state here and there: a long answer
    /// whole, a message's pictures, a plan limit's card with its windows and actions, and a Codex turn's notice,
    /// compaction, subagent and proposed plan.
    func testTheHostsFullConversationDrawsAsTheLocalTimelineDoes() async throws {
        let folder = URL(filePath: "/tmp/remote-render/yardlet", directoryHint: .isDirectory)
        let claude = URL(filePath: "/tmp/claude"), codex = URL(filePath: "/tmp/codex")
        let now = Date()
        func task(_ harness: HarnessKind, _ title: String, minutesAgo: Double, thread: String? = nil) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: harness == .codex ? codex : claude,
                          title: title, status: .completed, updatedAt: now.addingTimeInterval(-60 * minutesAgo),
                          providerSessionID: thread, completionState: .completed)
        }
        let answer = task(.claudeCode, "Write the migration guide", minutesAgo: 1)
        let pictures = task(.claudeCode, "Fix the login page", minutesAgo: 2)
        let limit = task(.claudeCode, "Refactor the session store", minutesAgo: 3)
        let plan = task(.codex, "Plan the sync engine", minutesAgo: 4, thread: "thread-plan")
        let child = task(.codex, "Survey the sync libraries", minutesAgo: 5, thread: "thread-child")

        // Past the phone's 32,000 characters, so its last paragraph is what a phone never reads.
        let guide = (1...12).map { step in
            "**Step \(step).** Move the next table to the new schema, then run the migration tests. "
                + String(repeating: "Keep the old index until the new one is verified. ", count: 70)
        }.joined(separator: "\n\n") + "\n\n**Last:** remove the compatibility view once every reader moved."
        XCTAssertGreaterThan(guide.count, RemoteText.assistantLimit)
        let answerEntries = [TranscriptEntry(content: .user(text: "Write the migration guide for the new schema")),
                             TranscriptEntry(content: .assistant(text: guide, isStreaming: false))]

        let imageFolder = FileManager.default.temporaryDirectory.appending(path: "remote-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imageFolder) }
        let shots = try [("login-page.png", NSColor.systemBlue), ("error-dialog.png", NSColor.systemOrange)].map { name, color in
            let url = imageFolder.appending(path: name)
            try Self.picture(color: color, label: name).write(to: url)
            return TranscriptImageAttachment(url: url)
        }
        let pictureEntries = [TranscriptEntry(content: .user(text: "The login button overlaps the error dialog", images: shots)),
                              TranscriptEntry(content: .assistant(text: "The dialog now sits below the button.", isStreaming: false))]

        let report = HarnessRateLimit(status: .rejected, window: .session, resetsAt: now.addingTimeInterval(2 * 3600),
                                      usedFraction: 1, windows: [
                                          .init(window: .session, model: nil, usedFraction: 1, resetsAt: now.addingTimeInterval(2 * 3600)),
                                          .init(window: .weekly, model: nil, usedFraction: 0.62,
                                                resetsAt: now.addingTimeInterval(4 * 24 * 3600))])
        // A subagent the same limit stopped reports so after the card, in a turn of its own; the card is still the one
        // the task continues from (`UsageLimitContinuation.card`).
        let limitEntries = [TranscriptEntry(content: .user(text: "Split the session store into its reader and writer")),
                            TranscriptEntry(content: .usageLimit(report)),
                            TranscriptEntry(content: .user(text: "<task-notification>\n<task-id>a5</task-id>\n<status>failed</status>\n"
                                + "<summary>Agent \"Review the store\" failed: You've hit your session limit</summary>\n</task-notification>"))]

        let decoder = CodexTaskDecoder()
        var thread = try XCTUnwrap(decoder.thread(from: .object(["id": .string("thread-plan")])))
        thread.turns = [try XCTUnwrap(decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("completed"), "durationMs": .integer(120_000),
            "items": .array([
                .object(["id": .string("user-1"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Plan the sync engine")])])]),
                .object(["id": .string("turn-1:notice:0"), "type": .string(CodexNoticeItem.itemType),
                         "kind": .string("modelRerouted"), "message": .string("gpt-5.5"), "fromModel": .string("gpt-6"),
                         "reason": .string("highRiskCyberActivity")]),
                .object(["id": .string("compact-1"), "type": .string("contextCompaction")]),
                .object(["id": .string("agent-1"), "type": .string("collabAgentToolCall"), "tool": .string("spawn_agent"),
                         "status": .string("completed"), "senderThreadId": .string("thread-plan"),
                         "receiverThreadIds": .array([.string("thread-child")]), "agentsStates": .object([:]),
                         "prompt": .string("Survey the sync libraries and compare their conflict handling"),
                         "model": .string("gpt-5.5")]),
                .object(["id": .string("plan-1"), "type": .string("plan"),
                         "text": .string("1. Store each change with its vector clock.\n2. Merge on read.\n3. Compact the log nightly.")]),
                .object(["id": .string("answer-1"), "type": .string("agentMessage"), "phase": .string("final_answer"),
                         "text": .string("The plan is above. Say the word and I'll implement it."),
                         "questions": .array([.object(["title": .string("Which store should be migrated first?"),
                             "options": .array([.string("The task index"), .string("The transcript store")])])])])
            ])
        ]), fallbackID: "turn-1"))]
        let codexState = CodexTaskState(thread: thread)

        let sessions = [answer, pictures, limit, plan, child]
        let transcripts = [answer.id: answerEntries, pictures.id: pictureEntries, limit.id: limitEntries]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostWindowRenderingTests")))
        let host = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), initialTranscripts: transcripts,
                            initialCodexPresentation: [plan.id: codexState], restoresIndexOnLaunch: false)
        let stack = try await LoopbackStack(name: "Mac Studio",
                                            bridge: AppModelRemoteBridge(model: host, makePreview: RemoteImagePreviewMaker.make))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.sendsFullConversation }
        let size = NSSize(width: 1280, height: 820)
        let column = NSSize(width: size.width - ParityTheme.sidebarWidth - 21, height: size.height - ParityTheme.paneToolbarHeight)
        func open(_ session: SessionRecord, until ready: @escaping (ConversationPresentation) -> Bool) async throws -> ConversationPresentation {
            model.select(.task(session.id.uuidString))
            let conversation = try XCTUnwrap(model.conversations[session.id.uuidString])
            try await waitUntil { conversation.isLoaded && ready(conversation.presentation) }
            return conversation.presentation
        }
        func transcript(_ entries: [TranscriptEntry]) -> ConversationPresentation {
            TranscriptConversationProjection.presentation(from: entries, harness: .claudeCode, status: .completed,
                                                          latestTurnIsComplete: true)
        }

        // The whole answer, not the phone's first 32,000 characters: Show more opens it to its last paragraph here as there.
        let remoteAnswer = try await open(answer) { !$0.turns.isEmpty }
        XCTAssertEqual(remoteAnswer.turns.last?.answers.map(\.kind), transcript(answerEntries).turns.last?.answers.map(\.kind))
        let more = { (label: String) in label == L10n.string("Show more") }
        let latest = { (label: String) in label == L10n.string("Latest response") }
        try await render("remote-full-answer", size: size, model: model, hosts: hosts, opening: more, press: latest)
        try await render("local-full-answer", size: column, titled: false, opening: more, press: latest) {
            localTimeline(answerEntries, folder: folder, status: .completed)
        }

        // The message's pictures as small previews, once the host made them.
        let remotePictures = try await open(pictures) { presentation in
            guard case let .userMessage(_, images)? = presentation.turns.first?.prompt.first?.kind else { return false }
            return images.count == 2 && images.allSatisfy { $0.url?.scheme == "data" }
        }
        guard case let .userMessage(_, previews)? = remotePictures.turns.first?.prompt.first?.kind else { return XCTFail() }
        XCTAssertEqual(previews.map(\.name), shots.map(\.name))
        try await render("remote-full-pictures", size: size, model: model, hosts: hosts)
        try await render("local-full-pictures", size: column, titled: false) {
            localTimeline(pictureEntries, folder: folder, status: .completed)
        }

        // The limit card with the windows the provider reported, and what the host's card offers: continuing once
        // the limit resets (no other account is saved there).
        let limitOutcome = { (presentation: ConversationPresentation) in presentation.turns.lazy.compactMap(\.outcome).last }
        let remoteLimit = try await open(limit) { limitOutcome($0) != nil }
        guard case let .usageLimit(remoteReport, _)? = limitOutcome(remoteLimit),
              case let .usageLimit(localReport, _)? = limitOutcome(transcript(limitEntries)) else { return XCTFail() }
        XCTAssertEqual(remoteLimit.turns.count, transcript(limitEntries).turns.count)
        XCTAssertEqual(remoteLimit.turns.last?.prompt.map(\.backgroundTaskNotice),
                       transcript(limitEntries).turns.last?.prompt.map(\.backgroundTaskNotice))
        XCTAssertEqual(remoteReport.windows.map(\.window), localReport.windows.map(\.window))
        XCTAssertEqual(remoteReport.window, localReport.window)
        try await waitUntil { model.conversations[limit.id.uuidString]?.usageLimit?.options == ["autoContinue", "resumeAfterReset"] }
        let toggle = L10n.string("Auto-continue when limits reset")
        try await render("remote-full-limit", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == toggle }, elements.description)
        }
        var limitActions = ConversationActions()
        limitActions.providerNotices = TaskProviderNotices(canContinue: true)
        try await render("local-full-limit", size: column, titled: false) {
            localTimeline(limitEntries, folder: folder, status: .completed, actions: limitActions)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label == toggle }, elements.description)
        }

        // A Codex turn: the reroute beside it, and in its work the compaction and the subagent, whose child thread
        // opens as the host's task it runs in; the proposed plan in its card above the answer.
        let remotePlan = try await open(plan) { !$0.turns.isEmpty }
        let localPlan = CodexConversationProjection.presentation(codexState, workspaceURL: folder, historySelection: nil)
        let remoteTurn = try XCTUnwrap(remotePlan.turns.last), localTurn = try XCTUnwrap(localPlan.turns.last)
        XCTAssertEqual(remoteTurn.notices.map(\.kind), localTurn.notices.map(\.kind))
        XCTAssertEqual(remoteTurn.answers.map(\.kind), localTurn.answers.map(\.kind))
        let kinds = { (turn: ConversationTurn) in
            turn.work.compactMap { item -> String? in
                switch item.kind {
                case .compaction: "compaction"
                case let .subagent(subagent): "subagent \(subagent.title) \(subagent.input ?? "") \(subagent.model ?? "")"
                default: nil
                }
            }
        }
        XCTAssertEqual(kinds(remoteTurn), kinds(localTurn))
        let routes = remoteTurn.work.compactMap { item -> [ConversationSubagentRoute]? in
            if case let .subagent(subagent) = item.kind { return subagent.routes }
            return nil
        }
        XCTAssertEqual(routes, [[.codexThread(child.id.uuidString)]])
        try await render("remote-full-codex", size: size, model: model, hosts: hosts)
        XCTAssertEqual(remoteTurn.actions.planToImplement, localTurn.actions.planToImplement)
        XCTAssertEqual(remoteTurn.actions.questionsToAnswer, localTurn.actions.questionsToAnswer)
        try await render("local-full-codex", size: column, titled: false) {
            ConversationTimeline(source: .codex(codexState, workspaceURL: folder, historySelection: nil),
                                 actions: ConversationActions(implementCodexPlan: { _ in }, answerQuestion: { _ in }))
                .environment(\.transcriptWorkspaceURL, folder)
                .background(ParityTheme.canvas)
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    /// A picture to send: a field of one color with its name.
    static func picture(color: NSColor, label: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { rect in
            color.setFill()
            rect.fill()
            (label as NSString).draw(at: NSPoint(x: 60, y: 360), withAttributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

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
                               status: SessionStatus = .waitingForApproval,
                               actions: ConversationActions = ConversationActions()) -> some View {
        var actions = actions
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

    /// The host's account, usage, plan, child and pull request survive the real encrypted loopback.
    func testRailFactsDrawAsTheLocalRailDoes() async throws {
        let fixture = try railHomeFixture()
        let host = fixture.host
        let session = fixture.task
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                       name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                       hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.offersTaskRail }
        let taskID = session.id.uuidString
        model.select(.task(taskID))
        try await waitUntil { model.conversations[taskID]?.isLoaded == true }
        await model.readTaskRail(taskID)
        try await waitUntil { model.taskRailFacts[taskID] != nil }
        let remoteSession = try XCTUnwrap(model.sidebar.sessions.first { $0.id == session.id })
        let remoteOptions = model.railComposerOptions(taskID)
        let remote = RemoteRailProjection.content(
            session: remoteSession, projectName: "rail-home", options: remoteOptions, outputs: [],
            hostName: model.name, facts: model.taskRailFacts[taskID])
        let localOptions = ComposerSessionOptionsProjection.make(
            harness: session.harness, session: session, providerCapabilities: host.composerProviderCapabilities(for: session),
            providerUsage: ComposerUnificationFixtures.providerUsage, entries: fixture.entries, isAttached: host.isAttached(session.id))
        let local = SessionRailContent.make(
            session: session, projectName: "rail-home", instructionSources: host.instructionSources(for: session),
            git: nil, options: localOptions, connectors: nil, account: fixture.account, entries: fixture.entries,
            codexPlan: nil, pullRequest: host.pullRequests.pullRequest(for: session.id),
            pullRequestState: host.pullRequestDetails.state(for: session.id), childTasks: host.railChildTasks(of: session.id))
        XCTAssertEqual(remote.cards(SessionRailPreferences()), local.cards(SessionRailPreferences()))
        XCTAssertEqual(remote.environment.locationTitle, "Mac Studio")
        XCTAssertNil(remote.environment.folderURL)
        XCTAssertEqual(remote.settings?.accountName, local.settings?.accountName)
        XCTAssertEqual(remote.context, local.context)
        XCTAssertEqual(remote.contextUsage?.contextUsedTokens, local.contextUsage?.contextUsedTokens)
        XCTAssertEqual(remoteOptions?.contextUsage?.contextUsedTokens, local.contextUsage?.contextUsedTokens)
        XCTAssertEqual(remote.usage?.windows.map(\.remainingPercent), local.usage?.windows.map(\.remainingPercent))
        XCTAssertEqual(remote.progress?.plan.steps.map(\.text), local.progress?.plan.steps.map(\.text))
        XCTAssertEqual(remote.progress?.plan.steps.map(\.status), local.progress?.plan.steps.map(\.status))
        XCTAssertEqual(remote.agents?.agents.map(\.title), local.agents?.agents.map(\.title))
        XCTAssertEqual(remote.changes?.pullRequest, local.changes?.pullRequest)
        XCTAssertEqual(remote.changes?.detail?.checks, local.changes?.detail?.checks)
        var folds = SessionRailFolds()
        folds.setAll(folded: false)
        let preferences = SessionRailPreferenceStore(defaults: fixture.defaults)
        let actions = SessionRailActions(pullRequest: SessionRailPullRequestActions())
        let size = NSSize(width: SessionRailPlacement.width, height: 1900)
        for (name, content) in [("local-rail-facts", local), ("remote-rail-facts", remote)] {
            try await render(name, size: size, titled: false) {
                SessionRailView(content: content, folds: .constant(folds), preferences: preferences, actions: actions)
                    .background(ParityTheme.canvas)
            } check: { elements in
                for title in ["Context", "Usage", "Progress", "Agents", "Changes"] {
                    XCTAssertTrue(elements.contains { $0.label == L10n.string(title) }, "Missing \(title): \(elements)")
                }
            }
        }
        try await render("comparison-rail-facts", size: NSSize(width: size.width * 2 + 1, height: size.height), titled: false) {
            HStack(spacing: 0) {
                SessionRailView(content: local, folds: .constant(folds), preferences: preferences, actions: actions)
                Divider()
                SessionRailView(content: remote, folds: .constant(folds), preferences: preferences, actions: actions)
            }
            .background(ParityTheme.canvas)
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    /// The home reads its answer lines and finished count from the same host as the task rail.
    func testHomeAnswerLinesAndFinishedTodayDrawAsTheLocalOnesDo() async throws {
        let fixture = try railHomeFixture()
        let host = fixture.host
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
        let remote = RemoteNewTaskView(model: model, draft: TaskComposerDraft(), chosenProjectID: .constant(nil)).activity
        let local = NewTaskHomeActivity(
            sessions: host.sidebarSessions, details: host.taskAttentionDetails,
            groups: host.projects.visibleGroups(sessions: host.sidebarSessions),
            chats: host.projects.chats(sessions: host.sidebarSessions),
            now: remote.now, answerLine: { host.answerLineBySessionID[$0] }, latestTurn: { host.latestTurnBySessionID[$0] })
        XCTAssertEqual(remote.answerLine(fixture.task.id), local.answerLine(fixture.task.id))
        XCTAssertEqual(remote.answerLine(fixture.task.id), "The migration is ready for review.")
        XCTAssertEqual(remote.latestTurn(fixture.task.id)?.startedAt?.timeIntervalSince1970 ?? 0,
                       local.latestTurn(fixture.task.id)?.startedAt?.timeIntervalSince1970 ?? 0, accuracy: 0.001)
        func summaries(_ activity: NewTaskHomeActivity) -> [NewTaskProjectSummary] {
            NewTaskHomeListsProjection.projectSummaries(groups: activity.groups, chats: activity.chats,
                details: activity.details, answerLine: activity.answerLine, latestTurn: activity.latestTurn, now: activity.now)
        }
        XCTAssertEqual(summaries(remote).map(\.finishedToday), summaries(local).map(\.finishedToday))
        XCTAssertEqual(summaries(remote).reduce(0) { $0 + $1.finishedToday }, 1)
        let size = NSSize(width: 640, height: 500)
        for (name, activity) in [("local-home-facts", local), ("remote-home-facts", remote)] {
            try await render(name, size: size, titled: false) {
                RailHomeListsRender(activity: activity)
            } check: { elements in
                XCTAssertTrue(elements.contains { $0.label.contains("The migration is ready for review.") }, elements.description)
                XCTAssertTrue(elements.contains { $0.label.contains(L10n.format("%lld finished today", 1)) }, elements.description)
            }
        }
        try await render("comparison-home-facts", size: NSSize(width: 1281, height: 500), titled: false) {
            HStack(spacing: 0) {
                RailHomeListsRender(activity: local).frame(width: 640)
                Divider()
                RailHomeListsRender(activity: remote).frame(width: 640)
            }
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    private struct RailHomeFixture {
        let host: AppModel
        let task: SessionRecord
        let entries: [TranscriptEntry]
        let account: SessionRailAccount
        let defaults: UserDefaults
    }

    /// Entirely in-memory account and pull-request readings; no credentials, CLI or GitHub requests.
    private func railHomeFixture() throws -> RailHomeFixture {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostWindowRenderingTests.railHome")))
        let connections = ProviderConnectionStore()
        let connection = ProviderConnection(id: "render-account", name: "Review account", harness: .claudeCode,
                                            providerID: nil, homePath: nil, credentialSelector: nil)
        try connections.save(connection)
        let now = Date()
        let accountSnapshot = HarnessAccountSnapshot(
            id: connection.id, harness: .claudeCode, providerID: nil, state: .signedIn,
            accountLabel: "review@example.test", accountOrganization: nil, accountPlan: nil, detail: "",
            credentialOwner: "", checkedAt: now,
            usage: [AccountUsageMetric(id: "claude:session", label: "5 hour limit", usedFraction: 0.36, detail: "",
                                        resetsAt: now.addingTimeInterval(7200), evidence: .exactQuota),
                    AccountUsageMetric(id: "claude:week", label: "7 day limit", usedFraction: 0.19, detail: "",
                                        resetsAt: now.addingTimeInterval(345600), evidence: .exactQuota)],
            canLogin: false, canLogout: false)
        connections.publish(accountSnapshot, for: connection)
        let folder = URL(filePath: "/tmp/remote-render/rail-home", directoryHint: .isDirectory)
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: "Migrate the session index", status: .completed, updatedAt: now,
                                 hasUnreadUpdate: true, completionState: .completed, connection: connection)
        let child = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Review the migration", status: .running, updatedAt: now.addingTimeInterval(-10),
                                  parentTaskID: task.id)
        let entries = [
            TranscriptEntry(createdAt: now.addingTimeInterval(-120), content: .user(text: "Migrate the session index")),
            TranscriptEntry(createdAt: now.addingTimeInterval(-60), content: .plan(
                "☑ Read the current schema\n☑ Write the migration\n◉ Review the migration\n☐ Run the full suite")),
            TranscriptEntry(createdAt: now, content: .assistant(text: "The migration is ready for review.", isStreaming: false))
        ]
        let host = AppModel(store: SessionStore(sessions: [task, child], repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), connections: connections,
                            initialTranscripts: [task.id: entries],
                            initialProviderCapabilities: [task.id: ComposerUnificationFixtures.claudeLiveCapabilities],
                            initialProviderUsage: [task.id: ComposerUnificationFixtures.providerUsage], preferences: defaults,
                            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
        let pullRequest = TaskPullRequest(number: 341, url: PullRequestDetailTests.url, repository: nil,
                                          state: .open, checks: .failing, review: .changesRequested)
        host.pullRequests.setPullRequest(pullRequest, for: task.id)
        var state = PullRequestDetailCenter.TaskState(url: pullRequest.url, folder: folder)
        state.detail = GitHubPullRequestDetailParser.parse(Data(PullRequestDetailTests.viewJSON().utf8))
        state.mergeMethods = .all
        host.pullRequestDetails.setState(state, for: task.id)
        return RailHomeFixture(host: host, task: task, entries: entries,
                               account: SessionRailAccount(choice: AccountChoice(harness: .claudeCode,
                                                                                connection: connection, snapshot: accountSnapshot)),
                               defaults: defaults)
    }

    private struct RailHomeListsRender: View {
        let activity: NewTaskHomeActivity
        @State private var keyboard = NewTaskHomeListKeyboard()
        @FocusState private var focus: NewTaskHomeLists.Part?

        var body: some View {
            NewTaskHomeLists(part: .projects, folder: nil, startsChat: false, canUseWorktree: false,
                             startsInNewWorktree: false, git: .none, activity: activity, rowLimit: 8,
                             recentSessions: activity.sessions, onAction: { _ in }, keyboard: $keyboard, focus: $focus,
                             onListed: { _, _ in }, onReturnToComposer: {},
                             readFolderGit: { _ in .none }, readLeftWork: { _ in nil })
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
    }

    // MARK: - Helpers

    func render(_ name: String, size: NSSize, model: RemoteHostModel, hosts: RemoteHostDirectory,
                        opensDetails: Bool = false,
                        check: ([WindowlessRender.AccessibilityElement]) -> Void = { _ in },
                        opening: ((String) -> Bool)? = nil, press: ((String) -> Bool)? = nil) async throws {
        try await render(name, size: size, titled: true, title: model.name, subtitle: RemoteConnectionText.line(model.connection),
                         opening: opening, press: press) {
            RemoteHostView(model: model, directory: hosts)
                .environment(\.opensDetailsForReview, opensDetails)
        } check: { check($0) }
    }

    /// Draws the view in an unshown window of `size`, in both appearances; a titled window draws its title
    /// bar too, as the host's window shows its name and connection there. What `opening` matches is pressed until
    /// nothing does (Show more on a long answer), then what `press` matches once.
    func render<Content: View>(_ name: String, size: NSSize, titled: Bool, title: String = "", subtitle: String = "",
                                       opening: ((String) -> Bool)? = nil, press: ((String) -> Bool)? = nil,
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
            func settle() async throws {
                for _ in 0..<10 {
                    Self.turnRunLoop(hosting)
                    await Task.yield()
                    try await Task.sleep(for: .milliseconds(15))
                }
            }
            // Folded parts opened, and a line pressed, as the person would, through the accessibility tree.
            if let opening {
                var opened = 0
                while opened < 20, hosting.pressAccessibilityElement(where: opening) {
                    opened += 1
                    try await settle()
                }
                XCTAssertGreaterThan(opened, 0, "Nothing to open in \(name)")
            }
            if let press {
                XCTAssertTrue(hosting.pressAccessibilityElement(where: press), "Nothing to press in \(name)")
                try await settle()
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
