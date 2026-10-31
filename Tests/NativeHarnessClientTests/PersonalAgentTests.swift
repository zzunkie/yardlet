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

        // A waiting reply keeps its target across a restart, in a record earlier builds refuse to read
        // and keep as a backup; a draft without one is written as before.
        let replyFile = directory.appending(path: "reply.json")
        let replying = PersonalAgentDraft(file: replyFile)
        replying.editor.text = "Looks right."
        let target = PersonalAgentReplyTarget(messageID: "parent", rootID: "root")
        let waiting = try XCTUnwrap(replying.prepare(replying.intended(replyingTo: target)))
        XCTAssertEqual(waiting.replyTarget, target)
        XCTAssertNil(waiting.replyToMessageID)
        XCTAssertNil(waiting.optionSelection)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: replyFile))["version"], .integer(3))
        let reread = PersonalAgentDraft(file: replyFile)
        XCTAssertEqual(reread.pending, waiting)
        XCTAssertEqual(reread.failure, .deliveryUnknown)
        reread.accepted(waiting.requestID)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: replyFile))["version"], .integer(1))
    }

    /// A thread keeps its root and the message replied to apart and reads on its own cursor; Send fixes
    /// its target before uploads end and a retry keeps it; a count is a number only while every reply
    /// can be counted; and a read that answers late or for another account changes nothing it should not.
    func testReplyThreadsKeepTheirTargetCursorAndFreshnessApartFromTheRoom() async throws {
        let (folder, original) = try chosenFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        func message(_ id: String, _ author: PersonalAgentMessage.Author, parent: String? = nil, root: String? = nil,
                     text: String? = nil, deleted: Bool = false) -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: id, author: author, text: deleted ? "" : text ?? id, createdAt: nil,
                                             isDeleted: deleted, attachments: [])
            value.replyToMessageID = parent
            value.replyRootMessageID = root
            return value
        }
        let room = [message("q", .agent), message("a1", .person, parent: "q", root: "q"), message("x", .agent),
                    message("a2", .agent, parent: "a1")]
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], losesFirstSend: true)
        await reader.setRoom(room, before: "room-cursor")
        await reader.setThread(["": .init(messages: [room[3]], before: "c1"), "c1": .init(messages: [room[1]], before: nil)])
        await center.connect(sourceKey: "account") { reader }
        let state = try XCTUnwrap(center.conversation)
        // Every reply to q is in the room's window, read through to the latest message: a number, shown
        // because they do not all follow it. a2 follows another thread's message, so it quotes a1.
        XCTAssertEqual(state.replies.indicators["q"], .some(2))
        XCTAssertFalse(state.replies.indicators.keys.contains("x"), "A message without replies shows none")
        XCTAssertEqual(state.replies.quoted, ["a2"])
        XCTAssertEqual(state.replies.quote(for: room[3]), .text("a1"))

        // Replying to a reply opens its thread's root, replying to the reply itself.
        center.openReplies(to: "a2")
        XCTAssertEqual(state.replies.focus, .init(rootID: "q", targetID: "a2"))
        let thread = try XCTUnwrap(state.replies.threads["q"])
        XCTAssertEqual(thread.messages.map(\.id), ["q", "a1", "a2"], "The thread shows what is read before its pages arrive")
        try await waitUntil { thread.cursor == .before("c1") }
        await center.loadOlderReplies()
        XCTAssertEqual(thread.cursor, .end, "A thread page without a cursor ends the thread, with no fallback")
        await center.loadOlderReplies()
        var reads = await reader.replyReads
        XCTAssertEqual(reads, ["", "c1"], "An ended thread reads nothing more")
        XCTAssertEqual(state.before, "room-cursor", "The room keeps its own cursor")

        // Reading the thread again reaches back to its earliest reply read, so a change to it is seen.
        await reader.setThread(["": .init(messages: [room[3]], before: "c1"),
                                "c1": .init(messages: [message("a1", .person, parent: "q", root: "q", text: "a1 edited")], before: nil)])
        center.openReplies(to: "q")
        await center.refreshFocusedReplies()
        XCTAssertEqual(state.replies.message("a1")?.text, "a1 edited")
        XCTAssertEqual(state.visibleMessages.first { $0.id == "a1" }?.text, "a1 edited", "The room shows the same read")
        XCTAssertEqual(thread.cursor, .end)
        // A cursor that comes back before the earliest reply is read once and ends the read unfinished;
        // so does a page that fails. Either keeps what is shown and says so.
        await reader.setThread(["": .init(messages: [room[3]], before: "loop"), "loop": .init(messages: [room[3]], before: "loop")])
        await center.refreshFocusedReplies()
        reads = await reader.replyReads
        XCTAssertEqual(Array(reads.suffix(4)), ["", "c1", "", "loop"])
        XCTAssertEqual(thread.latestFailure, .invalidResponse)
        XCTAssertEqual(state.replies.message("a1")?.text, "a1 edited")
        await reader.setThread(["": .init(messages: [room[3]], before: "gone")])
        await center.refreshFocusedReplies()
        XCTAssertEqual(thread.latestFailure, .network)
        XCTAssertEqual(state.replies.message("a1")?.text, "a1 edited", "A failed read keeps what is shown")
        await reader.setThread(["": .init(messages: [room[3]], before: "c1"),
                                "c1": .init(messages: [message("a1", .person, parent: "q", root: "q", text: "a1 edited")], before: nil)])
        await center.refreshFocusedReplies()
        XCTAssertNil(thread.latestFailure, "Trying again clears the failure")
        center.openReplies(to: "a2")

        // Send pressed while a file uploads keeps the thread's target, whatever is opened meanwhile.
        await reader.holdUploads()
        let draft = state.draft
        draft.editor.text = "Looks right."
        await center.attach([.init(url: original, declaredType: nil)], to: try XCTUnwrap(center.fileTarget()))
        try await waitUntil { await reader.hasPendingUpload() }
        let sending = Task { await center.send() }
        try await waitUntil { draft.waitsForUploads }
        center.closeReplies()
        center.openReplies(to: "x")
        await reader.releaseUpload()
        await sending.value
        var sent = await reader.sentRequests()
        XCTAssertEqual(sent.first?.replyTarget, .init(messageID: "a2", rootID: "q"))
        XCTAssertEqual(sent.first?.attachments.map(\.fileID), ["file-1"])
        XCTAssertNil(sent.first?.replyToMessageID)
        XCTAssertNil(sent.first?.optionSelection)
        XCTAssertEqual(draft.failure, .deliveryUnknown)
        XCTAssertEqual(state.replies.indicators["q"], .some(nil), "A reply of unknown delivery leaves the count unknown")
        XCTAssertEqual(state.replies.focus?.rootID, "x")
        // The retry is the same request to the same message, though another thread is open now.
        await center.send()
        sent = await reader.sentRequests()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1], sent[0])
        let uploads = await reader.uploadCount()
        XCTAssertEqual(uploads, 1)
        let reply = sent[0].requestID
        try await waitUntil { state.replies.indicators["q"] == .some(3) }
        XCTAssertEqual(thread.messages.map(\.id), ["q", "a1", "a2", reply])
        XCTAssertTrue(draft.editor.text.isEmpty)

        // A deletion the room read later stands over a thread page that answers late with the old words.
        center.openReplies(to: "q")
        await reader.setThread(["": .init(messages: [message("a1", .person, parent: "q", root: "q", text: "stale")], before: "c1")])
        await reader.holdReplies(before: "")
        let late = Task { await center.refreshFocusedReplies() }
        try await waitUntil { await reader.hasPendingReplies() }
        await reader.replaceInRoom(message("a1", .person, parent: "q", root: "q", deleted: true))
        await center.refreshConversation()
        await reader.releaseReplies()
        await late.value
        XCTAssertEqual(state.replies.message("a1")?.isDeleted, true)
        XCTAssertEqual(state.visibleMessages.first { $0.id == "a1" }?.isDeleted, true)
        XCTAssertEqual(state.replies.quote(for: room[3]), .deleted, "The parent's deletion stands over what was quoted")
        XCTAssertEqual(thread.messages.first { $0.id == "a1" }?.isDeleted, true)
        XCTAssertEqual(thread.cursor, .end, "A latest page keeps the earlier pages' cursor")
        XCTAssertEqual(state.replies.indicators["q"], .some(2), "A deleted reply is not counted")

        // Without the provider's times, the read that started later stands, whichever answers last.
        await reader.setThread(["": .init(messages: [message("a2", .agent, parent: "a1", text: "edited")], before: nil)])
        await center.refreshFocusedReplies()
        XCTAssertEqual(state.replies.message("a2")?.text, "edited", "A thread read after the room's shows its later edit")
        XCTAssertEqual(state.visibleMessages.first { $0.id == "a2" }?.text, "edited", "The room shows the thread's later read")
        await reader.setThread(["": .init(messages: [message("a2", .agent, parent: "a1", text: "older edit")], before: nil)])
        await reader.holdReplies(before: "")
        let earlier = Task { await center.refreshFocusedReplies() }
        try await waitUntil { await reader.hasPendingReplies() }
        await reader.replaceInRoom(message("a2", .agent, parent: "a1", text: "newest edit"))
        await center.refreshConversation()
        await reader.releaseReplies()
        await earlier.value
        XCTAssertEqual(state.replies.message("a2")?.text, "newest edit")
        XCTAssertEqual(state.visibleMessages.first { $0.id == "a2" }?.text, "newest edit")

        // A thread read that outlives the account shows nothing in the next one.
        await reader.holdReplies(before: "")
        let switching = Task { await center.refreshFocusedReplies() }
        try await waitUntil { await reader.hasPendingReplies() }
        let other = FixturePersonalAgentReader(agents: [fixtureAgent(account: "another")])
        await center.connect(sourceKey: "another") { other }
        await reader.releaseReplies()
        await switching.value
        XCTAssertNil(center.conversation?.replies.focus)
        XCTAssertEqual(center.conversation?.replies.threads.isEmpty, true)
        reads = await other.replyReads
        XCTAssertTrue(reads.isEmpty)
        await center.disconnect()
    }

    /// A reply read that answers after the person moved to another dot ends there and leaves the thread
    /// free to be read again on return, for earlier pages and the latest alike. A reply whose delivery
    /// was uncertain, which a thread read shows under its request, is settled without sending again.
    func testAReplyReadThatOutlivesItsDotEndsAndAnUncertainReplyTheThreadShowsIsSettled() async throws {
        let first = fixtureAgent()
        let second = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "dot-2", roomID: "room-2"),
                                   name: "Juniper", rootThreadID: nil, isPaused: false, isPrimary: false)
        let question = PersonalAgentMessage(id: "q", author: .agent, text: "Which day?", createdAt: nil, isDeleted: false, attachments: [])
        let other = PersonalAgentMessage(id: "x", author: .agent, text: "Noted.", createdAt: nil, isDeleted: false, attachments: [])
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [first, second], losesFirstSend: true)
        await reader.setRoom([question, other])
        await reader.setThread(["": .init(messages: [], before: "c1"), "c1": .init(messages: [], before: nil)])
        await center.connect(sourceKey: "account") { reader }
        let state = try XCTUnwrap(center.conversation)
        await reader.holdReplies(before: "")
        center.openReplies(to: "q")
        let thread = try XCTUnwrap(state.replies.threads["q"])
        try await waitUntil { await reader.hasPendingReplies() }
        await center.select(second.id)
        await reader.releaseReplies()
        try await waitUntil { !thread.isLoadingOlder }
        XCTAssertEqual(thread.cursor, .unread, "A page for a dot no longer shown is not kept")
        await center.select(first.id)
        XCTAssertTrue(center.conversation === state)
        await center.loadOlderReplies()
        try await waitUntil { thread.cursor == .before("c1") }

        await reader.holdReplies(before: "")
        let latest = Task { await center.refreshFocusedReplies() }
        try await waitUntil { await reader.hasPendingReplies() }
        await center.select(second.id)
        await reader.releaseReplies()
        await latest.value
        await center.select(first.id)
        let before = await reader.replyReads.count
        await center.refreshFocusedReplies()
        let after = await reader.replyReads.count
        XCTAssertGreaterThan(after, before, "The thread can be read again on return")

        // An uncertain reply that a thread read shows under its request has arrived: only its own draft
        // is let go, nothing is sent or uploaded again, and the count is worked out without it waiting.
        let draft = state.draft
        draft.editor.text = "Tuesday works."
        await center.send()
        let pending = try XCTUnwrap(draft.pending)
        XCTAssertEqual(pending.replyTarget, .init(messageID: "q", rootID: "q"))
        XCTAssertEqual(state.replies.indicators["q"], nil, "Nothing read yet answers q")
        var arrived = PersonalAgentMessage(id: "server-reply", author: .person, text: "Tuesday works.", createdAt: nil,
                                           isDeleted: false, attachments: [], requestID: pending.requestID)
        arrived.replyToMessageID = "q"
        arrived.replyRootMessageID = "q"
        await reader.setThread(["": .init(messages: [arrived], before: nil)])
        await center.refreshFocusedReplies()
        XCTAssertNil(draft.pending)
        XCTAssertNil(draft.failure)
        XCTAssertTrue(draft.editor.text.isEmpty)
        XCTAssertNil(state.optionReply.pending)
        let sent = await reader.sentRequests()
        XCTAssertEqual(sent.count, 1, "Settled by reading, not by sending again")
        let uploads = await reader.uploadCount()
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(state.replies.indicators["q"], .some(1))

        // The other order: a read shows the request while it is still being sent, and the send then
        // comes back uncertain. The draft is settled from that read, without another read or send.
        draft.editor.text = "Wednesday also works."
        await reader.holdAndLoseNextSend()
        let sending = Task { await center.send() }
        try await waitUntil { await reader.hasPendingSend() }
        let racing = try XCTUnwrap(draft.pending)
        var early = arrived
        early = PersonalAgentMessage(id: "server-reply-2", author: .person, text: racing.text, createdAt: nil,
                                     isDeleted: false, attachments: [], requestID: racing.requestID)
        early.replyToMessageID = "q"
        early.replyRootMessageID = "q"
        await reader.setThread(["": .init(messages: [arrived, early], before: nil)])
        await center.refreshFocusedReplies()
        XCTAssertEqual(draft.pending, racing, "Still being sent: nothing is settled under it")
        let readsBefore = await reader.replyReads.count
        await reader.releaseSend()
        await sending.value
        XCTAssertNil(draft.pending, "Settled from the read that already showed it")
        XCTAssertTrue(draft.editor.text.isEmpty)
        let readsAfter = await reader.replyReads.count
        XCTAssertEqual(readsAfter, readsBefore, "Settling read nothing more")
        let resent = await reader.sentRequests()
        XCTAssertEqual(resent.count, 2, "Nothing was sent again")
        XCTAssertEqual(state.replies.indicators["q"], .some(2))
        await center.disconnect()
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

    /// The room-live wire format is read as the provider's client reads it, and anything else ends
    /// the observation: before the stream names its subscription, the newest event of at most four
    /// subscriptions waits, and an event for another room is never kept for this one.
    func testRoomLiveStatesBindToTheirSubscriptionAndFailClosed() throws {
        func thread(_ fields: String = "") -> String {
            #"{"thread_id":"t","stream_state":"attached","turn_id":"turn","turn_status":"in_progress","is_active":true\#(fields)}"#
        }
        func event(_ subscription: String, _ revision: String, room: String = "room", threads: String? = nil) throws -> JSONValue {
            try value(#"{"type":"calpico-room-live","payload":{"type":"calpico-room-live-state","version":1,"room_id":"\#(room)","subscription_id":"\#(subscription)","revision":\#(revision),"threads":[\#(threads ?? thread())]}}"#)
        }
        func ready(_ subscription: String, room: String = "room") throws -> JSONValue {
            try value(#"{"type":"calpico-room-live-ready","version":1,"room_id":"\#(room)","subscription_id":"\#(subscription)"}"#)
        }
        XCTAssertNotNil(DotsLiveProtocol.event(try event("s", "0", threads: thread(#","summary":["a"],"summary_item_id":null,"activity_status":null"#))))
        for malformed in [try event("s", "-1"), try event("s", "1.5"), try event("s", "\"1\""),
                          try event("s", "1", threads: thread(#","computer_status":null"#)),
                          try event("s", "1", threads: thread(#","computer_status":"browsing""#)),
                          try event("s", "1", threads: #"{"thread_id":"t","stream_state":"attached","turn_status":"paused"}"#),
                          try event("s", "1", threads: thread(#","summary":[1]"#)),
                          try event("s", "1", threads: thread(#","activity_status":{"status_type":"Working"}"#)),
                          try event("s", "1", threads: #"{"thread_id":"t","stream_state":"detached"}"#),
                          try value(#"{"type":"calpico-room-live","payload":{"type":"calpico-room-live-error","version":1,"room_id":"room","subscription_id":"s","revision":0,"code":"gone"}}"#),
                          try value(#"{"type":"calpico-room-live","payload":{"type":"calpico-room-live-state","version":2,"room_id":"room","subscription_id":"s","revision":0,"threads":[]}}"#)] {
            XCTAssertNil(DotsLiveProtocol.event(malformed))
            var observation = PersonalAgentLiveObservation(roomID: "room")
            XCTAssertEqual(observation.receive(malformed), .ended(retry: false))
        }
        XCTAssertNil(DotsLiveProtocol.ready(try value(#"{"type":"calpico-room-live-ready","version":1,"room_id":"room"}"#)))

        // Five subscriptions before ready keep the newest four; ready takes its own and drops the rest.
        var observation = PersonalAgentLiveObservation(roomID: "room")
        for name in ["a", "b", "c", "d", "e"] { XCTAssertEqual(observation.receive(try event(name, "1")), .ignored) }
        XCTAssertEqual(observation.ready(try ready("a")), .ignored, "The oldest held subscription was let go")
        XCTAssertEqual(observation.receive(try event("b", "5")), .ignored, "Another subscription is never shown")
        guard case let .shown(first, _) = observation.receive(try event("a", "2")) else { return XCTFail("Expected a state") }
        XCTAssertEqual(first.subscriptionID, "a")
        XCTAssertEqual(observation.receive(try event("a", "2")), .ignored, "A revision is taken once")
        XCTAssertEqual(observation.receive(try event("a", "1")), .ignored)
        XCTAssertEqual(observation.ready(try ready("b")), .ended(retry: false), "A second subscription ends it")

        // Another room's event before ready ends the observation rather than wait as this room's.
        var waiting = PersonalAgentLiveObservation(roomID: "room")
        XCTAssertEqual(waiting.receive(try event("s", "1")), .ignored)
        XCTAssertEqual(waiting.receive(try event("s", "2", room: "elsewhere")), .ended(retry: false))
        var other = PersonalAgentLiveObservation(roomID: "room")
        XCTAssertEqual(other.ready(try ready("s", room: "elsewhere")), .ended(retry: false))
        var errors = PersonalAgentLiveObservation(roomID: "room")
        _ = errors.ready(try ready("s"))
        XCTAssertEqual(errors.receive(try value(#"{"type":"calpico-room-live","payload":{"type":"calpico-room-live-error","version":1,"room_id":"room","subscription_id":"s","revision":0,"code":"temporarily_unavailable"}}"#)), .ended(retry: true))

        // Using the computer lasts through the same turn's states that omit it, until its hold ends,
        // and never into another turn. A held state before ready passes it on the same way.
        var computer = PersonalAgentLiveObservation(roomID: "room")
        XCTAssertEqual(computer.receive(try event("s", "1", threads: thread(#","computer_status":"using_computer""#))), .ignored)
        XCTAssertEqual(computer.receive(try event("s", "2")), .ignored)
        guard case let .shown(held, holds) = computer.ready(try ready("s")) else { return XCTFail("Expected the held state") }
        XCTAssertEqual(held.threads.first?.computerStatus, .usingComputer)
        XCTAssertTrue(holds)
        guard case let .shown(same, renewed) = computer.receive(try event("s", "3")) else { return XCTFail("Expected a state") }
        XCTAssertEqual(same.threads.first?.computerStatus, .usingComputer)
        XCTAssertFalse(renewed, "An omitted status keeps the running hold without renewing it")
        XCTAssertNil(computer.computerHoldEnded()?.threads.first?.computerStatus)
        _ = computer.receive(try event("s", "4", threads: thread(#","computer_status":"using_computer""#)))
        guard case let .shown(next, _) = computer.receive(try event("s", "5", threads:
            #"{"thread_id":"t","stream_state":"attached","turn_id":"another","turn_status":"in_progress","is_active":true}"#))
        else { return XCTFail("Expected a state") }
        XCTAssertNil(next.threads.first?.computerStatus, "A new turn does not inherit the computer")
    }

    /// The dot's status comes from its room's attached state only. Waiting for input, a failure, a
    /// pause or a finished turn are idle; a turn under way is the working row whatever its label.
    func testADotWorksOnlyWhileItsAttachedRoomSaysSo() {
        func state(_ stream: PersonalAgentLiveThread.StreamState = .attached, turn: PersonalAgentLiveThread.TurnStatus? = .inProgress,
                   active: Bool? = true, type: String? = "Working", label: String? = "**Drafting** the plan\n") -> PersonalAgentLiveState {
            .init(roomID: "room", subscriptionID: "s", revision: 1, threads: [
                .init(threadID: "t", streamState: stream, turnID: "turn", turnStatus: turn, isActive: active,
                      computerStatus: nil, activityType: type, activityLabel: label)])
        }
        let working = PersonalAgentStatus(live: state(), isPaused: false)
        XCTAssertEqual(working.kind, .working)
        XCTAssertEqual(working.motion, .working)
        XCTAssertEqual(working.label, "Drafting the plan")
        XCTAssertEqual(PersonalAgentStatus.heading("Checking sources\n**Searching the web**\n<!-- note -->"), "Searching the web")
        for (type, kind) in [("Searching", PersonalAgentStatus.Kind.searching), ("Creating", .creating), ("Payment", .payment),
                             ("Something new", .thinking)] {
            let status = PersonalAgentStatus(live: state(type: type), isPaused: false)
            XCTAssertEqual(status.kind, kind)
            XCTAssertEqual(status.motion, .working)
        }
        XCTAssertEqual(PersonalAgentStatus(live: state(type: nil, label: nil), isPaused: false).label, L10n.string("Thinking"))
        let idle: [(PersonalAgentStatus, PersonalAgentStatus.Kind)] = [
            (PersonalAgentStatus(live: nil, isPaused: false), .none),
            (PersonalAgentStatus(live: state(.attaching), isPaused: false), .none),
            (PersonalAgentStatus(live: .init(roomID: "room", subscriptionID: "s", revision: 1, threads: []), isPaused: false), .none),
            (PersonalAgentStatus(live: state(type: "Needs input"), isPaused: false), .needsInput),
            (PersonalAgentStatus(live: state(type: "Paused"), isPaused: false), .paused),
            (PersonalAgentStatus(live: state(turn: .failed), isPaused: false), .error),
            (PersonalAgentStatus(live: state(type: "Ready"), isPaused: false), .ready),
            (PersonalAgentStatus(live: state(turn: .completed, active: false), isPaused: false), .ready),
            (PersonalAgentStatus(live: state(turn: .completed, active: false), isPaused: true), .paused),
            (PersonalAgentStatus(live: nil, isPaused: true), .paused),
            (PersonalAgentStatus(live: state(), isPaused: false, mode: .local), .none)
        ]
        for (status, kind) in idle {
            XCTAssertEqual(status.kind, kind)
            XCTAssertEqual(status.motion, .idle, "\(kind) is idle")
        }
        XCTAssertEqual(PersonalAgentStatus(live: nil, isPaused: true).label, L10n.string("Paused"))
        XCTAssertNil(PersonalAgentStatus(live: state(turn: .completed, active: false, label: "Done"), isPaused: false).label,
                     "A finished turn's words are not shown")
        // The profile's pause was read when the dots were; a turn the room shows under way since is newer.
        XCTAssertEqual(PersonalAgentStatus(live: state(), isPaused: true).kind, .working)
    }

    /// The selected room is observed only while the window shows it. A pending send is not work, a
    /// state that arrives after the window moved to another dot or account shows nothing, and leaving
    /// the section ends the observation.
    func testTheSelectedRoomIsObservedOnlyWhileShownAndLateStatesStayOut() async throws {
        let first = fixtureAgent()
        let second = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "dot-2", roomID: "room-2"),
                                   name: "Juniper", rootThreadID: nil, isPaused: true, isPrimary: false)
        let reader = FixturePersonalAgentReader(agents: [first, second])
        let center = PersonalAgentCenter()
        // The window is seen while the first conversation is still being read: the dot is observed
        // then, and once only when the reading ends.
        await reader.delayNextMessageRead()
        let connecting = Task { await center.connect(sourceKey: "a") { reader } }
        try await waitUntil { await reader.hasPendingMessageRead() }
        let requestsWhileHidden = await reader.liveRequests
        XCTAssertTrue(requestsWhileHidden.isEmpty, "A window that does not show the dots observes no room")
        center.conversation?.draft.isSending = true
        XCTAssertEqual(center.liveMotion, .idle, "A pending send is not work")
        center.setVisible(true)
        try await waitUntil { await reader.liveRequests == [first.id] }
        await reader.releaseMessageRead()
        await connecting.value
        // A second view of the same window saying so changes nothing either.
        let otherView = UUID()
        center.setVisible(true, reporter: otherView)
        try await Task.sleep(for: .milliseconds(50))
        let opened = await reader.liveRequests
        XCTAssertEqual(opened, [first.id], "Opening observes the room once, not \(opened.count) times")
        let endedOnOpening = await reader.liveEnded
        XCTAssertEqual(endedOnOpening, 0)
        await reader.pushLive(Self.working(first, label: "Drafting the plan"), to: 0)
        try await waitUntil { center.liveMotion == .working }
        XCTAssertEqual(center.liveStatus.label, "Drafting the plan")
        XCTAssertEqual(center.motion(for: second), .idle, "Only the selected room is observed")
        XCTAssertEqual(center.status(for: second).label, L10n.string("Paused"))
        var waiting = Self.working(first, label: "Waiting")
        waiting.threads[0] = .init(threadID: "t", streamState: .attached, turnID: "turn", turnStatus: .inProgress, isActive: true,
                                   computerStatus: nil, activityType: "Needs input", activityLabel: nil)
        await reader.pushLive(waiting, to: 0)
        try await waitUntil { center.liveStatus.kind == .needsInput }
        XCTAssertEqual(center.liveMotion, .idle)
        await reader.pushLive(nil, to: 0)
        try await waitUntil { center.liveStatus == .idle }

        // Another dot: the first room's observation ends, and its late state shows nothing.
        await reader.pushLive(Self.working(first, label: "Drafting"), to: 0)
        try await waitUntil { center.liveMotion == .working }
        await center.select(second.id)
        XCTAssertEqual(center.liveMotion, .idle)
        XCTAssertEqual(center.liveStatus.label, L10n.string("Paused"))
        XCTAssertTrue(center.isPaused(second))
        try await waitUntil { await reader.liveRequests == [first.id, second.id] }
        try await waitUntil { await reader.liveEnded >= 1 }
        await reader.pushLive(Self.working(first, label: "Late"), to: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(center.liveMotion, .idle)

        // A covered window ends the observation; shown again, it observes anew.
        await reader.pushLive(Self.working(second, label: "Working"), to: 1)
        try await waitUntil { center.liveMotion == .working }
        center.setVisible(false)
        XCTAssertEqual(center.liveMotion, .working, "Another view still sees the window")
        center.setVisible(false, reporter: otherView)
        XCTAssertEqual(center.liveMotion, .idle)
        try await waitUntil { await reader.liveEnded >= 2 }
        center.setVisible(true)
        try await waitUntil { await reader.liveRequests.count == 3 }

        // A dot read paused that the room has since shown at work is not paused any more when its turn
        // ends, in the header or the list, until its profile is read again.
        var finished = Self.working(second, label: "Done")
        finished.threads[0] = .init(threadID: "t", streamState: .attached, turnID: "turn", turnStatus: .completed,
                                    isActive: false, computerStatus: nil, activityType: nil, activityLabel: nil)
        await reader.pushLive(finished, to: 2)
        try await waitUntil { center.liveStatus.kind == .ready }
        XCTAssertFalse(center.isPaused(second))
        XCTAssertNil(center.liveStatus.label)
        await reader.pushLive(Self.working(second, label: "Working"), to: 2)
        try await waitUntil { center.liveMotion == .working }

        // Another account clears it, and leaving the section ends the new one's observation.
        await reader.pushLive(Self.working(second, label: "Working"), to: 2)
        try await waitUntil { center.liveMotion == .working }
        let next = FixturePersonalAgentReader(agents: [fixtureAgent(account: "other")])
        await center.connect(sourceKey: "b") { next }
        XCTAssertEqual(center.liveMotion, .idle)
        try await waitUntil { await reader.liveEnded >= 3 }
        await reader.pushLive(Self.working(second, label: "Late"), to: 2)
        try await waitUntil { await next.liveRequests.count == 1 }
        await center.disconnect()
        try await waitUntil { await next.liveEnded == 1 }
        XCTAssertEqual(center.liveMotion, .idle)

        // A login the observer finds gone ends the account's whole reading, as any read's would.
        let lost = FixturePersonalAgentReader(agents: [first])
        await center.connect(sourceKey: "c") { lost }
        try await waitUntil { await lost.liveRequests.count == 1 }
        XCTAssertNotNil(center.conversation)
        await lost.failLive(.accountChanged, at: 0)
        try await waitUntil { center.failure == .accountChanged }
        XCTAssertTrue(center.agents.isEmpty)
        XCTAssertNil(center.conversation)
        XCTAssertEqual(center.liveMotion, .idle)
        await center.disconnect()
    }

    private static func working(_ agent: PersonalAgent, label: String) -> PersonalAgentLiveState {
        .init(roomID: agent.id.roomID, subscriptionID: "s", revision: 1, threads: [
            .init(threadID: "t", streamState: .attached, turnID: "turn", turnStatus: .inProgress, isActive: true,
                  computerStatus: nil, activityType: "Working", activityLabel: label)])
    }

    /// The two kinds of pages a task's record arrives in, and what makes one not the provider's history:
    /// a turn page newest first, kept oldest first; items wrapped with their turn or bare; a wrapper of
    /// another turn, a repeated or unmoving cursor, and metadata that names another thread or carries turns.
    func testAnActivityRecordIsWholeOnlyWhenBothItsTurnsAndItemsRunOut() throws {
        XCTAssertThrowsError(try PersonalAgentActivityHistory.thread(value(#"{"thread":{"id":"other"}}"#), id: "task"))
        let thread = try PersonalAgentActivityHistory.thread(
            value(#"{"thread":{"id":"task","parentThreadId":"root","name":"Plan","turns":[{"id":"hidden","items":[]}]}}"#),
            id: "task")
        XCTAssertTrue(thread.turns.isEmpty, "The metadata never stands for the record")
        var history = PersonalAgentActivityHistory(threadID: "task")
        history.begin(thread)
        let newest = try PersonalAgentActivityHistory.turnPage(value("""
            {"data":[{"id":"t3","status":"completed","items":[],"itemsView":"notLoaded"},
                     {"id":"t2","status":"completed","items":[],"itemsView":"notLoaded"}],
             "nextCursor":"older","backwardsCursor":null}
            """))
        XCTAssertEqual(try history.apply(turns: newest, after: nil), ["t2", "t3"])
        XCTAssertEqual(history.turns.map(\.id), ["t2", "t3"])
        XCTAssertFalse(history.isComplete)
        // A turn's items: a wrapper must name its turn; a bare item is the turn's.
        XCTAssertThrowsError(try PersonalAgentActivityHistory.itemPage(
            value(#"{"data":[{"turnId":"t2","item":{"id":"i1","type":"agentMessage","text":"x"}}],"nextCursor":null,"backwardsCursor":null}"#),
            turnID: "t3"))
        // A page must name both its cursors, as strings or null: one it leaves out is not its end.
        for page in [#"{"data":[],"nextCursor":3,"backwardsCursor":null}"#, #"{"data":[],"backwardsCursor":null}"#,
                     #"{"data":[],"nextCursor":null}"#] {
            XCTAssertThrowsError(try PersonalAgentActivityHistory.turnPage(value(page)), page)
            XCTAssertThrowsError(try PersonalAgentActivityHistory.itemPage(value(page), turnID: "t3"), page)
        }
        let first = try PersonalAgentActivityHistory.itemPage(value("""
            {"data":[{"turnId":"t3","item":{"id":"u","type":"userMessage","content":[{"type":"text","text":"Plan it"}]}},
                     {"id":"a","type":"agentMessage","text":"Working on it."}],
             "nextCursor":"i-next","backwardsCursor":null}
            """), turnID: "t3")
        try history.apply(items: first, of: "t3", after: nil)
        XCTAssertEqual(history.turns.last?.items.map(\.id), ["u", "a"])
        XCTAssertEqual(history.itemsToRead(of: "t3").cursor, "i-next")
        // The same cursor again is not a next page; the record keeps what it read.
        XCTAssertThrowsError(try history.apply(items: CodexItemPage(entries: first.entries, nextCursor: "i-next",
                                                                    backwardsCursor: nil), of: "t3", after: "i-next"))
        let last = try PersonalAgentActivityHistory.itemPage(value("""
            {"data":[{"turnId":"t3","item":{"id":"done","type":"agentMessage","text":"Done.","phase":"final_answer"}},
                     {"turnId":"t3","item":{"id":"shot","type":"imageView","path":"/mnt/data/screen.png"}},
                     {"turnId":"t3","item":{"id":"widget","type":"realtimeSegment"}}],
             "nextCursor":null,"backwardsCursor":null}
            """), turnID: "t3")
        try history.apply(items: last, of: "t3", after: "i-next")
        XCTAssertNil(history.turns.last?.itemsNextCursor)
        // A path on the provider's computer is never read on this Mac; an item Yardlet cannot draw stays, named.
        let kinds = history.turns.last!.items.map(\.content)
        XCTAssertTrue(kinds.contains(.unknown(type: "imageView", raw: last.entries[1].item.raw)))
        XCTAssertTrue(kinds.contains { if case let .unknown(type, _) = $0, type == "realtimeSegment" { true } else { false } })
        let fileImage = PersonalAgentActivityHistory.readOnly(CodexTaskDecoder().item(from: try value("""
            {"id":"m","type":"userMessage","content":[{"type":"image","url":"file:///Users/example/photo.png"}]}
            """), fallbackID: "m", lifecycle: .historical))
        XCTAssertEqual(fileImage.content, .unknown(type: "userMessage", raw: fileImage.raw))
        for (link, opens) in [("https://example.com/report", true), ("file:///mnt/data/report.pdf", false),
                              ("/mnt/data/report.pdf", false), ("vscode://file/tmp/a", false)] {
            XCTAssertEqual(PersonalAgentActivityHistory.opensLink(URL(string: link)!), opens, link)
        }
        history.itemFailures["t2"] = .network
        XCTAssertTrue(history.isPartial)
        try history.apply(items: .init(entries: [], nextCursor: nil, backwardsCursor: nil), of: "t2", after: nil)
        XCTAssertFalse(history.isPartial)
        XCTAssertFalse(history.isComplete, "Earlier turns are still to be read")
        // An earlier page that adds nothing but names more is not the provider's history.
        XCTAssertThrowsError(try history.apply(turns: .init(turns: newest.turns, nextCursor: "oldest", backwardsCursor: nil),
                                               after: "older"))
        // Items a turn page carries are not the turn's: only its item pages are.
        let earlier = try PersonalAgentActivityHistory.turnPage(value(
            #"{"data":[{"id":"t1","status":"failed","items":[{"id":"x","type":"imageView","path":"/mnt/data/a.png"}]}],"nextCursor":null,"backwardsCursor":null}"#))
        XCTAssertEqual(earlier.turns.first?.items, [])
        XCTAssertEqual(try history.apply(turns: earlier, after: "older"), ["t1"])
        XCTAssertEqual(history.turns.map(\.id), ["t1", "t2", "t3"])
        try history.apply(items: .init(entries: [], nextCursor: nil, backwardsCursor: nil), of: "t1", after: nil)
        XCTAssertTrue(history.isComplete)
    }

    /// Opening a task of the dot's Activity reads its metadata, its newest turns and their first items,
    /// and nothing else: no message, send or other thread. Only a listed task opens; another dot, a
    /// closed task or a new connection drops a read that comes back late.
    /// What becomes an output, by the provider's rules: a citation or a file link a completed turn's
    /// answer presents, not one it names as a source or puts in code; a picture saved on the dot's
    /// computer, not one known only by its file ID; a connector's resources it says it created or
    /// updated, and nothing guessed when that metadata does not read; the ready files and links a dot
    /// sends, not a person's. The same path on two computers is two files, and a picture stands over
    /// the plain file at its place.
    func testOutputsAreWhatTheDotAndItsTasksPresented() throws {
        func item(_ raw: [String: JSONValue]) -> CodexItemState {
            let id = raw["id"]?.stringValue ?? "item"
            return CodexTaskDecoder().item(from: .object(raw), fallbackID: id, lifecycle: .historical)
        }
        func turn(_ id: String, status: String = "completed") -> CodexTurnState {
            CodexTaskDecoder().turn(from: .object(["id": .string(id), "status": .string(status), "completedAt": .integer(1_800_000_000)]),
                                    fallbackID: id)!
        }
        let answer = """
        Here is :codex-file-citation{path="/mnt/data/report.pdf" purpose="output"} and :codex-file-citation{path="/mnt/data/input.csv" purpose="source"}.
        See [the chart](charts/sales.png), [notes](sandbox:/mnt/data/notes.md), [site](https://example.com) and ![shot](/mnt/data/shot.png).
        The [input](/mnt/data/input.csv) is where the numbers came from.
        Shared as :codex-file-citation{path="https://docs.google.com/document/d/abc/edit" title="Plan doc"},         :codex-file-citation{path="https://example.com/notes" purpose="source"},         :codex-file-citation{path="/pages/brief" page_id="page_1"} and         :codex-file-citation{path="/mnt/data/deck.pptx" mode="live" artifact_kind="presentation"}.
        `:codex-file-citation{path="/mnt/data/inline.txt"}`
        ```
        [code](/mnt/data/code.txt)
        ```
        <div>
        :codex-file-citation{path="/mnt/data/example.pdf" purpose="output"}
        </div>

        <script>
        [run](/mnt/data/run.js)
        </script>
        Written by <b>the dot</b>.
        """
        let resources: (JSONValue) -> CodexItemState = { meta in
            item(["id": .string("mcp"), "type": .string("mcpToolCall"), "status": .string("completed"), "error": .null,
                  "server": .string("drive"), "tool": .string("create"),
                  "result": .object(["content": .array([.object(["type": .string("text"), "text": .string("https://guess.example")])]),
                                     "_meta": .object(["openai/resourceActivities": meta])])])
        }
        let valid: JSONValue = .object(["version": .integer(1), "resources": .array([
            .object(["id": .string("made"), "url": .string("https://docs.example.com/d/1"), "title": .string("Plan"),
                     "activities": .array([.string("created")])]),
            .object(["id": .string("seen"), "url": .string("https://docs.example.com/d/2"), "activities": .array([.string("read")])])
        ])])
        let items = [
            item(["id": .string("a"), "type": .string("agentMessage"), "phase": .string("final_answer"), "text": .string(answer)]),
            item(["id": .string("c"), "type": .string("agentMessage"), "phase": .string("commentary"),
                  "text": .string(":codex-file-citation{path=\"/mnt/data/draft.txt\"}")]),
            item(["id": .string("img"), "type": .string("imageGeneration"), "status": .string("completed"), "failure": .null,
                  "result": .string(""), "savedPath": .string("/mnt/data/report.pdf")]),
            item(["id": .string("fid"), "type": .string("imageGeneration"), "status": .string("completed"), "fileId": .string("file_1"),
                  "result": .string("")]),
            item(["id": .string("drawn"), "type": .string("imageGeneration"), "status": .string("completed"), "failure": .null,
                  "result": .string("/mnt/data/drawn.png")]),
            item(["id": .string("pixels"), "type": .string("imageGeneration"), "status": .string("completed"),
                  "result": .string("/9j/4AAQSkZJRgABAQ/AAAAAAAD")]),
            resources(valid),
            item(["id": .string("bad"), "type": .string("mcpToolCall"), "status": .string("completed"),
                  "result": .object(["_meta": .object(["openai/resourceActivities": .object(["version": .integer(1),
                    "resources": .array([.object(["id": .string("x"), "url": .string("https://user:pw@docs.example.com"),
                                                  "activities": .array([.string("created")])])])])])])])
        ]
        let found = PersonalAgentOutputScan.outputs(of: turn("t1"), items: items, threadID: "root",
                                                    environment: .computer(id: "env", cwd: "/workspace"))
        XCTAssertEqual(found.map(\.title), ["report.pdf", "the chart", "notes", "Plan doc", "report.pdf", "drawn.png", "Plan"],
                       "A source, its link, code, HTML blocks, a file ID and picture data are no outputs")
        let paths = found.compactMap { if case let .remoteFile(file, _) = $0.kind { file.path } else { nil } }
        XCTAssertEqual(paths, ["/mnt/data/report.pdf", "/workspace/charts/sales.png", "/mnt/data/notes.md", "/mnt/data/report.pdf",
                               "/mnt/data/drawn.png"])
        XCTAssertTrue(found.allSatisfy { if case let .remoteFile(file, _) = $0.kind { file.environmentID == "env" } else { true } })
        // A web document cited as output is a link; a cited source, a provider Page by its ID and a live
        // document are neither a file nor a link.
        XCTAssertEqual(found.compactMap { if case let .link(url) = $0.kind { url.absoluteString } else { nil } },
                       ["https://docs.google.com/document/d/abc/edit", "https://docs.example.com/d/1"])
        XCTAssertTrue(PersonalAgentOutputScan.outputs(of: turn("t2", status: "inProgress"), items: [items[0]], threadID: "root",
                                                      environment: .unavailable).isEmpty, "An answer counts once its turn completed")
        XCTAssertTrue(PersonalAgentOutputScan.outputs(of: turn("t3"), items: [items[0]], threadID: "root", environment: .unavailable)
            .allSatisfy { if case let .remoteFile(file, _) = $0.kind { file.path.hasPrefix("/mnt/") } else { true } },
                      "A relative path waits for a known working folder")

        // The same place on another computer is another file; a picture stands over the plain file.
        let outputs = PersonalAgentOutputs(roomID: "room")
        _ = outputs
        let elsewhere = PersonalAgentOutputScan.outputs(of: turn("t1"), items: [items[0]], threadID: "other",
                                                        environment: .computer(id: "env-2", cwd: nil))
        XCTAssertNotEqual(elsewhere.first?.id, found.first?.id)
        XCTAssertEqual(found[0].id, found[4].id)
        // A turn that says only when it started gives its outputs no time.
        let started = try XCTUnwrap(CodexTaskDecoder().turn(from: .object(["id": .string("t4"), "status": .string("completed"),
                                                                           "startedAt": .integer(1_800_000_000)]), fallbackID: "t4"))
        let undated = PersonalAgentOutputScan.outputs(of: started, items: [items[0]], threadID: "root",
                                                      environment: .computer(id: "env", cwd: "/workspace"))
        XCTAssertFalse(undated.isEmpty)
        XCTAssertTrue(undated.allSatisfy { $0.producedAt == nil })

        // Environments: the first; a managed one with one connected computer; an empty list is none,
        // and only a list never given leaves it to the parent.
        XCTAssertEqual(PersonalAgentOutputEnvironment(thread: .object(["environments": .array([])])), .unavailable)
        XCTAssertEqual(PersonalAgentOutputEnvironment(thread: .object([:])), .parents)
        XCTAssertEqual(PersonalAgentOutputEnvironment(thread: .object([
            "environments": .array([.object(["environmentId": .string("managed")])]),
            "connectedEnvironmentIds": .array([.string("a"), .string("b")])])), .unavailable)
        XCTAssertEqual(PersonalAgentOutputEnvironment.parent(of: .object(["source": .string("subAgent")])), nil)

        // A dot's ready file and links; a person's upload and a file still being made are not.
        let file = PersonalAgentAttachment(fileID: "f1", name: "deck.key", type: "file")
        let making = PersonalAgentAttachment(fileID: "f2", name: "draft.key", type: "file", isLoading: true)
        let sent = PersonalAgentMessage(id: "m1", author: .agent, text: "Read [the brief](https://example.com/brief/#top).",
                                        createdAt: Date(timeIntervalSince1970: 10), isDeleted: false, attachments: [file, making])
        let upload = PersonalAgentMessage(id: "m2", author: .person, text: "[mine](https://example.com/mine)",
                                          createdAt: Date(timeIntervalSince1970: 20), isDeleted: false, attachments: [file])
        XCTAssertEqual(PersonalAgentOutputScan.outputs(of: sent, roomID: "room").map(\.title), ["deck.key", "the brief"])

        // A link the dot attached is its own output, once with the same page its words link; only a
        // public HTTPS link with a title, no signature or token and no thread it points into is one.
        func link(_ fields: [String: JSONValue]) -> PersonalAgentAttachment? {
            PersonalAgentAttachment.publicLink(.object(fields.merging(["type": .string("link")]) { $1 }))
        }
        let brief = try XCTUnwrap(link(["url": .string("https://example.com/brief/"), "title": .string("Brief")]))
        for refused: [String: JSONValue] in [
            ["url": .string("http://example.com/brief"), "title": .string("Brief")],
            ["url": .string("https://example.com/brief"), "title": .string("  ")],
            ["url": .string("https://example.com/file?X-Amz-Signature=1"), "title": .string("File")],
            ["url": .string("https://example.com/file?sig=1"), "title": .string("File")],
            ["url": .string("https://example.com/brief"), "title": .string("Brief"), "conversation_id": .string("thread")]
        ] { XCTAssertNil(link(refused), "\(refused)") }
        let linked = PersonalAgentMessage(id: "m3", author: .agent, text: "See [the brief](https://example.com/brief).",
                                          createdAt: nil, isDeleted: false, attachments: [brief])
        XCTAssertEqual(PersonalAgentOutputScan.outputs(of: linked, roomID: "room").map(\.title), ["Brief"])
        let room: JSONValue = .object(["id": .string("room"), "aeon_id": .string("dot"), "members": .array([])])
        let projected = try DotsProjection.messages(.object(["items": .array([.object(["id": .string("m"), "content": .object([
            "text": .string("Ready."), "attachments": .array([.object(["type": .string("link"), "url": .string("https://example.com/r"),
                                                                      "title": .string("Report")])])])])])]),
            room: room, agent: fixtureAgent())
        XCTAssertEqual(projected.messages.first?.attachments.first?.url, URL(string: "https://example.com/r"))
        XCTAssertFalse(projected.messages.first?.attachments.first?.opensHere ?? true, "A link is never a file to download")
        XCTAssertTrue(PersonalAgentOutputScan.outputs(of: upload, roomID: "room").isEmpty)

        // The dot's computer's own addresses are not this Mac's.
        for raw in ["http://localhost:3000", "http://127.0.0.1/x", "http://[::1]:8080", "http://app.localhost", "http://0.0.0.0"] {
            XCTAssertTrue(PersonalAgentOutputScan.namesItsOwnComputer(try XCTUnwrap(URL(string: raw))), raw)
        }
        XCTAssertFalse(PersonalAgentOutputScan.namesItsOwnComputer(try XCTUnwrap(URL(string: "https://example.com"))))
    }

    /// A deleted message's outputs are gone for good: a later page that still has its old copy, or an
    /// older read of a message since changed, never brings them back. A page that leaves a message out
    /// does not delete it.
    @MainActor
    func testOutputsOfADeletedMessageDoNotComeBack() {
        let outputs = PersonalAgentOutputs(roomID: "room")
        let file = PersonalAgentAttachment(fileID: "f1", name: "deck.key", type: "file")
        func message(_ id: String, deleted: Bool = false, at seconds: TimeInterval, files: [PersonalAgentAttachment]) -> PersonalAgentMessage {
            var message = PersonalAgentMessage(id: id, author: .agent, text: "", createdAt: Date(timeIntervalSince1970: 1),
                                               isDeleted: deleted, attachments: files)
            message.updatedAt = Date(timeIntervalSince1970: seconds)
            return message
        }
        outputs.noteRoom([message("m1", at: 1, files: [file]), message("m2", at: 1, files: [.init(fileID: "f2", name: "b.txt", type: "file")])])
        XCTAssertEqual(outputs.items.count, 2)
        outputs.noteRoom([message("m2", at: 2, files: [])])
        XCTAssertEqual(outputs.items.map(\.title), ["deck.key"], "A changed message keeps only what it has now")
        outputs.noteRoom([message("m2", at: 1, files: [.init(fileID: "f2", name: "b.txt", type: "file")])])
        XCTAssertEqual(outputs.items.map(\.title), ["deck.key"], "An older read changes nothing")
        outputs.noteRoom([message("m1", deleted: true, at: 3, files: [])])
        outputs.noteRoom([message("m1", at: 4, files: [file])])
        XCTAssertTrue(outputs.items.isEmpty, "A deletion stands")
        outputs.noteRoom([])
        XCTAssertTrue(outputs.items.isEmpty)
    }

    /// The Outputs read the dot's threads a page at a time when first shown: the root and bound threads,
    /// and children only once verified. A part that fails says so and is read again by Try again; more
    /// work and earlier messages are read only when the person looks further back, from their own
    /// cursors, without moving the conversation; a changed connection drops a late page.
    func testOutputsReadTheDotsWorkAPartAtATime() async throws {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()])
        let turn: (String) -> CodexTurnState = {
            CodexTaskDecoder().turn(from: .object(["id": .string($0), "status": .string("completed")]), fallbackID: $0)!
        }
        func entry(_ turnID: String, _ raw: [String: JSONValue]) -> CodexItemPageEntry {
            .init(turnID: turnID, item: CodexTaskDecoder().item(from: .object(raw), fallbackID: raw["id"]!.stringValue!, lifecycle: .historical))
        }
        await reader.setOutputs(
            scope: ["root", "bound", "listed"],
            metadata: ["root": .object(["id": .string("root"), "environments": .array([.object(["environmentId": .string("env"),
                                                                                                "cwd": .string("/w")])])]),
                       "child": .object(["id": .string("child"), "parentThreadId": .string("root")]),
                       "listed": .object(["id": .string("listed"), "source": .object(["subAgent": .object([
                           "thread_spawn": .object(["parent_thread_id": .string("root")])])])]),
                       "stray": .object(["id": .string("stray"), "parentThreadId": .string("elsewhere")])],
            turns: ["root:": .init(turns: [turn("r1")], nextCursor: "older", backwardsCursor: nil),
                    "root:older": .init(turns: [turn("r0")], nextCursor: nil, backwardsCursor: nil),
                    "child:": .init(turns: [turn("c1")], nextCursor: nil, backwardsCursor: nil),
                    "listed:": .init(turns: [turn("l1")], nextCursor: nil, backwardsCursor: nil)],
            items: ["root:r1:": .init(entries: [entry("r1", ["id": .string("a"), "type": .string("agentMessage"),
                                                              "text": .string(":codex-file-citation{path=\"/w/report.pdf\"}")])],
                                      nextCursor: "p2", backwardsCursor: nil),
                    "root:r1:p2": .init(entries: [entry("r1", ["id": .string("s"), "type": .string("collabAgentToolCall"),
                                                                "tool": .string("spawnAgent"),
                                                                "receiverThreadIds": .array([.string("child"), .string("stray"), .string("denied")])])],
                                        nextCursor: nil, backwardsCursor: nil),
                    "root:r0:": .init(entries: [entry("r0", ["id": .string("b"), "type": .string("agentMessage"),
                                                              "text": .string("[old](/w/old.txt)")])], nextCursor: nil, backwardsCursor: nil),
                    "listed:l1:": .init(entries: [entry("l1", ["id": .string("l"), "type": .string("agentMessage"),
                                                                "text": .string("[listed](notes/listed.txt)")])],
                                        nextCursor: nil, backwardsCursor: nil),
                    "child:c1:": .init(entries: [entry("c1", ["id": .string("i"), "type": .string("imageGeneration"),
                                                               "status": .string("completed"), "savedPath": .string("/w/chart.png")])],
                                       nextCursor: nil, backwardsCursor: nil)])
        await reader.failOutputs("turns:bound:", with: .unavailable)
        // A child whose metadata cannot be read is missing, not ruled out.
        await reader.failOutputs("child:denied", with: .accessDenied)
        await reader.setRoom([.init(id: "m1", author: .agent, text: "", createdAt: nil, isDeleted: false,
                                    attachments: [.init(fileID: "f1", name: "deck.key", type: "file")])], before: "m1")
        await center.connect(sourceKey: "home") { reader }
        let outputs = try XCTUnwrap(center.details?.outputs)
        try await waitUntil { center.conversation?.loaded == true }
        XCTAssertEqual(outputs.items.map(\.title), ["deck.key"], "The conversation's page feeds the Outputs before any task is read")
        let readsBefore = await reader.outputReads
        XCTAssertTrue(readsBefore.isEmpty, "Nothing is read until the Outputs are shown")

        center.startOutputs()
        try await waitUntil { !outputs.isReading && outputs.scope == .loaded }
        XCTAssertEqual(Set(outputs.items.map(\.title)), ["deck.key", "report.pdf", "chart.png", "listed"])
        XCTAssertTrue(outputs.hasEarlier)
        XCTAssertEqual(outputs.checkedTasks, 3)
        // A bound thread that is also the root's child works on the root's computer, in its folder.
        let listed = try XCTUnwrap(outputs.items.first { $0.title == "listed" })
        guard case let .remoteFile(listedFile, false) = listed.kind else { return XCTFail("A file on the dot's computer") }
        XCTAssertEqual(listedFile.environmentID, "env")
        XCTAssertEqual(listedFile.path, "/w/notes/listed.txt")
        XCTAssertNotNil(outputs.failure)
        let image = try XCTUnwrap(outputs.items.first { $0.title == "chart.png" })
        guard case let .remoteFile(file, true) = image.kind else { return XCTFail("A picture on the dot's computer") }
        XCTAssertEqual(file.environmentID, "env", "A child naming no computer works on its verified parent's")
        var reads = await reader.outputReads
        XCTAssertFalse(reads.contains { $0.hasPrefix("turns:stray") }, "A child naming another parent is not read")
        XCTAssertFalse(reads.contains("turns:root:older"), "Earlier work waits for the person")
        XCTAssertFalse(reads.contains { $0.hasPrefix("thread:child") })

        let anchor = center.conversation?.anchor
        await reader.failOutputs("turns:bound:", with: nil)
        await reader.failOutputs("child:denied", with: nil)
        center.retryOutputs()
        try await waitUntil { !outputs.isReading }
        reads = await reader.outputReads
        XCTAssertEqual(reads.filter { $0 == "turns:bound:" }.count, 2)
        XCTAssertEqual(reads.filter { $0 == "child:denied" }.count, 2, "Try again reads the child that could not be read")
        XCTAssertEqual(reads.filter { $0 == "child:stray" }.count, 1, "A child of another parent is not read again")
        XCTAssertNil(outputs.failure)
        // An earlier page of messages that fails is read again by Try again.
        await reader.failNextOlderRead()
        center.readEarlierOutputs()
        try await waitUntil { !outputs.isReading }
        XCTAssertTrue(outputs.items.contains { $0.title == "old" })
        XCTAssertEqual(outputs.failure, .network)
        center.retryOutputs()
        try await waitUntil { !outputs.isReading }
        let olderReads = await reader.olderMessageReads
        XCTAssertEqual(olderReads, 2)
        XCTAssertNil(outputs.failure)
        XCTAssertEqual(center.conversation?.anchor, anchor, "Looking further back does not move the conversation")
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m1"])

        // A page that arrives after the connection changed shows nothing.
        let next = FixturePersonalAgentReader(agents: [fixtureAgent()])
        await next.setOutputs(scope: ["root"], metadata: [:], turns: [:], items: [:])
        await next.holdOutputs("threads")
        await center.connect(sourceKey: "home") { next }
        let fresh = try XCTUnwrap(center.details?.outputs)
        center.startOutputs()
        try await waitUntil { await next.hasPendingOutputs() }
        await center.disconnect()
        await next.releaseOutputs()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotEqual(fresh.scope, .loaded)
        XCTAssertFalse(fresh.items.contains { $0.title == "report.pdf" })
    }

    func testAnActivityTaskOpensOnlyFromItsDotAndDropsLateReads() async throws {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()])
        let task = PersonalAgentActivity(id: "task", title: "Prepare the plan", status: .completed, outcome: .succeeded,
                                         updatedAt: nil, preview: nil)
        await reader.setActivity(["": .init(items: [task], cursor: nil)])
        let turn: (String) -> CodexTurnState = { CodexTaskDecoder().turn(from: .object(["id": .string($0)]), fallbackID: $0)! }
        let item: (String) -> CodexItemPageEntry = { id in
            .init(turnID: "t2", item: CodexTaskDecoder().item(from: .object(["id": .string(id), "type": .string("agentMessage"),
                                                                              "text": .string("Step \(id)")]),
                                                              fallbackID: id, lifecycle: .historical))
        }
        await reader.setHistory(turns: ["": .init(turns: [turn("t1"), turn("t2")], nextCursor: "older", backwardsCursor: nil),
                                        "older": .init(turns: [turn("t0")], nextCursor: nil, backwardsCursor: nil)],
                                items: ["t2:": .init(entries: [item("a")], nextCursor: "more", backwardsCursor: nil),
                                        "t2:more": .init(entries: [item("b")], nextCursor: nil, backwardsCursor: nil)])
        await reader.failHistory("items:t1:", with: .tooLarge)
        await center.connect(sourceKey: "home") { reader }
        try await waitUntil { center.details?.activity.value?.isEmpty == false }
        let readsBefore = await reader.historyReads
        center.openActivity("another-thread")
        XCTAssertNil(center.activityReading, "Only a task the dot's Activity lists opens")
        center.openActivity("task")
        let reading = try XCTUnwrap(center.activityReading)
        try await waitUntil {
            reading.history.phase == .loaded && reading.history.loadingItems.isEmpty
                && !reading.history.unreadTurns.contains("t2") && reading.history.itemFailures["t1"] != nil
        }
        XCTAssertTrue(readsBefore.isEmpty)
        let opened = await reader.historyReads
        XCTAssertEqual(Set(opened), ["thread:task", "turns:", "items:t2:", "items:t1:"])
        XCTAssertEqual(reading.history.phase, .loaded)
        XCTAssertTrue(reading.history.isPartial, "A turn whose items failed says so")
        XCTAssertEqual(reading.history.itemFailures["t1"], .tooLarge)
        XCTAssertTrue(reading.history.hasEarlierTurns)
        // More of a turn, then the turns before, each only when asked.
        center.loadActivityItems(of: "t2")
        try await waitUntil { reading.history.turns.last?.items.map(\.id) == ["a", "b"] }
        await reader.failHistory("items:t1:", with: nil)
        center.retryActivityItems()
        try await waitUntil { !reading.history.isPartial && reading.history.loadingItems.isEmpty }
        // A page that is not the provider's history keeps what was read and its way to the earlier turns.
        await reader.failHistory("turns:older", with: .invalidResponse)
        center.loadEarlierActivityTurns()
        try await waitUntil { reading.history.earlierTurnsFailure == .invalidResponse }
        XCTAssertEqual(reading.history.turns.map(\.id), ["t1", "t2"])
        XCTAssertTrue(reading.history.hasEarlierTurns)
        XCTAssertFalse(reading.history.isComplete)
        await reader.failHistory("turns:older", with: nil)
        center.loadEarlierActivityTurns()
        try await waitUntil { reading.history.turns.map(\.id) == ["t0", "t1", "t2"] && reading.history.loadingItems.isEmpty }
        XCTAssertNil(reading.history.earlierTurnsFailure)
        XCTAssertTrue(reading.history.isComplete)
        let sends = await reader.sentRequests()
        XCTAssertTrue(sends.isEmpty)

        // A read still out when the task closes changes nothing.
        center.openActivity("task")
        XCTAssertTrue(center.activityReading === reading, "Opening the open task again reads nothing new")
        await reader.holdHistory("turns:")
        center.reloadActivity()
        try await waitUntil { await reader.hasPendingHistory() }
        center.closeActivity()
        await reader.releaseHistory()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(center.activityReading)
        XCTAssertEqual(reading.history.phase, .loading)
        XCTAssertTrue(reading.history.turns.isEmpty)
        // Nor when a new connection closes it.
        center.openActivity("task")
        let reopened = try XCTUnwrap(center.activityReading)
        await reader.holdHistory("turns:")
        center.reloadActivity()
        try await waitUntil { await reader.hasPendingHistory() }
        await center.connect(sourceKey: "home") { reader }
        XCTAssertNil(center.activityReading)
        await reader.releaseHistory()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reopened.history.phase, .loading)
        XCTAssertNil(center.activityReading)

        // A task the provider no longer has is not an empty one.
        try await waitUntil { center.details?.activity.value?.isEmpty == false }
        await reader.failHistory("thread:task", with: .missing)
        center.openActivity("task")
        try await waitUntil { center.activityReading?.history.phase == .missing }
        await center.disconnect()
        XCTAssertNil(center.activityReading)
    }

    /// An upload under way when an Activity task opens finishes in the draft it was added to while the
    /// task is read, and coming back finds that draft with the same file and its provider file ID,
    /// nothing sent and the words as they were.
    func testAnUploadUnderWayFinishesInItsDraftWhileAnActivityTaskIsRead() async throws {
        let (folder, original) = try chosenFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()])
        await reader.setActivity(["": .init(items: [.init(id: "task", title: "Prepare the plan", status: .completed,
                                                         outcome: .succeeded, updatedAt: nil, preview: nil)], cursor: nil)])
        await reader.holdUploads()
        await center.connect(sourceKey: "account") { reader }
        try await waitUntil { center.details?.activity.value?.isEmpty == false }
        let draft = try XCTUnwrap(center.conversation?.draft)
        draft.editor.text = "The plan, with the photo"
        await center.attach([.init(url: original, declaredType: nil)], to: try XCTUnwrap(center.fileTarget()))
        let file = try XCTUnwrap(draft.files.first)
        try await waitUntil { await reader.hasPendingUpload() }
        center.openActivity("task")
        XCTAssertNotNil(center.activityReading)
        await reader.releaseUpload()
        try await waitUntil { draft.files.first?.uploaded != nil }
        XCTAssertNotNil(center.activityReading, "The task is still open while the upload finishes")
        center.closeActivity()
        XCTAssertTrue(center.conversation?.draft === draft)
        XCTAssertEqual(draft.files.map(\.id), [file.id])
        XCTAssertEqual(draft.files.first?.uploaded?.fileID, "file-1")
        XCTAssertEqual(draft.editor.text, "The plan, with the photo")
        let sends = await reader.sentRequests()
        XCTAssertTrue(sends.isEmpty)
        let uploads = await reader.uploadCount()
        XCTAssertEqual(uploads, 1)
        await center.disconnect()
    }

    /// Bringing in earlier turns of a long record projects only the turns that arrived.
    func testEarlierTurnsOfALongActivityRecordProjectOnlyWhatArrived() throws {
        var history = PersonalAgentActivityHistory(threadID: "task")
        history.begin(try PersonalAgentActivityHistory.thread(.object(["thread": .object(["id": .string("task")])]), id: "task"))
        let decoder = CodexTaskDecoder()
        let turns = (0..<2_000).map { index in
            decoder.turn(from: .object(["id": .string("t\(index)"), "status": .string("completed"), "items": .array([
                .object(["id": .string("u\(index)"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                .object(["id": .string("a\(index)"), "type": .string("agentMessage"), "text": .string("Answer \(index)")])
            ])]), fallbackID: "")!
        }
        try history.apply(turns: .init(turns: Array(turns[5...]), nextCursor: "older", backwardsCursor: nil), after: nil)
        let cache = ConversationProjectionCache()
        let url = URL(filePath: "/")
        _ = cache.codex(history.state, workspaceURL: url, historySelection: nil)
        let before = cache.counts
        try history.apply(turns: .init(turns: Array(turns[..<5]), nextCursor: nil, backwardsCursor: nil), after: "older")
        let presentation = cache.codex(history.state, workspaceURL: url, historySelection: nil)
        XCTAssertEqual(presentation.turns.count, 2_000)
        XCTAssertEqual(cache.counts.projected - before.projected, 5)
        XCTAssertEqual(cache.counts.reused - before.reused, 1_995)
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
        if before != nil {
            olderMessageReads += 1
            if failsNextOlderRead { failsNextOlderRead = false; throw PersonalAgentFailure.network }
        }
        if delayMessageRead {
            delayMessageRead = false
            await withCheckedContinuation { pendingMessageRead = $0 }
        }
        if let room { return .init(messages: room, before: roomCursor) }
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
    private var liveStreams: [AsyncStream<PersonalAgentLiveUpdate>.Continuation] = []
    private(set) var liveRequests: [PersonalAgentIdentity] = []
    private(set) var liveEnded = 0
    func liveState(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentLiveUpdate> {
        let pair = AsyncStream<PersonalAgentLiveUpdate>.makeStream()
        liveRequests.append(agent.id)
        liveStreams.append(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.endLive() } }
        return pair.stream
    }
    private func endLive() { liveEnded += 1 }
    func pushLive(_ state: PersonalAgentLiveState?, to index: Int) { liveStreams[index].yield(.state(state)) }
    func failLive(_ failure: PersonalAgentFailure, at index: Int) { liveStreams[index].yield(.failed(failure)) }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        sends.append(submission)
        if delaysSend { await withCheckedContinuation { pendingSend = $0 } }
        if holdsNextSend { holdsNextSend = false; await withCheckedContinuation { pendingSend = $0 } }
        if losesFirstSend, sends.count == 1 { throw PersonalAgentFailure.deliveryUnknown }
        if losesNextSend { losesNextSend = false; throw PersonalAgentFailure.deliveryUnknown }
        var message = PersonalAgentMessage(id: submission.requestID, author: .person, text: submission.text, createdAt: nil,
              isDeleted: false, attachments: [], requestID: submission.requestID)
        if history != nil { history?.append(message) }
        message.replyToMessageID = submission.replyTarget?.messageID ?? submission.replyToMessageID
        if room != nil { room?.append(message) }
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
    // An Activity task's record: pages by cursor, each read recorded by its key.
    private var turnPages: [String: CodexTurnPage] = [:]
    private var itemPages: [String: CodexItemPage] = [:]
    private var historyFailures: [String: PersonalAgentFailure] = [:]
    private var heldHistoryRead: String?
    private var pendingHistoryRead: CheckedContinuation<Void, Never>?
    private(set) var historyReads: [String] = []
    func setHistory(turns: [String: CodexTurnPage], items: [String: CodexItemPage]) { turnPages = turns; itemPages = items }
    func failHistory(_ key: String, with failure: PersonalAgentFailure?) { historyFailures[key] = failure }
    func holdHistory(_ key: String) { heldHistoryRead = key }
    func hasPendingHistory() -> Bool { pendingHistoryRead != nil }
    func releaseHistory() { pendingHistoryRead?.resume(); pendingHistoryRead = nil }
    private func readHistory(_ key: String) async throws {
        historyReads.append(key)
        if heldHistoryRead == key {
            heldHistoryRead = nil
            await withCheckedContinuation { pendingHistoryRead = $0 }
        }
        if let failure = historyFailures[key] { throw failure }
    }
    func activityThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        try await readHistory("thread:" + threadID)
        return try PersonalAgentActivityHistory.thread(.object(["thread": .object(["id": .string(threadID)])]), id: threadID)
    }
    func activityTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        try await readHistory("turns:" + (cursor ?? ""))
        return turnPages[cursor ?? ""] ?? .init(turns: [], nextCursor: nil, backwardsCursor: nil)
    }
    func activityItems(_ threadID: String, turnID: String, cursor: String?,
                       for agent: PersonalAgent) async throws -> CodexItemPage {
        try await readHistory("items:\(turnID):\(cursor ?? "")")
        return itemPages["\(turnID):\(cursor ?? "")"] ?? .init(entries: [], nextCursor: nil, backwardsCursor: nil)
    }
    func stop() { stopped = true }
    func didStop() -> Bool { stopped }
    func hasPendingRead() -> Bool { pending != nil }
    func release() { pending?.resume(returning: values); pending = nil }
    func advance() { advanced = true }
    func sentRequests() -> [PersonalAgentSubmission] { sends }
    func hasPendingSend() -> Bool { pendingSend != nil }
    func releaseSend() { pendingSend?.resume(); pendingSend = nil }
    func replaceHistory(_ messages: [PersonalAgentMessage]) { history = messages }
    private var holdsNextSend = false
    private var losesNextSend = false
    /// The next send waits for `releaseSend`, then is lost.
    func holdAndLoseNextSend() { holdsNextSend = true; losesNextSend = true }
    /// The room as one page, with `before` as its earlier cursor.
    private var room: [PersonalAgentMessage]?
    private var roomCursor: String?
    func setRoom(_ messages: [PersonalAgentMessage], before: String? = nil) { room = messages; roomCursor = before }
    func replaceInRoom(_ message: PersonalAgentMessage) {
        if let index = room?.firstIndex(where: { $0.id == message.id }) { room?[index] = message }
    }
    /// Reply pages by their cursor, "" for the latest; a held read answers with the page it read when it started.
    private var threadPages: [String: PersonalAgentPage] = [:]
    private var heldReplies: String?
    private var pendingReplies: CheckedContinuation<Void, Never>?
    private(set) var replyReads: [String] = []
    func setThread(_ pages: [String: PersonalAgentPage]) { threadPages = pages }
    func holdReplies(before: String) { heldReplies = before }
    func hasPendingReplies() -> Bool { pendingReplies != nil }
    func releaseReplies() { pendingReplies?.resume(); pendingReplies = nil }
    func replies(to rootID: String, for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        let key = before ?? ""
        replyReads.append(key)
        let page = threadPages[key]
        if heldReplies == key {
            heldReplies = nil
            await withCheckedContinuation { pendingReplies = $0 }
        }
        guard let page else { throw PersonalAgentFailure.network }
        return page
    }
    // The dot's Outputs: its threads, their metadata and pages, each read recorded by its key.
    private var outputScope: [String] = []
    private var outputMetadata: [String: JSONValue] = [:]
    private var outputTurnPages: [String: CodexTurnPage] = [:]
    private var outputItemPages: [String: CodexItemPage] = [:]
    private var outputFailures: [String: PersonalAgentFailure] = [:]
    private var heldOutputRead: String?
    private var pendingOutputRead: CheckedContinuation<Void, Never>?
    private(set) var outputReads: [String] = []
    func setOutputs(scope: [String], metadata: [String: JSONValue], turns: [String: CodexTurnPage],
                    items: [String: CodexItemPage]) {
        outputScope = scope; outputMetadata = metadata; outputTurnPages = turns; outputItemPages = items
    }
    func failOutputs(_ key: String, with failure: PersonalAgentFailure?) { outputFailures[key] = failure }
    func holdOutputs(_ key: String) { heldOutputRead = key }
    func hasPendingOutputs() -> Bool { pendingOutputRead != nil }
    func releaseOutputs() { pendingOutputRead?.resume(); pendingOutputRead = nil }
    private func readOutputs(_ key: String) async throws {
        outputReads.append(key)
        if heldOutputRead == key {
            heldOutputRead = nil
            await withCheckedContinuation { pendingOutputRead = $0 }
        }
        if let failure = outputFailures[key] { throw failure }
    }
    func outputThreads(for agent: PersonalAgent) async throws -> [String] {
        try await readOutputs("threads")
        return outputScope
    }
    private func metadata(_ id: String) throws -> CodexThreadState {
        try PersonalAgentActivityHistory.thread(.object(["thread": outputMetadata[id] ?? .object(["id": .string(id)])]), id: id)
    }
    func outputThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        try await readOutputs("thread:" + threadID)
        return try metadata(threadID)
    }
    func outputChild(_ threadID: String, of parentID: String, for agent: PersonalAgent) async throws -> CodexThreadState? {
        try await readOutputs("child:" + threadID)
        let thread = try metadata(threadID)
        guard PersonalAgentOutputEnvironment.parent(of: thread.raw) == parentID else { return nil }
        return thread
    }
    func outputTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        let key = "\(threadID):\(cursor ?? "")"
        try await readOutputs("turns:" + key)
        return outputTurnPages[key] ?? .init(turns: [], nextCursor: nil, backwardsCursor: nil)
    }
    func outputItems(_ threadID: String, turnID: String, cursor: String?,
                     for agent: PersonalAgent) async throws -> CodexItemPage {
        let key = "\(threadID):\(turnID):\(cursor ?? "")"
        try await readOutputs("items:" + key)
        return outputItemPages[key] ?? .init(entries: [], nextCursor: nil, backwardsCursor: nil)
    }
    func delayNextMessageRead() { delayMessageRead = true }
    private var failsNextOlderRead = false
    private(set) var olderMessageReads = 0
    func failNextOlderRead() { failsNextOlderRead = true }
    func delayReadAfterNextSend() { delayAfterSend = true }
    func hasPendingMessageRead() -> Bool { pendingMessageRead != nil }
    func releaseMessageRead() { pendingMessageRead?.resume(); pendingMessageRead = nil }
}
