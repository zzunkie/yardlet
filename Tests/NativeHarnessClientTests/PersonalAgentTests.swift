import XCTest
@testable import NativeHarnessClient

@MainActor
final class PersonalAgentTests: XCTestCase {
    private func value(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testRoomMembershipSeparatesDotRepliesFromPeopleAndPaginationKeepsIdentity() throws {
        let agent = fixtureAgent()
        let room = try value(#"{"id":"room","aeon_id":"dot","members":[{"account_user_id":"person","name":"Person","role":"user"},{"account_user_id":"dot-member","name":"Atlas","role":"user","aeon_id":"dot"}]}"#)
        let page = try value(#"{"items":[{"id":"m1","role":"user","account_user_id":"person","created_at":"2026-10-01T09:00:00Z","content":{"text":"Prepare a draft.","attachments":[]}},{"id":"m2","role":"user","account_user_id":"dot-member","created_at":"2026-10-01T09:01:00Z","content":{"text":"The draft is ready.","attachments":[{"file":{"id":"report","file_name":"report.txt"}}]}},{"id":"m3","role":"user","account_user_id":"dot-member","created_at":"2026-10-01T09:02:00Z","content":{"text":"","attachments":[]}}],"prev_cursor":null}"#)
        let result = try DotsProjection.messages(page, room: room, agent: agent)
        XCTAssertEqual(result.messages.map(\.author), [.person, .agent, .agent])
        // What Yardlet cannot show yet is marked so, not told by its words.
        XCTAssertEqual(result.messages.map(\.isUnsupported), [false, false, true])
        XCTAssertEqual(result.messages[1].attachments.map(\.opensHere), [true])
        XCTAssertEqual(result.before, "m1")
        XCTAssertEqual(result.messages[1].attachments, [.init(fileID: "report", name: "report.txt", type: "file")])
        let changedAccount = fixtureAgent(account: "different-account")
        XCTAssertNotEqual(agent.id, changedAccount.id)
        let wrongRoom = try value(#"{"id":"another-room","aeon_id":"dot","members":[]}"#)
        XCTAssertThrowsError(try DotsProjection.messages(page, room: wrongRoom, agent: agent))

        let edited = PersonalAgentMessage(id: "m2", author: .agent, text: "", createdAt: nil, isDeleted: true, attachments: [])
        let merged = DotsProjection.merge(result.messages, with: [edited], older: false)
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged[1].isDeleted)
        XCTAssertEqual(merged[0].id, "m1")

        // A profile's picture is its HTTPS snapshot, versioned by content; asset pointers are not URLs.
        let profiles = try value(#"{"items":[{"id":"dot","aeon_kind":"orbit","messaging_room_id":"room","display_name":"Atlas","avatar_url":"https://files.oaiusercontent.com/avatar?sig=example","avatar_manifest":{"pet_id":"pet","snapshot":{"asset_pointer":"sediment://file_a","content_sha256":"abc"}}},{"id":"dot-2","aeon_kind":"orbit","messaging_room_id":"room-2","avatar_url":"sediment://file_b"}]}"#)
        let agents = try DotsProjection.agents(catalog: profiles, primary: .object([:]), accountID: "account", userID: "person")
        XCTAssertEqual(agents[0].avatar?.version, "abc")
        XCTAssertNil(agents[1].avatar)
        XCTAssertFalse(String(describing: agents[0]).contains("sig="), "A signed picture URL never reaches a description")
        // The dot's own page names its profile identity as one escaped path component, nothing else;
        // the app's Dots home is the one address the app takes.
        XCTAssertEqual(DotsLinks.web(for: agents[0])?.absoluteString, "https://chatgpt.com/dots/dot")
        let composite = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "example-account~example dot/2", roomID: "room"),
                                      name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        XCTAssertEqual(DotsLinks.web(for: composite)?.absoluteString, "https://chatgpt.com/dots/example-account~example%20dot%2F2")
        XCTAssertEqual(DotsLinks.appHome.absoluteString, "codex://dots")
        // The animated form is the pet the manifest names, read from the account's pets; the snapshot's
        // hash says nothing about the sheet, whose version is its artwork revision and last change.
        XCTAssertEqual(agents.map(\.petID), ["pet", nil])
        let petPage = try DotsProjection.pets(value(#"{"pets":[{"id":"pet","artwork_revision":"3","updated_at":"2026-10-29T06:00:00Z","spritesheet_url":"https://files.oaiusercontent.com/sheet?sig=example"},{"id":"pet-2","spritesheet_url":null},{"id":"pet-3","spritesheet_url":"http://files.oaiusercontent.com/sheet"}],"cursor":"next"}"#))
        XCTAssertEqual(petPage.pets.map(\.id), ["pet"])
        XCTAssertEqual(petPage.pets[0].version, "3|2026-10-29T06:00:00Z")
        XCTAssertEqual(petPage.cursor, "next")
        XCTAssertFalse(String(describing: petPage.pets[0]).contains("sig="), "A signed sheet URL never reaches a description")

        // Activity keeps the provider's order and its unknowns; it is not the thread list.
        let activity = try DotsProjection.activity(value(#"{"data":[{"thread_id":"a","title":"Weekly report","status":"completed","outcome":"succeeded","updated_at":1793200300},{"thread_id":"b","title":"Call notes","status":"completed","outcome":"interrupted","updated_at":1793200900},{"thread_id":"c","status":"in_progress","updated_at":1793200000},{"thread_id":"d","status":null,"updated_at":1793200600}],"next_cursor":"next"}"#))
        XCTAssertEqual(activity.items.map(\.id), ["c", "d", "a", "b"])
        XCTAssertEqual(activity.items[1].status, .unknown)
        XCTAssertEqual(activity.cursor, "next")

        // Attached is the dot's permission to use a computer; only a provider status says it is reachable.
        let computers = try DotsProjection.computers(value(#"{"thread_id":"root","computers":[{"kind":"cloud","environment_id":"e1","is_attached":true},{"kind":"user","environment_id":"e2","display_name":"Studio","is_attached":true,"status":"offline"},{"kind":"user","environment_id":"e3","is_attached":false,"status":"connected"},{"kind":"user","environment_id":"e4","is_attached":true,"status":"connected"}]}"#), rootThreadID: "root")
        XCTAssertEqual(computers.map(\.availability), [.unknown, .offline, .disconnected, .connected])
        XCTAssertEqual(computers.map(\.isCloud), [true, false, false, false])
        XCTAssertThrowsError(try DotsProjection.computers(value(#"{"thread_id":"another","computers":[]}"#), rootThreadID: "root"))
    }

    func testLeavingAndReturningRetainsReadingPositionWithoutStartingAConversation() async throws {
        let center = PersonalAgentCenter()
        let agent = fixtureAgent()
        let reader = FixturePersonalAgentReader(agents: [agent])
        await center.connect(sourceKey: "saved-account") { reader }
        let state = try XCTUnwrap(center.conversation)
        state.anchor = "m1"
        await center.disconnect()
        XCTAssertEqual(center.selectedID, agent.id)
        XCTAssertEqual(center.conversation?.anchor, "m1")
        let stopped = await reader.didStop()
        XCTAssertTrue(stopped)
        let next = FixturePersonalAgentReader(agents: [agent])
        await center.connect(sourceKey: "saved-account") { next }
        XCTAssertEqual(center.conversation?.anchor, "m1")
        XCTAssertEqual(center.conversation?.messages.count, 1)
        // A detail that cannot be read fails alone; the conversation and the other parts stay.
        try await waitUntil { center.details?.computers == .failed(.accessDenied) && center.details?.activity == .loaded([]) }
        XCTAssertNil(center.failure)
        XCTAssertEqual(center.conversation?.messages.count, 1)

        // A later page of an Activity read that a refresh replaced is dropped, not merged into the new list.
        let running = PersonalAgentActivity(id: "a", title: "Report", status: .running, outcome: .unknown,
                                            updatedAt: nil, preview: nil)
        let earlier = PersonalAgentActivity(id: "b", title: "Notes", status: .completed, outcome: .succeeded,
                                            updatedAt: nil, preview: nil)
        let finished = PersonalAgentActivity(id: "a", title: "Report", status: .completed, outcome: .succeeded,
                                             updatedAt: nil, preview: nil)
        await next.setActivity(["": .init(items: [running], cursor: "more"), "more": .init(items: [earlier], cursor: nil)])
        center.refreshDetails()
        try await waitUntil { center.details?.activity == .loaded([running]) && center.details?.activityCursor == "more" }
        await next.holdActivity(cursor: "more")
        let more = Task { await center.loadMoreActivity() }
        try await waitUntil { await next.hasPendingActivity() }
        await next.setActivity(["": .init(items: [finished], cursor: nil)])
        center.refreshDetails()
        try await waitUntil { center.details?.activity == .loaded([finished]) }
        await next.releaseActivity()
        await more.value
        XCTAssertEqual(center.details?.activity, .loaded([finished]))
        XCTAssertNil(center.details?.activityCursor)

        // While a refresh waits for its first page, the old list's next page is not asked for.
        await next.setActivity(["": .init(items: [running], cursor: "more"), "more": .init(items: [earlier], cursor: nil)])
        center.refreshDetails()
        try await waitUntil { center.details?.activityCursor == "more" }
        await next.holdActivity(cursor: "")
        await next.setActivity(["": .init(items: [finished], cursor: "after"), "more": .init(items: [earlier], cursor: nil)])
        center.refreshDetails()
        try await waitUntil { await next.hasPendingActivity() }
        XCTAssertNil(center.details?.activityCursor)
        await center.loadMoreActivity()
        XCTAssertEqual(center.details?.activity, .loaded([running]), "The shown list stays while it refreshes")
        await next.releaseActivity()
        try await waitUntil { center.details?.activity == .loaded([finished]) }
        XCTAssertEqual(center.details?.activityCursor, "after")

        // The other parts of an earlier refresh that answer last do not replace the newer reply either.
        let off = PersonalAgentSchedule(id: "s", title: "Weekly report", isEnabled: false)
        let on = PersonalAgentSchedule(id: "s", title: "Weekly report", isEnabled: true)
        await next.setSchedules([off])
        await next.holdNextSchedules()
        center.refreshDetails()
        try await waitUntil { await next.hasPendingSchedules() }
        await next.setSchedules([on])
        center.refreshDetails()
        try await waitUntil { center.details?.schedules == .loaded([on]) }
        await next.releaseSchedules()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(center.details?.schedules, .loaded([on]))
        await center.disconnect()
    }

    func testLateAccountReadCannotReplaceTheNewSelection() async {
        let center = PersonalAgentCenter()
        let delayed = FixturePersonalAgentReader(agents: [fixtureAgent()], delay: true)
        let pending = Task { await center.connect(sourceKey: "old") { delayed } }
        while !(await delayed.hasPendingRead()) { await Task.yield() }
        let replacement = fixtureAgent(account: "new-account")
        let next = FixturePersonalAgentReader(agents: [replacement])
        await center.connect(sourceKey: "new") { next }
        await delayed.release()
        await pending.value
        XCTAssertEqual(center.selectedID, replacement.id)
        await center.disconnect()
    }

    /// Whatever keeps a dot's pet from playing leaves its still picture, and nothing of an earlier pet,
    /// version or account plays on; the next connection reads the pet and its sheet again.
    func testAPetThatCannotPlayLeavesTheSnapshotUntilTheNextConnection() async throws {
        let center = PersonalAgentCenter()
        var dot = fixtureAgent()
        dot.petID = "pet"
        let plain = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "dot-2", roomID: "room-2"),
                                  name: "Juniper", rootThreadID: nil, isPaused: false, isPrimary: false)
        let reader = FixturePersonalAgentReader(agents: [dot, plain])
        func pet(_ version: String) -> PersonalAgentPet {
            .init(id: "pet", location: "https://files.oaiusercontent.com/sheet", version: version)
        }
        func reconnect(_ pets: [PersonalAgentPet], failure: PersonalAgentFailure? = nil,
                       petFailure: PersonalAgentFailure? = nil) async {
            await reader.usePets(pets, sheetFailure: failure, petFailure: petFailure)
            await center.connect(sourceKey: "account") { reader }
        }
        let shown = { center.spriteSheet(for: dot)?.version }

        // A sheet the storage refuses: the snapshot stays; a dot without a pet is not looked up.
        await reconnect([pet("v1")], failure: .attachmentUnavailable)
        try await waitUntil { await reader.sheetReads == 1 }
        XCTAssertNil(shown())
        XCTAssertNil(center.spriteSheet(for: plain))
        let lookups = await reader.petReads
        XCTAssertEqual(lookups, 1)
        // The next connection reads the pet and its sheet again.
        await reconnect([pet("v1")])
        try await waitUntil { shown() == "v1" }
        let first = try XCTUnwrap(center.spriteSheet(for: dot))
        await reconnect([pet("v1")])
        try await waitUntil { await reader.petReads == 3 }
        XCTAssertTrue(center.spriteSheet(for: dot) === first, "The same version is not read again")
        // A new version that cannot be read, or a pet gone, does not leave the old one playing.
        await reconnect([pet("v2")], failure: .attachmentUnavailable)
        try await waitUntil { shown() == nil }
        await reconnect([pet("v2")])
        try await waitUntil { shown() == "v2" }
        await reconnect([])
        try await waitUntil { shown() == nil }
        // A passing failure to read the pets keeps the pet playing.
        await reconnect([pet("v1")])
        try await waitUntil { shown() == "v1" }
        var reads = await reader.petReads
        await reconnect([], petFailure: .network)
        try await waitUntil { await reader.petReads == reads + 1 }
        XCTAssertEqual(shown(), "v1")
        // A pet read that finds another login clears the whole reading, as the details do.
        reads = await reader.petReads
        await reconnect([], petFailure: .accountChanged)
        try await waitUntil { await reader.petReads == reads + 1 }
        try await waitUntil { center.failure == .accountChanged }
        XCTAssertTrue(center.agents.isEmpty)
        XCTAssertNil(center.selectedID)
        XCTAssertNil(center.conversation)
        XCTAssertNil(shown())
        // Another account keeps nothing of this one's.
        await reconnect([pet("v1")])
        try await waitUntil { shown() == "v1" }
        await center.connect(sourceKey: "another-account") { FixturePersonalAgentReader(agents: [dot]) }
        XCTAssertNil(shown())
        await center.disconnect()
    }

    func testEarlierMessagesKeepTheCurrentReadingAnchor() async {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], paged: true)
        await center.connect(sourceKey: "account") { reader }
        center.conversation?.anchor = "m1"
        await center.refreshConversation(older: true)
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m0", "m1"])
        XCTAssertEqual(center.conversation?.anchor, "m1")
        XCTAssertNil(center.conversation?.before)
        await center.disconnect()
    }

    func testRefreshingAfterSeveralPagesOfUpdatesDoesNotLeaveAHole() async {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], gap: true)
        await center.connect(sourceKey: "account") { reader }
        center.conversation?.anchor = "m1"
        await reader.advance()
        await center.refreshConversation()
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(center.conversation?.anchor, "m1")
        await center.disconnect()
    }

    func testUncertainDeliveryRetainsItsRequestAcrossRetryAndRefresh() async throws {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], losesFirstSend: true)
        await center.connect(sourceKey: "account") { reader }
        let draft = try XCTUnwrap(center.conversation?.draft)
        draft.editor.text = "Prepare a draft, without publishing it."
        await center.send()
        let pending = try XCTUnwrap(draft.pending)
        XCTAssertEqual(draft.failure, .deliveryUnknown)
        XCTAssertEqual(draft.editor.text, pending.text)
        // A rejected retry cannot prove that the earlier request was rejected.
        draft.failed(.signInRequired, retry: false)
        XCTAssertEqual(draft.pending, pending)
        draft.failed(.sendRejected, retry: true)
        XCTAssertEqual(draft.pending, pending)
        await center.send()
        let requests = await reader.sentRequests()
        XCTAssertEqual(requests.map(\.requestID), [pending.requestID, pending.requestID])
        XCTAssertTrue(draft.editor.text.isEmpty)
        XCTAssertNil(draft.pending)
        await center.disconnect()
    }

    func testSendingInOneAccountCannotClearAnotherAccountsDraftOrSendTwice() async throws {
        let drafts = PersonalAgentDrafts()
        let center = PersonalAgentCenter(drafts: drafts)
        let oldAgent = fixtureAgent()
        let old = FixturePersonalAgentReader(agents: [oldAgent], delaysSend: true)
        await center.connect(sourceKey: "old") { old }
        let oldDraft = try XCTUnwrap(center.conversation?.draft)
        oldDraft.editor.text = "Old account draft"
        let sending = Task { await center.send() }
        while !(await old.hasPendingSend()) { await Task.yield() }
        await center.send()
        let nextAgent = fixtureAgent(account: "another")
        let next = FixturePersonalAgentReader(agents: [nextAgent])
        await center.connect(sourceKey: "new") { next }
        center.conversation?.draft.editor.text = "Keep this new account draft"
        await old.releaseSend()
        await sending.value
        XCTAssertEqual(center.selectedID, nextAgent.id)
        XCTAssertEqual(center.conversation?.draft.editor.text, "Keep this new account draft")
        XCTAssertTrue(oldDraft.editor.text.isEmpty)
        let requests = await old.sentRequests()
        XCTAssertEqual(requests.count, 1)
        await center.connect(sourceKey: "old") { FixturePersonalAgentReader(agents: [oldAgent]) }
        XCTAssertTrue(center.conversation?.draft.editor.text.isEmpty == true)
        await center.connect(sourceKey: "new") { FixturePersonalAgentReader(agents: [nextAgent]) }
        XCTAssertEqual(center.conversation?.draft.editor.text, "Keep this new account draft")
        await center.disconnect()
    }

    func testOnlyTheSameAccountAndHomeRestoreAnUncertainDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalAgentDrafts(directory: directory)
        let draft = store.draft(source: "home-a", identity: fixtureAgent().id)
        draft.editor.text = "A draft kept across restart"
        let request = try XCTUnwrap(draft.prepare())
        draft.failed(.deliveryUnknown, retry: false)
        let restored = PersonalAgentDrafts(directory: directory)
        let same = restored.draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertEqual(same.editor.text, request.text)
        XCTAssertEqual(same.prepare(), request)
        XCTAssertEqual(same.failure, .deliveryUnknown)
        same.failed(.verificationRequired, retry: true)
        same.isSending = true
        XCTAssertFalse(same.resumeEditing())
        XCTAssertEqual(same.pending, request)
        same.isSending = false
        XCTAssertTrue(same.resumeEditing())
        XCTAssertNil(same.pending)
        XCTAssertEqual(same.editor.text, request.text)
        let editable = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertNil(editable.pending)
        XCTAssertEqual(editable.editor.text, request.text)
        XCTAssertNotEqual(editable.prepare()?.requestID, request.requestID)
        XCTAssertTrue(restored.draft(source: "home-b", identity: fixtureAgent().id).editor.text.isEmpty)
        XCTAssertTrue(restored.draft(source: "home-a", identity: fixtureAgent(account: "other").id).editor.text.isEmpty)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let corrupt = Data("unreadable draft".utf8)
        try corrupt.write(to: file)
        let broken = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        broken.editor.text = "Must not overwrite the unreadable original"
        XCTAssertNil(broken.prepare())
        XCTAssertTrue(broken.storageFailed)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertTrue(broken.needsRecovery)
        XCTAssertTrue(broken.recoverStorage())
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(".backup-") })
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        let recovered = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertFalse(recovered.needsRecovery)
        XCTAssertEqual(recovered.editor.text, "Must not overwrite the unreadable original")
        XCTAssertNil(recovered.pending)

        let blocker = directory.appending(path: "blocked")
        let recoverable = PersonalAgentDraft(file: blocker.appending(path: "draft.json"))
        try Data().write(to: blocker)
        recoverable.editor.text = "Save before sending"
        XCTAssertNil(recoverable.prepare())
        XCTAssertNil(recoverable.pending)
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(recoverable.save())
        XCTAssertNotNil(recoverable.prepare())
    }

    func testHistoryRefreshRevalidatesOldMessagesAndDoesNotUseASendAsItsBoundary() async throws {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()])
        func message(_ id: String, _ text: String = "Earlier message") -> PersonalAgentMessage {
            .init(id: id, author: .agent, text: text, createdAt: nil, isDeleted: false, attachments: [])
        }
        await reader.replaceHistory([message("m1"), message("m2")])
        await center.connect(sourceKey: "runtime-a", draftSourceKey: "same-home") { reader }
        await center.refreshConversation(older: true)
        await reader.replaceHistory([message("m1", "Edited elsewhere"), message("m2"), message("m3"), message("m4")])
        center.conversation?.draft.editor.text = "A new message after the missing pages"
        await center.send()
        XCTAssertEqual(center.conversation?.messages.prefix(4).map(\.id), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(center.conversation?.messages.first?.text, "Edited elsewhere")
        XCTAssertEqual(center.conversation?.messages.last?.author, .person)
        XCTAssertTrue(center.conversation?.sentMessages.isEmpty == true)
        await reader.delayReadAfterNextSend()
        center.conversation?.draft.editor.text = "A message removed elsewhere before the first read"
        let sending = Task { await center.send() }
        while !(await reader.hasPendingMessageRead()) { await Task.yield() }
        XCTAssertFalse(center.conversation?.draft.isSending ?? true)
        center.conversation?.draft.editor.text = "The next draft remains editable during backfill"
        await reader.replaceHistory([message("m2"), message("m3"), message("m4")])
        await reader.releaseMessageRead()
        await sending.value
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m2", "m3", "m4"])
        XCTAssertEqual(center.conversation?.visibleMessages.map(\.id), ["m2", "m3", "m4"])
        XCTAssertEqual(center.conversation?.draft.editor.text, "The next draft remains editable during backfill")

        await reader.delayNextMessageRead()
        let refresh = Task { await center.refreshConversation() }
        while !(await reader.hasPendingMessageRead()) { await Task.yield() }
        refresh.cancel()
        await reader.releaseMessageRead()
        await refresh.value
        XCTAssertFalse(center.conversation?.isLoading ?? true)
        await center.refreshConversation()
        XCTAssertNil(center.conversation?.failure)

        center.conversation?.draft.editor.text = "Keep this when changing the runtime executable"
        await center.connect(sourceKey: "runtime-b", draftSourceKey: "same-home") {
            FixturePersonalAgentReader(agents: [fixtureAgent()])
        }
        XCTAssertEqual(center.conversation?.draft.editor.text, "Keep this when changing the runtime executable")
        await center.disconnect()
    }

    func testSendDuringUploadSendsThePressedDraftAndARetryKeepsItsFileIDs() async throws {
        let (folder, original) = try chosenFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], losesFirstSend: true)
        await reader.holdUploads()
        await center.connect(sourceKey: "account") { reader }
        let draft = try XCTUnwrap(center.conversation?.draft)
        await center.attach([.init(url: original, declaredType: nil)], to: try XCTUnwrap(center.fileTarget()))
        let file = try XCTUnwrap(draft.files.first)
        XCTAssertNotEqual(file.copy, original, "The draft keeps its own copy")
        try await waitUntil { await reader.hasPendingUpload() }
        // A file alone is a message; Send waits for its upload instead of leaving it out.
        let sending = Task { await center.send() }
        try await waitUntil { draft.waitsForUploads }
        draft.editor.text = "Typed after Send was pressed"
        await reader.releaseUpload()
        await sending.value
        var requests = await reader.sentRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.text, "", "The words as they were when Send was pressed")
        XCTAssertEqual(requests.first?.attachments.map(\.fileID), ["file-1"])
        XCTAssertEqual(draft.failure, .deliveryUnknown)
        XCTAssertEqual(draft.pending, requests.first)
        center.removeFile(file.id)
        XCTAssertEqual(draft.files.map(\.id), [file.id], "A pending message's files stay as they were sent")
        await center.send()
        requests = await reader.sentRequests()
        XCTAssertEqual(requests.map(\.requestID), [requests[0].requestID, requests[0].requestID])
        XCTAssertEqual(requests[1], requests[0], "The same words, file IDs and request")
        let uploads = await reader.uploadCount()
        XCTAssertEqual(uploads, 1, "A retry never uploads the files again")
        XCTAssertTrue(draft.files.isEmpty)
        XCTAssertEqual(draft.editor.text, "Typed after Send was pressed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.copy.path(percentEncoded: false)))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8), "The person's file is untouched")
        await center.disconnect()
    }

    func testAFailedOrStoppedUploadNeverLeavesASendWithoutItsFile() async throws {
        let (folder, original) = try chosenFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()])
        await reader.failUploads(true)
        await center.connect(sourceKey: "account") { reader }
        let draft = try XCTUnwrap(center.conversation?.draft)
        draft.editor.text = "Here is the file"
        await center.attach([.init(url: original)], to: try XCTUnwrap(center.fileTarget()))
        try await waitUntil { draft.hasFailedUploads }
        await center.send()
        var sent = await reader.sentRequests()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(draft.failure, .attachmentsIncomplete)
        XCTAssertEqual(draft.editor.text, "Here is the file")
        await reader.failUploads(false)
        center.retryUploads()
        try await waitUntil { draft.files.first?.uploaded != nil }
        await center.send()
        sent = await reader.sentRequests()
        XCTAssertEqual(sent.first?.attachments.count, 1)

        // Files picked for one connection never reach the draft of the next, and an upload the
        // connection change stopped is left to retry, not counted as sent.
        await reader.holdUploads()
        let target = try XCTUnwrap(center.fileTarget())
        await center.attach([.init(url: original)], to: target)
        try await waitUntil { await reader.hasPendingUpload() }
        let stale = try XCTUnwrap(center.fileTarget())
        await center.connect(sourceKey: "another") { FixturePersonalAgentReader(agents: [self.fixtureAgent(account: "another")]) }
        await reader.releaseUpload()
        try await waitUntil { draft.files.first?.state == .failed(.uploadInterrupted) }
        let next = try XCTUnwrap(center.conversation?.draft)
        await center.attach([.init(url: original)], to: stale)
        XCTAssertTrue(next.files.isEmpty)
        XCTAssertEqual(draft.files.count, 1)
        await center.disconnect()
    }

    func testDraftFilesAreSavedCopiesThatOutliveARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let (folder, original) = try chosenFile()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: folder) }
        let store = PersonalAgentDrafts(directory: directory)
        let draft = store.draft(source: "home-a", identity: fixtureAgent().id)
        draft.editor.text = "Text only"
        let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: record))["version"], .integer(1),
                       "A draft without files stays readable by earlier builds")
        let added = await draft.addFiles([.init(url: original), .init(url: original)])
        draft.setState(added[0], .uploaded(.init(fileID: "file-1", name: "notes.txt", mimeType: "text/plain", sizeBytes: 8)))
        draft.setState(added[1], .uploading)
        let copy = try XCTUnwrap(draft.file(added[1])?.copy)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let restored = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertEqual(restored.files.map(\.state), [.uploaded(.init(fileID: "file-1", name: "notes.txt", mimeType: "text/plain", sizeBytes: 8)),
                                                      .failed(.uploadInterrupted)])
        XCTAssertEqual(try Data(contentsOf: restored.files[1].copy), Data("original".utf8))
        XCTAssertTrue(PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent(account: "other").id).files.isEmpty)
        restored.removeFile(added[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))

        // A copy made while the draft cannot be saved is not uploaded, and is not lost: the next start
        // takes it back to retry, since the saved draft never said it was removed.
        let blocked = directory.appending(path: "blocked.json")
        let unsaved = PersonalAgentDraft(file: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let none = await unsaved.addImage(name: "image.png", mimeType: "image/png") { Data("pasted".utf8) }
        XCTAssertTrue(none.isEmpty, "Nothing uploads before the draft names the file")
        let kept = try XCTUnwrap(unsaved.files.first)
        XCTAssertEqual(kept.state, .failed(.draftStorage))
        try FileManager.default.removeItem(at: blocked)
        let reopened = PersonalAgentDraft(file: blocked)
        XCTAssertEqual(reopened.files.map(\.id), [kept.id])
        XCTAssertEqual(reopened.files.first?.state, .failed(.uploadInterrupted))
        XCTAssertEqual(try Data(contentsOf: kept.copy), Data("pasted".utf8))

        // A removal whose save failed keeps the copy only until a later save succeeds; after that, a
        // restart does not bring the removed file back.
        let removing = PersonalAgentDraft(file: blocked)
        let gone = try XCTUnwrap(removing.files.first)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        removing.removeFile(gone.id)
        XCTAssertTrue(removing.files.isEmpty)
        XCTAssertTrue(removing.storageFailed)
        try FileManager.default.removeItem(at: blocked)
        removing.editor.text = "Saved again without the file"
        XCTAssertFalse(removing.storageFailed)
        let afterRemoval = PersonalAgentDraft(file: blocked)
        XCTAssertTrue(afterRemoval.files.isEmpty, "A removed file never returns")
        XCTAssertEqual(afterRemoval.editor.text, "Saved again without the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.copy.deletingLastPathComponent().path(percentEncoded: false)))

        // A damaged record cannot name a copy outside the draft's own folder.
        var raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: record))
        if case var .object(fields) = raw, case var .array(files)? = fields["files"], case var .object(file) = files[0] {
            file["copyName"] = .string("../../outside")
            files[0] = .object(file)
            fields["files"] = .array(files)
            raw = .object(fields)
        }
        try JSONEncoder().encode(raw).write(to: record)
        let damaged = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertEqual(damaged.files.first?.copy.lastPathComponent, "file")
        XCTAssertEqual(damaged.files.first?.copy.deletingLastPathComponent().lastPathComponent, added[0].uuidString)
    }

    private func chosenFile() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "notes.txt")
        try Data("original".utf8).write(to: file)
        return (folder, file)
    }

    private func fixtureAgent(account: String = "account") -> PersonalAgent {
        .init(id: .init(accountID: account, userID: "person", agentID: "dot", roomID: "room"),
              name: "Atlas", rootThreadID: "thread", isPaused: false, isPrimary: true)
    }
}

private actor FixturePersonalAgentReader: PersonalAgentClient {
    let values: [PersonalAgent]
    let delay: Bool
    let paged: Bool
    let gap: Bool
    let losesFirstSend: Bool
    let delaysSend: Bool
    private var sends: [PersonalAgentSubmission] = []
    private var pendingSend: CheckedContinuation<Void, Never>?
    private var history: [PersonalAgentMessage]?
    private var delayMessageRead = false
    private var delayAfterSend = false
    private var pendingMessageRead: CheckedContinuation<Void, Never>?
    private var advanced = false
    private var pending: CheckedContinuation<[PersonalAgent], Never>?
    private var stopped = false
    init(agents: [PersonalAgent], delay: Bool = false, paged: Bool = false, gap: Bool = false,
         losesFirstSend: Bool = false, delaysSend: Bool = false) {
        values = agents; self.delay = delay; self.paged = paged; self.gap = gap
        self.losesFirstSend = losesFirstSend; self.delaysSend = delaysSend
    }
    func agents() async throws -> [PersonalAgent] {
        if delay { return await withCheckedContinuation { pending = $0 } }
        return values
    }
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        if delayMessageRead {
            delayMessageRead = false
            await withCheckedContinuation { pendingMessageRead = $0 }
        }
        if let history {
            let end = before.flatMap { id in history.firstIndex { $0.id == id } } ?? history.count
            let start = max(0, end - 1)
            return .init(messages: Array(history[start..<end]), before: start > 0 ? history[start].id : nil)
        }
        if gap && advanced {
            let id = before == nil ? "m3" : before == "m3" ? "m2" : "m1"
            return .init(messages: [.init(id: id, author: .agent, text: "Draft ready.", createdAt: nil, isDeleted: false, attachments: [])],
                         before: id == "m1" ? nil : id)
        }
        return .init(messages: [.init(id: before == nil ? "m1" : "m0", author: .agent, text: "Draft ready.",
                               createdAt: nil, isDeleted: false, attachments: [])],
              before: paged && before == nil ? "m1" : nil)
    }
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> { AsyncStream { $0.finish() } }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        sends.append(submission)
        if delaysSend { await withCheckedContinuation { pendingSend = $0 } }
        if losesFirstSend, sends.count == 1 { throw PersonalAgentFailure.deliveryUnknown }
        let message = PersonalAgentMessage(id: submission.requestID, author: .person, text: submission.text, createdAt: nil,
              isDeleted: false, attachments: [], requestID: submission.requestID)
        if history != nil { history?.append(message) }
        if delayAfterSend { delayMessageRead = true; delayAfterSend = false }
        return message
    }
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        throw PersonalAgentFailure.attachmentUnavailable
    }
    private var uploads = 0
    private var holdsUploads = false
    private var failsUploads = false
    private var pendingUpload: CheckedContinuation<Void, Never>?
    func upload(_ file: PersonalAgentPreparedFile, to agent: PersonalAgent) async throws -> PersonalAgentUploadedFile {
        if holdsUploads { await withCheckedContinuation { pendingUpload = $0 } }
        if failsUploads { throw PersonalAgentFailure.uploadFailed }
        uploads += 1
        return .init(fileID: "file-\(uploads)", name: file.name, mimeType: file.mimeType, sizeBytes: file.data.count)
    }
    func holdUploads() { holdsUploads = true }
    func failUploads(_ value: Bool) { failsUploads = value }
    func hasPendingUpload() -> Bool { pendingUpload != nil }
    func releaseUpload() { holdsUploads = false; pendingUpload?.resume(); pendingUpload = nil }
    func uploadCount() -> Int { uploads }
    func avatar(for agent: PersonalAgent) async throws -> Data { throw PersonalAgentFailure.attachmentUnavailable }
    private var pets: [String: PersonalAgentPet] = [:]
    private var sheetFailure: PersonalAgentFailure?
    private var petFailure: PersonalAgentFailure?
    private(set) var petReads = 0
    private(set) var sheetReads = 0
    func usePets(_ value: [PersonalAgentPet], sheetFailure: PersonalAgentFailure? = nil,
                 petFailure: PersonalAgentFailure? = nil) {
        pets = Dictionary(uniqueKeysWithValues: value.map { ($0.id, $0) })
        self.sheetFailure = sheetFailure
        self.petFailure = petFailure
    }
    func pet(_ id: String, for agent: PersonalAgent) async throws -> PersonalAgentPet? {
        petReads += 1
        if let petFailure { throw petFailure }
        return pets[id]
    }
    func spriteSheet(_ pet: PersonalAgentPet, for agent: PersonalAgent) async throws -> Data {
        sheetReads += 1
        if let sheetFailure { throw sheetFailure }
        return Data(pet.version.utf8)
    }
    private var activityPages: [String: PersonalAgentActivityPage] = [:]
    private var heldActivityCursor: String?
    private var pendingActivity: CheckedContinuation<Void, Never>?
    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage {
        let key = cursor ?? ""
        if heldActivityCursor == key {
            heldActivityCursor = nil
            await withCheckedContinuation { pendingActivity = $0 }
        }
        return activityPages[key] ?? .init(items: [], cursor: nil)
    }
    func setActivity(_ pages: [String: PersonalAgentActivityPage]) { activityPages = pages }
    func holdActivity(cursor: String) { heldActivityCursor = cursor }
    func hasPendingActivity() -> Bool { pendingActivity != nil }
    func releaseActivity() { pendingActivity?.resume(); pendingActivity = nil }
    private var scheduleValues: [PersonalAgentSchedule] = []
    private var holdsNextSchedules = false
    private var pendingSchedules: CheckedContinuation<Void, Never>?
    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule] {
        let values = scheduleValues
        if holdsNextSchedules {
            holdsNextSchedules = false
            await withCheckedContinuation { pendingSchedules = $0 }
        }
        return values
    }
    func setSchedules(_ values: [PersonalAgentSchedule]) { scheduleValues = values }
    func holdNextSchedules() { holdsNextSchedules = true }
    func hasPendingSchedules() -> Bool { pendingSchedules != nil }
    func releaseSchedules() { pendingSchedules?.resume(); pendingSchedules = nil }
    /// An optional part that fails, which must stay in its own part.
    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer] { throw PersonalAgentFailure.accessDenied }
    func stop() { stopped = true }
    func didStop() -> Bool { stopped }
    func hasPendingRead() -> Bool { pending != nil }
    func release() { pending?.resume(returning: values); pending = nil }
    func advance() { advanced = true }
    func sentRequests() -> [PersonalAgentSubmission] { sends }
    func hasPendingSend() -> Bool { pendingSend != nil }
    func releaseSend() { pendingSend?.resume(); pendingSend = nil }
    func replaceHistory(_ messages: [PersonalAgentMessage]) { history = messages }
    func delayNextMessageRead() { delayMessageRead = true }
    func delayReadAfterNextSend() { delayAfterSend = true }
    func hasPendingMessageRead() -> Bool { pendingMessageRead != nil }
    func releaseMessageRead() { pendingMessageRead?.resume(); pendingMessageRead = nil }
}
