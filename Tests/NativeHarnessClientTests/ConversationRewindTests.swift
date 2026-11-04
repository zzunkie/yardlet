import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

final class ConversationRewindTests: XCTestCase {
    func testSupportedLegacyRuntimeStillUsesRollbackThroughBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: [
                "initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [thread(historyMode: "legacy")],
                "thread/turns/list": [page([turn("target", "Original")]), page([])],
                "thread/rollback": [thread(historyMode: "legacy")]
            ])
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
            let adapter: any HarnessAdapter = routed
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let session = SessionRecord(id: handle.localSessionID, harness: .codex, workspaceURL: handle.workspaceURL,
                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Legacy", providerSessionID: "original")
            let editing = try XCTUnwrap(adapter as? any CodexConversationEditing)
            try await editing.prepareConversationEdit(.init(session: session, targetID: "target", previousID: nil,
                originalText: "Original", draft: .init(text: "Keep draft"), entries: []), in: handle)
            let requests = await transport.requests
            XCTAssertEqual(requests.first { $0.method == "thread/rollback" }?.params["numTurns"], .integer(1))
            XCTAssertFalse(requests.contains { ["thread/revert", "turn/start"].contains($0.method) })
            await adapter.close(handle)
        }
    }

    func testUnsupportedLegacyRollbackPreservesHistoryAndOtherErrorsRemainVisible() async throws {
        for routed in [false, true] {
            for (code, message, unavailable) in [
                (Int64(-32600), "Invalid request: unknown variant `thread/rollback`", true),
                (Int64(-32601), "Method not found", true),
                (Int64(-32000), "Could not write history", false)
            ] {
                let transport = FakeCodexTransport(responses: [
                    "initialize": [.object(["platformOs": .string("macos")])],
                    "thread/start": [thread(historyMode: "legacy")],
                    "thread/turns/list": [page([turn("target", "Original")])]
                ], errorResponses: ["thread/rollback": [.object(["code": .integer(code), "message": .string(message)])]])
                let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
                let adapter: any HarnessAdapter = routed
                    ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
                let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
                let session = SessionRecord(id: handle.localSessionID, harness: .codex, workspaceURL: handle.workspaceURL,
                    runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Legacy", providerSessionID: "original")
                let editing = try XCTUnwrap(adapter as? any CodexConversationEditing)
                do {
                    try await editing.prepareConversationEdit(.init(session: session, targetID: "target", previousID: nil,
                        originalText: "Original", draft: .init(text: "Keep draft"), entries: []), in: handle)
                    XCTFail("A rejected legacy operation cannot be prepared")
                } catch {
                    XCTAssertEqual(error.localizedDescription, unavailable ? L10n.string(
                        "This Codex runtime cannot edit legacy conversations. Your draft and conversation are preserved.") : message)
                }
                let state = try await direct.presentationState(for: handle)
                XCTAssertEqual(state.thread?.turns.map(\.id), ["target"])
                XCTAssertEqual(state.thread?.id, "original")
                let requests = await transport.requests
                XCTAssertFalse(requests.contains { ["thread/revert", "turn/start"].contains($0.method) })
                await adapter.close(handle)
            }
        }
    }

    func testCodexEditUsesNativeRevertThroughBothRoutesAndKeepsThreadIdentity() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: [
                "initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [thread()],
                "thread/turns/list": [page([turn("target", "Original")]), page([])],
                "thread/revert": [thread()],
                "turn/start": [.object(["turn": .object(["id": .string("edited")])])]
            ])
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
            let adapter: any HarnessAdapter = routed
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
            let localID = UUID()
            let handle = try await adapter.createSession(.init(localSessionID: localID, workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let session = SessionRecord(id: localID, harness: .codex, workspaceURL: handle.workspaceURL,
                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Test", providerSessionID: "original")
            let edit = ConversationEditState(session: session, targetID: "target", previousID: nil,
                originalText: "Original", draft: .init(text: "Keep draft"), entries: [])
            let editing = try XCTUnwrap(adapter as? any CodexConversationEditing)
            try await editing.prepareConversationEdit(edit, in: handle)
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.method == "thread/revert" }.count, 1)
            XCTAssertEqual(requests.first { $0.method == "thread/revert" }?.params["beforeTurnId"], .string("target"))
            XCTAssertFalse(requests.contains { $0.method == "turn/start" })
            try await adapter.send("Edited", to: handle)
            let sent = await transport.requests
            XCTAssertEqual(sent.last?.params["threadId"], .string("original"))
            await adapter.close(handle)
        }
    }

    func testCodexChangedLatestMessageRejectsBeforeMutatingHistory() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])], "thread/start": [thread()],
            "thread/turns/list": [page([turn("newer", "New request"), turn("target", "Original")])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let session = SessionRecord(id: handle.localSessionID, harness: .codex, workspaceURL: handle.workspaceURL,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Test", providerSessionID: "original")
        do {
            try await adapter.prepareConversationEdit(.init(session: session, targetID: "target", previousID: nil,
                originalText: "Original", draft: .init(), entries: []), in: handle)
            XCTFail("An older user message cannot be replaced")
        } catch {}
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { ["thread/revert", "thread/rollback", "turn/start"].contains($0.method) })
        await adapter.close(handle)
    }

    func testCodexAlreadyRevertedPrefixDoesNotRepeatMutation() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])], "thread/start": [thread()],
            "thread/turns/list": [page([turn("previous", "Before")])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let session = SessionRecord(id: handle.localSessionID, harness: .codex, workspaceURL: handle.workspaceURL,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Test", providerSessionID: "original")
        try await adapter.prepareConversationEdit(.init(session: session, targetID: "target", previousID: "previous",
            originalText: "Original", draft: .init(), entries: []), in: handle)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.method == "thread/revert" })
        await adapter.close(handle)
    }

    func testClaudeFilePreviewAndRestoreCarryUserUUIDAndNeverChangeConversation() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            await transport.setFileRewindResponses([previewJSON, previewJSON, previewJSON])
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let controller = try XCTUnwrap(adapter as? any HarnessFileRewinding)
            let userID = UUID().uuidString
            let preview = try await controller.previewFileRewind(userMessageID: userID, in: handle)
            let before = await transport.requestedValues
            XCTAssertEqual(before.last?["request"]?["dry_run"], .bool(true))
            XCTAssertEqual(before.last?["request"]?["user_message_id"], .string(userID))
            _ = try await controller.restoreFiles(userMessageID: userID, expecting: preview, in: handle)
            let requests = await transport.requestedValues
            XCTAssertEqual(requests.suffix(3).map { $0["request"]?["dry_run"] }, [.bool(true), .bool(true), .bool(false)])
            let inputs = await transport.sentValues
            XCTAssertTrue(inputs.isEmpty)
            await adapter.close(handle)
        }
    }

    func testClaudeRestoreRechecksAuthorizationAfterTheFreshPreviewThroughBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            await transport.setFileRewindResponses([previewJSON, previewJSON, previewJSON, previewJSON])
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let controller = try XCTUnwrap(adapter as? any HarnessFileRewinding)
            let userID = UUID().uuidString
            let preview = try await controller.previewFileRewind(userMessageID: userID, in: handle)
            let permit = RemoteFileWritePermit()
            await transport.holdRewindPreview()
            let restore = Task {
                try await controller.restoreFiles(userMessageID: userID, expecting: preview, in: handle, authorizing: {
                    guard permit.isValid else { throw RemoteError(.notAllowed) }
                })
            }
            try await waitUntil { await transport.hasHeldRewindPreview }
            permit.revoke()
            await transport.releaseRewindPreview()
            do { _ = try await restore.value; XCTFail("Revoked authorization must stop before dispatch") }
            catch let error as RemoteError { XCTAssertEqual(error.code, .notAllowed) }
            let requests = await transport.requestedValues
            XCTAssertFalse(requests.contains { $0["request"]?["dry_run"] == .bool(false) })
            // A refusal sent no write and must not poison the adapter as an uncertain restore.
            _ = try await controller.restoreFiles(userMessageID: userID, expecting: preview, in: handle)
            let retried = await transport.requestedValues
            XCTAssertEqual(retried.filter { $0["request"]?["dry_run"] == .bool(false) }.count, 1)
            await adapter.close(handle)
        }
    }

    func testClaudeChangedPreviewAndUnknownRestoreResultBlockFurtherMutation() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        await transport.setFileRewindResponses([previewJSON, .object(["canRewind": .bool(false), "error": .string("changed")])])
        let userID = UUID().uuidString
        let preview = try await adapter.previewFileRewind(userMessageID: userID, in: handle)
        do { _ = try await adapter.restoreFiles(userMessageID: userID, expecting: preview, in: handle); XCTFail() } catch {}
        var requests = await transport.requestedValues
        XCTAssertFalse(requests.contains { $0["request"]?["dry_run"] == .bool(false) })
        await transport.setFileRewindResponses([previewJSON, .object(["canRewind": .bool(true), "filesChanged": .array([]), "inFlight": .bool(true)])])
        _ = try await adapter.restoreFiles(userMessageID: userID, expecting: preview, in: handle)
        do { try await adapter.send("Must not race restore", to: handle); XCTFail() } catch {}
        requests = await transport.requestedValues
        let inputs = await transport.sentValues
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(requests.filter { $0["request"]?["dry_run"] == .bool(false) }.count, 1)
        await adapter.close(handle)
    }

    func testEditMetadataRoundTripsAndDoesNotMatchAnotherAccount() throws {
        let source = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Original", providerSessionID: UUID().uuidString)
        let edit = ConversationEditState(session: source, targetID: UUID().uuidString, previousID: nil,
            originalText: "Original", draft: .init(text: "Keep whitespace\n"), entries: [.init(content: .user(text: "Original"))])
        let draft = TaskDraftSnapshot(text: "Edit", editState: edit)
        XCTAssertEqual(try JSONDecoder().decode(TaskDraftSnapshot.self, from: JSONEncoder().encode(draft)), draft)
        let old = try JSONDecoder().decode(TaskDraftSnapshot.self, from: Data(#"{"text":"Keep","attachments":[]}"#.utf8))
        XCTAssertNil(old.editState)
        var changed = source
        changed.providerSessionID = UUID().uuidString
        XCTAssertFalse(edit.matches(changed))
    }

    private var previewJSON: JSONValue {
        .object(["canRewind": .bool(true), "filesChanged": .array([.string("main.swift")]),
            "insertions": .integer(1), "deletions": .integer(2)])
    }
    private func thread(historyMode: String = "paginated") -> JSONValue { .object(["thread": .object(["id": .string("original"), "historyMode": .string(historyMode), "turns": .array([])])]) }
    private func page(_ turns: [JSONValue]) -> JSONValue { .object(["data": .array(turns), "nextCursor": .null]) }
    private func turn(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "status": .string("completed"), "items": .array([
            .object(["id": .string(id + "-user"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string(text)])
            ])])
        ])])
    }
}
