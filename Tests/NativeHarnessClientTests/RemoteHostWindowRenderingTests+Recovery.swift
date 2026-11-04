import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

extension RemoteHostWindowRenderingTests {
    func testRetryAndResumeCardsDrawFromTheSameHostTurns() async throws {
        let folder = URL(filePath: "/tmp/remote-recovery-render")
        let retry = SessionRecord(harness: .claudeCode, workspaceURL: folder,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Retry the parser tests", status: .failed)
        let resume = SessionRecord(harness: .claudeCode, workspaceURL: folder,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Continue the parser tests", status: .ready)
        let retryEntries = [TranscriptEntry(content: .user(text: "Check the parser")),
            TranscriptEntry(content: .error(message: "The provider was temporarily unavailable.", recoverable: true, transient: true))]
        let resumeEntries = [TranscriptEntry(content: .user(text: "Check the parser")),
            TranscriptEntry(content: .usageLimit(HarnessRateLimit(status: .rejected, window: .session,
                resetsAt: Date().addingTimeInterval(-60), usedFraction: 1)))]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteRecoveryRender")))
        let host = AppModel(store: SessionStore(sessions: [retry, resume], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            initialTranscripts: [retry.id: retryEntries, resume.id: resumeEntries], restoresIndexOnLaunch: false)
        let stack = try await LoopbackStack(name: "Host Mac", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Host Mac", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "Client Mac", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        defer { hosts.close(paired.id) }
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.nextSteps }
        for (name, session, entries) in [("retry", retry, retryEntries), ("resume", resume, resumeEntries)] {
            model.select(.task(session.id.uuidString))
            let conversation = try XCTUnwrap(model.conversations[session.id.uuidString])
            try await waitUntil { conversation.isLoaded }
            let local = TranscriptConversationProjection.presentation(from: entries, harness: .claudeCode,
                status: session.status, latestTurnIsComplete: true)
            var actions = ConversationActions()
            actions.retryTurn = { _ in }
            actions.providerNotices = TaskProviderNotices(canContinue: true, continueAfterReset: { _ in })
            if name == "retry" {
                XCTAssertTrue(conversation.presentation.turns.last?.actions.canRetry == true)
                XCTAssertEqual(conversation.presentation.turns.last?.actions.canRetry, local.turns.last?.actions.canRetry)
            } else {
                XCTAssertTrue(conversation.usageLimit?.options?.contains("resumeAfterReset") == true)
            }
            for (prefix, presentation) in [("local", local), ("remote", conversation.presentation)] {
                try await render("\(prefix)-next-\(name)", size: NSSize(width: 850, height: 420), titled: false) {
                    ConversationTimeline(source: .presented(presentation), actions: actions)
                        .background(ParityTheme.canvas)
                } check: { elements in
                    XCTAssertTrue(elements.contains { $0.label == L10n.string(name == "retry" ? "Retry" : "Resume") }, elements.description)
                }
            }
        }
        await host.shutdown()
    }
}
