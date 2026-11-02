import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class SessionForkAndResetTests: XCTestCase {
    func testDetachedClaudeRefreshReadsNativeHistoryWithoutModelOrDraftMutation() async throws {
        let fixture = try ForkFixture(); defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter(), model = try fixture.model(adapter)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id); draft.text = "Keep the current unsent draft"
        await model.refreshConversationStatus(for: fixture.parent)
        let first = try XCTUnwrap(model.transcriptBySessionID[fixture.parent.id])
        XCTAssertEqual(first.map(\.content), [.user(text: "Original request"), .assistant(text: "Original answer", isStreaming: false)])
        let reading = model.taskWorkspaces.state(for: fixture.parent.id).transcript
        reading.bookmark.anchorID = first.last?.id.uuidString; reading.bookmark.followsLatest = false
        let bytes = try Data(contentsOf: fixture.parentFile)
        await model.refreshConversationStatus(for: fixture.parent)
        XCTAssertEqual(model.transcriptBySessionID[fixture.parent.id]?.map(\.id), first.map(\.id))
        XCTAssertEqual(reading.bookmark.anchorID, first.last?.id.uuidString)
        XCTAssertEqual(draft.text, "Keep the current unsent draft")
        XCTAssertEqual(model.store.sessions.first, fixture.parent)
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        let probes = await adapter.probes, sent = await adapter.sentInputs
        XCTAssertEqual(probes, 0); XCTAssertTrue(sent.isEmpty)
        await model.shutdown()
    }

    func testClaudeEditedOriginalOpensSeparatelyAfterSQLiteRestartAndReusesTheSameBinding() async throws {
        let fixture = try ForkFixture(); defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter(), model = try fixture.model(adapter)
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Edited request"
        await model.send("Edited request", to: fixture.parent)
        try await model.store.updateSession(id: fixture.parent.id, status: .completed)
        let edited = try XCTUnwrap(model.store.sessions.first)
        let origin = try XCTUnwrap(edited.inheritedContext?.nativeConversationOrigin)
        XCTAssertTrue(origin.matches(fixture.parent))
        XCTAssertEqual(origin.runtimeExecutableURL, edited.runtimeExecutableURL)
        XCTAssertNil(edited.inheritedContext?.nativeForkSource)
        let plannedIDs = await adapter.newSessionIDs
        XCTAssertEqual(plannedIDs.last, edited.providerSessionID)
        XCTAssertThrowsError(try edited.inheritedContext?.prefix())
        let repository = try SQLiteSessionRepository(databaseURL: fixture.root.appending(path: "original-index.sqlite3"))
        try await repository.upsert(edited)
        let records = try await repository.loadSessions()
        let persisted = try XCTUnwrap(records.first)
        XCTAssertEqual(persisted.inheritedContext?.nativeConversationOrigin, origin)
        await model.shutdown()
        let reopenedAdapter = ForkRecordingAdapter(), reopened = try fixture.model(reopenedAdapter, sessions: records)
        let currentDraft = reopened.composerDrafts.tasks.draft(for: persisted.id)
        currentDraft.text = "Keep the edited chat draft"
        let attachment = CodexUserInput.localImage(fixture.root.appending(path: "current.png"), detail: .auto)
        currentDraft.attachments = [attachment]
        let before = currentDraft.snapshot, bytes = try Data(contentsOf: fixture.parentFile)
        let result = await reopened.openOriginalClaudeConversation(from: persisted)
        let original = try XCTUnwrap(result)
        XCTAssertNotEqual(original.id, persisted.id)
        XCTAssertEqual(original.parentTaskID, persisted.id, "The opened original nests under the edited chat")
        XCTAssertEqual(original.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertEqual(original.connection, fixture.parent.connection)
        XCTAssertEqual(original.environmentScope, fixture.parent.environmentScope)
        XCTAssertEqual(original.workspaceURL, fixture.parent.workspaceURL)
        XCTAssertEqual(original.projectID, fixture.parent.projectID)
        XCTAssertEqual(original.additionalRoots, fixture.parent.additionalRoots)
        XCTAssertEqual(original.providerOptions, fixture.parent.providerOptions)
        XCTAssertNil(original.inheritedContext)
        XCTAssertEqual(reopened.store.sessions.first(where: { $0.id == persisted.id }), persisted)
        XCTAssertEqual(currentDraft.snapshot, before)
        XCTAssertEqual(reopened.store.selectedSessionID, original.id)
        XCTAssertFalse(reopened.isAttached(original.id))
        XCTAssertEqual(reopened.transcriptBySessionID[original.id]?.map(\.content), [
            .user(text: "Original request"), .assistant(text: "Original answer", isStreaming: false)])
        let again = await reopened.openOriginalClaudeConversation(from: persisted)
        XCTAssertEqual(again?.id, original.id)
        XCTAssertEqual(reopened.store.sessions.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        let probes = await reopenedAdapter.probes, inputs = await reopenedAdapter.sentInputs
        XCTAssertEqual(probes, 0); XCTAssertTrue(inputs.isEmpty)
        await reopened.shutdown()
    }

    func testClaudeOriginalReadIncludesAnUnansweredUserTailAndDoesNotRequireAForkPoint() async throws {
        let fixture = try ForkFixture(); defer { fixture.cleanup() }
        let first = try String(contentsOf: fixture.parentFile, encoding: .utf8).split(separator: "\n").first!
        try Data((first + "\n").utf8).write(to: fixture.parentFile)
        var edited = fixture.parent
        edited.providerSessionID = UUID().uuidString.lowercased()
        var context = SideChatContext(source: fixture.parent, entries: [])
        context.nativeConversationOrigin = NativeConversationOrigin(session: fixture.parent)
        context.isDelivered = true
        edited.inheritedContext = context
        let adapter = ForkRecordingAdapter(), model = try fixture.model(adapter, sessions: [edited])
        let result = await model.openOriginalClaudeConversation(from: edited)
        let original = try XCTUnwrap(result)
        XCTAssertEqual(model.transcriptBySessionID[original.id]?.map(\.content), [.user(text: "Original request")])
        let probes = await adapter.probes; XCTAssertEqual(probes, 0)
        await model.shutdown()
    }

    func testClaudeOriginalOpeningUsesCapturedHomeAndNeverReusesAnotherScopeOrAccount() async throws {
        let fixture = try ForkFixture(); defer { fixture.cleanup() }
        var edited = fixture.parent; edited.providerSessionID = UUID().uuidString.lowercased()
        let anotherAccount = ProviderConnection(id: "other", name: "Other", harness: .claudeCode,
            providerID: nil, homePath: fixture.root.appending(path: "other").path, credentialSelector: nil)
        edited.connection = anotherAccount
        var context = SideChatContext(source: fixture.parent, entries: [])
        context.nativeConversationOrigin = NativeConversationOrigin(session: fixture.parent)
        context.isDelivered = true; edited.inheritedContext = context
        let wrongAccount = SessionRecord(harness: .claudeCode, workspaceURL: fixture.parent.workspaceURL,
            runtimeExecutableURL: fixture.parent.runtimeExecutableURL, title: "Other home", providerSessionID: fixture.parent.providerSessionID,
            environmentScope: fixture.parent.environmentScope, connection: anotherAccount)
        let wrongScope = SessionRecord(harness: .claudeCode, workspaceURL: fixture.parent.workspaceURL,
            runtimeExecutableURL: fixture.parent.runtimeExecutableURL, title: "Other scope", providerSessionID: fixture.parent.providerSessionID,
            environmentScope: .native, connection: fixture.parent.connection)
        let adapter = ForkRecordingAdapter(), model = try fixture.model(adapter, sessions: [edited, wrongAccount, wrongScope])
        let result = await model.openOriginalClaudeConversation(from: edited)
        let original = try XCTUnwrap(result)
        XCTAssertFalse([wrongAccount.id, wrongScope.id].contains(original.id))
        XCTAssertEqual(original.connection, fixture.parent.connection)
        XCTAssertEqual(original.environmentScope, fixture.parent.environmentScope)
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == edited.id })?.connection, anotherAccount)
        XCTAssertEqual(model.store.sessions.count, 4)
        let probes = await adapter.probes; XCTAssertEqual(probes, 0)
        await model.shutdown()
    }

    func testClaudeUnavailableOrBusyOriginalPreservesCurrentChatDraftAndOldContextCompatibility() async throws {
        let fixture = try ForkFixture(); defer { fixture.cleanup() }
        var edited = fixture.parent; edited.providerSessionID = UUID().uuidString.lowercased()
        let oldContext = SideChatContext(source: fixture.parent, entries: [],
            nativeForkSource: .init(providerSessionID: fixture.parent.providerSessionID!, throughMessageID: fixture.answerID))
        let decoded = try JSONDecoder().decode(SideChatContext.self, from: JSONEncoder().encode(oldContext))
        XCTAssertNil(decoded.nativeConversationOrigin)
        var context = oldContext; context.nativeConversationOrigin = NativeConversationOrigin(session: fixture.parent)
        edited.inheritedContext = context
        let adapter = ForkRecordingAdapter(), model = try fixture.model(adapter, sessions: [edited])
        let draft = model.composerDrafts.tasks.draft(for: edited.id); draft.text = "Unsent draft"
        try await model.store.updateSession(id: edited.id, status: .running)
        let running = try XCTUnwrap(model.store.sessions.first)
        XCTAssertFalse(model.canOpenOriginalConversation(in: running))
        let busyResult = await model.openOriginalClaudeConversation(from: running); XCTAssertNil(busyResult)
        try await model.store.updateSession(id: edited.id, status: .ready)
        try FileManager.default.removeItem(at: fixture.parentFile)
        let current = try XCTUnwrap(model.store.sessions.first)
        let result = await model.openOriginalClaudeConversation(from: current); XCTAssertNil(result)
        XCTAssertEqual(model.store.sessions, [current])
        XCTAssertEqual(draft.text, "Unsent draft")
        XCTAssertNotNil(model.errorBySessionID[current.id])
        let probes = await adapter.probes, inputs = await adapter.sentInputs
        XCTAssertEqual(probes, 0); XCTAssertTrue(inputs.isEmpty)
        await model.shutdown()
    }

    func testClaudeImageEditOpeningCancelAndSendKeepBytesAndSavedScope() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let originalImage = Data([0x89, 0x50, 0x4e, 0x47, 0, 255])
        try fixture.setUserBlocks([.object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/png"), "data": .string(originalImage.base64EncodedString())])])])
        let original = try Data(contentsOf: fixture.parentFile)
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Keep my old draft"
        let oldAttachment = CodexUserInput.localImage(fixture.root.appending(path: "old.png"), detail: .auto)
        draft.attachments = [oldAttachment]
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        XCTAssertNotNil(draft.editState?.originalInputFingerprint)
        XCTAssertEqual(draft.attachments.count, 1)
        XCTAssertEqual(try HarnessUserInput.projecting(draft.submission).input.encodedImages().first?.base64Data, originalImage.base64EncodedString())
        let restored = try JSONDecoder().decode(TaskDraftSnapshot.self, from: JSONEncoder().encode(draft.snapshot))
        XCTAssertEqual(restored, draft.snapshot)
        model.cancelConversationEdit(in: fixture.parent)
        XCTAssertEqual(draft.text, "Keep my old draft")
        XCTAssertEqual(draft.attachments, [oldAttachment])
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        draft.text = "Edited request"
        await model.send("Edited request", to: fixture.parent)
        let record = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(record.id, fixture.parent.id)
        XCTAssertNotEqual(record.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertEqual(record.connection, fixture.parent.connection)
        XCTAssertEqual(record.environmentScope, fixture.parent.environmentScope)
        XCTAssertNil(draft.editState)
        let inputs = await adapter.sentInputs
        XCTAssertEqual(inputs.map(\.text), ["Edited request"])
        XCTAssertEqual(try inputs.first?.encodedImages().first?.base64Data, originalImage.base64EncodedString())
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), original)
        await model.shutdown()
    }

    func testClaudeChangedImageOnSameNativeMessageRejectsBeforeRebinding() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        func image(_ value: UInt8) -> JSONValue { .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/png"), "data": .string(Data([value]).base64EncodedString())])]) }
        try fixture.setUserBlocks([image(1)])
        let adapter = ForkRecordingAdapter(); let model = try fixture.model(adapter)
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Edited request"
        try fixture.setUserBlocks([image(2)])
        await model.send(HarnessUserInput.projecting(draft.submission).input, to: fixture.parent)
        XCTAssertEqual(model.store.sessions.first?.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertNotNil(draft.editState)
        XCTAssertNotNil(draft.notice)
        let inputs = await adapter.sentInputs; XCTAssertTrue(inputs.isEmpty)
        let probes = await adapter.probes; XCTAssertEqual(probes, 0)
        await model.shutdown()
    }

    func testClaudeUnsupportedOriginalOrOutgoingAttachmentKeepsDraftAndNativeIdentity() async throws {
        let fixture = try ForkFixture(); defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter(); let model = try fixture.model(adapter)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id); draft.text = "Keep draft"
        try fixture.setUserBlocks([.object(["type": .string("document"), "source": .object(["type": .string("base64"), "data": .string("AA==")])])])
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        XCTAssertNil(draft.editState); XCTAssertEqual(draft.text, "Keep draft")
        try fixture.setUserBlocks([])
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        draft.attachments = [.image(URL(string: "https://example.invalid/remote.png")!, detail: .auto)]
        draft.text = "Edited request"
        await model.send("Edited request", to: fixture.parent)
        XCTAssertEqual(model.store.sessions.first?.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertNotNil(draft.editState); XCTAssertNotNil(draft.notice)
        let inputs = await adapter.sentInputs; XCTAssertTrue(inputs.isEmpty)
        await model.shutdown()
    }

    func testClaudeNativeForkPersistsBoundaryAndSendsOnlyTheUsersInputAfterRestart() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        model.composerDrafts.tasks.draft(for: fixture.parent.id).text = "Keep the parent draft 👩🏽‍💻"
        let bytes = try Data(contentsOf: fixture.parentFile)
        let prepared = await model.branch(fixture.parent, placement: .sidePanel)
        let child = try XCTUnwrap(prepared)
        XCTAssertEqual(model.store.selectedSessionID, fixture.parent.id)
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == fixture.parent.id }), fixture.parent)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: fixture.parent.id).text, "Keep the parent draft 👩🏽‍💻")
        XCTAssertEqual(child.environmentScope, fixture.parent.environmentScope)
        XCTAssertEqual(child.connection, fixture.parent.connection)
        XCTAssertEqual(child.providerOptions, fixture.parent.providerOptions)
        XCTAssertEqual(child.projectID, fixture.parent.projectID)
        XCTAssertEqual(child.additionalRoots, fixture.parent.additionalRoots)
        let source = try XCTUnwrap(child.inheritedContext?.nativeForkSource)
        XCTAssertEqual(source.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertEqual(source.throughMessageID, fixture.answerID)
        XCTAssertNotEqual(child.providerSessionID, source.providerSessionID)
        XCTAssertFalse(model.isAttached(child.id))
        let preparationProbes = await adapter.probes
        XCTAssertEqual(preparationProbes, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        // SQLite persists the origin as optional context metadata without moving the provider ID.
        let database = fixture.root.appending(path: "index.sqlite3")
        let repository = try SQLiteSessionRepository(databaseURL: database)
        try await repository.upsert(child)
        let records = try await repository.loadSessions()
        let saved = try XCTUnwrap(records.first)
        XCTAssertEqual(saved.inheritedContext?.nativeForkSource, source)
        await model.shutdown()
        let resumedAdapter = ForkRecordingAdapter()
        let resumed = try fixture.model(resumedAdapter, sessions: [fixture.parent, saved])
        await resumed.send("Continue exactly", to: saved)
        let configured = await resumedAdapter.forkSources
        let inputs = await resumedAdapter.sentInputs
        let resumedIDs = await resumedAdapter.resumedIDs
        XCTAssertEqual(configured, [source])
        XCTAssertEqual(resumedIDs, [saved.providerSessionID])
        XCTAssertEqual(inputs.map(\.text), ["Continue exactly"])
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        await resumed.shutdown()
    }

    /// A fork of the saved conversation is a task of its own nested under its source, and the index
    /// keeps the link; the side chat made the same way is not nested.
    func testAClaudeForkNestsUnderItsTaskAndTheIndexKeepsTheLink() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let model = try fixture.model(ForkRecordingAdapter())
        let sideResult = await model.branch(fixture.parent, placement: .sidePanel)
        let side = try XCTUnwrap(sideResult)
        XCTAssertNil(side.parentTaskID)
        let forkResult = await model.branch(fixture.parent)
        let forked = try XCTUnwrap(forkResult)
        XCTAssertEqual(forked.parentTaskID, fixture.parent.id)
        XCTAssertEqual(model.store.selectedSessionID, forked.id)
        let repository = try SQLiteSessionRepository(databaseURL: fixture.root.appending(path: "lineage-index.sqlite3"))
        try await repository.upsert(forked)
        let saved = try await repository.loadSessions()
        XCTAssertEqual(saved.first?.parentTaskID, fixture.parent.id)
        await model.shutdown()
    }

    /// A side chat opens on a task whose turn is still running, as in the Claude app, through Claude's
    /// last text that calls no tool, so the fork holds no call without its result. With no such text
    /// yet the side chat says so, and the task's own error stays clear.
    func testAClaudeSideChatOpensOnARunningTaskThroughItsLastTextWithoutACall() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let id = try XCTUnwrap(fixture.parent.providerSessionID)
        let requestID = UUID().uuidString.lowercased(), textID = UUID().uuidString.lowercased()
        func row(_ type: String, _ uuid: String, after parent: String?, _ content: Any, in session: String? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "sessionId": session ?? id, "uuid": uuid,
                "parentUuid": parent.map { $0 as Any } ?? NSNull(), "message": ["role": type, "content": content]]) + Data([10])
        }
        let call = [["type": "tool_use", "id": "toolu_running", "name": "Bash", "input": ["command": "ls"]]]
        let handle = try FileHandle(forWritingTo: fixture.parentFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: row("user", requestID, after: fixture.answerID, "Check the files")
            + row("assistant", textID, after: requestID, [["type": "text", "text": "Checking them now"]])
            + row("assistant", UUID().uuidString.lowercased(), after: textID, call))
        try handle.close()
        let model = try fixture.model(ForkRecordingAdapter())
        try await model.store.updateSession(id: fixture.parent.id, status: .running)
        let running = try XCTUnwrap(model.store.sessions.first)
        let opened = await model.branch(running, placement: .sidePanel)
        XCTAssertEqual(try XCTUnwrap(opened).inheritedContext?.nativeForkSource?.throughMessageID, textID)
        XCTAssertNil(model.sideChatErrors[running.id])
        await model.shutdown()

        let firstTurn = try ForkFixture()
        defer { firstTurn.cleanup() }
        let firstID = try XCTUnwrap(firstTurn.parent.providerSessionID)
        let firstRequestID = UUID().uuidString.lowercased()
        try (row("user", firstRequestID, after: nil, "Check the files", in: firstID)
            + row("assistant", UUID().uuidString.lowercased(), after: firstRequestID, call, in: firstID))
            .write(to: firstTurn.parentFile)
        let waiting = try firstTurn.model(ForkRecordingAdapter())
        try await waiting.store.updateSession(id: firstTurn.parent.id, status: .running)
        let unopened = await waiting.branch(try XCTUnwrap(waiting.store.sessions.first), placement: .sidePanel)
        XCTAssertNil(unopened)
        XCTAssertEqual(waiting.sideChatErrors[firstTurn.parent.id],
                       L10n.string("Claude has not replied yet. Try again after its first reply."))
        XCTAssertNil(waiting.errorBySessionID[firstTurn.parent.id])
        await waiting.shutdown()
    }

    func testMaterializedClaudeForkResumesItsOwnHistoryInsteadOfReforkingTheParent() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let model = try fixture.model(ForkRecordingAdapter())
        let prepared = await model.branch(fixture.parent, placement: .sidePanel)
        let child = try XCTUnwrap(prepared)
        let childID = try XCTUnwrap(child.providerSessionID)
        _ = try fixture.writeSession(childID, answer: "Own child answer")
        await model.shutdown()
        let adapter = ForkRecordingAdapter()
        let reopened = try fixture.model(adapter, sessions: [fixture.parent, child])
        await reopened.resume(child)
        let sources = await adapter.forkSources
        let ids = await adapter.resumedIDs
        XCTAssertEqual(sources.count, 1)
        XCTAssertNil(sources[0])
        XCTAssertEqual(ids, [childID])
        XCTAssertTrue(reopened.isAttached(child.id))
        await reopened.shutdown()
    }

    func testMissingOriginalForkPointFailsWithoutFallingBackToASnapshotPrompt() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let model = try fixture.model(ForkRecordingAdapter())
        let prepared = await model.branch(fixture.parent, placement: .sidePanel)
        let child = try XCTUnwrap(prepared)
        await model.shutdown()
        // A different active branch has replaced the old checkpoint. Its text is not a fallback.
        _ = try fixture.writeSession(try XCTUnwrap(fixture.parent.providerSessionID), answer: "Different branch")
        let adapter = ForkRecordingAdapter()
        let reopened = try fixture.model(adapter, sessions: [fixture.parent, child])
        await reopened.send("Continue", to: child)
        let inputs = await adapter.sentInputs
        let ids = await adapter.resumedIDs
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertNotNil(reopened.errorBySessionID[child.id])
        XCTAssertFalse(reopened.isAttached(child.id))
        await reopened.shutdown()
    }

    func testClearCreatesANewLocalChatWithoutTouchingTheSourceOrStartingTheProvider() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Independent unsent draft"
        let bytes = try Data(contentsOf: fixture.parentFile)
        await model.send("/clear", to: fixture.parent)
        let fresh = try XCTUnwrap(model.store.selectedSession)
        XCTAssertNotEqual(fresh.id, fixture.parent.id)
        XCTAssertNil(fresh.providerSessionID)
        XCTAssertNil(fresh.inheritedContext)
        XCTAssertEqual(fresh.connection, fixture.parent.connection)
        XCTAssertEqual(fresh.environmentScope, fixture.parent.environmentScope)
        XCTAssertEqual(fresh.workspaceURL, fixture.parent.workspaceURL)
        XCTAssertEqual(fresh.projectID, fixture.parent.projectID)
        XCTAssertEqual(fresh.additionalRoots, fixture.parent.additionalRoots)
        XCTAssertEqual(fresh.providerOptions, fixture.parent.providerOptions)
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == fixture.parent.id }), fixture.parent)
        XCTAssertEqual(draft.text, "Independent unsent draft")
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        let probes = await adapter.probes
        let inputs = await adapter.sentInputs
        XCTAssertEqual(probes, 0)
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertFalse(model.isAttached(fresh.id))
        await model.shutdown()
    }

    func testResetRejectsArgumentsAttachmentsAndBusyStateWithoutConsumingTheDraft() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "/clear extra"
        await model.send(draft.text, to: fixture.parent)
        XCTAssertEqual(draft.text, "/clear extra")
        XCTAssertNotNil(draft.notice)
        draft.text = "/clear"
        draft.attachments = [.localImage(fixture.root.appending(path: "keep.png"), detail: .auto)]
        await model.send(HarnessUserInput(text: "/clear", images: [.init(url: fixture.root.appending(path: "keep.png"), mimeType: "image/png")]), to: fixture.parent)
        XCTAssertEqual(draft.attachments.count, 1)
        try await model.store.updateSession(id: fixture.parent.id, status: .running)
        let busy = try XCTUnwrap(model.store.sessions.first)
        let rejected = await model.restartClaudeConversation(busy)
        XCTAssertNil(rejected)
        XCTAssertEqual(model.store.sessions.count, 1)
        XCTAssertEqual(model.store.sessions.first?.status, .running)
        let probes = await adapter.probes
        XCTAssertEqual(probes, 0)
        await model.shutdown()
    }

    func testAProjectCommandOwnsTheResetAliasAndIsSentLiterally() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let state = ProviderCapabilityState(composerCommands: [
            .init(name: "new", description: "Project command", argumentHint: "", builtin: false)
        ])
        let model = try fixture.model(adapter, capabilities: [fixture.parent.id: state])
        await model.send("/new project arguments", to: fixture.parent)
        XCTAssertEqual(model.store.sessions.count, 1)
        let inputs = await adapter.sentInputs
        XCTAssertEqual(inputs.map(\.text), ["/new project arguments"])
        await model.shutdown()
    }

    func testNativeForkContextCannotBecomeATextPrefixAndOldContextStillDecodes() throws {
        let source = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Original")
        let context = SideChatContext(source: source, entries: [.init(content: .user(text: "Saved text"))],
            nativeForkSource: .init(providerSessionID: UUID().uuidString, throughMessageID: UUID().uuidString))
        XCTAssertThrowsError(try context.prefix())
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        value.removeValue(forKey: "nativeForkSource")
        let old = try JSONDecoder().decode(SideChatContext.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(old.nativeForkSource)
        XCTAssertTrue(try old.prefix().contains("Saved text"))
    }

    func testClaudeEditOpeningAndCancelPreserveOriginalDraftAndDoNotAttach() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Keep original draft 👩🏽‍💻\n"
        let bytes = try Data(contentsOf: fixture.parentFile)
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        XCTAssertEqual(draft.text, "Original request")
        XCTAssertNotNil(draft.editState)
        model.cancelConversationEdit(in: fixture.parent)
        XCTAssertEqual(draft.text, "Keep original draft 👩🏽‍💻\n")
        XCTAssertNil(draft.editState)
        let probes = await adapter.probes
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        await model.shutdown()
    }

    func testFirstClaudeMessageEditUsesNewIdentityAndPreservesOriginalHistory() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        let bytes = try Data(contentsOf: fixture.parentFile)
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Edited request"
        await model.send("Edited request", to: fixture.parent)
        let current = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(current.id, fixture.parent.id)
        XCTAssertNotEqual(current.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertEqual(current.connection, fixture.parent.connection)
        XCTAssertEqual(current.environmentScope, fixture.parent.environmentScope)
        XCTAssertEqual(try Data(contentsOf: fixture.parentFile), bytes)
        let inputs = await adapter.sentInputs
        XCTAssertEqual(inputs.map(\.text), ["Edited request"])
        XCTAssertNil(draft.editState)
        XCTAssertEqual(model.store.sessions.count, 1)
        await model.shutdown()
    }

    func testChangedRawClaudeMessageRefusesEditWithoutRebinding() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        await model.beginClaudeEdit("Original request", in: fixture.parent)
        let draft = model.composerDrafts.tasks.draft(for: fixture.parent.id)
        draft.text = "Edited"
        _ = try fixture.writeSession(fixture.parent.providerSessionID!, answer: "Other branch")
        await model.send("Edited", to: fixture.parent)
        XCTAssertEqual(model.store.sessions.first?.providerSessionID, fixture.parent.providerSessionID)
        XCTAssertNotNil(draft.notice)
        XCTAssertNotNil(draft.editState)
        let inputs = await adapter.sentInputs
        XCTAssertTrue(inputs.isEmpty)
        await model.shutdown()
    }

    func testFileFingerprintsDetectEditsAndRejectPathsOutsideProjectAndSymlinks() throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appending(path: "file.swift")
        try Data("first".utf8).write(to: file)
        let first = try ClaudeSubagentTranscriptReader.fileFingerprints(["file.swift"], in: fixture.parent)
        try Data("second".utf8).write(to: file)
        XCTAssertNotEqual(try ClaudeSubagentTranscriptReader.fileFingerprints(["file.swift"], in: fixture.parent), first)
        XCTAssertThrowsError(try ClaudeSubagentTranscriptReader.fileFingerprints(["../outside.swift"], in: fixture.parent))
        let linked = fixture.root.appending(path: "linked.swift")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        XCTAssertThrowsError(try ClaudeSubagentTranscriptReader.fileFingerprints(["linked.swift"], in: fixture.parent))
    }

    func testReviewedFilePreviewRejectsAFileChangedAfterReviewWithoutRestoring() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appending(path: "file.swift")
        try Data("reviewed".utf8).write(to: file)
        let adapter = ForkRecordingAdapter()
        let model = try fixture.model(adapter)
        let points = try await model.loadClaudeFilePoints(in: fixture.parent)
        let point = try XCTUnwrap(points.last)
        let preview = try await model.previewClaudeFiles(pointID: point.id, in: fixture.parent)
        try Data("changed by user".utf8).write(to: file)
        do { _ = try await model.restoreClaudeFiles(preview); XCTFail() } catch {}
        let restores = await adapter.fileRestoreCount
        XCTAssertEqual(restores, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed by user")
        await model.shutdown()
    }

    func testMainForkReaderRejectsAmbiguitySymlinksAndFifosWithoutChangingTheOriginal() throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanup() }
        let bytes = try Data(contentsOf: fixture.parentFile)
        let id = try XCTUnwrap(fixture.parent.providerSessionID)
        let reader = ClaudeSubagentTranscriptReader(configDirectory: fixture.root)
        let duplicate = fixture.root.appending(path: "projects/duplicate/\(id).jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: duplicate)
        XCTAssertThrowsError(try reader.readSession(sessionID: id))
        try FileManager.default.removeItem(at: duplicate)
        let real = fixture.root.appending(path: "real-original.jsonl")
        try FileManager.default.moveItem(at: fixture.parentFile, to: real)
        try FileManager.default.createSymbolicLink(at: fixture.parentFile, withDestinationURL: real)
        XCTAssertThrowsError(try reader.readSession(sessionID: id))
        XCTAssertEqual(try Data(contentsOf: real), bytes)
        try FileManager.default.removeItem(at: fixture.parentFile)
        XCTAssertEqual(mkfifo(fixture.parentFile.path, 0o600), 0)
        XCTAssertThrowsError(try reader.readSession(sessionID: id))
        XCTAssertEqual(try Data(contentsOf: real), bytes)
    }
}

private struct ForkFixture {
    let root: URL
    let parent: SessionRecord
    let answerID: String
    var parentFile: URL { file(try! XCTUnwrap(parent.providerSessionID)) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.Fork.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connection = ProviderConnection(id: "saved-account", name: "Saved", harness: .claudeCode,
            providerID: nil, homePath: root.path, credentialSelector: nil)
        parent = .init(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Original", providerSessionID: UUID().uuidString.lowercased(),
            providerOptions: ["permissionMode": "plan", "model": "opus"], environmentScope: .yardlet,
            connection: connection, projectID: UUID(), additionalRoots: [root.appending(path: "extra").path])
        answerID = UUID().uuidString.lowercased()
        _ = try writeSession(parent.providerSessionID!, answer: "Original answer", answerID: answerID)
    }
    func file(_ id: String) -> URL { root.appending(path: "projects/test/\(id).jsonl") }
    func setUserBlocks(_ blocks: [JSONValue]) throws {
        var rows = try String(contentsOf: parentFile, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        guard case var .object(user) = rows[0], case var .object(message) = user["message"] else { return }
        message["content"] = .array([.object(["type": .string("text"), "text": .string("Original request")])] + blocks)
        user["message"] = .object(message); rows[0] = .object(user)
        var data = Data()
        for row in rows { data.append(try JSONEncoder().encode(row)); data.append(10) }
        try data.write(to: parentFile)
    }
    @discardableResult
    func writeSession(_ id: String, answer: String, answerID: String = UUID().uuidString.lowercased()) throws -> URL {
        let target = file(id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userID = UUID().uuidString.lowercased()
        let rows: [[String: Any]] = [
            ["type": "user", "sessionId": id, "uuid": userID, "parentUuid": NSNull(),
             "message": ["role": "user", "content": "Original request"]],
            ["type": "assistant", "sessionId": id, "uuid": answerID, "parentUuid": userID,
             "message": ["role": "assistant", "content": [["type": "text", "text": answer]]]]
        ]
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
        try bytes.write(to: target)
        return target
    }
    @MainActor
    func model(_ adapter: ForkRecordingAdapter, sessions: [SessionRecord]? = nil,
        capabilities: [UUID: ProviderCapabilityState] = [:]) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.Fork.Test")))
        return AppModel(store: SessionStore(sessions: sessions ?? [parent], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
            initialProviderCapabilities: capabilities, transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor ForkRecordingAdapter: HarnessAdapter, HarnessSessionForkConfiguring, HarnessNewSessionConfiguring, HarnessConversationQuiescing, HarnessFileRewinding, ProviderCapabilityProviding, HarnessSessionBranching {
    nonisolated let kind = HarnessKind.claudeCode
    nonisolated let sessionBranchMethod: HarnessSessionBranchMethod? = .savedConversation
    private(set) var probes = 0
    private(set) var forkSources: [HarnessSessionForkSource?] = []
    private(set) var resumedIDs: [String?] = []
    private(set) var newSessionIDs: [String?] = []
    private(set) var sentInputs: [HarnessUserInput] = []
    private(set) var fileRestoreCount = 0
    private var continuations: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        probes += 1
        return .init(harness: kind, executableURL: URL(filePath: "/tmp/claude"), version: "2.1.284",
            capabilities: .init(canResume: true, canInterrupt: true, hasStructuredPermissions: true,
                hasStructuredActivities: true, hasPlans: true, acceptsImages: true, hasSubagents: false), fingerprint: "test")
    }
    func setSessionForkSource(_ source: HarnessSessionForkSource?, for localSessionID: UUID) { forkSources.append(source) }
    func setNewSessionID(_ providerSessionID: String?, for localSessionID: UUID) { newSessionIDs.append(providerSessionID) }
    func requireReadyForRewind(in session: HarnessSessionHandle) async throws {}
    func previewFileRewind(userMessageID: String, in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        .init(canRewind: true, error: nil, filesChanged: ["file.swift"], insertions: 1, deletions: 1, skippedLinks: nil, inFlight: nil)
    }
    func restoreFiles(userMessageID: String, expecting preview: HarnessFileRewindResult,
        in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        fileRestoreCount += 1
        return preview
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        .init(harness: kind, localSessionID: request.localSessionID, providerSessionID: UUID().uuidString,
            workspaceURL: request.workspaceURL)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        resumedIDs.append(providerSessionID)
        return .init(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID, workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { sentInputs.append(.init(text: prompt)) }
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws { sentInputs.append(input) }
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let pair = AsyncStream<HarnessEventEnvelope>.makeStream()
        continuations[session.localSessionID] = pair.continuation
        return pair.stream
    }
    func close(_ session: HarnessSessionHandle) async { continuations.removeValue(forKey: session.localSessionID)?.finish() }
    func providerCapabilities(for session: HarnessSessionHandle) async throws -> ProviderCapabilityState { .empty }
    func setProviderOption(id: String, value: String, in session: HarnessSessionHandle) async throws -> ProviderCapabilityState { .empty }
    func performProviderAction(id: String, in session: HarnessSessionHandle) async throws -> ProviderCapabilityState { .empty }
}
