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
/// - `remote-host-suggestion-*.png` and `local-suggestion-*.png`: a finished task with a suggested task's chip;
///   `remote-host-suggestion-options-*.png` and `local-suggestion-options-*.png`: its Options popover.
/// - `remote-host-outputs-*.png` and `local-outputs-*.png`: a task that wrote a report and a chart, with the
///   session rail's Outputs card beside it.
/// - `remote-host-schedules-*.png` and `local-schedules-*.png`: the scheduled tasks list beside a schedule.
/// - `remote-rail-facts-*.png` and `local-rail-facts-*.png`: the host's account, context, limits, plan, child task
///   and pull-request checks on the shared rail; `comparison-rail-facts-*.png` puts them side by side.
/// - `remote-home-facts-*.png` and `local-home-facts-*.png`: the same answer line and finished-today count;
///   `comparison-home-facts-*.png` puts the local home on the left and the remote home on the right.
/// - `remote-attention-menu-*.png` and `local-attention-menu-*.png`: the Dock badge count, activity toggle and menu
///   bar menu with the host's waiting and unread tasks; `comparison-attention-menu-*.png` puts them side by side.
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
/// - `remote-controls-needs-terminal-*.png`: Bypass permissions refused for a device without its Terminal permission.
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

    func testTaskActionSurfacesDrawFromTheSameHost() async throws {
        let accountFolder = FileManager.default.temporaryDirectory.appending(path: "remote-account-render-\(UUID())")
        try FileManager.default.createDirectory(at: accountFolder.appending(path: "projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: accountFolder) }
        let connections = (0..<3).map { index in
            ProviderConnection(id: "account-\(index)", name: ["Primary", "Secondary", "Signed out"][index],
                harness: .claudeCode, providerID: nil, homePath: accountFolder.path, credentialSelector: nil)
        }
        let readings = Dictionary(uniqueKeysWithValues: connections.enumerated().map { index, connection in
            (connection.id, HarnessAccountSnapshot(id: connection.id, harness: .claudeCode, providerID: nil,
                state: index == 2 ? .signedOut : .signedIn, accountLabel: ["primary@example.test", "secondary@example.test", "offline@example.test"][index],
                detail: "", credentialOwner: "", checkedAt: Date(),
                usage: index == 2 ? [] : [AccountUsageMetric(id: "session", label: "5-hour", usedFraction: index == 0 ? 0.7 : 0.2,
                    detail: "", resetsAt: Date(timeIntervalSince1970: 2_000_000_000), evidence: .exactQuota)],
                canLogin: false, canLogout: false))
        })
        let accountStore = ProviderConnectionStore(connectionLoader: { connection, _ in readings[connection.id]! })
        for connection in connections {
            try accountStore.save(connection)
            accountStore.publish(readings[connection.id]!, for: connection)
        }
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/remote-render/actions"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review the migration", status: .waitingForApproval, connection: connections[0])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteTaskActionsRender")))
        let saved = SessionRecord(harness: .claudeCode, workspaceURL: session.workspaceURL,
            runtimeExecutableURL: session.runtimeExecutableURL, title: "Restore the release notes")
        let parent = SessionRecord(harness: .claudeCode, workspaceURL: session.workspaceURL,
            runtimeExecutableURL: session.runtimeExecutableURL, title: "Plan the release")
        let repository = InMemorySessionRepository(sessions: [session, parent, saved], archived: [saved.id])
        let host = AppModel(store: SessionStore(sessions: [session, parent], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), connections: accountStore, initialTranscripts: [session.id: [
                TranscriptEntry(content: .permission(PermissionRequest(id: "request", title: "Bash", detail: nil, command: "swift test"), state: .pending))
            ]], preferences: defaults, restoresIndexOnLaunch: false)
        _ = host.projects.ensureProject(forRoot: session.workspaceURL)
        _ = host.projects.ensureProject(forRoot: URL(filePath: "/tmp/remote-render/documentation"))
        let pullRequest = TaskPullRequest(number: 42, url: URL(string: "https://github.com/example/project/pull/42")!,
            repository: "example/project", state: .open, checks: .passing)
        host.pullRequests.setPullRequest(pullRequest, for: session.id)
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let remote = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { remote.hasSnapshot }
        await host.loadArchivedTasks()
        await remote.loadArchivedTasks()
        let accountReply = await remote.response(to: .taskAccounts(taskID: session.id.uuidString))
        XCTAssertTrue(accountReply.ok)
        XCTAssertEqual(accountReply.taskAccounts?.count, 3)
        XCTAssertTrue(accountReply.taskAccounts?.allSatisfy { $0.checkedAt != nil } == true)
        XCTAssertEqual(accountReply.taskAccounts?.filter { $0.current == true }.count, 1)
        XCTAssertEqual(accountReply.taskAccounts?.filter { $0.available == true }.count, 1)
        XCTAssertFalse(RemoteJSON.string(accountReply.taskAccounts ?? []).contains(accountFolder.path))
        XCTAssertEqual(remote.archivedTasks?.map(\.id), host.store.archivedSessions?.map(\.id))
        let mirrored = try XCTUnwrap(remote.sidebar.sessions.first { $0.id == session.id })
        let localActions = TaskHeaderActions(isAttached: { host.isAttached($0.id) },
            projectMoveOptions: { host.projectMoveOptions(for: $0, visibleProjects: host.projects.projects) }, onChooseAccount: { _ in },
            pullRequest: { host.pullRequests.pullRequest(for: $0.id) })
        for (name, record, actions) in [("local", session, localActions), ("remote", mirrored, remote.taskHeaderActions)] {
            try await render("\(name)-task-actions-header", size: NSSize(width: 700, height: 52), titled: false) {
                HStack { TaskHeaderIdentity(session: record, actions: actions); Spacer() }.padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            }
            try await render("\(name)-task-actions-title-menu", size: NSSize(width: 320, height: 360), titled: false) {
                VStack(alignment: .leading, spacing: 8) {
                    TaskTitleMenu(session: record, actions: actions).menuContents
                }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.primary)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            let nesting = SidebarNesting()
            let groups = name == "local" ? host.projects.visibleGroups(sessions: host.sidebarSessions) : remote.sidebar.groups
            nesting.layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
            let row = SidebarTaskEntry(session: record, title: record.title, isSelected: false, onSelect: {},
                onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in },
                onMarkRead: { _ in }, onMarkUnread: { _ in }, projectMove: actions.projectMoveOptions(record),
                onMoveToProject: { _ in }, onDropTask: nil, nesting: nesting)
            try await render("\(name)-task-actions-row-menu", size: NSSize(width: 320, height: 300), titled: false) {
                VStack(alignment: .leading, spacing: 8) { row.menuContents }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.primary)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            let archived = name == "local" ? host.store.archivedSessions : remote.archivedTasks
            try await render("\(name)-task-actions-archive", size: NSSize(width: 320, height: 280), titled: false) {
                ArchivedTaskList(archived: archived, errorMessage: nil, restoringIDs: [], searchText: .constant(""),
                    projectName: { record in name == "local" ? host.projects.displayName(for: record.workspaceURL) : remote.archiveProjectNames[record.id] ?? "" },
                    onBack: {}, onUnarchive: { _ in }, showsWorkspace: name == "local")
            }
        }
        try await render("local-task-actions-accounts", size: NSSize(width: 660, height: 460), titled: false) {
            TaskAccountSelectionView(session: session, store: host.connections, runtimeSelections: host.runtimeSelections, onSelect: { _ in })
                .background(Color(nsColor: .windowBackgroundColor))
        }
        try await render("remote-task-actions-accounts", size: NSSize(width: 660, height: 460), titled: false) {
            RemoteTaskAccounts(model: remote, session: mirrored).background(Color(nsColor: .windowBackgroundColor))
        }
        let directory = try WindowlessRender.directory("remote-qa")
        for surface in ["header", "title-menu", "row-menu", "archive", "accounts"] {
            for appearance in WindowlessRender.Appearance.allCases {
                let suffix = "task-actions-\(surface)-\(appearance.suffix).png"
                let left = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appending(path: "local-" + suffix))))
                let right = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appending(path: "remote-" + suffix))))
                let combined = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: left.pixelsWide + right.pixelsWide, pixelsHigh: max(left.pixelsHigh, right.pixelsHigh),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: combined)).cgContext
                context.draw(try XCTUnwrap(left.cgImage), in: CGRect(x: 0, y: 0, width: left.pixelsWide, height: left.pixelsHigh))
                context.draw(try XCTUnwrap(right.cgImage), in: CGRect(x: left.pixelsWide, y: 0, width: right.pixelsWide, height: right.pixelsHigh))
                try WindowlessRender.writePNG(combined, to: directory.appending(path: "comparison-" + suffix))
            }
        }
        hosts.close(paired.id)
        await host.shutdown()
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
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Stop") }, elements.description)
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

    /// Match the production scene's hidden title bar; the older recovery fixture also draws a
    /// native window title, which would overlap this view's own title bar in a design review.
    func testDesignAuditRemoteWindowWithHiddenTitleBar() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: RemoteFixtureBridge())
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey,
            secret: ticket.secret, name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot }
        model.select(.task(RemoteFixtureBridge.ID.history))
        try await waitUntil { model.conversations[RemoteFixtureBridge.ID.history]?.isLoaded == true }
        let directory = try WindowlessRender.directory("design-audit/remote")
        let size = NSSize(width: 1280, height: 820)
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(RemoteHostView(model: model, directory: hosts)
                .environment(\.colorScheme, appearance.colorScheme)
                .environment(\.controlActiveState, .active), size: size,
                appearance: appearance, titled: true)
            defer { host.close() }
            host.settle(passes: 12)
            XCTAssertFalse(host.window.isVisible)
            XCTAssertFalse(host.window.isKeyWindow)
            try WindowlessRender.writePNG(host.capture().bitmap,
                to: directory.appending(path: "window-\(appearance.suffix).png"))
        }
        hosts.close(paired.id)
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
        morning.state.runs = [run(.started, hoursAgo: 1, task: crash.id),
                              run(.started, hoursAgo: 25, task: footer.id),
                              run(.failed, hoursAgo: 72, failure: "The runtime was unavailable.")]
        morning.state.lastRunAt = morning.state.runs.first?.at
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
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let host = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                            runtimeSelections: runtimes, initialTranscripts: transcripts,
                            scheduleRepository: InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: schedules)),
                            restoresIndexOnLaunch: false)
        let scheduleProject = host.projects.ensureProject(forRoot: website, name: "website")
        morning.destination.projectID = scheduleProject.id
        host.scheduledTasks.update(morning)
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

        // The chip: Options, Start, Do it here and ✕ as on the Mac.
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
        // Its Options: the local popover, drawn from the host's choices for the chip (§15.9) beside the host's own.
        XCTAssertTrue(model.offersSuggestionOptions)
        let options = RemoteSuggestionOptions(host: model, taskID: footer.id.uuidString, suggestion: suggestion)
        await options.read()
        try await waitUntil { options.menus().canStart }
        let popover = NSSize(width: 400, height: 260)
        let drawn = [L10n.string("Harness"), L10n.string("taskSuggestion.where"), "website", L10n.string("Permissions"),
                     L10n.string("Start")]
        try await render("remote-host-suggestion-options", size: popover, titled: false) {
            TaskSuggestionOptionsPopover(context: options, dismiss: {}).background(ParityTheme.elevated)
        } check: { elements in
            for label in drawn { XCTAssertTrue(elements.contains { $0.description.contains(label) }, "\(label): \(elements)") }
        }
        let local = try XCTUnwrap(localSuggestionOptions(host, suggestion: suggestion, session: footer))
        XCTAssertEqual(options.menus().options.permission?.title, local.menus().options.permission?.title)
        XCTAssertEqual(options.menus().place.title, local.menus().place.title)
        try await render("local-suggestion-options", size: popover, titled: false) {
            TaskSuggestionOptionsPopover(context: local, dismiss: {}).background(ParityTheme.elevated)
        } check: { elements in
            for label in drawn { XCTAssertTrue(elements.contains { $0.description.contains(label) }, "\(label): \(elements)") }
        }
        XCTAssertNil(host.taskSuggestions.choice(of: suggestion.id, in: footer.id), "Opening Options changes nothing")

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
        // A schedule action the host refuses says why on the schedules screen, in this Mac's words for its reason.
        model.schedules.refused(.failure("r", RemoteError(.notAllowed, "Edit it on the Mac", reason: .hostOnly)))
        let refusal = L10n.format("Do this on %@.", model.name)
        try await render("remote-host-schedule-refused", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.value == refusal }, elements.description)
        }
        model.commandError = nil
        let detailSize = NSSize(width: 900, height: 1000)
        let remoteMorning = try XCTUnwrap(model.schedules.schedule(morning.id.uuidString))
        try await render("remote-schedule-detail", size: detailSize, titled: false) {
            RemoteScheduleDetail(model: model, schedule: remoteMorning, now: now)
        }
        try await render("local-schedule-detail", size: detailSize, titled: false) {
            ScheduledTaskDetail(schedule: morning, nextRun: host.scheduledTasks.nextRun(of: morning),
                                isStarting: false, now: host.scheduledTasks.displayNow,
                                context: ScheduledTaskContext(task: { id in sessions.first { $0.id == id } },
                                                              projectName: { _ in "website" },
                                                              accountName: { schedule in
                let harness = schedule.destination.harness
                let accountID = schedule.destination.accountID ?? host.connections.selection[harness] ?? AccountChoice.nativeID(for: harness)
                return host.connections.choices(for: [harness], includingMoving: true).first { $0.id == accountID }?.title
            }),
                                actions: ScheduledTaskActions())
        }
        let editorSize = NSSize(width: 600, height: 680)
        var draft = ScheduleDraft(now: now, place: .chat, harness: .claudeCode)
        draft.name = "Morning check"
        draft.prompt = "Summarize the new crash reports and list what needs attention."
        let editorOptions = await model.response(to: .scheduledTaskOptions(
            projectID: RemoteTaskProjection.chatsProjectID, harness: HarnessKind.claudeCode.rawValue, settings: [:]))
        XCTAssertTrue(editorOptions.ok)
        try await render("remote-schedule-editor", size: editorSize, titled: false) {
            RemoteScheduleEditor(model: model, request: .init(draft: draft, existing: nil),
                                 initialOptions: editorOptions, loadsOptions: false)
                .background(ParityTheme.canvas)
        }
        try await render("local-schedule-editor", size: editorSize, titled: false) {
            ScheduledTaskEditor(draft: draft, existing: nil, projects: host.projects.projects.filter { !$0.isHidden },
                                tasks: sessions, runtimeSelections: runtimes, connections: host.connections,
                                models: NewTaskModelSource(catalogs: host.modelCatalogs) { _, _, _, _ in },
                                now: { now }, projectName: { _ in "website" }, onCancel: {}, onSave: { _ in })
                .background(ParityTheme.canvas)
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
        // A phone reading the basic detail is offered what the turn does too: the plan to carry out and the child task
        // to open, while what the subagent read and wrote stays in full detail.
        let basic = try XCTUnwrap(AppModelRemoteBridge(model: host).conversation(of: plan.id.uuidString)?.turns.last)
        XCTAssertNotNil(basic.items.first { $0.kind == .turn }?.planToImplement)
        let basicSubagent = try XCTUnwrap(basic.items.first { $0.activity == "subagent" }?.subagent)
        XCTAssertEqual(basicSubagent.taskIds, [child.id.uuidString])
        XCTAssertNil(basicSubagent.input)
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

    /// The chip's Options as the host's own window builds them for its task.
    private func localSuggestionOptions(_ model: AppModel, suggestion: ConversationTaskSuggestion,
                                        session: SessionRecord) -> TaskSuggestionOptionsContext? {
        guard case let .success(start) = model.suggestedTaskStart(for: suggestion, from: session) else { return nil }
        let runtimes = model.runtimeSelections, connections = model.connections
        return TaskSuggestionOptionsContext(
            choice: { model.suggestedTaskChoice(for: suggestion, start: start, in: session.id) }, parentLabel: nil,
            projects: model.projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project),
            harnesses: runtimes.connectedDescriptors,
            models: NewTaskModelSource(catalogs: model.modelCatalogs) { _, _, _, _ in },
            accounts: { connections.choices(for: [$0]) }, runtimeURL: { runtimes.selectedURL(for: $0) },
            defaults: { model.suggestedTaskOptions(harness: $0, parent: start.parent) },
            connection: { model.suggestedTaskConnection(harness: $0, parent: start.parent) },
            isRepository: SuggestedTaskPlace.isInRepository, chooseWorkspace: { _ in nil }, save: { _ in }, start: { _ in })
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
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-composer-window-\(UUID())")
        let folder = root.appending(path: "yardlet")
        let claudeHome = root.appending(path: "claude")
        let codexHome = root.appending(path: "codex")
        for directory in [folder, claudeHome, codexHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model":"fable","effortLevel":"xhigh"}"#.utf8).write(to: claudeHome.appending(path: "settings.json"))
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: claudeHome, codexHome: codexHome, codexYardletHome: root.appending(path: "yardlet-codex")), environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        let codexAdapter = FakeHarnessAdapter(kind: .codex)
        let claudeAdapter = FakeHarnessAdapter(kind: .claudeCode)
        var thread = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"),
            "turns": .array([RemoteTaskControlsTests.codexTurn(1), RemoteTaskControlsTests.codexTurn(2)])
        ]), to: &thread))
        thread.thread?.turns[1].tokenUsage = ComposerUnificationFixtures.codexTokenUsage
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
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
                            registry: HarnessRegistry { kind, _ in kind == .codex ? codexAdapter : claudeAdapter }, modelCatalogs: catalogs,
                            initialTranscripts: [guide.id: guideEntries], initialCodexPresentation: [parser.id: thread],
                            initialProviderUsage: [guide.id: ComposerUnificationFixtures.providerUsage],
                            preferences: defaults, transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
        host.projects.ensureProject(forRoot: folder)
        host.connections.usesFixtureSnapshots = true
        host.connections.publishDefaults([HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedIn, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [],
            canLogin: false, canLogout: true)])
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
        await model.readTaskRail(parserID)
        try await waitUntil { model.railComposerOptions(parserID)?.contextUsage != nil }
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
        await model.readTaskRail(guideID)
        try await waitUntil { model.railComposerOptions(guideID)?.contextUsage != nil }
        // Asked from a device without its Terminal permission, the choice is refused, saying what it takes (§15.28).
        model.setTaskSetting(guideID, id: ClaudeLaunchOption.permissionMode, value: ClaudePermissionMode.bypassPermissions,
                             confirmed: true)
        let needsTerminal = L10n.format(
            "To use this from here, allow Terminal for this device in Settings › Remote › Paired devices on %@.", model.name)
        try await waitUntil { model.commandError == needsTerminal }
        try await render("remote-controls-needs-terminal", size: size, titled: true, title: model.name) {
            RemoteHostView(model: model, directory: hosts)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.value == needsTerminal || $0.label == needsTerminal }, elements.description)
        }
        model.commandError = nil
        try await stack.server.setPermission(.terminal, allowed: true, for: try XCTUnwrap(model.host.deviceID))
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
        host.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        host.composerDrafts.home.workspaceURL = nil
        host.composerDrafts.home.projectID = nil
        host.composerDrafts.home.harness = .claudeCode
        host.revealNewTask()
        await catalogs.refreshDefaults(for: .claudeCode, connection: host.connections.selected(for: .claudeCode), workspaceURL: nil)
        let homeOptions = ComposerSessionOptionsProjection.newTask(harness: .claudeCode,
            choice: host.composerDrafts.home.modelChoices[.claudeCode], catalogs: catalogs,
            connection: host.connections.selected(for: .claudeCode), workspaceURL: nil)
        let expectedModel = try XCTUnwrap(homeOptions.model?.menu.accessibilityValue)
        XCTAssertTrue(expectedModel.contains("Fable"))
        func ready(_ elements: [WindowlessRender.AccessibilityElement]) -> Bool {
            elements.contains { $0.label == L10n.string("Model") && $0.value == expectedModel }
                && elements.contains { $0.label == L10n.string("Permissions") }
                && !elements.contains { $0.label.contains(L10n.string("Checking account…")) }
        }
        model.select(.newTask)
        func remoteHome() -> some View {
            let newDrafts = RemoteComposerDrafts()
            return RemoteHostView(model: model, directory: hosts, drafts: newDrafts)
        }
        try await render("remote-composer-new-task", size: size, titled: false, ready: ready, focusedPlaceholder: NewTaskComposerText.placeholder(harnessName: HarnessKind.claudeCode.displayName)) { remoteHome() }
        try await render("local-composer-new-task", size: size, titled: false, ready: ready, onMounted: { host.revealNewTask() }, focusedPlaceholder: NewTaskComposerText.placeholder(harnessName: HarnessKind.claudeCode.displayName)) {
            MainWindow(model: host)
        }
        hosts.close(paired.id)
        await host.shutdown()
    }

    func testEmptyHomesShareTheNewTaskDestinationControl() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteEmptyHome")))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let catalogs = HarnessModelCatalogStore(environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        let host = AppModel(store: SessionStore(repository: InMemorySessionRepository()), runtimeSelections: runtimes,
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .claudeCode) }, modelCatalogs: catalogs,
            preferences: defaults, restoresIndexOnLaunch: false)
        host.connections.usesFixtureSnapshots = true
        host.connections.publishDefaults([HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedIn, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [],
            canLogin: false, canLogout: true)])
        host.composerDrafts.home.harness = .claudeCode
        host.revealNewTask()
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "Client", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.composerExtensions }
        model.select(.newTask)
        func ready(_ elements: [WindowlessRender.AccessibilityElement]) -> Bool {
            elements.contains { $0.label == L10n.string("Model") && !$0.value.isEmpty }
                && elements.contains { $0.label == L10n.string("Permissions") }
                && !elements.contains { $0.label.contains(L10n.string("Checking account…")) }
        }
        let size = NSSize(width: 1280, height: 820)
        try await render("remote-composer-new-task-empty", size: size, titled: false, ready: ready, focusedPlaceholder: NewTaskComposerText.placeholder(harnessName: HarnessKind.claudeCode.displayName)) {
            RemoteHostView(model: model, directory: hosts)
        }
        try await render("local-composer-new-task-empty", size: size, titled: false, ready: ready, onMounted: { host.revealNewTask() }, focusedPlaceholder: NewTaskComposerText.placeholder(harnessName: HarnessKind.claudeCode.displayName)) {
            MainWindow(model: host)
        }
        // Each window's title bar row is its top, with the window's buttons on it, the sidebar shown and hidden.
        let remoteRow = try await titleBarRows("remote-title-bar", size: size, ready: ready) {
            RemoteHostView(model: model, directory: hosts)
        }
        let localRow = try await titleBarRows("local-title-bar", size: size, ready: ready) {
            // The main scene's own safe area rule, which `MainWindow` leaves to it.
            MainWindow(model: host).ignoresSafeArea(.container, edges: .top)
        }
        XCTAssertEqual(remoteRow, localRow)
        hosts.close(paired.id)
        await host.shutdown()
    }

    /// The window's top as it draws in a window shaped as `.windowStyle(.hiddenTitleBar)` shapes the app's: first with the
    /// sidebar shown, over the sidebar's column, then with it hidden, over the row's sidebar part. Each is one number for
    /// each of the row's pixel lines, so two windows compare without comparing what their details show. The window's
    /// buttons must be centred on the row.
    private func titleBarRows<Content: View>(_ name: String, size: NSSize,
                                             ready: @escaping ([WindowlessRender.AccessibilityElement]) -> Bool,
                                             @ViewBuilder content: () -> Content) async throws -> [[Int]] {
        let hosting = NSHostingView(rootView: content().environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        let themeFrame = try XCTUnwrap(hosting.superview)
        func pixelLines(width: CGFloat) throws -> [Int] {
            let bitmap = try WindowlessRender.capture(themeFrame)
            let scale = bitmap.pixelsWide / Int(themeFrame.bounds.width)
            let columns = Int(width) * scale
            let background = bitmap.colorAt(x: columns - 2 * scale, y: scale)
            return (0..<(Int(ParityTheme.titleBarHeight) * scale)).map { y in
                (0..<columns).filter { bitmap.colorAt(x: $0, y: y) != background }.count
            }
        }
        // At rest: the buttons on the row, and the row the same twice over once the sidebar's motion has ended.
        func row(_ state: String, width: CGFloat) async throws -> [Int] {
            var last: [Int] = []
            try await waitUntil {
                Self.turnRunLoop(hosting)
                guard let button = window.standardWindowButton(.closeButton), let bar = button.superview,
                      let lines = try? pixelLines(width: width) else { return false }
                defer { last = lines }
                let center = bar.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
                return abs(window.frame.height - center.y - ParityTheme.titleBarHeight / 2) < 1 && lines == last
            }
            try WindowlessRender.writePNG(WindowlessRender.capture(themeFrame), to: WindowlessRender.directory("remote-qa")
                .appending(path: "\(name)-\(state).png"))
            return last
        }
        try await waitUntil {
            Self.turnRunLoop(hosting)
            return ready(WindowlessRender.accessibilityElements(in: hosting))
        }
        let shown = try await row("sidebar-shown", width: SidebarWidth.minimum)
        XCTAssertTrue(hosting.pressAccessibilityElement(labelled: L10n.string("Hide sidebar")))
        try await waitUntil {
            Self.turnRunLoop(hosting)
            return WindowlessRender.accessibilityElements(in: hosting).contains { $0.label == L10n.string("Show sidebar") }
        }
        try await Task.sleep(for: .milliseconds(500))
        let hidden = try await row("sidebar-hidden", width: TitleBarSidebarPart.collapsedWidth)
        return [shown, hidden]
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
                providerEntries: host.transcriptBySessionID[session.id] ?? [],
                providerCapabilities: host.composerProviderCapabilities(for: session),
                providerUsage: host.providerUsageBySessionID[session.id], isProviderAttached: host.isAttached(session.id),
                isRunning: false, codexHasThread: session.providerSessionID != nil,
                codexTokenUsage: host.codexPresentationBySessionID[session.id]?.thread?.turns.last(where: { $0.tokenUsage != nil })?.tokenUsage,
                workspaceURL: session.workspaceURL,
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

        // The host's desk lists what this Mac's would, the host's pull requests read from its list: the coordinator's
        // failing checks wait on the person, its family runs.
        func desk(_ activity: NewTaskHomeActivity, pullRequest: @escaping (UUID) -> TaskPullRequest?) -> Desk {
            DeskProjection.desk(sessions: activity.sessions, details: activity.details, shellBusy: activity.shellBusy,
                                archivedParents: activity.archivedParents, agents: activity.agents,
                                pullRequest: pullRequest, schedules: activity.schedules, now: activity.now)
        }
        func lines(_ desk: Desk) -> [String] {
            desk.waiting.map { item in
                if case let .checksFailed(pullRequest) = item.kind { return "\(item.id) checks failed #\(pullRequest.number)" }
                return "\(item.id) \(item.kind)"
            }
        }
        let remoteDesk = desk(remote, pullRequest: try XCTUnwrap(remote.pullRequest))
        let localDesk = desk(local, pullRequest: { host.pullRequests.pullRequest(for: $0) })
        XCTAssertEqual(lines(remoteDesk), lines(localDesk))
        XCTAssertEqual(lines(remoteDesk), ["\(fixture.task.id) checks failed #341"])
        XCTAssertEqual(remoteDesk.families.map(\.id), localDesk.families.map(\.id))
        XCTAssertEqual(remoteDesk.families.map(\.id), [fixture.task.id])
        DeskPreview.show()
        defer { DeskPreview.hide() }
        model.select(.newTask)
        let wide = NSSize(width: 1_280, height: 820)
        try await render("remote-desk", size: wide, titled: true, title: model.name) {
            RemoteHostView(model: model, directory: hosts)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label.contains(L10n.string("Checks failed")) }, elements.description)
            XCTAssertTrue(elements.contains { $0.label.contains("Review the migration") }, elements.description)
            XCTAssertTrue(elements.contains { $0.label.contains("Migrate the session index") }, elements.description)
        }

        // The host renaming the running subtask draws the desk and that family's line again, not the line that waits.
        let window = WindowlessRender.Host(RemoteHostView(model: model, directory: hosts), size: wide, appearance: .light)
        defer { window.close() }
        window.settle(passes: 20)
        let child = try XCTUnwrap(host.store.sessions.first { $0.parentTaskID == fixture.task.id })
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
        }
        try await host.store.renameSession(id: child.id, title: "Review the migration again")
        try await waitUntil {
            window.settle(passes: 1)
            return model.sidebar.sessions.contains { $0.title == "Review the migration again" }
        }
        window.settle(passes: 10)
        let counts = ViewBodyCensus.counts
        XCTAssertGreaterThanOrEqual(counts[.desk] ?? 0, 1, "The desk lists the host's change")
        XCTAssertLessThanOrEqual(counts[.desk] ?? 0, 2, "\(counts)")
        XCTAssertEqual(counts[.deskRow] ?? 0, 1, "Only the family whose member changed: \(counts)")
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

    func testComposerListsDrawFromTheHostsValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-render-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("struct Parser {}".utf8).write(to: root.appending(path: "Sources/Parser.swift"))
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review the parser")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteComposerMenus")))
        let host = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), restoresIndexOnLaunch: false)
        let center = ConnectorCenter(environment: .init(
            repository: InMemoryConnectorRepository(records: Array(ConnectorsRenderingTests.records.prefix(2))),
            credentials: InMemoryConnectorCredentialStore(), http: FakeConnectorServer(), userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256, clientVersion: "test"))
        host.connectorCenter = center
        let bridge = AppModelRemoteBridge(model: host)
        let wireCommands = try await bridge.composerCommands(taskID: session.id.uuidString).get()
        let decodedCommands = try JSONDecoder().decode([RemoteComposerCommand].self,
            from: JSONEncoder().encode(wireCommands))
        func commands(_ values: [RemoteComposerCommand]) -> [ProviderComposerCommand] {
            values.map { .init(name: $0.name, description: $0.description ?? "", argumentHint: $0.argumentHint ?? "",
                               builtin: true, title: $0.title, group: $0.group) }
        }
        let localSearch = ComposerFileMentionSearch()
        localSearch.update(query: "Parser", roots: [root])
        let scope = try await bridge.fileScope(taskID: session.id.uuidString).get()
        let index = try RemoteFileReader.index(in: scope).get()
        let remoteSearch = ComposerFileMentionSearch()
        remoteSearch.update(query: "Parser", roots: [], search: { query in
            .init(matches: WorkspaceFileRanking.rank(WorkspaceFileRanking.entries(forFiles: index.paths),
                query: query, limit: 50).map { .init(root: scope.folder, relativePath: $0.relativePath, isDirectory: $0.isDirectory) })
        })
        try await waitUntil { !localSearch.isSearching && !remoteSearch.isSearching }
        XCTAssertEqual(localSearch.matches, remoteSearch.matches)
        let state = try await bridge.composerState(taskID: session.id.uuidString).get()
        let wireState = try JSONDecoder().decode(RemoteComposerState.self, from: JSONEncoder().encode(state))
        let empty = ComposerConnectorList(rows: [], toolListFollowsNextTurn: false)
        let localConnectors = ComposerConnectorList.make(AppModelRemoteBridge.composerOptions(of: session, in: host).connectors,
            connectors: center.connectors, taskState: { center.state(of: $0, inTask: session.id,
                scope: ConnectorTaskScope(harness: session.harness)) }) ?? empty
        let remoteConnectors = wireState.connectorList ?? empty
        XCTAssertEqual(localConnectors.rows.map(\.name), remoteConnectors.rows.map(\.name))
        XCTAssertEqual(localConnectors.rows.map(\.state), remoteConnectors.rows.map(\.state))
        XCTAssertFalse(remoteConnectors.rows.isEmpty)
        let chip = ComposerQueueChip(icon: "clock", status: L10n.string("Queued"), help: nil,
            send: .init(label: L10n.string("Send now"), icon: "arrow.turn.up.right", help: ""),
            stopAndSend: nil, removeLabel: L10n.string("Delete"), canMoveUp: true, canMoveDown: true)
        for (name, values, search, connectors) in [("local", wireCommands, localSearch, localConnectors),
                                                   ("remote", decodedCommands, remoteSearch, remoteConnectors)] {
            try await render("\(name)-composer-mentions", size: .init(width: 640, height: 150), titled: false) {
                ComposerFileMentionPicker(search: search, onSelect: { _ in }).padding().background(ParityTheme.canvas)
            }
            try await render("\(name)-composer-commands", size: .init(width: 640, height: 260), titled: false) {
                ComposerCommandRows(commands: commands(values), highlightedIndex: 0).padding().background(ParityTheme.canvas)
            }
            try await render("\(name)-composer-connectors", size: .init(width: 340, height: 250), titled: false) {
                ComposerConnectorsMenu(list: connectors, onManage: nil, onSwitch: { _, _ in })
                    .background(ParityTheme.canvas)
            }
            try await render("\(name)-composer-queue", size: .init(width: 740, height: 130), titled: false) {
                VStack {
                    ComposerQueueRow(title: "Run the parser tests", failed: false, fromTask: false, chip: chip,
                        moveUp: {}, moveDown: {}, sendNow: {}, edit: {}, remove: {})
                    ComposerQueueRow(title: "Update the migration guide", failed: true, fromTask: false, chip: chip,
                        moveUp: {}, moveDown: {}, retry: {}, edit: {}, remove: {})
                }.padding().background(ParityTheme.canvas)
            }
        }
        try await render("composer-mentions-local-remote", size: .init(width: 1280, height: 160), titled: false) {
            HStack {
                ComposerFileMentionPicker(search: localSearch, onSelect: { _ in }).frame(width: 620)
                Divider()
                ComposerFileMentionPicker(search: remoteSearch, onSelect: { _ in }).frame(width: 620)
            }.padding().background(ParityTheme.canvas)
        }
        try await render("composer-commands-local-remote", size: .init(width: 1280, height: 260), titled: false) {
            HStack {
                ComposerCommandRows(commands: commands(wireCommands), highlightedIndex: 0).frame(width: 620)
                Divider()
                ComposerCommandRows(commands: commands(decodedCommands), highlightedIndex: 0).frame(width: 620)
            }.padding().background(ParityTheme.canvas)
        }
        await host.shutdown()
    }

    /// The remote window's Settings sheet (§15.36) drawn from the host's values beside the local
    /// Settings sheet drawn from the same host model, in light and dark, plus the remote sheet
    /// without the `settings` permission.
    func testHostSettingsSheetMatchesLocalSettingsOverLoopback() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-settings-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteSettingsRender")))
        defaults.set(true, forKey: LidClosedWorkPreference.key)
        defaults.set("steer", forKey: FollowUpMode.preferenceKey)

        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .codex)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)

        let host = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: runtimes,
            preferences: defaults,
            restoresIndexOnLaunch: false)
        ShowcaseFixture.Accounts.add(to: host.connections, selections: runtimes)

        let instructions = YardletInstructionsStore(directory: folder.appending(path: "instructions"), defaults: defaults)
        instructions.text = "Prefer small, focused commits and run only the relevant tests before opening a pull request."
        host.yardletInstructions = instructions
        host.routingEvaluation = RoutingEvaluationStore(directory: folder.appending(path: "evaluation"), defaults: defaults)

        let lidHelper = LidSleepHelper(backend: FakeLidSleepHelperBackend(status: .needsApproval))
        host.lidSleepHelper = lidHelper

        let cliRunner = FakeCLIRunner { command in
            let version = command.executable.lastPathComponent == "codex" ? "0.157.1" : "2.1.293"
            return CLICommandResult(exitCode: 0, stdout: version, stderr: "")
        }
        let cliUpdates = CLIUpdateCenter(dependencies: .init(
            runtimes: { [.codex: URL(filePath: "/opt/homebrew/bin/codex"),
                         .claudeCode: URL(filePath: "/opt/homebrew/bin/claude")] },
            busyHarnesses: { [] },
            runner: cliRunner,
            verifier: FakeVerifier(failing: [], verifiable: [.codex, .claudeCode]),
            overrides: CLIRuntimeOverrides(defaults: defaults),
            defaults: defaults,
            previousVersionsDirectory: folder.appending(path: "cli-previous"),
            environment: [:]))
        await cliUpdates.checkAll()
        host.cliUpdates = cliUpdates

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let codexAmount = TokenUsageAmount(
            freshInput: 420_000, cacheWrite: 0, cacheRead: 180_000, output: 64_000, requests: 18,
            kindCost: [.freshInput: 1.2, .cacheRead: 0.8, .output: 1.85])
        let claudeAmount = TokenUsageAmount(
            freshInput: 310_000, cacheWrite: 40_000, cacheRead: 120_000, output: 52_000, requests: 14,
            kindCost: [.freshInput: 0.9, .cacheWrite: 1.1, .cacheRead: 1.4, .output: 1.5])
        var totalToday = codexAmount
        totalToday.add(claudeAmount)
        let days = (0..<30).reversed().compactMap { offset -> TokenUsageDay? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return TokenUsageDay(start: start, amount: offset == 0 ? totalToday : TokenUsageAmount())
        }
        var groups: [TokenUsageRange: [TokenUsageGrouping: [TokenUsageSummary.Key: TokenUsageAmount]]] = [:]
        for range in TokenUsageRange.allCases {
            groups[range] = [
                .model: [
                    .init(harness: .codex, value: "gpt-5.6-codex"): codexAmount,
                    .init(harness: .claudeCode, value: "claude-opus-4-6"): claudeAmount
                ]
            ]
        }
        let usageSummary = TokenUsageSummary(days: days, groups: groups, updatedAt: now)
        host.tokenUsage = TokenUsageCenter(directory: folder.appending(path: "usage"), summary: usageSummary)

        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        let client = try XCTUnwrap(directory.model(for: paired.id))
        try await waitUntil { client.hasSnapshot }
        XCTAssertTrue(client.offersHostSettings)

        let sheetSize = NSSize(width: SettingsCenterView.preferredSize.width, height: SettingsCenterView.preferredSize.height)

        // First render the remote sheet without the settings permission (read-only).
        client.openSettings(section: SettingsSection.general.rawValue)
        try await waitUntil { client.hostSettings != nil }
        XCTAssertEqual(client.hostSettings?.writable, false)
        try await render("remote-settings-general-readonly", size: sheetSize, titled: false) {
            SettingsCenterView(size: SettingsCenterView.preferredSize, initialSection: SettingsSection.general.rawValue,
                               remoteHost: client)
        } check: { elements in
            let text = elements.map { "\($0.label) \($0.value)" }.joined(separator: " ")
            XCTAssertTrue(text.contains(RemoteHostSettingsProjection.permissionNote(hostName: "Mac Studio")), text)
        }

        // Now grant the settings permission and render each section side by side with the local sheet.
        let devices = await stack.server.devicesForSettings()
        let deviceID = try XCTUnwrap(devices.first?.id)
        try await stack.server.setPermission(.settings, allowed: true, for: deviceID)
        try await waitUntil { client.hostSettings?.writable == true }

        let localUsage = SettingsUsageContext(
            overview: { [weak host] in
                host?.tokenUsageOverview() ?? TokenUsageOverview(days: [], limits: [], updatedAt: now, rows: { _, _ in [] })
            },
            isCounting: { [weak host] in host?.tokenUsage.isEnabled == true },
            limitsCheckedAt: { [weak host] in
                guard let host else { return nil }
                return MenuBarMenuProjection.limitAccounts(
                    choices: host.connections.menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id))
                ).compactMap(\.checkedAt).max()
            })

        for (section, slug) in [
            (SettingsSection.general, "general"),
            (SettingsSection.instructions, "instructions"),
            (SettingsSection.cliUpdates, "cli-updates"),
            (SettingsSection.usage, "usage")
        ] {
            client.requestedSettingsSection = section.rawValue
            try await render("remote-settings-\(slug)", size: sheetSize, titled: false) {
                SettingsCenterView(size: SettingsCenterView.preferredSize, initialSection: section.rawValue,
                                   remoteHost: client)
            }
            try await render("local-settings-\(slug)", size: sheetSize, titled: false) {
                SettingsCenterView(size: SettingsCenterView.preferredSize, initialSection: section.rawValue,
                                   notificationCenter: MenuBarQuietNotificationCenter(),
                                   cliUpdates: cliUpdates, instructions: instructions,
                                   evaluation: host.routingEvaluation, usage: localUsage, lidHelper: lidHelper)
                    .defaultAppStorage(defaults)
            }
        }
        // With `hostAccounts` (§15.37) the same sheet lists the host's Accounts, Harnesses and Connectors.
        for (section, slug) in [(SettingsSection.accounts, "accounts"), (SettingsSection.connectors, "connectors")] {
            client.requestedSettingsSection = section.rawValue
            try await render("remote-settings-sheet-\(slug)", size: sheetSize, titled: false) {
                SettingsCenterView(size: SettingsCenterView.preferredSize, initialSection: section.rawValue,
                                   remoteHost: client)
            }
        }

        client.closeSettings()
        directory.close(paired.id)
        await host.shutdown()
    }

    /// The host's Accounts, Harnesses and Connectors sections (§15.37) drawn from the same host model
    /// locally and over the remote loopback, with and without the `settings` permission.
    func testHostAccountsHarnessesAndConnectorsSectionsMatchLocalSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-accounts-render-\(UUID().uuidString)")
        let binDir = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeExec = binDir.appending(path: "claude")
        let claudeAltExec = binDir.appending(path: "claude-alt")
        let codexExec = binDir.appending(path: "codex")
        for url in [claudeExec, claudeAltExec, codexExec] {
            try Data("#!/bin/sh\necho 2.1.80\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAccountsRender")))
        let runtimeSelections = RuntimeSelectionStore(
            defaults: defaults,
            candidates: { kind in
                switch kind {
                case .claudeCode: [claudeExec, claudeAltExec]
                case .codex: [codexExec]
                default: []
                }
            }
        )
        let connections = ProviderConnectionStore(fileURL: nil, snapshotCacheURL: nil, defaults: defaults)
        connections.usesFixtureSnapshots = true
        let work = try connections.add(name: "Work", harness: .claudeCode, home: root.appending(path: "work"))
        let studio = try connections.add(name: "Studio", harness: .claudeCode, home: root.appending(path: "studio"))
        let now = Date()
        let claudeDefaultSnapshot = HarnessAccountSnapshot(
            id: AccountSnapshotCache.defaultKey(for: .claudeCode),
            harness: .claudeCode,
            providerID: "anthropic",
            state: .signedIn,
            accountLabel: "alex@acme.example",
            accountOrganization: "Acme",
            accountPlan: "Claude Max",
            detail: "The selected runtime reports usable authentication.",
            credentialOwner: "Claude Code credential store",
            checkedAt: now.addingTimeInterval(-45),
            usage: [
                AccountUsageMetric(id: "claude:session", label: "5 hour limit", usedFraction: 0.28, detail: "72% left", resetsAt: now.addingTimeInterval(7200), evidence: .exactQuota),
                AccountUsageMetric(id: "claude:week", label: "7 day limit", usedFraction: 0.14, detail: "86% left", resetsAt: now.addingTimeInterval(345600), evidence: .exactQuota)
            ],
            canLogin: true,
            canLogout: true
        )
        let codexDefaultSnapshot = HarnessAccountSnapshot(
            id: AccountSnapshotCache.defaultKey(for: .codex),
            harness: .codex,
            providerID: "openai",
            state: .signedIn,
            accountLabel: "alex@acme.example",
            accountOrganization: nil,
            accountPlan: "ChatGPT Pro",
            detail: "The selected runtime reports usable authentication.",
            credentialOwner: "Codex CLI",
            checkedAt: now.addingTimeInterval(-45),
            usage: [
                AccountUsageMetric(id: "codex:five_hour", label: "5 hour limit", usedFraction: 0.12, detail: "88% left", resetsAt: now.addingTimeInterval(10800), evidence: .exactQuota)
            ],
            canLogin: true,
            canLogout: true
        )
        let workSnapshot = HarnessAccountSnapshot(
            id: work.id,
            harness: .claudeCode,
            providerID: "anthropic",
            state: .signedIn,
            accountLabel: "work@acme.example",
            accountOrganization: "Acme",
            accountPlan: "Claude Max",
            detail: "The selected runtime reports usable authentication.",
            credentialOwner: "Claude Code credential store",
            checkedAt: now.addingTimeInterval(-45),
            usage: [
                AccountUsageMetric(id: "claude:session", label: "5 hour limit", usedFraction: 0.42, detail: "58% left", resetsAt: now.addingTimeInterval(5400), evidence: .exactQuota),
                AccountUsageMetric(id: "claude:week", label: "7 day limit", usedFraction: 0.31, detail: "69% left", resetsAt: now.addingTimeInterval(300000), evidence: .exactQuota)
            ],
            canLogin: true,
            canLogout: true
        )
        let studioSnapshot = HarnessAccountSnapshot(
            id: studio.id,
            harness: .claudeCode,
            providerID: "anthropic",
            state: .signedIn,
            accountLabel: "studio@acme.example",
            accountOrganization: "Acme",
            accountPlan: "Claude Max",
            detail: "The selected runtime reports usable authentication.",
            credentialOwner: "Claude Code credential store",
            checkedAt: now.addingTimeInterval(-45),
            usage: [
                AccountUsageMetric(id: "claude:session", label: "5 hour limit", usedFraction: 0.08, detail: "92% left", resetsAt: now.addingTimeInterval(14400), evidence: .exactQuota)
            ],
            canLogin: true,
            canLogout: true
        )
        connections.publishDefaults([claudeDefaultSnapshot, codexDefaultSnapshot])
        connections.publish(workSnapshot, for: work)
        connections.publish(studioSnapshot, for: studio)

        let connectorCenter = ConnectorCenter(environment: .init(
            repository: InMemoryConnectorRepository(records: Array(ConnectorsRenderingTests.records.prefix(3))),
            credentials: InMemoryConnectorCredentialStore(),
            http: FakeConnectorServer(),
            userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256,
            clientVersion: "test"
        ))
        let session = SessionRecord(
            harness: .claudeCode,
            workspaceURL: root,
            runtimeExecutableURL: claudeExec,
            title: "Build remote settings",
            connection: work
        )
        let host = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository()),
            runtimeSelections: runtimeSelections,
            connections: connections,
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        host.connectorCenter = connectorCenter

        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(
            macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]
        ).url)
        let hosts = RemoteHostDirectory(
            store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test")
        )
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.offersHostAccounts }
        await model.watchHostAccounts()
        try await waitUntil { model.hostAccountsState != nil }

        let localAccountModel = AccountCenterModel(connections: connections)
        let localUsage = AccountHarnessScope.Usage(withTasks: [.claudeCode], chosenForNewTask: .claudeCode, withSubagents: [])
        let size = NSSize(width: 680, height: 660)

        func sectionHeader(_ section: SettingsSection) -> some View {
            HStack(spacing: 10) {
                Image(systemName: section.systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ParityTheme.accent)
                Text(section.title)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
            }
        }

        // 1. Without the `settings` permission (read-only).
        XCTAssertFalse(model.canEditHostSettings)
        try await render("remote-accounts-readonly", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.accounts).padding(.horizontal, 20).padding(.top, 20)
                model.accountsSettingsSectionView()
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-harnesses-readonly", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.harnesses).padding(.horizontal, 20).padding(.top, 20)
                model.harnessesSettingsSectionView()
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-harnesses-detail-readonly", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.harnesses).padding(.horizontal, 20).padding(.top, 20)
                model.harnessesSettingsSectionView(initialSelectedHarness: .claudeCode, showsInitialConnectionDetails: true)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-connectors-readonly", size: size, titled: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionHeader(.connectors)
                    model.connectorsSettingsSectionView()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }

        // 2. Grant `settings` permission and render local vs. remote side by side.
        try await stack.server.setPermission(.settings, allowed: true, for: try XCTUnwrap(model.host.deviceID))
        try await waitUntil { model.canEditHostSettings }

        try await render("local-accounts", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.accounts).padding(.horizontal, 20).padding(.top, 20)
                ConnectionCenterContent(
                    tab: .accounts,
                    model: localAccountModel,
                    runtimeSelections: runtimeSelections,
                    connections: connections,
                    harnessUsage: localUsage,
                    initialHarness: nil,
                    addingAccount: .constant(false),
                    setupExpanded: .constant(false),
                    isFixture: false,
                    onFinish: {}
                )
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-accounts", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.accounts).padding(.horizontal, 20).padding(.top, 20)
                model.accountsSettingsSectionView()
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }

        try await render("local-harnesses", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.harnesses).padding(.horizontal, 20).padding(.top, 20)
                ConnectionCenterContent(
                    tab: .harnesses,
                    model: localAccountModel,
                    runtimeSelections: runtimeSelections,
                    connections: connections,
                    harnessUsage: localUsage,
                    initialHarness: nil,
                    addingAccount: .constant(false),
                    setupExpanded: .constant(false),
                    isFixture: false,
                    onFinish: {}
                )
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-harnesses", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.harnesses).padding(.horizontal, 20).padding(.top, 20)
                model.harnessesSettingsSectionView()
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("local-harnesses-detail", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.harnesses).padding(.horizontal, 20).padding(.top, 20)
                ConnectionCenterContent(
                    tab: .harnesses,
                    model: localAccountModel,
                    runtimeSelections: runtimeSelections,
                    connections: connections,
                    harnessUsage: localUsage,
                    initialHarness: nil,
                    addingAccount: .constant(false),
                    setupExpanded: .constant(false),
                    isFixture: false,
                    initialSelectedHarness: .claudeCode,
                    showsInitialConnectionDetails: true,
                    onFinish: {}
                )
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-harnesses-detail", size: size, titled: false) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(.harnesses).padding(.horizontal, 20).padding(.top, 20)
                model.harnessesSettingsSectionView(initialSelectedHarness: .claudeCode, showsInitialConnectionDetails: true)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }

        try await render("local-connectors", size: size, titled: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionHeader(.connectors)
                    ConnectorSettingsView(center: connectorCenter)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
        try await render("remote-connectors", size: size, titled: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionHeader(.connectors)
                    model.connectorsSettingsSectionView()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }

        model.unwatchHostAccounts()
        hosts.close(paired.id)
        await host.shutdown()
    }

    func testDockBadgeAndMenuBarItemsDrawFromTheSameHost() async throws {
        let now = Date(timeIntervalSince1970: 1_792_158_000)
        let folder = URL(filePath: "/tmp/remote-attention-render/yardlet", directoryHint: .isDirectory)
        let approval = SessionRecord(
            harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Approve the index migration", titleOrigin: .provider, status: .waitingForApproval,
            updatedAt: now.addingTimeInterval(-60), hasUnreadUpdate: true
        )
        let unread = SessionRecord(
            harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Summarize the crash reports", titleOrigin: .provider, status: .completed,
            updatedAt: now.addingTimeInterval(-120), hasUnreadUpdate: true, completionState: .completed
        )
        let failed = SessionRecord(
            harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Fix the flaky sampler test", titleOrigin: .provider, status: .failed,
            updatedAt: now.addingTimeInterval(-180), hasUnreadUpdate: true, completionState: .failed
        )
        let hostDefaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAttentionHost")))
        let host = AppModel(
            store: SessionStore(sessions: [approval, unread, failed],
                                repository: InMemorySessionRepository(sessions: [approval, unread, failed])),
            runtimeSelections: RuntimeSelectionStore(defaults: hostDefaults, discoversRuntimes: false, loadsPersistedSelections: false),
            initialTranscripts: [
                approval.id: [
                    TranscriptEntry(content: .permission(
                        PermissionRequest(id: "bash-1", title: "Bash", detail: nil, command: "swift test"),
                        state: .pending
                    ))
                ]
            ],
            preferences: hostDefaults,
            restoresIndexOnLaunch: false
        )
        host.projects.rename(host.projects.ensureProject(forRoot: folder).id, to: "Yardlet")

        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let clientDefaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAttentionClient")))
        let client = AppModel(
            store: SessionStore(sessions: [], repository: InMemorySessionRepository(sessions: [])),
            runtimeSelections: RuntimeSelectionStore(defaults: clientDefaults, discoversRuntimes: false, loadsPersistedSelections: false),
            preferences: clientDefaults,
            restoresIndexOnLaunch: false
        )
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        client.followRemoteHosts(directory)
        let paired = try await directory.pair(link: link.absoluteString)
        let remoteModel = try XCTUnwrap(directory.model(for: paired.id))
        try await waitUntil { remoteModel.hasSnapshot && remoteModel.attentionBadgeCount == 3 }

        XCTAssertEqual(host.attentionBadgeCount, 3)
        XCTAssertEqual(client.attentionBadgeCount, 3)

        let localController = MenuBarMenuController(content: { host.menuBarMenu(now: now) }, actions: .init())
        localController.rebuild()
        let localLines = MenuLine.lines(localController.menu.items)

        let remoteController = MenuBarMenuController(content: { client.menuBarMenu(now: now) }, actions: .init())
        remoteController.rebuild()
        let remoteLines = MenuLine.lines(remoteController.menu.items)

        let size = NSSize(width: 420, height: max(MenuPanel.height(localLines), MenuPanel.height(remoteLines)) + 100)
        @ViewBuilder
        func card(badgeCount: Int, needsAttention: Bool, lines: [MenuLine]) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TitleBarSidebarPart(
                        isSidebarVisible: true,
                        width: 220,
                        onToggleSidebar: {},
                        onNewTask: {},
                        activityToggle: ActivityViewToggle(isOn: false, needsAttention: needsAttention, toggle: {})
                    )
                    Spacer()
                    HStack(spacing: 6) {
                        Text(verbatim: "Dock")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(verbatim: "\(badgeCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                    }
                    .padding(.trailing, 12)
                }
                .background(ParityTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                MenuPanel(lines: lines, width: 380)
            }
            .padding(20)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }

        try await render("local-attention-menu", size: size, titled: false) {
            card(badgeCount: host.attentionBadgeCount, needsAttention: host.attentionBadgeCount > 0, lines: localLines)
        }
        try await render("remote-attention-menu", size: size, titled: false) {
            card(badgeCount: client.attentionBadgeCount, needsAttention: remoteModel.attentionBadgeCount > 0, lines: remoteLines)
        }

        let qaDirectory = try WindowlessRender.directory("remote-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let suffix = "attention-menu-\(appearance.suffix).png"
            let left = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: qaDirectory.appending(path: "local-" + suffix))))
            let right = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: qaDirectory.appending(path: "remote-" + suffix))))
            let combined = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: left.pixelsWide + right.pixelsWide, pixelsHigh: max(left.pixelsHigh, right.pixelsHigh),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: combined)).cgContext
            context.draw(try XCTUnwrap(left.cgImage), in: CGRect(x: 0, y: 0, width: left.pixelsWide, height: left.pixelsHigh))
            context.draw(try XCTUnwrap(right.cgImage), in: CGRect(x: left.pixelsWide, y: 0, width: right.pixelsWide, height: right.pixelsHigh))
            try WindowlessRender.writePNG(combined, to: qaDirectory.appending(path: "comparison-" + suffix))
        }

        directory.close(paired.id)
        await client.shutdown()
        await host.shutdown()
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
                                       ready: (([WindowlessRender.AccessibilityElement]) -> Bool)? = nil,
                                       onMounted: (() -> Void)? = nil, focusedPlaceholder: String? = nil,
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
            // Navigation sent before mounting cannot reach a view's onChange observer. Deliver the
            // local New task action now, then compare the same native input-focus state on both sides.
            onMounted?()
            if let focusedPlaceholder {
                func field(in view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.placeholderString == focusedPlaceholder { return field }
                    return view.subviews.lazy.compactMap { field(in: $0) }.first
                }
                try await waitUntil {
                    Self.turnRunLoop(hosting)
                    guard let field = field(in: hosting), let editor = field.currentEditor() else { return false }
                    return window.firstResponder === editor
                }
                let composer = try XCTUnwrap(field(in: hosting))
                XCTAssertTrue(composer.stringValue.isEmpty)
                XCTAssertNil(composer.placeholderAttributedString)
                XCTAssertEqual(composer.textColor, NSColor.controlTextColor)
                XCTAssertTrue(composer.isEnabled)
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertFalse(window.isVisible)
            }
            if let ready {
                try await waitUntil {
                    Self.turnRunLoop(hosting)
                    return ready(WindowlessRender.accessibilityElements(in: hosting))
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
