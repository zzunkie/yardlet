import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

@MainActor
final class RemoteMailCalendarV2Tests: XCTestCase {
    // MARK: - Wire JSON Stability (Cross-Platform)

    func testWireJSONUsesUnixEpochMillisecondsAndPlainStringEnums() throws {
        let accountID = "6D3B0A6E-1F7A-4C52-9C55-6A2B8F0D1E01"
        // 2026-11-23T09:00:00Z in Unix epoch milliseconds (far above Apple 2001-epoch float seconds).
        let startMs: Int64 = 1_795_424_400_000
        let endMs: Int64 = 1_795_428_000_000

        let state = RemoteMailCalendarV2State(
            mailConnected: true,
            calendarConnected: true,
            mailEnabled: true,
            calendarEnabled: true,
            permitted: true,
            mailAccounts: [
                RemoteMailV2Account(id: accountID, provider: "gmail", email: "dana@acme.example", displayName: "dana", unreadCount: 3)
            ],
            calendarAccounts: [
                RemoteCalendarV2Account(id: accountID, provider: "google", email: "dana@acme.example", displayName: "dana@acme.example", canRespond: true)
            ]
        )
        let stateData = try RemoteJSON.encoder.encode(state)
        let stateJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(stateJSON["mailConnected"] as? Bool, true)
        XCTAssertEqual(stateJSON["calendarConnected"] as? Bool, true)
        XCTAssertEqual(stateJSON["permitted"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(RemoteMailCalendarV2State.self, from: stateData), state)

        let summary = RemoteMailV2ThreadSummary(
            id: "t-1",
            threadId: "t-1",
            accountId: accountID,
            fromName: "Alex",
            fromEmail: "alex@example.com",
            subject: "Quarterly review",
            snippet: "Draft slides attached",
            dateMs: startMs,
            unread: true,
            starred: true,
            hasAttachments: true,
            hasDraft: false,
            messageCount: 2
        )
        let event = RemoteCalendarV2Event(
            id: "evt-1",
            calendarId: "primary",
            accountId: accountID,
            calendarName: "Work",
            calendarColor: "#4A7BD0",
            title: "Design sync",
            startMs: startMs,
            endMs: endMs,
            allDay: false,
            location: "Room 4B",
            notes: "Agenda",
            meetingUrl: "https://meet.example.com/abc",
            responseStatus: .needsAction,
            isOrganizer: false,
            canRespond: true,
            organizer: RemoteCalendarV2Person(name: "Sam", email: "sam@example.com"),
            attendees: [RemoteCalendarV2Person(name: "Dana", email: "dana@acme.example", responseStatus: .accepted)]
        )
        let payload = RemoteMailCalendarV2Response(threads: [summary], events: [event])
        let payloadData = try RemoteJSON.encoder.encode(payload)
        let payloadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])

        // Verify integer epoch ms and plain string enums on the wire (no Apple 2001 floats, no enum wrapper dicts).
        let encodedThreads = try XCTUnwrap(payloadObject["threads"] as? [[String: Any]])
        XCTAssertEqual((encodedThreads[0]["dateMs"] as? NSNumber)?.int64Value, startMs)
        XCTAssertEqual(encodedThreads[0]["unread"] as? Bool, true)

        let encodedEvents = try XCTUnwrap(payloadObject["events"] as? [[String: Any]])
        XCTAssertEqual((encodedEvents[0]["startMs"] as? NSNumber)?.int64Value, startMs)
        XCTAssertEqual((encodedEvents[0]["endMs"] as? NSNumber)?.int64Value, endMs)
        XCTAssertEqual(encodedEvents[0]["responseStatus"] as? String, "needsAction")
        let encodedAttendees = try XCTUnwrap(encodedEvents[0]["attendees"] as? [[String: Any]])
        XCTAssertEqual(encodedAttendees[0]["responseStatus"] as? String, "accepted")

        XCTAssertEqual(try JSONDecoder().decode(RemoteMailCalendarV2Response.self, from: payloadData), payload)

        // Verify all request enum raw values serialize as flat strings.
        for action in RemoteMailCalendarV2Action.allCases {
            let data = try RemoteJSON.encoder.encode(action)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(action.rawValue)\"")
        }
        for folder in RemoteMailV2Folder.allCases {
            let data = try RemoteJSON.encoder.encode(folder)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(folder.rawValue)\"")
        }
        for msgAction in RemoteMailV2MessageAction.allCases {
            let data = try RemoteJSON.encoder.encode(msgAction)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(msgAction.rawValue)\"")
        }
        for status in RemoteCalendarV2ResponseStatus.allCases {
            let data = try RemoteJSON.encoder.encode(status)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(status.rawValue)\"")
        }
        for answer in RemoteCalendarV2InvitationResponse.allCases {
            let data = try RemoteJSON.encoder.encode(answer)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(answer.rawValue)\"")
        }
    }

    func testRequestValidationAndPermissionMetadata() throws {
        let validAccount = "6D3B0A6E-1F7A-4C52-9C55-6A2B8F0D1E01"

        // Permission and command flags.
        let stateReq = RemoteRequest.mailCalendarV2State(watching: true)
        XCTAssertNil(stateReq.requiredPermission)
        XCTAssertFalse(stateReq.isCommand)

        let readReq = RemoteRequest.mailCalendarV2(.init(action: .listThreads, folder: .inbox, limit: 10))
        XCTAssertEqual(readReq.requiredPermission, .mailCalendar)
        XCTAssertFalse(readReq.isCommand)
        XCTAssertEqual(readReq.auditTarget, "listThreads")

        let writeReqs: [RemoteMailCalendarV2Request] = [
            .init(action: .updateMessage, accountId: validAccount, threadId: "t-1", messageAction: .archive),
            .init(action: .sendMessage, accountId: validAccount, to: ["a@example.com"], subject: "Hi", body: "Hello"),
            .init(action: .replyMessage, accountId: validAccount, body: "Thanks", replyToThreadId: "t-1"),
            .init(action: .respondEvent, calendarId: "cal-1", eventId: "evt-1", response: .tentative),
        ]
        for v2 in writeReqs {
            let req = RemoteRequest.mailCalendarV2(v2)
            XCTAssertEqual(req.requiredPermission, .mailCalendar)
            XCTAssertTrue(req.isCommand)
            XCTAssertEqual(req.auditTarget, v2.action.rawValue)
            let envelope = RemoteRequestEnvelope(id: "id-\(v2.action.rawValue)", request: req)
            XCTAssertEqual(try RemoteRequestEnvelope.decode(envelope.encoded()).get(), envelope)
        }

        // Validation failures.
        let invalidRequests: [RemoteMailCalendarV2Request] = [
            .init(action: .listThreads, accountId: "not-a-uuid"),
            .init(action: .listThreads, limit: 0),
            .init(action: .listThreads, query: String(repeating: "a", count: RemoteMailCalendarV2Limits.maxQueryCharacters + 1)),
            .init(action: .readThread, accountId: validAccount),
            .init(action: .readMessage, accountId: validAccount),
            .init(action: .updateMessage, accountId: validAccount, threadId: "t-1"),
            .init(action: .sendMessage, accountId: validAccount, to: [], subject: "Hi", body: "Body"),
            .init(action: .replyMessage, accountId: validAccount, body: "   ", replyToThreadId: "t-1"),
            .init(action: .listEvents, startMs: 2_000, endMs: 1_000),
            .init(action: .listEvents, startMs: 0, endMs: RemoteMailCalendarV2Limits.maxCalendarRangeMs + 1),
            .init(action: .respondEvent, calendarId: "cal-1", eventId: "evt-1"),
        ]
        for invalid in invalidRequests {
            XCTAssertNotNil(invalid.validationError, "Expected validation error for \(invalid)")
            let data = RemoteRequestEnvelope(id: "bad", request: .mailCalendarV2(invalid)).encoded()
            if case .success = RemoteRequestEnvelope.decode(data) {
                XCTFail("Expected decode failure for \(invalid)")
            }
        }
    }

    func testSnapshotCapabilityFlagDecodesWhenPresentAndAbsent() throws {
        // Older host response without mailCalendarV2 decodes cleanly with nil.
        let legacyJSON = Data(#"{"ok":true,"re":"1","projects":[],"tasks":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(RemoteResponse.self, from: legacyJSON)
        XCTAssertNil(legacy.mailCalendarV2)

        // Newer host response with mailCalendarV2: true decodes cleanly.
        var newer = RemoteResponse(re: "2")
        newer.mailCalendarV2 = true
        let encoded = try RemoteJSON.encoder.encode(newer)
        let decoded = try JSONDecoder().decode(RemoteResponse.self, from: encoded)
        XCTAssertEqual(decoded.mailCalendarV2, true)
    }

    // MARK: - Host Permission Gating & End-to-End Mapping

    func testHostPermissionGatingAndMailV2Operations() async throws {
        let fixture = MailFixture()
        let transports = fixture.transports()
        let workTransport = try XCTUnwrap(transports.first)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteMailCalendarV2Mail")))
        let host = AppModel(
            store: SessionStore(sessions: [], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        host.mailbox.setEnabled(true)
        host.mailbox.setAccounts(transports.map { ($0.account, $0) })
        await host.mailbox.refresh()
        defer { host.mailbox.setEnabled(false) }

        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(
            macKey: stack.identity.noise.publicKey,
            secret: ticket.secret,
            name: "Mac Studio",
            hosts: ["127.0.0.1:\(stack.port)"]
        ).url)
        let hosts = RemoteHostDirectory(
            store: RemoteHostStore(fileURL: nil),
            keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "iPhone", platform: "ios", appVersion: "test")
        )
        let paired = try await hosts.pair(link: link.absoluteString)
        defer { hosts.close(paired.id) }
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.mailCalendarState?.mailbox == true }

        // 1. Snapshot advertises mailCalendarV2 capability.
        let snapshotResponse = await model.response(to: .snapshot)
        XCTAssertTrue(snapshotResponse.ok)
        XCTAssertEqual(snapshotResponse.mailCalendarV2, true)
        XCTAssertEqual(snapshotResponse.hostMail, true)
        XCTAssertEqual(snapshotResponse.hostCalendar, true)

        // 2. Permission OFF: mailCalendarV2State hides accounts, and all mailCalendarV2 ops are denied with .mailCalendar.
        let unpermittedStateResp = await model.response(to: .mailCalendarV2State(watching: true))
        XCTAssertTrue(unpermittedStateResp.ok)
        let unpermittedState = try XCTUnwrap(unpermittedStateResp.mailCalendarV2State)
        XCTAssertTrue(unpermittedState.mailConnected)
        XCTAssertFalse(unpermittedState.calendarConnected)
        XCTAssertFalse(unpermittedState.permitted)
        XCTAssertTrue(unpermittedState.mailAccounts.isEmpty)
        XCTAssertTrue(unpermittedState.calendarAccounts.isEmpty)

        let deniedList = await model.response(to: .mailCalendarV2(.init(action: .listThreads)))
        XCTAssertFalse(deniedList.ok)
        XCTAssertEqual(deniedList.error?.code, .notAllowed)
        XCTAssertEqual(deniedList.error?.reason, .mailCalendar)

        // 3. Grant mailCalendar permission.
        try await stack.server.setPermission(.mailCalendar, allowed: true, for: try XCTUnwrap(model.host.deviceID))

        let permittedStateResp = await model.response(to: .mailCalendarV2State(watching: true))
        XCTAssertTrue(permittedStateResp.ok)
        let permittedState = try XCTUnwrap(permittedStateResp.mailCalendarV2State)
        XCTAssertTrue(permittedState.permitted)
        XCTAssertEqual(permittedState.mailAccounts.count, 2)
        XCTAssertEqual(permittedState.mailAccounts[0].id, MailFixture.work.id.uuidString)
        XCTAssertEqual(permittedState.mailAccounts[0].provider, "gmail")
        XCTAssertEqual(permittedState.mailAccounts[0].email, "dana@acme.example")
        XCTAssertEqual(permittedState.mailAccounts[0].unreadCount, 2)

        // 4. Mail: listThreads (all accounts, limit, unread filter, query search).
        let allInboxResp = await model.response(to: .mailCalendarV2(.init(action: .listThreads, folder: .inbox, limit: 3)))
        XCTAssertTrue(allInboxResp.ok, "\(String(describing: allInboxResp.error))")
        let allInbox = try XCTUnwrap(allInboxResp.mailCalendarV2Result?.threads)
        XCTAssertEqual(allInbox.count, 3)
        XCTAssertTrue(allInbox[0].dateMs >= allInbox[1].dateMs)
        XCTAssertGreaterThan(allInbox[0].dateMs, 1_700_000_000_000)

        let unreadWorkResp = await model.response(to: .mailCalendarV2(.init(
            action: .listThreads,
            accountId: MailFixture.work.id.uuidString,
            folder: .unread,
            limit: 50
        )))
        XCTAssertTrue(unreadWorkResp.ok, "\(String(describing: unreadWorkResp.error))")
        let unreadWork = try XCTUnwrap(unreadWorkResp.mailCalendarV2Result?.threads)
        XCTAssertEqual(unreadWork.count, 2)
        XCTAssertTrue(unreadWork.allSatisfy(\.unread))

        let searchPersonalResp = await model.response(to: .mailCalendarV2(.init(
            action: .listThreads,
            query: "Jeju"
        )))
        XCTAssertTrue(searchPersonalResp.ok, "\(String(describing: searchPersonalResp.error))")
        XCTAssertEqual(searchPersonalResp.mailCalendarV2Result?.threads?.map(\.threadId), ["thread-trip"])

        // 5. Mail: readThread & readMessage.
        let readThreadResp = await model.response(to: .mailCalendarV2(.init(
            action: .readThread,
            accountId: MailFixture.work.id.uuidString,
            threadId: MailFixture.quoteThread
        )))
        XCTAssertTrue(readThreadResp.ok, "\(String(describing: readThreadResp.error))")
        let quoteThread = try XCTUnwrap(readThreadResp.mailCalendarV2Result?.thread)
        XCTAssertEqual(quoteThread.threadId, MailFixture.quoteThread)
        XCTAssertEqual(quoteThread.messages.count, 4)
        XCTAssertEqual(quoteThread.messages[2].attachments.first?.name, "견적서_v3.pdf")
        XCTAssertGreaterThan(quoteThread.messages[2].dateMs, 1_700_000_000_000)

        let readMsgResp = await model.response(to: .mailCalendarV2(.init(
            action: .readMessage,
            accountId: MailFixture.work.id.uuidString,
            threadId: MailFixture.quoteThread,
            messageId: "q3"
        )))
        XCTAssertTrue(readMsgResp.ok, "\(String(describing: readMsgResp.error))")
        let q3 = try XCTUnwrap(readMsgResp.mailCalendarV2Result?.message)
        XCTAssertEqual(q3.id, "q3")
        XCTAssertEqual(q3.from.email, "haneul@vendor.example")
        XCTAssertEqual(q3.cc.map(\.email), ["doyun@vendor.example"])

        // 6. Mail: updateMessage (markRead, star, archive, trash unsupported).
        let markReadResp = await model.response(to: .mailCalendarV2(.init(
            action: .updateMessage,
            accountId: MailFixture.work.id.uuidString,
            threadId: MailFixture.quoteThread,
            messageAction: .markRead
        )))
        XCTAssertTrue(markReadResp.ok, "\(String(describing: markReadResp.error))")
        XCTAssertEqual(markReadResp.mailCalendarV2Result?.updated, true)

        let starResp = await model.response(to: .mailCalendarV2(.init(
            action: .updateMessage,
            accountId: MailFixture.work.id.uuidString,
            threadId: MailFixture.quoteThread,
            messageAction: .star
        )))
        XCTAssertTrue(starResp.ok, "\(String(describing: starResp.error))")

        let archiveResp = await model.response(to: .mailCalendarV2(.init(
            action: .updateMessage,
            accountId: MailFixture.work.id.uuidString,
            threadId: "thread-ci",
            messageAction: .archive
        )))
        XCTAssertTrue(archiveResp.ok, "\(String(describing: archiveResp.error))")

        let recordedChanges = await workTransport.changes
        XCTAssertTrue(recordedChanges.contains { $0.0 == MailFixture.quoteThread && $0.1 == .read(true) })
        XCTAssertTrue(recordedChanges.contains { $0.0 == MailFixture.quoteThread && $0.1 == .starred(true) })
        XCTAssertTrue(recordedChanges.contains { $0.0 == "thread-ci" && $0.1 == .archived })

        let trashResp = await model.response(to: .mailCalendarV2(.init(
            action: .updateMessage,
            accountId: MailFixture.work.id.uuidString,
            threadId: MailFixture.quoteThread,
            messageAction: .trash
        )))
        XCTAssertFalse(trashResp.ok)
        XCTAssertEqual(trashResp.error?.code, .unsupportedCommand)

        // 7. Mail: sendMessage & replyMessage.
        let sendResp = await model.response(to: .mailCalendarV2(.init(
            action: .sendMessage,
            accountId: MailFixture.work.id.uuidString,
            to: ["jordan@acme.example"],
            cc: ["mina@acme.example"],
            subject: "Follow up",
            body: "See you tomorrow."
        )))
        XCTAssertTrue(sendResp.ok, "\(String(describing: sendResp.error))")
        XCTAssertEqual(sendResp.mailCalendarV2Result?.sent, true)

        let replyResp = await model.response(to: .mailCalendarV2(.init(
            action: .replyMessage,
            accountId: MailFixture.work.id.uuidString,
            body: "Looks good, let's proceed.",
            replyToThreadId: MailFixture.quoteThread,
            replyToMessageId: "q3"
        )))
        XCTAssertTrue(replyResp.ok, "\(String(describing: replyResp.error))")
        XCTAssertEqual(replyResp.mailCalendarV2Result?.sent, true)
        XCTAssertEqual(replyResp.mailCalendarV2Result?.threadId, MailFixture.quoteThread)
        let sentDrafts = await workTransport.sent
        XCTAssertEqual(sentDrafts.count, 2)

        // 8. Legacy Mac mail wire continues working alongside V2.
        let legacyMail = await model.response(to: .mail(action: "accounts", data: nil))
        XCTAssertTrue(legacyMail.ok, "\(String(describing: legacyMail.error))")

        await host.shutdown()
    }

    func testHostCalendarV2OperationsPermissionGatingAndLegacyCoexistence() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: Date()))
        func day(_ index: Int) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: index, to: week.start)!
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        let googleCal = FakeCalendarService(account: CalendarAccount(
            id: UUID(uuidString: "7D3B0A6E-1F7A-4C52-9C55-6A2B8F0D1E10")!,
            provider: .google,
            address: "dana@acme.example",
            connectorSlug: "calendar"
        ))
        let primaryKey = googleCal.add("dana@acme.example", isPrimary: true, color: "#4A7BD0")
        let teamKey = googleCal.add("Team", color: "#3E9B6F")
        let manyAttendees = (0..<65).map { idx in
            CalendarPerson(name: "Guest \(idx)", email: "guest\(idx)@example.com", response: .accepted)
        }
        googleCal.add(
            event: "Investor call",
            hour: 16.5,
            minutes: 30,
            to: primaryKey,
            day: day(1),
            response: .needsAction,
            notes: "Review Q4 roadmap",
            organizer: CalendarPerson(name: "Partner IR", email: "ir@partner.example"),
            attendees: manyAttendees,
            conference: URL(string: "https://meet.example.com/investor")
        )
        googleCal.add(
            event: "Company offsite",
            hour: 0,
            to: teamKey,
            day: day(2),
            allDay: true,
            organizer: CalendarPerson(name: "Dana Park", email: "dana@acme.example")
        )

        let appleCal = FakeCalendarService(account: CalendarAccount(
            id: UUID(uuidString: "7D3B0A6E-1F7A-4C52-9C55-6A2B8F0D1E11")!,
            provider: .apple,
            address: nil
        ))
        let appleKey = appleCal.add("Personal", isPrimary: true, color: "#E06C75")
        appleCal.add(event: "Dentist", hour: 10, minutes: 45, to: appleKey, day: day(3))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteMailCalendarV2Cal")))
        let host = AppModel(
            store: SessionStore(sessions: [], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        host.calendar.setEnabled(true)
        host.calendar.setAccounts([(googleCal.account, googleCal), (appleCal.account, appleCal)])
        defer { host.calendar.setEnabled(false) }

        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(
            macKey: stack.identity.noise.publicKey,
            secret: ticket.secret,
            name: "Mac Studio",
            hosts: ["127.0.0.1:\(stack.port)"]
        ).url)
        let hosts = RemoteHostDirectory(
            store: RemoteHostStore(fileURL: nil),
            keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "Android", platform: "android", appVersion: "test")
        )
        let paired = try await hosts.pair(link: link.absoluteString)
        defer { hosts.close(paired.id) }
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.mailCalendarState?.calendar == true }

        // Permission OFF: denied with .notAllowed / .mailCalendar.
        let deniedEvents = await model.response(to: .mailCalendarV2(.init(
            action: .listEvents,
            startMs: RemoteJSON.milliseconds(week.start),
            endMs: RemoteJSON.milliseconds(week.end)
        )))
        XCTAssertFalse(deniedEvents.ok)
        XCTAssertEqual(deniedEvents.error?.code, .notAllowed)
        XCTAssertEqual(deniedEvents.error?.reason, .mailCalendar)

        // Grant permission.
        try await stack.server.setPermission(.mailCalendar, allowed: true, for: try XCTUnwrap(model.host.deviceID))

        let stateResp = await model.response(to: .mailCalendarV2State(watching: true))
        XCTAssertTrue(stateResp.ok, "\(String(describing: stateResp.error))")
        let state = try XCTUnwrap(stateResp.mailCalendarV2State)
        XCTAssertTrue(state.calendarConnected)
        XCTAssertTrue(state.permitted)
        XCTAssertEqual(state.calendarAccounts.count, 2)
        XCTAssertEqual(state.calendarAccounts[0].provider, "google")
        XCTAssertTrue(state.calendarAccounts[0].canRespond)
        XCTAssertEqual(state.calendarAccounts[1].provider, "apple")
        XCTAssertFalse(state.calendarAccounts[1].canRespond)

        // listCalendars & listEvents.
        let calendarsResp = await model.response(to: .mailCalendarV2(.init(action: .listCalendars)))
        XCTAssertTrue(calendarsResp.ok, "\(String(describing: calendarsResp.error))")
        let calendars = try XCTUnwrap(calendarsResp.mailCalendarV2Result?.calendars)
        XCTAssertEqual(calendars.count, 3)

        let eventsResp = await model.response(to: .mailCalendarV2(.init(
            action: .listEvents,
            startMs: RemoteJSON.milliseconds(week.start),
            endMs: RemoteJSON.milliseconds(week.end)
        )))
        XCTAssertTrue(eventsResp.ok, "\(String(describing: eventsResp.error))")
        let events = try XCTUnwrap(eventsResp.mailCalendarV2Result?.events)
        XCTAssertEqual(events.count, 3)

        let investor = try XCTUnwrap(events.first { $0.title == "Investor call" })
        XCTAssertEqual(investor.calendarId, primaryKey.calendarID)
        XCTAssertEqual(investor.calendarName, "dana@acme.example")
        XCTAssertEqual(investor.responseStatus, .needsAction)
        XCTAssertFalse(investor.isOrganizer)
        XCTAssertTrue(investor.canRespond)
        XCTAssertEqual(investor.meetingUrl, "https://meet.example.com/investor")
        XCTAssertEqual(investor.attendees.count, RemoteMailCalendarV2Limits.maxEventAttendees)
        XCTAssertEqual(investor.attendeesTruncated, true)
        XCTAssertNil(investor.startDate)

        let offsite = try XCTUnwrap(events.first { $0.title == "Company offsite" })
        XCTAssertTrue(offsite.allDay)
        XCTAssertTrue(offsite.isOrganizer)
        XCTAssertFalse(offsite.canRespond)
        XCTAssertEqual(offsite.responseStatus, .none)
        XCTAssertEqual(offsite.startDate?.count, 10)
        XCTAssertEqual(offsite.endDate?.count, 10)

        // Filter by calendarId.
        let filteredEventsResp = await model.response(to: .mailCalendarV2(.init(
            action: .listEvents,
            startMs: RemoteJSON.milliseconds(week.start),
            endMs: RemoteJSON.milliseconds(week.end),
            calendarId: teamKey.calendarID
        )))
        XCTAssertTrue(filteredEventsResp.ok, "\(String(describing: filteredEventsResp.error))")
        XCTAssertEqual(filteredEventsResp.mailCalendarV2Result?.events?.map(\.title), ["Company offsite"])

        // Respond to invitation without specifying accountId (resolved from calendarId).
        let respondResp = await model.response(to: .mailCalendarV2(.init(
            action: .respondEvent,
            calendarId: investor.calendarId,
            eventId: investor.id,
            response: .accepted
        )))
        XCTAssertTrue(respondResp.ok, "\(String(describing: respondResp.error))")
        XCTAssertEqual(respondResp.mailCalendarV2Result?.responded, true)
        XCTAssertEqual(googleCal.answers, ["\(investor.id) accepted"])

        // Apple calendar cannot respond to invitations.
        let appleEvent = try XCTUnwrap(events.first { $0.title == "Dentist" })
        let appleRespond = await model.response(to: .mailCalendarV2(.init(
            action: .respondEvent,
            accountId: appleCal.account.id.uuidString,
            calendarId: appleEvent.calendarId,
            eventId: appleEvent.id,
            response: .declined
        )))
        XCTAssertFalse(appleRespond.ok)
        XCTAssertEqual(appleRespond.error?.code, .badRequest)

        // Legacy Mac calendar wire continues working alongside V2.
        let legacyCal = await model.response(to: .calendar(action: "accounts", data: nil))
        XCTAssertTrue(legacyCal.ok, "\(String(describing: legacyCal.error))")

        await host.shutdown()
    }

    func testBodyAndAttachmentCapsAreEnforcedOnMapping() {
        let accountID = UUID()
        let hugeText = String(repeating: "x", count: RemoteMailCalendarV2Limits.maxTextBodyCharacters + 500)
        let hugeHTML = "<p>" + String(repeating: "h", count: RemoteMailCalendarV2Limits.maxHtmlBodyCharacters + 500) + "</p>"
        let manyAttachments = (0..<70).map { i in
            MailAttachment(id: "att-\(i)", name: "file-\(i).txt", size: 100, mimeType: "text/plain")
        }
        let message = MailMessage(
            id: "m-1",
            from: MailAddress(name: "Sender", address: "sender@example.com"),
            to: [MailAddress(address: "rcpt@example.com")],
            cc: [],
            date: Date(timeIntervalSince1970: 1_795_424_400),
            subject: String(repeating: "S", count: 800),
            snippet: String(repeating: "P", count: 800),
            text: hugeText,
            html: hugeHTML,
            attachments: manyAttachments,
            isDraft: false,
            isUnread: true
        )
        let mapped = AppModelRemoteBridge.mapMessage(message, accountID: accountID, threadID: "t-1")
        XCTAssertEqual(mapped.textBody.count, RemoteMailCalendarV2Limits.maxTextBodyCharacters)
        XCTAssertEqual(mapped.htmlBody?.count, RemoteMailCalendarV2Limits.maxHtmlBodyCharacters)
        XCTAssertTrue(mapped.bodyTruncated)
        XCTAssertEqual(mapped.subject.count, RemoteMailCalendarV2Limits.maxSubjectCharacters)
        XCTAssertEqual(mapped.snippet.count, RemoteMailCalendarV2Limits.maxSnippetCharacters)
        XCTAssertEqual(mapped.attachments.count, RemoteMailCalendarV2Limits.maxAttachments)
        XCTAssertEqual(mapped.dateMs, 1_795_424_400_000)
    }
}
