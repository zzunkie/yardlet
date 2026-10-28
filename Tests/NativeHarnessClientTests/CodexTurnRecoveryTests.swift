import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CodexTurnRecoveryTests: XCTestCase {
    func testNativeCapacityRetryUsesEmptyInputThroughBothRoutesAndCannotRepeatAfterAcceptance() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: responses())
            let adapter = makeAdapter(transport: transport, routed: routed)
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let recovery = try XCTUnwrap(adapter as? any CodexTurnRecovering)
            try await recovery.retryFailedTurn("failed", in: handle)
            let requests = await transport.requests
            let start = try XCTUnwrap(requests.first { $0.method == "turn/start" })
            XCTAssertEqual(start.params["threadId"], .string("original"))
            XCTAssertEqual(start.params["input"], .array([]))
            XCTAssertEqual(start.params["turnTrigger"], .string("capacity_retry_manual"))
            XCTAssertEqual(requests.first { $0.method == "thread/read" }?.params["includeTurns"], .bool(false))
            XCTAssertEqual(requests.first { $0.method == "thread/turns/list" }?.params["limit"], .integer(1))
            XCTAssertFalse(requests.contains { ["thread/revert", "thread/rollback", "turn/steer", "thread/fork"].contains($0.method) })
            let active = await (adapter as? any CodexComposerProviding)?.activeTurnID(for: handle)
            XCTAssertEqual(active, "continued")
            do { try await recovery.retryFailedTurn("failed", in: handle); XCTFail("Accepted recovery cannot append another continuation") } catch {}
            let after = await transport.requests
            XCTAssertEqual(after.filter { $0.method == "turn/start" }.count, 1)
            await adapter.close(handle)
        }
    }

    func testNativeRetryRechecksBusyChangedLatestAndErrorTypeBeforeSending() async throws {
        for routed in [false, true] {
            for (runtimeStatus, latest) in [
                ("active", turn()), ("idle", turn(id: "newer")),
                ("idle", turn(status: "completed")), ("idle", turn(errorInfo: "usageLimitExceeded")),
                ("idle", turn(errorInfo: "other"))
            ] {
                var fixture = responses()
                fixture["thread/read"] = [threadResult(status: runtimeStatus)]
                fixture["thread/turns/list"] = [page([latest])]
                let transport = FakeCodexTransport(responses: fixture)
                let adapter = makeAdapter(transport: transport, routed: routed)
                let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
                let recovery = try XCTUnwrap(adapter as? any CodexTurnRecovering)
                do { try await recovery.retryFailedTurn("failed", in: handle); XCTFail("Stale or unsupported recovery must fail closed") } catch {}
                let requests = await transport.requests
                XCTAssertFalse(requests.contains { $0.method == "turn/start" })
                await adapter.close(handle)
            }
        }
    }

    func testLostRetryAcknowledgementCannotDuplicateACompletedContinuation() async throws {
        for routed in [false, true] {
            var fixture = responses()
            fixture["thread/read"] = [threadResult(), threadResult()]
            fixture["thread/turns/list"] = [page([turn()]), page([turn(id: "continued", status: "completed")])]
            let transport = FakeCodexTransport(responses: fixture, errorResponses: ["turn/start": [
                .object(["code": .integer(-32000), "message": .string("Acknowledgement lost")])
            ]])
            let adapter = makeAdapter(transport: transport, routed: routed)
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let recovery = try XCTUnwrap(adapter as? any CodexTurnRecovering)
            do { try await recovery.retryFailedTurn("failed", in: handle); XCTFail() } catch {}
            do { try await recovery.retryFailedTurn("failed", in: handle); XCTFail() } catch {}
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.method == "turn/start" }.count, 1)
            await adapter.close(handle)
        }
    }

    func testAppModelRetryPreservesDraftHistoryIdentityAndQueueThroughBothRoutes() async throws {
        for routed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.Retry.\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appending(path: "codex")
            try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let transport = FakeCodexTransport(responses: responses())
            let adapter = makeAdapter(transport: transport, routed: routed, executable: executable)
            let session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
                title: "Keep this chat", providerSessionID: "original", environmentScope: .yardlet)
            let suite = testDefaultsSuite("NativeHarnessClientTests.Retry")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                restoresIndexOnLaunch: false)
            await model.resume(session)
            try await waitUntil { model.codexPresentationBySessionID[session.id]?.thread?.turns.last != nil }
            let failed = try XCTUnwrap(model.codexPresentationBySessionID[session.id]?.thread?.turns.last)
            XCTAssertEqual(failed.status, .failed)
            let draft = model.composerDrafts.tasks.draft(for: session.id)
            draft.text = "Unsent draft\n"
            draft.attachments = [.localImage(root.appending(path: "not-sent.png"), detail: .original)]
            let before = draft.snapshot
            let entries = model.transcriptBySessionID[session.id]
            await model.retryTurn(failed.id, in: session)
            XCTAssertEqual(draft.snapshot, before)
            XCTAssertEqual(model.transcriptBySessionID[session.id], entries)
            let current = try XCTUnwrap(model.store.sessions.first)
            XCTAssertEqual(current.id, session.id)
            XCTAssertEqual(current.providerSessionID, session.providerSessionID)
            XCTAssertEqual(current.environmentScope, session.environmentScope)
            XCTAssertEqual(current.connection, session.connection)
            XCTAssertTrue(model.followUps.queue(for: current.id).isEmpty)
            let starts = await transport.requests.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 1)
            XCTAssertEqual(starts.first?.params["input"], .array([]))
            await model.shutdown()
        }
    }

    func testRetryProjectionOnlyAdmitsLatestIdleCapacityFailure() throws {
        var state = CodexTaskState(thread: try XCTUnwrap(CodexTaskDecoder().thread(from: threadResult()["thread"]!)))
        XCTAssertTrue(CodexTurnRecoveryProjection.canRetry("failed", in: state))
        XCTAssertFalse(CodexTurnRecoveryProjection.canRetry("older", in: state))
        for status in [CodexTurnStatus.completed, .interrupted, .inProgress, .unknown("future")] {
            state.thread?.turns[0].status = status
            XCTAssertFalse(CodexTurnRecoveryProjection.canRetry("failed", in: state))
        }
        state.thread?.turns[0].status = .failed
        state.thread?.turns[0].error = .string("serverOverloaded")
        XCTAssertFalse(CodexTurnRecoveryProjection.canRetry("failed", in: state))
        state.thread?.turns[0].error = turn()["error"]
        state.thread?.status = .active(flags: [])
        XCTAssertFalse(CodexTurnRecoveryProjection.canRetry("failed", in: state))
    }

    func testConcurrentRetryCannotStartTwiceWhileNativeValidationIsPending() async throws {
        let transport = FakeCodexTransport(responses: responses())
        let adapter = makeAdapter(transport: transport, routed: true)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let recovery = try XCTUnwrap(adapter as? any CodexTurnRecovering)
        await transport.suspendNextRequest("thread/read")
        let first = Task { try await recovery.retryFailedTurn("failed", in: handle) }
        try await waitUntil { await transport.isRequestSuspended }
        let suspended = await transport.isRequestSuspended; XCTAssertTrue(suspended)
        do { try await recovery.retryFailedTurn("failed", in: handle); XCTFail() } catch {}
        await transport.releaseSuspendedRequest()
        try await first.value
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.method == "turn/start" }.count, 1)
        await adapter.close(handle)
    }

    func testClosedSessionDuringNativeValidationCannotStartOrRebindAConversation() async throws {
        let transport = FakeCodexTransport(responses: responses())
        let adapter = makeAdapter(transport: transport, routed: true)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let recovery = try XCTUnwrap(adapter as? any CodexTurnRecovering)
        await transport.suspendNextRequest("thread/read")
        let pending = Task { try await recovery.retryFailedTurn("failed", in: handle) }
        try await waitUntil { await transport.isRequestSuspended }
        await adapter.close(handle)
        await transport.releaseSuspendedRequest()
        do { try await pending.value; XCTFail() } catch {}
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.method == "turn/start" })
    }

    func testCompletionBeforeStartAcknowledgementDoesNotRestoreAnActiveRetry() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: responses())
            let adapter = makeAdapter(transport: transport, routed: routed)
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let recovery = try XCTUnwrap(adapter as? any CodexTurnRecovering)
            let presentation = try XCTUnwrap(adapter as? any CodexPresentationProviding)
            _ = try await presentation.presentationStates(for: handle)
            await transport.suspendNextRequest("turn/start")
            let pending = Task { try await recovery.retryFailedTurn("failed", in: handle) }
            try await waitUntil { await transport.isRequestSuspended }
            await transport.emit(method: "turn/started", params: .object(["threadId": .string("original"),
                "turn": .object(["id": .string("continued"), "status": .string("inProgress"), "items": .array([])])]))
            await transport.emit(method: "turn/completed", params: .object(["threadId": .string("original"),
                "turn": .object(["id": .string("continued"), "status": .string("completed"), "items": .array([])])]))
            try await waitUntil {
                try await presentation.presentationState(for: handle).thread?.turns.last?.status == .completed
            }
            let completed = try await presentation.presentationState(for: handle)
            XCTAssertEqual(completed.thread?.turns.last?.id, "continued")
            XCTAssertEqual(completed.thread?.turns.last?.status, .completed)
            await transport.releaseSuspendedRequest()
            try await pending.value
            let active = await (adapter as? any CodexComposerProviding)?.activeTurnID(for: handle)
            XCTAssertNil(active)
            await adapter.close(handle)
        }
    }

    func testActualRetryErrorCardAndTurnMenuRenderWithoutAWindow() throws {
        let directory = try WindowlessRender.directory("codex-retry-qa")
        for appearance in [ColorScheme.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 16) {
                TranscriptErrorCard(harness: .codex, message: "The service is currently overloaded. Try again later.", recoverable: true, onRetry: {})
                Divider()
                // The turn's actions as its messages draw them, shown as on hover.
                HStack(spacing: 12) {
                    ConversationMessageActionButtons(actions: [ConversationTurnAction.fork, .editTurn].map {
                        $0.messageAction(turn: ConversationTurn(id: "turn-qa", status: .failed, timing: ConversationTurnTiming()),
                                         handlers: ConversationTurnHandlers(edit: { _ in }, fork: {}))
                    })
                }
                .environment(\.revealsSentMessageActions, true)
                OriginalConversationMenuItem(canOpen: true, onOpen: {}).buttonStyle(.plain)
            }.padding(12).frame(width: 500).background(ParityTheme.input).environment(\.colorScheme, appearance)
            // The turn's actions are AppKit buttons, which only a window draws.
            let capture = try WindowlessRender.hosted(content, size: NSSize(width: 500, height: 280),
                                                      appearance: WindowlessRender.Appearance(appearance))
            XCTAssertEqual(capture.bitmap.pixelsWide, Int(500 * capture.backingScaleFactor))
            try WindowlessRender.writePNG(capture.bitmap, to:
                directory.appending(path: appearance == .dark ? "retry-dark.png" : "retry-light.png"))
        }
    }

    private func makeAdapter(transport: FakeCodexTransport, routed: Bool,
        executable: URL = URL(filePath: "/tmp/codex")) -> any HarnessAdapter {
        let direct = CodexAdapter(executableURL: executable, transport: transport)
        return routed ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
    }

    private func responses() -> [String: [JSONValue]] {
        ["initialize": [.object(["platformOs": .string("macos")])],
         "thread/start": [threadResult()], "thread/resume": [threadResult()],
         "thread/items/list": [.object(["data": .array([]), "nextCursor": .null])],
         "thread/read": [threadResult()], "thread/turns/list": [page([turn()])],
         "turn/start": [.object(["turn": .object(["id": .string("continued")])])]]
    }

    private func threadResult(status: String = "idle") -> JSONValue {
        .object(["thread": .object(["id": .string("original"), "status": .object(["type": .string(status)]),
            "historyMode": .string("paginated"), "turns": .array([turn()])])])
    }

    private func page(_ turns: [JSONValue]) -> JSONValue { .object(["data": .array(turns), "nextCursor": .null]) }

    private func turn(id: String = "failed", status: String = "failed", errorInfo: String = "serverOverloaded") -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "itemsView": .string("full"), "items": .array([
            .object(["id": .string(id + "-user"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string("Original request")]),
                .object(["type": .string("future_attachment"), "payload": .string("Retain without decoding")])
            ])])]), "error": .object(["message": .string("Capacity failure"), "codexErrorInfo": .string(errorInfo)])])
    }
}
