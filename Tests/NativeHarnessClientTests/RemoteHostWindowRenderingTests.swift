import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
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
///
/// Against the fixture host (`RemoteFixtureBridge`), which streams and answers:
/// - `remote-connect-*.png`: File › Connect to Mac… with one paired Mac.
/// - `remote-host-running-*.png`: a turn running after its approval was answered, with a queued message.
/// - `remote-host-answered-*.png`: a finished task's turns, each folded under its answer.
/// - `remote-host-new-*.png`: a new task with the host's project, harness and model menus.
/// - `remote-host-offline-*.png`: the host gone, its list and conversation kept under the banner.
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

    /// The local timeline of a Claude Code task waiting on the person, whose cards can answer as the window's do.
    private func localTimeline(_ entries: [TranscriptEntry], folder: URL) -> some View {
        var actions = ConversationActions()
        actions.chooseOption = { _, _ in }
        actions.answer = { _, _ in }
        return ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .waitingForApproval,
                                                        latestTurnIsComplete: false), actions: actions)
            .environment(\.transcriptWorkspaceURL, folder)
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
