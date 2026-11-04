import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

extension RemoteHostWindowRenderingTests {
    func testSubtaskControlsAndHostNoticesUseLocalViews() async throws {
        let folder = URL(fileURLWithPath: "/tmp/remote-render/project", isDirectory: true)
        let activity = HarnessActivity(id: "agent-call", kind: "Agent", title: "Review the parser",
            input: "Check malformed input and report failures.",
            subtask: HarnessSubtaskReference(taskID: "child", agentID: "agent", taskType: "local_agent"))
        let entries = [TranscriptEntry(content: .user(text: "Review the parser")),
                       TranscriptEntry(content: .activity(activity, state: .running))]
        let session = SessionRecord(harness: .claudeCode, workspaceURL: folder,
            runtimeExecutableURL: URL(fileURLWithPath: "/tmp/claude"), title: "Review parser", status: .running)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteSubtaskRender")))
        let host = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), initialTranscripts: [session.id: entries],
            restoresIndexOnLaunch: false)
        let stack = try await LoopbackStack(name: "Host Mac", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Host Mac", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "Client Mac", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.offersSubtasks }
        model.select(.task(session.id.uuidString))
        let conversation = try XCTUnwrap(model.conversations[session.id.uuidString])
        try await waitUntil { conversation.isLoaded }
        var actions = ConversationActions()
        actions.subtaskControls = HarnessActivityActions(open: { _ in }, stop: nil, isStopping: { _ in false }, error: { _ in nil })
        let local = TranscriptConversationProjection.presentation(from: entries, harness: .claudeCode,
            status: .running, latestTurnIsComplete: false)
        let size = NSSize(width: 850, height: 540)
        try await render("local-next-subtask", size: size, titled: false) {
            ConversationTimeline(source: .presented(local), actions: actions).background(ParityTheme.canvas)
        }
        try await render("remote-next-subtask", size: size, titled: false) {
            ConversationTimeline(source: .presented(conversation.presentation), actions: actions).background(ParityTheme.canvas)
        }
        let childEntries = [TranscriptEntry(content: .user(text: "Check malformed input")),
            TranscriptEntry(content: .assistant(text: "The parser rejects incomplete headers and preserves the previous record.", isStreaming: false))]
        let child = TranscriptConversationProjection.presentation(from: childEntries, harness: .claudeCode,
            status: .ready, latestTurnIsComplete: false)
        try await render("local-next-subtask-panel", size: NSSize(width: 700, height: 540), titled: false) {
            HarnessSubtaskPane(activity: activity, session: session, readingPosition: TranscriptReadingPosition(),
                load: { HarnessSubtaskTranscript(entries: childEntries, isTruncated: false) }, onClose: {})
                .background(ParityTheme.canvas)
        }
        let wire = RemoteConversationProjection.conversation(child, workspaceURL: folder)
        let childModel = RemoteConversationModel(taskID: session.id.uuidString, harness: .claudeCode, hostName: "Host Mac")
        childModel.load(wire.turns.flatMap(\.items), cursor: nil, hasOlder: false)
        try await render("remote-next-subtask-panel", size: NSSize(width: 700, height: 540), titled: false) {
            HarnessSubtaskPane(activity: activity, session: session, readingPosition: TranscriptReadingPosition(),
                load: { HarnessSubtaskTranscript(entries: [], isTruncated: false) }, onClose: {},
                loadPresented: { (childModel.presentation, false) }, hostWorkspace: true).background(ParityTheme.canvas)
        }
        let point = ClaudeConversationPoint(id: "checkpoint", text: "Review the parser", previousAssistantID: nil,
            hasAttachments: false, precedingEntries: [])
        let result = HarnessFileRewindResult(canRewind: true, error: nil, filesChanged: ["Sources/Parser.swift"],
            insertions: 4, deletions: 8, skippedLinks: nil, inFlight: false)
        let preview = FileRewindPreview(id: UUID(), session: session, point: point, result: result, fileFingerprints: [:])
        var rewind = ConversationRewindActions(beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {},
            loadFilePoints: { [point] }, previewFiles: { _ in preview }, restoreFiles: { _ in result })
        try await render("local-next-rewind", size: NSSize(width: 520, height: 400), titled: false,
            press: { $0 == L10n.string("Preview file changes") }) {
                ClaudeFileRewindSheet(actions: rewind).background(ParityTheme.canvas)
        }
        rewind.confirmsRestore = true
        try await render("remote-next-rewind", size: NSSize(width: 520, height: 400), titled: false,
            press: { $0 == L10n.string("Preview file changes") }) {
                ClaudeFileRewindSheet(actions: rewind).background(ParityTheme.canvas)
        }
        var notices = RemoteTaskNotices()
        notices.missingFolder = folder.path
        notices.resumedAfterRestart = true; notices.reconnecting = true
        notices.warning = RemoteLimit(status: "warning", window: "session", usedFraction: 0.95)
        notices.warningReset = RemoteJSON.milliseconds(Date().addingTimeInterval(3600))
        notices.accountName = "Work account"; notices.accountMoveInTurn = true
        let localNotices = TaskProviderNotices(limitWarning: HarnessRateLimit(status: .warning, window: .session,
            resetsAt: Date(timeIntervalSince1970: Double(notices.warningReset!) / 1000), usedFraction: 0.95),
            resumedAfterRestart: true, reconnecting: true)
        try await render("local-next-notices", size: NSSize(width: 850, height: 320), titled: false) {
            VStack {
                TaskFolderMissingBanner(notice: TaskFolderMissingNotice(
                    missing: TaskFolderMissing(path: folder.path, worktreeBranch: nil), isRecreating: false, recreateWorktree: {}))
                ProviderNoticeLines(notices: localNotices)
                TaskAccountMoveLine(notice: TaskAccountMoveNotice(accountName: "Work account", cancel: {}))
            }.background(ParityTheme.canvas)
        }
        try await render("remote-next-notices", size: NSSize(width: 850, height: 320), titled: false) {
            VStack { RemoteTaskNoticeLines(notices: notices, cancelAccountMove: {}) }.background(ParityTheme.canvas)
        }
    }
}
