import Foundation
import XCTest
@testable import YardletRemote

/// The remote server over channels the test holds (no sockets, no Noise: a channel is handed over as its
/// handshake would hand it): connections that never prove themselves, removed devices and their pairing,
/// connection limits, devices paired with protocol 1 dropped from the file, snapshots and their change and
/// attention events, conversation pages and changes, and commands reaching the bridge with their audit
/// lines — never the message text.
final class RemoteServerTests: XCTestCase {
    func testDevicePermissionsDefaultToDeniedPersistAndRevokeLive() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        let connectionID = try XCTUnwrap(phone.id)
        let allDevices = await harness.devices.all()
        let device = try XCTUnwrap(allDevices.first)
        for permission in RemoteDevicePermission.allCases {
            let refused = await harness.server.permissionError(permission, on: connectionID)
            XCTAssertEqual(refused?.code, .notAllowed)
        }
        try await harness.server.setPermission(.terminal, allowed: true, for: device.id)
        let allowed = await harness.server.permissionError(.terminal, on: connectionID)
        XCTAssertNil(allowed)
        let files = await harness.server.permissionError(.fileWrites, on: connectionID)
        XCTAssertEqual(files?.code, .notAllowed)
        try await harness.server.setPermission(.terminal, allowed: false, for: device.id)
        let revoked = await harness.server.permissionError(.terminal, on: connectionID)
        XCTAssertEqual(revoked?.code, .notAllowed)
        XCTAssertEqual(harness.audit.entries().filter { $0.type == "permission.terminal" }.map(\.result),
                       ["allowed", "notAllowed"])
        // Even a paired device cannot edit the host's device permissions over the wire.
        await harness.send(#"{"id":"permissions","type":"setPermission","terminal":true}"#, on: phone)
        let response = try await phone.response("permissions")
        XCTAssertNotNil(response.error)

        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "devices.json")
        let store = RemoteDeviceStore(fileURL: file, devices: [device])
        _ = try await store.setPermission(.settings, allowed: true, for: device.id)
        let saved = await RemoteDeviceStore(fileURL: file).device(device.id)
        XCTAssertEqual(saved?.permissions, RemoteDevicePermissions(settings: true))
        _ = try await store.setPermission(.settings, allowed: false, for: device.id)
        let replaced = await RemoteDeviceStore(fileURL: file).device(device.id)
        XCTAssertEqual(replaced?.permissions, RemoteDevicePermissions())
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let partial = try JSONDecoder().decode(RemoteDevicePermissions.self, from: Data(#"{"terminal":true}"#.utf8))
        XCTAssertEqual(partial, RemoteDevicePermissions(terminal: true))
        // A failed save never grants a permission in memory.
        let badStore = RemoteDeviceStore(fileURL: file.appending(path: "impossible.json"), devices: [device])
        do {
            _ = try await badStore.setPermission(.terminal, allowed: true, for: device.id)
            XCTFail("Expected a persistence failure")
        } catch {}
        let unchanged = await badStore.device(device.id)
        XCTAssertNil(unchanged?.permissions)
    }

    func testPermissionObserversAndIndependentChanges() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        let connection = try XCTUnwrap(phone.id)
        let devices = await harness.devices.all()
        let device = try XCTUnwrap(devices.first)
        let first = PermissionEvents()
        let second = PermissionEvents()
        let token = await harness.server.addPermissionsChangedHandler { first.append($0, $1) }
        _ = await harness.server.addPermissionsChangedHandler { second.append($0, $1) }
        try await harness.server.setPermission(.terminal, allowed: true, for: device.id)
        try await harness.server.setPermission(.fileWrites, allowed: true, for: device.id)
        let gate = PermissionChangeGate()
        let change = Task {
            try await harness.server.withPermissionChange(.fileWrites, for: device.id) { await gate.wait() }
        }
        try await waitUntilAsync { await gate.isWaiting }
        let terminal = await harness.server.permissionError(.terminal, on: connection)
        let files = await harness.server.permissionError(.fileWrites, on: connection)
        XCTAssertNil(terminal, "Saving another flag must not interrupt terminal access")
        XCTAssertEqual(files?.code, .notAllowed)
        await gate.release()
        try await change.value
        let filesAfter = await harness.server.permissionError(.fileWrites, on: connection)
        XCTAssertNil(filesAfter)
        XCTAssertEqual(first.values, second.values)
        await harness.server.removePermissionsChangedHandler(token)
        let firstCount = first.values.count
        await harness.server.shutdown(reason: "test")
        XCTAssertEqual(first.values.count, firstCount)
        XCTAssertEqual(second.values.last?.permissions, RemoteDevicePermissions())
    }

    func testFreshRegistrationDeniesExistingRightsBeforeAnUpdateConflict() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        let all = await harness.devices.all()
        let device = try XCTUnwrap(all.first)
        let key = try XCTUnwrap(RemoteEncoding.data(base64url: device.publicKey))
        try await harness.server.setPermission(.terminal, allowed: true, for: device.id)
        let snapshot = await harness.devices.permissionSnapshot(device.id)
        let before = try XCTUnwrap(snapshot)
        let gate = PermissionChangeGate()
        let change = Task { try await harness.server.withPermissionChange(.settings, for: device.id) { await gate.wait() } }
        try await waitUntilAsync { await gate.isWaiting }
        let ticket = await harness.server.openPairing()
        let registration = await harness.server.acceptHandshake(
            RemoteHandshakeHello(name: "Replacement", pair: RemoteEncoding.base64url(ticket.secret)),
            publicKey: key, channel: TestChannel(), path: .local)
        guard case .refused = registration else {
            await gate.release()
            return XCTFail("A conflicting registration must not report success")
        }
        let denied = await harness.devices.device(device.id)
        XCTAssertEqual(denied?.permissions, RemoteDevicePermissions())
        let access = await harness.server.permissionError(.terminal, on: try XCTUnwrap(phone.id))
        XCTAssertEqual(access?.code, .notAllowed)
        do {
            _ = try await harness.devices.setPermission(.terminal, allowed: true, for: device.id,
                                                        expectedGeneration: before.generation)
            XCTFail("A grant queued before the reset must not restore rights")
        } catch let error as RemoteError { XCTAssertEqual(error.code, .notAllowed) }
        await gate.release()
        try await change.value
        let returning = TestChannel()
        let reconnected = await harness.server.acceptHandshake(RemoteHandshakeHello(name: "Returning"), publicKey: key,
                                                               channel: returning, path: .local)
        guard case let .accepted(id, _) = reconnected else { return XCTFail("The retained key should reconnect without grants") }
        returning.id = id
        await harness.send(#"{"id":"proof","type":"ping"}"#, on: returning)
        _ = try await returning.response("proof")
        let stillDenied = await harness.server.permissionError(.terminal, on: id)
        XCTAssertEqual(stillDenied?.code, .notAllowed)
    }

    func testPermissionRefusalsKeepImportantAuditEntries() async throws {
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        let phone = try await harness.authenticatedPhone()
        let all = await harness.devices.all()
        let device = try XCTUnwrap(all.first)
        try await harness.server.setPermission(.terminal, allowed: true, for: device.id)
        let request = RemoteRequest.setTaskSetting(taskID: "A", setting: "example", value: "not audit content")
        for _ in 0..<2_600 { await harness.server.auditPermissionRefusal(device: device.id, request: request) }
        let initial = harness.audit.entries()
        XCTAssertTrue(initial.contains { $0.type == "permission.terminal" })
        XCTAssertEqual(initial.filter { $0.type == request.type }.count, 1)
        clock.advance(by: 61)
        await harness.server.auditPermissionRefusal(device: device.id, request: request)
        XCTAssertEqual(harness.audit.entries().filter { $0.type == request.type }.count, 2)
        XCTAssertFalse(try String(contentsOf: harness.auditURL, encoding: .utf8).contains("not audit content"))
        await harness.server.closed(try XCTUnwrap(phone.id))
    }

    func testShutdownNotifiesDevicesLoadedWithExistingGrants() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-shutdown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("devices.json")
        let original = RemoteDeviceStore(fileURL: file)
        let device = await original.addSecure(name: "Offline device", publicKey: Data(repeating: 8, count: 32), platform: nil)
        _ = try await original.setPermission(.terminal, allowed: true, for: device.id)
        let server = RemoteServer(configuration: .init(server: RemoteServerInfo(name: "Test", appVersion: "test")),
                                  bridge: FakeBridge(), devices: RemoteDeviceStore(fileURL: file))
        await server.start()
        let received = PermissionEvents()
        _ = await server.addPermissionsChangedHandler { received.append($0, $1) }
        await server.shutdown(reason: "test")
        XCTAssertEqual(received.values, [.init(device: device.id, permissions: RemoteDevicePermissions())])
    }

    func testUnprovenAndQuietConnectionsAreClosed() async throws {
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        // A handshake whose phone never sends a message (message 1 sent again by someone else) does not count
        // as the device's connection, and closes.
        let replayed = try await harness.authenticatedPhone(proving: false)
        let shown = await harness.server.status.connectedDeviceIDs
        XCTAssertTrue(shown.isEmpty)
        let phone = try await harness.authenticatedPhone()
        let connected = await harness.server.status.connectedDeviceIDs
        XCTAssertEqual(connected.count, 1)
        clock.advance(by: 31)
        await harness.server.sweep()
        try await replayed.waitUntilClosed(.idle)
        XCTAssertFalse(phone.isClosed)
        clock.advance(by: 80)
        await harness.server.sweep()
        try await phone.waitUntilClosed(.idle)
    }

    func testDevicesPairedWithTheFirstProtocolAreDropped() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-devices-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "devices.json")
        // The same phone paired once with each protocol, under the same name.
        try Data(#"""
        {"version": 2, "devices": [
          {"id": "OLD-PHONE", "name": "Pixel 9", "tokenHash": "\#(String(repeating: "a", count: 64))",
           "createdAt": "2026-10-01T09:00:00Z", "lastSeenAt": "2026-10-20T09:00:00Z"},
          {"id": "NEW-PHONE", "name": "Pixel 9", "publicKey": "\#(RemoteEncoding.base64url(Data(repeating: 7, count: 32)))",
           "platform": "android", "createdAt": "2026-10-21T09:00:00Z", "lastSeenAt": "2026-10-22T09:00:00Z"}
        ]}
        """#.utf8).write(to: file)
        let devices = await RemoteDeviceStore(fileURL: file).all()
        XCTAssertEqual(devices.map(\.id), ["NEW-PHONE"])
        XCTAssertEqual(devices.first?.platform, "android")
        XCTAssertNil(devices.first?.permissions)
        // Written back without it, so it does not come back.
        let reread = await RemoteDeviceStore(fileURL: file).all()
        XCTAssertEqual(reread, devices)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("tokenHash"))
    }

    func testTheSnapshotThenItsChangesAndAttention() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.send(#"{"id":"s","type":"snapshot"}"#, on: phone)
        let snapshot = try await phone.response("s")
        XCTAssertEqual(snapshot.tasks?.map(\.id), ["A", "B"])
        XCTAssertEqual(snapshot.projects?.map(\.name), ["Yardlet"])
        XCTAssertEqual(snapshot.serverTime, RemoteJSON.milliseconds(RemoteTestClock().now), "The phone corrects for clock skew")
        // A bridge without schedules says nothing of them, and answers no list (§15.21).
        XCTAssertNil(snapshot.scheduledTasks)
        await harness.send(#"{"id":"l","type":"scheduledTasks"}"#, on: phone)
        let noSchedules = try await phone.response("l").error?.code
        XCTAssertEqual(noSchedules, .unavailable)
        // Nor of a task's files (§15.22).
        XCTAssertNil(snapshot.taskFiles)
        await harness.send(#"{"id":"o","type":"taskOutputs","taskId":"A"}"#, on: phone)
        let noOutputs = try await phone.response("o").error?.code
        XCTAssertEqual(noOutputs, .unavailable)
        await harness.send(#"{"id":"f","type":"readFile","taskId":"A","path":"notes.txt","offset":0}"#, on: phone)
        let noFiles = try await phone.response("f").error?.code
        XCTAssertEqual(noFiles, .unavailable)

        var next = FakeBridge.snapshot
        next.tasks[0].attention = .waiting
        next.tasks[0].indicator = .awaitingApproval
        next.tasks[0].pendingRequest = .approval
        next.newestRequestIDs["A"] = "toolu_1"
        next.requestSummaries["A"] = "Bash: Run the migration tests"
        next.tasks.remove(at: 1)
        await harness.bridge.setSnapshot(next)
        await harness.bridge.signal(.tasks)

        let changed = try await phone.event(.tasksChanged)
        XCTAssertEqual(changed.tasks?.map(\.id), ["A"])
        XCTAssertEqual(changed.removedTaskIds, ["B"])
        XCTAssertNil(changed.projects)
        let attention = try await phone.event(.attention)
        XCTAssertEqual(attention.taskId, "A")
        XCTAssertEqual(attention.state, .waiting)
        XCTAssertEqual(attention.previousState, .active)
        XCTAssertEqual(attention.requestId, "toolu_1")
        XCTAssertEqual(attention.summary, "Bash: Run the migration tests")
        XCTAssertEqual(attention.projectName, "Yardlet")

        // A second request in a task that already waits is news too.
        next.newestRequestIDs["A"] = "toolu_2"
        await harness.bridge.setSnapshot(next)
        await harness.bridge.signal(.tasks)
        let awaited9 = try await phone.event(.attention, after: attention.seq ?? 0).requestId
        XCTAssertEqual(awaited9, "toolu_2")
    }

    func testAConversationPagesAndFollowsItsChanges() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        var turns = (1...14).map { RemoteProtocolTests.turn("t\($0)", items: 3) }
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")

        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        let page = try await phone.response("1")
        var client = try XCTUnwrap(page.items)
        XCTAssertEqual(client.first?.turnId, "t5")
        XCTAssertEqual(page.hasOlder, true)
        let watched = await harness.bridge.watchedTasks
        XCTAssertEqual(watched, ["A"])
        let prepared = await harness.bridge.preparedTasks
        XCTAssertEqual(prepared, ["A"])

        await harness.send(#"{"id":"2","type":"loadOlder","taskId":"A","cursor":"\#(page.cursor ?? "")"}"#, on: phone)
        let older = try await phone.response("2")
        XCTAssertEqual(older.items?.first?.turnId, "t1")
        XCTAssertEqual(older.hasOlder, false)
        client = (older.items ?? []) + client

        turns[13].items[2].text = "streaming…"
        turns.append(RemoteProtocolTests.turn("t15", items: 2))
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")
        await harness.bridge.signal(.conversation("A"))
        let delta = try await phone.event(.conversation)
        client = RemoteProtocolTests.strictlyApplying(delta.changes ?? [], to: client)
        XCTAssertEqual(client, turns.flatMap(\.items))

        await harness.send(#"{"id":"3","type":"loadOlder","taskId":"A","cursor":"stale"}"#, on: phone)
        let awaited10 = try await phone.response("3").error?.code
        XCTAssertEqual(awaited10, .invalidCursor)

        await harness.bridge.setConversation(nil, for: "A")
        await harness.bridge.signal(.conversation("A"))
        let awaited11 = try await phone.event(.conversationEnded).reason
        XCTAssertEqual(awaited11, "removed")
        await harness.send(#"{"id":"4","type":"subscribeTask","taskId":"missing"}"#, on: phone)
        let awaited12 = try await phone.response("4").error?.code
        XCTAssertEqual(awaited12, .notFound)
    }

    /// A subscription in full detail (§15.24) reads the bridge's full conversation while a phone's beside it keeps its
    /// own, and changes too large for one message go out as several events that, applied in order, are the change.
    func testAFullSubscriptionReadsItsOwnDetailAndLargeChangesGoInParts() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        let desktop = try await harness.authenticatedPhone()
        let basic = RemoteConversation(turns: [RemoteProtocolTests.turn("t1", items: 2)])
        var full = basic
        full.turns[0].items[0].images = [RemoteImagePreview(data: Data(repeating: 7, count: 64), name: "shot.png")]
        await harness.bridge.setConversation(basic, for: "A")
        await harness.bridge.setConversation(full, for: "A", detail: .full)
        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A","detail":"full"}"#, on: desktop)
        let phonePage = try await phone.response("1").items
        XCTAssertEqual(phonePage, basic.turns[0].items)
        let desktopPage = try await desktop.response("1").items
        var held = try XCTUnwrap(desktopPage)
        XCTAssertEqual(held, full.turns[0].items)

        var turns = full.turns
        turns.append(RemoteTurn(id: "t2", items: (0..<30).map { index in
            var item = RemoteItem(id: "i:answer-\(index)", turnId: "t2", kind: .assistant)
            item.text = String(repeating: "Long answer. ", count: 15_000)
            return item
        }))
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A", detail: .full)
        await harness.bridge.signal(.conversation("A"))
        var seq = 0
        var events = 0
        while held.count < turns.flatMap(\.items).count {
            let event = try await desktop.event(.conversation, after: seq)
            seq = event.seq ?? seq
            events += 1
            let size = (event.changes ?? []).reduce(0) { $0 + ($1.item?.text?.utf8.count ?? 0) }
            XCTAssertLessThanOrEqual(size, RemoteServer.maxChangesBytes)
            held = RemoteProtocolTests.strictlyApplying(event.changes ?? [], to: held)
        }
        XCTAssertEqual(held, turns.flatMap(\.items))
        XCTAssertEqual(events, 3)
    }

    /// A change read while older turns load is not lost: the page goes first, then the changes to the
    /// newer turns, and every change names only items the phone holds by then.
    func testAChangeReadWhileOlderTurnsLoadFollowsThePage() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        var turns = (1...14).map { RemoteProtocolTests.turn("t\($0)", items: 3) }
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")
        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        let page = try await phone.response("1")
        // The conversation moves on, and the phone asks for older turns before the change is told.
        turns[13].items[1].text = "changed while loading"
        turns[13].items.insert(RemoteProtocolTests.item("i:new-before-answer"), at: 2)
        turns.append(RemoteProtocolTests.turn("t15", items: 2))
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")
        await harness.send(#"{"id":"2","type":"loadOlder","taskId":"A","cursor":"\#(page.cursor ?? "")"}"#, on: phone)
        let older = try await phone.response("2")
        let changes = try await phone.event(.conversation)
        var client = (older.items ?? []) + (page.items ?? [])
        client = RemoteProtocolTests.strictlyApplying(changes.changes ?? [], to: client)
        XCTAssertEqual(client, turns.flatMap(\.items))
        // The change signal arriving late finds nothing more to send.
        await harness.bridge.signal(.conversation("A"))
        do {
            let after = try await phone.event(.conversation, after: changes.seq ?? 0, timeout: 0.3)
            XCTFail("Unexpected second change: \(after)")
        } catch is TestChannel.TimedOut {}
    }

    func testOlderTurnsTheProviderHoldsAreAskedFor() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        let held = (1...3).map { RemoteProtocolTests.turn("h\($0)", items: 2) }
        let loaded = (1...2).map { RemoteProtocolTests.turn("t\($0)", items: 2) }
        await harness.bridge.setConversation(RemoteConversation(turns: loaded, hasEarlier: true), for: "A")
        await harness.bridge.setEarlier(RemoteConversation(turns: held + loaded), for: "A")
        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        let page = try await phone.response("1")
        XCTAssertEqual(page.cursor, "t:t1")
        await harness.send(#"{"id":"2","type":"loadOlder","taskId":"A","cursor":"t:t1"}"#, on: phone)
        let older = try await phone.response("2")
        XCTAssertEqual(older.items?.map(\.turnId).first, "h1")
        XCTAssertEqual(older.hasOlder, false)
    }

    func testCommandsReachTheBridgeAndTheAuditLogKeepsNoText() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.send(#"{"id":"1","type":"sendMessage","taskId":"A","text":"  Secret plan: ship it  "}"#, on: phone)
        let awaited13 = try await phone.response("1").ok
        XCTAssertTrue(awaited13)
        await harness.send(#"{"id":"2","type":"answerApproval","taskId":"A","requestId":"toolu_1","answer":"deny"}"#, on: phone)
        let awaited14 = try await phone.response("2").ok
        XCTAssertTrue(awaited14)
        await harness.send(#"{"id":"3","type":"stopTurn","taskId":"A"}"#, on: phone)
        let awaited15 = try await phone.response("3").ok
        XCTAssertTrue(awaited15)
        await harness.send(#"{"id":"4","type":"markRead","taskId":"B"}"#, on: phone)
        let awaited16 = try await phone.response("4").ok
        XCTAssertTrue(awaited16)
        await harness.send(#"{"id":"5","type":"sendMessage","taskId":"A","text":"/clear"}"#, on: phone)
        let awaited17 = try await phone.response("5").error?.code
        XCTAssertEqual(awaited17, .unsupportedCommand)
        await harness.bridge.failNext(RemoteError(.notRunning))
        await harness.send(#"{"id":"6","type":"stopTurn","taskId":"B"}"#, on: phone)
        let awaited18 = try await phone.response("6").error?.code
        XCTAssertEqual(awaited18, .notRunning)

        let commands = await harness.bridge.commands
        XCTAssertEqual(commands, [
            .sendMessage(taskID: "A", text: "Secret plan: ship it"),
            .answerApproval(taskID: "A", requestID: "toolu_1", answer: .deny),
            .stopTurn(taskID: "A"),
            .markRead(taskID: "B"),
            .stopTurn(taskID: "B")
        ])
        let audit = harness.audit.entries().filter { $0.type != "pair" && $0.type != "hello" }
        XCTAssertEqual(audit.map(\.type), ["sendMessage", "answerApproval", "stopTurn", "markRead", "sendMessage", "stopTurn"])
        XCTAssertEqual(audit.map(\.result), ["ok", "ok", "ok", "ok", "unsupportedCommand", "notRunning"])
        XCTAssertEqual(audit.map(\.task), ["A", "A", "A", "B", "A", "B"])
        let log = try String(contentsOf: harness.auditURL, encoding: .utf8)
        XCTAssertFalse(log.contains("Secret"))
        XCTAssertFalse(log.contains("clear"))
    }

    func testCommandsAreRateLimited() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        for index in 0..<11 {
            await harness.send(#"{"id":"\#(index)","type":"markRead","taskId":"A"}"#, on: phone)
        }
        let awaited19 = try await phone.response("9").ok
        XCTAssertTrue(awaited19)
        let awaited20 = try await phone.response("10").error?.code
        XCTAssertEqual(awaited20, .rateLimited)
    }

    // MARK: - Files (§15.22)

    /// A phone reads a task's file only from the task's folders and outputs. A path outside them, a `..` that climbs out,
    /// a link that points out, a folder, a FIFO, a folder whose name only starts like the task's and a file that is not
    /// there all answer `notFound`, with no path in the answer. The audit log keeps, by the file's name only, every read
    /// of a listed task that does not go on from the part before it and every refusal, the same line once a minute.
    func testATasksFilesAreReadFromItsFoldersAndOutputsOnly() async throws {
        let files = try TaskFiles()
        defer { files.remove() }
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        var snapshot = FakeBridge.snapshot
        snapshot.taskFiles = true
        await harness.bridge.setSnapshot(snapshot)
        let gone = files.root + "/outside/gone.pdf"
        await harness.bridge.setFiles(files.scope, outputs: [RemoteOutput(path: files.summary, name: "summary.pdf", writtenAt: 1),
                                                             RemoteOutput(path: gone, name: "gone.pdf")], for: "A")
        let phone = try await harness.authenticatedPhone()
        var sent = 0
        func ask(_ type: String, _ fields: String = "") async throws -> RemoteResponse {
            sent += 1
            // Time enough for the rate limits to let each request through.
            clock.advance(by: 1)
            await harness.send(#"{"id":"r\#(sent)","type":"\#(type)"\#(fields)}"#, on: phone)
            return try await phone.response("r\(sent)")
        }
        func read(_ path: String, offset: Int = 0, task: String = "A") async throws -> RemoteResponse {
            try await ask("readFile", #","taskId":"\#(task)","path":"\#(path)","offset":\#(offset)"#)
        }

        let listed = try await ask("snapshot")
        XCTAssertEqual(listed.taskFiles, true)
        let outputs = try await ask("taskOutputs", #","taskId":"A""#)
        XCTAssertEqual(outputs.outputs, [RemoteOutput(path: files.summary, name: "summary.pdf", size: 9, writtenAt: 1),
                                         RemoteOutput(path: gone, name: "gone.pdf")], "A file that is gone has no size")
        let noTask = try await ask("taskOutputs", #","taskId":"Z""#)
        XCTAssertEqual(noTask.error?.code, .notFound)

        // In the task's folder by a relative path, through a link that stays in it, in the project's other folder, and
        // an output outside both.
        let notes = try await read("notes.txt")
        XCTAssertEqual(notes.data, Data("notes".utf8))
        XCTAssertEqual(notes.path, files.folder + "/notes.txt")
        XCTAssertEqual(notes.name, "notes.txt")
        XCTAssertEqual(notes.mediaType, "text/plain")
        XCTAssertEqual(notes.size, 5)
        XCTAssertEqual(notes.offset, 0)
        XCTAssertNotNil(notes.modifiedAt)
        let linked = try await read("latest.md")
        XCTAssertEqual(linked.path, files.folder + "/docs/report.md", "The path the Mac read")
        XCTAssertEqual(linked.name, "report.md")
        XCTAssertEqual(linked.mediaType, "text/markdown")
        let other = try await read(files.root + "/other/data.csv")
        XCTAssertEqual(other.mediaType, "text/csv")
        let output = try await read(files.summary)
        XCTAssertEqual(output.data, Data("%PDF-1.4\n".utf8))
        XCTAssertEqual(output.mediaType, "application/pdf")
        let rest = try await read("notes.txt", offset: 2)
        XCTAssertEqual(rest.data, Data("tes".utf8))
        XCTAssertEqual(rest.offset, 2)
        let past = try await read("notes.txt", offset: 6)
        XCTAssertEqual(past.error?.code, .badRequest)

        // Anything else answers as a file that is not there would, and says nothing of where it looked.
        let refused = ["../outside/secret.txt", files.root + "/outside/secret.txt", "escape.txt", "docs", "pipe", "missing.txt",
                       files.root + "/project2/x.txt", "docs/../../outside/secret.txt", "/etc/passwd"]
        for path in refused {
            let answer = try await read(path)
            XCTAssertEqual(answer.error?.code, .notFound, path)
            XCTAssertNil(answer.data, path)
            let message = try XCTUnwrap(answer.error?.message)
            XCTAssertFalse(message.contains("/") || message.contains("secret"), message)
        }
        let otherTask = try await read("notes.txt", task: "Z")
        XCTAssertEqual(otherTask.error?.code, .notFound)

        // A file read in parts is one line; a read that starts elsewhere than where the last one ended is another.
        let whole = Data(repeating: 7, count: RemoteProtocol.maxReadPartBytes + 10)
        try whole.write(to: URL(filePath: files.folder + "/build.bin"))
        let first = try await read("build.bin")
        let second = try await read("build.bin", offset: first.data?.count ?? 0)
        XCTAssertEqual((first.data ?? Data()) + (second.data ?? Data()), whole)
        try whole.write(to: URL(filePath: files.folder + "/skipped.bin"))
        let skipped = try await read("skipped.bin", offset: 1)
        XCTAssertEqual(skipped.offset, 1)
        XCTAssertEqual(skipped.data?.count, RemoteProtocol.maxReadPartBytes)

        let audit = harness.audit.entries().filter { $0.type == "readFile" }
        XCTAssertEqual(audit.map(\.file), ["notes.txt", "report.md", "data.csv", "summary.pdf", "notes.txt", "secret.txt",
                                           "escape.txt", "docs", "pipe", "missing.txt", "x.txt", "passwd", "build.bin",
                                           "skipped.bin"],
                       "By the file's name; the same refusal once; not for a task that is not there")
        XCTAssertEqual(audit.map(\.result), Array(repeating: "ok", count: 4) + ["badRequest"]
                       + Array(repeating: "notFound", count: 7) + ["ok", "ok"])
        XCTAssertTrue(audit.allSatisfy { $0.task == "A" && $0.device != nil })
        let log = try String(contentsOf: harness.auditURL, encoding: .utf8)
        XCTAssertFalse(log.contains("remote-files-") || log.contains("outside") || log.contains("project"), log)
    }

    /// A device's file reads carry at most 32 MiB at once and then 32 MiB per 10 s; past that a read answers
    /// `rateLimited` until the budget refills. The file is sparse, so nothing fills the disk.
    func testFileReadsHaveAByteBudgetPerDevice() async throws {
        let files = try TaskFiles()
        defer { files.remove() }
        let large = files.folder + "/large.mov"
        XCTAssertTrue(FileManager.default.createFile(atPath: large, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(filePath: large))
        try handle.truncate(atOffset: UInt64(RemoteProtocol.maxReadFileBytes))
        try handle.close()
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        await harness.bridge.setFiles(files.scope, outputs: [], for: "A")
        let phone = try await harness.authenticatedPhone()
        let parts = RemoteProtocol.readFileBudgetBytes / RemoteProtocol.maxReadPartBytes
        var offset = 0
        func next(_ id: Int) async throws -> RemoteResponse {
            await harness.send(#"{"id":"b\#(id)","type":"readFile","taskId":"A","path":"large.mov","offset":\#(offset)}"#, on: phone)
            let response = try await phone.response("b\(id)")
            offset += response.data?.count ?? 0
            return response
        }
        for index in 0..<parts {
            let part = try await next(index)
            XCTAssertEqual(part.data?.count, RemoteProtocol.maxReadPartBytes, "Part \(index)")
        }
        let over = try await next(parts)
        XCTAssertEqual(over.error?.code, .rateLimited)
        XCTAssertEqual(offset, RemoteProtocol.readFileBudgetBytes)
        clock.advance(by: RemoteProtocol.readFileBudgetWindow / 4)
        let refilled = try await next(parts + 1)
        XCTAssertEqual(refilled.data?.count, RemoteProtocol.maxReadPartBytes, "A quarter of the window refills 8 MiB")
    }

    /// A file is read in parts of at most 4 MiB that join into the whole file, up to 100 MiB; one byte more is too large.
    /// The large files are sparse, so nothing fills the disk.
    func testAFileIsReadInPartsUpTo100MiB() throws {
        let files = try TaskFiles()
        defer { files.remove() }
        let whole = Data((0..<(2 * RemoteProtocol.maxReadPartBytes + 1_234)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 12) })
        try whole.write(to: URL(filePath: files.folder + "/build.bin"))
        var joined = Data()
        var parts: [RemoteFilePart] = []
        while joined.count < whole.count {
            let part = try RemoteFileReader.read("build.bin", offset: joined.count, in: files.scope).get()
            XCTAssertLessThanOrEqual(part.data.count, RemoteProtocol.maxReadPartBytes)
            XCTAssertEqual(part.size, whole.count)
            parts.append(part)
            joined += part.data
        }
        XCTAssertEqual(joined, whole)
        XCTAssertEqual(parts.map(\.offset), [0, RemoteProtocol.maxReadPartBytes, 2 * RemoteProtocol.maxReadPartBytes])
        XCTAssertEqual(Set(parts.map(\.modifiedAt)).count, 1, "Unchanged between parts")
        XCTAssertEqual(parts.first?.mediaType, "application/octet-stream")
        XCTAssertEqual(try RemoteFileReader.read("build.bin", offset: whole.count, in: files.scope).get().data, Data())

        func sparse(_ name: String, size: Int) throws -> String {
            let path = files.folder + "/" + name
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
            let handle = try FileHandle(forWritingTo: URL(filePath: path))
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            return path
        }
        let largest = try RemoteFileReader.read(sparse("largest.mov", size: RemoteProtocol.maxReadFileBytes), offset: 0,
                                                in: files.scope).get()
        XCTAssertEqual(largest.size, RemoteProtocol.maxReadFileBytes)
        XCTAssertEqual(largest.data.count, RemoteProtocol.maxReadPartBytes)
        XCTAssertEqual(largest.mediaType, "video/quicktime")
        let over = try sparse("over.mov", size: RemoteProtocol.maxReadFileBytes + 1)
        guard case let .failure(error) = RemoteFileReader.read(over, offset: 0, in: files.scope) else { return XCTFail("Read") }
        XCTAssertEqual(error.code, .tooLarge)
    }

    /// A folder that is the person's home folder or holds it gives no files of its own; the task's outputs are still
    /// served, and so is another folder of the task's below it.
    func testAFolderHoldingTheHomeFolderServesOnlyOutputs() throws {
        let files = try TaskFiles()
        defer { files.remove() }
        let home = files.folder
        func code(_ path: String, in scope: RemoteFileScope) -> RemoteErrorCode? {
            guard case let .failure(error) = RemoteFileReader.read(path, offset: 0, in: scope, home: home) else { return nil }
            return error.code
        }
        XCTAssertEqual(code("notes.txt", in: files.scope), .notFound, "The home folder itself")
        XCTAssertNil(code(files.root + "/other/data.csv", in: files.scope), "Another folder, beside the home folder")
        let above = RemoteFileScope(folder: URL(filePath: files.root, directoryHint: .isDirectory),
                                    outputs: [URL(filePath: files.summary)])
        XCTAssertEqual(code("outside/secret.txt", in: above), .notFound, "A folder above the home folder")
        XCTAssertNil(code(files.summary, in: above), "An output")
        // A path a conversation writes from the home folder (`~/…`) is read from it, within the same folders.
        func fromHome(_ path: String) -> RemoteErrorCode? {
            guard case let .failure(error) = RemoteFileReader.read(path, offset: 0, in: files.scope, home: files.root) else { return nil }
            return error.code
        }
        XCTAssertNil(fromHome("~/other/data.csv"), "Another folder of the task's, under the home folder")
        XCTAssertEqual(fromHome("~/outside/secret.txt"), .notFound, "Under the home folder, outside the task's folders")
        XCTAssertTrue(RemoteFileReader.isInside("/a/b/c", "/a/b"))
        XCTAssertFalse(RemoteFileReader.isInside("/a/bc", "/a/b"), "Whole path components")
        XCTAssertFalse(RemoteFileReader.isInside("/a/caf\u{E9}/x", "/a/cafe\u{301}"), "Byte for byte, not as Swift's strings compare")
        // The same home folder by the data volume's path, which `realpath` keeps.
        let dataForm = "/System/Volumes/Data" + files.folder
        if FileManager.default.fileExists(atPath: dataForm) {
            let aliased = RemoteFileScope(folder: URL(filePath: dataForm, directoryHint: .isDirectory))
            XCTAssertEqual(code(dataForm + "/notes.txt", in: aliased), .notFound, "The home folder by another path")
        }
    }

    /// An output is the file the task wrote at its path, not what a link put there since points at, and its folder's
    /// links are followed: the answer names the folder as resolved.
    func testAnOutputIsReadInItsOwnPlaceOnly() throws {
        let files = try TaskFiles()
        defer { files.remove() }
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: files.root + "/linked", withDestinationPath: "outside")
        let viaLink = files.root + "/linked/summary.pdf"
        let swapped = files.root + "/outside/report.txt"
        try manager.createSymbolicLink(atPath: swapped, withDestinationPath: "secret.txt")
        let scope = RemoteFileScope(folder: URL(filePath: files.folder, directoryHint: .isDirectory),
                                    outputs: [URL(filePath: viaLink), URL(filePath: swapped)])
        let served = try RemoteFileReader.read(viaLink, offset: 0, in: scope).get()
        XCTAssertEqual(served.path, files.summary)
        guard case let .failure(error) = RemoteFileReader.read(swapped, offset: 0, in: scope) else { return XCTFail("A link was followed") }
        XCTAssertEqual(error.code, .notFound)
        XCTAssertEqual(RemoteFileReader.sized([RemoteOutput(path: viaLink, name: "summary.pdf"),
                                               RemoteOutput(path: swapped, name: "report.txt")]).map(\.size),
                       [9, nil], "Sizes follow no link in an output's place either")
    }

    // MARK: - Browser tabs (§15.25)

    /// A watched tab's frames: the first at once, the next only once the client acknowledged the last and the tab drew
    /// something new, and a picture like the last never again. Input reaches the watched tab only, and the audit log
    /// keeps its kind, never what was typed. Letting the tab go and closing the connection stop the frames and tell the
    /// bridge, so the tab stops painting. A tab's acknowledgements and input have a rate of their own.
    func testAWatchedTabsFramesWaitForTheirAcknowledgementAndStopWithTheWatch() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.send(#"{"id":"1","type":"watchTab","taskId":"A","maxWidth":640}"#, on: phone)
        let watching = try await phone.response("1")
        XCTAssertEqual(watching.tabId, "T1", "the panel's front tab when none is named")
        XCTAssertEqual(watching.tabs?.map(\.tabId), ["T1", "T2"])
        let watched = await harness.bridge.watchedTabs
        XCTAssertEqual(watched, [RemoteTabWatch(taskID: "A", tabID: "T1")])
        let first = try await phone.event(.tabFrame)
        XCTAssertEqual(first.frame, 1)
        XCTAssertEqual(first.image, Data("one".utf8))
        XCTAssertEqual(first.width, 640)
        XCTAssertEqual(first.viewportWidth, 1280)

        // Drawn again before the first frame was acknowledged: nothing more is looked at or sent.
        await harness.bridge.setPicture(Data("two".utf8))
        await harness.bridge.signal(.tabPainted(taskID: "A", tabID: "T1"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(phone.events(.tabFrame).count, 1)
        let capturedBeforeAck = await harness.bridge.captures
        XCTAssertEqual(capturedBeforeAck, 1)
        await harness.send(#"{"id":"2","type":"tabFrameAck","taskId":"A","tabId":"T1","frame":1}"#, on: phone)
        let second = try await phone.event(.tabFrame, after: first.seq ?? 0)
        XCTAssertEqual(second.frame, 2)
        XCTAssertEqual(second.image, Data("two".utf8))

        // The same picture drawn again many times goes once; the looks come less and less often.
        await harness.send(#"{"id":"3","type":"tabFrameAck","taskId":"A","tabId":"T1","frame":2}"#, on: phone)
        let bytesBefore = phone.sentBytes
        let looksBefore = await harness.bridge.captures
        let started = Date()
        for _ in 0..<20 {
            await harness.bridge.signal(.tabPainted(taskID: "A", tabID: "T1"))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(phone.events(.tabFrame).count, 2)
        // Once the picture stays, a look at most every idle interval (0.08 s here), after two shorter ones.
        let looks = await harness.bridge.captures - looksBefore
        XCTAssertLessThanOrEqual(looks, Int(Date().timeIntervalSince(started) / 0.08) + 3,
                                 "a tab drawing the same picture is not looked at on every draw")
        XCTAssertLessThan(looks, 20)
        XCTAssertLessThan(phone.sentBytes - bytesBefore, 2_000, "nothing but acknowledgements' answers went out")

        // Input reaches the watched tab only; a click needs its point.
        await harness.send(#"{"id":"4","type":"tabInput","taskId":"A","tabId":"T2","input":{"kind":"click","x":10,"y":10}}"#,
                           on: phone)
        let notWatched = try await phone.response("4").error?.code
        XCTAssertEqual(notWatched, .notAllowed)
        await harness.send(#"{"id":"5","type":"tabInput","taskId":"A","tabId":"T1","input":{"kind":"click"}}"#, on: phone)
        let pointless = try await phone.response("5").error?.code
        XCTAssertEqual(pointless, .badRequest)
        await harness.send(#"{"id":"6","type":"tabInput","taskId":"A","tabId":"T1","input":{"kind":"text","text":"hunter2-secret"}}"#,
                           on: phone)
        let typed = try await phone.response("6").ok
        XCTAssertTrue(typed)
        let inputs = await harness.bridge.tabInputs
        XCTAssertEqual(inputs, [.text("hunter2-secret")])
        let audit = harness.audit.entries().filter { $0.type == "tabInput" || $0.type == "watchTab" }
        XCTAssertEqual(audit.map(\.type), ["watchTab", "tabInput", "tabInput", "tabInput"])
        XCTAssertEqual(audit.map(\.input), [nil, "click", "click", "text"])
        XCTAssertEqual(audit.map(\.result), ["ok", "notAllowed", "badRequest", "ok"])
        let log = try String(contentsOf: harness.auditURL, encoding: .utf8)
        XCTAssertFalse(log.contains("hunter2"), "what was typed is never logged")

        // The list follows the task's tabs; a tab that closed has no more frames.
        await harness.bridge.setTabs([RemoteBrowserTab(tabId: "T2", title: "Docs", active: true)])
        await harness.bridge.signal(.browserTabs("A"))
        let changed = try await phone.event(.browserTabsChanged)
        XCTAssertEqual(changed.tabs?.map(\.tabId), ["T2"])
        try await waitUntilAsync { await harness.bridge.watchedTabs == [RemoteTabWatch(taskID: "A", tabID: nil)] }

        // A tab's acknowledgements do not use up the other requests' rate.
        for index in 0..<40 {
            await harness.send(#"{"id":"ack\#(index)","type":"tabFrameAck","taskId":"A","tabId":"T2","frame":9}"#, on: phone)
        }
        let lastAck = try await phone.response("ack39").ok
        XCTAssertTrue(lastAck)
        await harness.send(#"{"id":"7","type":"markRead","taskId":"B"}"#, on: phone)
        let marked = try await phone.response("7").ok
        XCTAssertTrue(marked)

        await harness.send(#"{"id":"8","type":"watchTab","taskId":"A","tabId":"T2"}"#, on: phone)
        _ = try await phone.response("8")
        try await waitUntilAsync { await harness.bridge.watchedTabs == [RemoteTabWatch(taskID: "A", tabID: "T2")] }
        await harness.send(#"{"id":"9","type":"unwatchTab","taskId":"A"}"#, on: phone)
        _ = try await phone.response("9")
        try await waitUntilAsync { await harness.bridge.watchedTabs.isEmpty }
        let framesBefore = phone.events(.tabFrame).count
        await harness.bridge.signal(.tabPainted(taskID: "A", tabID: "T2"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(phone.events(.tabFrame).count, framesBefore, "no frames once the tab is let go")

        // Watching the same tab again starts no frame its last one was not acknowledged for.
        await harness.bridge.setTabs([RemoteBrowserTab(tabId: "T2", title: "Docs", active: true)])
        await harness.bridge.setPicture(Data("three".utf8))
        await harness.send(#"{"id":"w1","type":"watchTab","taskId":"A","tabId":"T2"}"#, on: phone)
        _ = try await phone.response("w1")
        let third = try await phone.event(.tabFrame, after: second.seq ?? 0)
        await harness.bridge.setPicture(Data("four".utf8))
        for index in 0..<3 {
            await harness.send(#"{"id":"rw\#(index)","type":"watchTab","taskId":"A","tabId":"T2"}"#, on: phone)
            _ = try await phone.response("rw\(index)")
            await harness.bridge.signal(.tabPainted(taskID: "A", tabID: "T2"))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(phone.events(.tabFrame).last?.frame, third.frame, "no frame before the last is acknowledged")
        await harness.send(#"{"id":"a3","type":"tabFrameAck","taskId":"A","tabId":"T2","frame":\#(third.frame ?? 0)}"#, on: phone)
        let fourth = try await phone.event(.tabFrame, after: third.seq ?? 0)
        XCTAssertEqual(fourth.image, Data("four".utf8))
        await harness.send(#"{"id":"a4","type":"tabFrameAck","taskId":"A","tabId":"T2","frame":\#(fourth.frame ?? 0)}"#, on: phone)

        // Letting the tab go does not wait for the input under way, which then sends nothing more.
        await harness.bridge.setDelays(input: .seconds(2))
        let reached = await harness.bridge.tabInputs.count
        await harness.send(#"{"id":"slow","type":"tabInput","taskId":"A","tabId":"T2","input":{"kind":"text","text":"abc"}}"#,
                           on: phone)
        try await waitUntilAsync { await harness.bridge.tabInputs.count == reached + 1 }
        await harness.send(#"{"id":"stop","type":"unwatchTab","taskId":"A"}"#, on: phone)
        let stopped = try await phone.response("stop", timeout: 1).ok
        XCTAssertTrue(stopped, "answered while the input was still under way")
        _ = try await phone.response("slow")
        let permits = await harness.bridge.permitsAtEnd
        XCTAssertEqual(permits.count, reached + 1)
        XCTAssertEqual(permits.last, false, "the input saw its watch end")
        // Input that comes after the watch ended reaches nothing.
        await harness.bridge.setDelays()
        await harness.send(#"{"id":"after","type":"tabInput","taskId":"A","tabId":"T2","input":{"kind":"text","text":"x"}}"#,
                           on: phone)
        let after = try await phone.response("after").error?.code
        XCTAssertEqual(after, .notAllowed)
        let reachedAfter = await harness.bridge.tabInputs.count
        XCTAssertEqual(reachedAfter, reached + 1)

        // A phone's own size goes to the bridge with the watch; a size past the limits is refused.
        await harness.send(#"{"id":"vp","type":"watchTab","taskId":"A","tabId":"T2","viewport":{"width":390,"height":844,"mobile":true}}"#,
                           on: phone)
        _ = try await phone.response("vp")
        try await waitUntilAsync {
            await harness.bridge.watchedTabs == [RemoteTabWatch(taskID: "A", tabID: "T2",
                                                                viewport: RemoteTabViewport(width: 390, height: 844, mobile: true))]
        }
        await harness.send(#"{"id":"vp2","type":"watchTab","taskId":"A","viewport":{"width":5000,"height":844}}"#, on: phone)
        let tooWide = try await phone.response("vp2").error?.code
        XCTAssertEqual(tooWide, .badRequest)

        await harness.send(#"{"id":"10","type":"watchTab","taskId":"A","tabId":"T9"}"#, on: phone)
        let missing = try await phone.response("10").error?.code
        XCTAssertEqual(missing, .notFound)
        await harness.send(#"{"id":"11","type":"watchTab","taskId":"A","tabId":"T2"}"#, on: phone)
        _ = try await phone.response("11")
        try await waitUntilAsync { await !harness.bridge.watchedTabs.isEmpty }
        await harness.server.closed(try XCTUnwrap(phone.id))
        try await waitUntilAsync { await harness.bridge.watchedTabs.isEmpty }
        XCTAssertEqual(harness.audit.entries().filter { $0.type == "watchTab" && $0.task == "A" && $0.result == "ok" }.count, 1)
    }

    private func waitUntilAsync(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while await !condition() {
            guard Date() < deadline else { return XCTFail("Condition not met in time", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Input waiting behind a slow page is bounded per connection, and a device removed ends its input under way before
    /// its removal is saved (§15.25).
    func testWaitingInputIsBoundedAndARemovedDeviceEndsItsInput() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.send(#"{"id":"w","type":"watchTab","taskId":"A"}"#, on: phone)
        _ = try await phone.response("w")
        await harness.bridge.setDelays(input: .seconds(3))
        for index in 0...RemoteProtocol.maxPendingTabInputs {
            await harness.send(#"{"id":"i\#(index)","type":"tabInput","taskId":"A","tabId":"T1","input":{"kind":"click","x":1,"y":1}}"#,
                               on: phone)
        }
        let over = try await phone.response("i\(RemoteProtocol.maxPendingTabInputs)").error?.code
        XCTAssertEqual(over, .rateLimited, "past the input that may wait")
        try await waitUntilAsync { await harness.bridge.tabInputs.count == 1 }
        let devices = await harness.devices.all()
        let device = try XCTUnwrap(devices.first?.id)
        try await harness.server.revoke(device)
        try await waitUntilAsync { await harness.bridge.permitsAtEnd.count == 1 }
        let permits = await harness.bridge.permitsAtEnd
        XCTAssertEqual(permits, [false], "the removed device's input saw its watch end")
        let reached = await harness.bridge.tabInputs.count
        XCTAssertEqual(reached, 1, "nothing queued behind it went on")
    }

    /// Watching again while a look runs does not let the next look come sooner than the connection's pace (§15.25).
    func testWatchingAgainDoesNotSpeedUpTheLooks() async throws {
        let harness = try await ServerHarness { $0.tabFrameInterval = 0.5; $0.tabFrameIdleInterval = 1 }
        let phone = try await harness.authenticatedPhone()
        await harness.bridge.setDelays(capture: .milliseconds(200))
        await harness.send(#"{"id":"w0","type":"watchTab","taskId":"A","tabId":"T1"}"#, on: phone)
        _ = try await phone.response("w0")
        try await waitUntilAsync { await harness.bridge.captureStarts.count == 1 }
        // Watched again during the look, twice, with new pictures to send.
        for index in 1...2 {
            await harness.bridge.setPicture(Data("p\(index)".utf8))
            await harness.send(#"{"id":"w\#(index)","type":"watchTab","taskId":"A","tabId":"T2"}"#, on: phone)
            _ = try await phone.response("w\(index)")
        }
        try await waitUntilAsync { await harness.bridge.captureStarts.count >= 2 }
        let starts = await harness.bridge.captureStarts
        XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.45, "the next look waited for the pace")
    }

    /// A connection that sends faster than the Mac handles its requests is closed once it holds the most messages the Mac
    /// keeps for it, rather than queued without end (§7).
    func testAConnectionThatOutrunsTheMacIsClosed() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.bridge.setDelays(list: .seconds(2))
        await harness.send(#"{"id":"slow","type":"watchTab","taskId":"A"}"#, on: phone)
        for index in 0...RemoteProtocol.maxQueuedMessages {
            await harness.send(#"{"id":"p\#(index)","type":"ping"}"#, on: phone)
        }
        try await phone.waitUntilClosed(.rateLimited)
    }

    func testRemovingADeviceDisconnectsItAndEndsItsPairing() async throws {
        let harness = try await ServerHarness()
        let ticket = await harness.server.openPairing()
        let key = Data(RemoteRandom.bytes(32))
        let pairing = RemoteHandshakeHello(name: "Pixel", pair: RemoteEncoding.base64url(ticket.secret))
        let phone = TestChannel()
        guard case let .accepted(id, reply) = await harness.server.acceptHandshake(pairing, publicKey: key, channel: phone, path: .local) else {
            return XCTFail("The pairing was refused")
        }
        phone.id = id
        XCTAssertEqual(reply.paired, true)
        await harness.send(#"{"id":"1","type":"ping"}"#, on: phone)
        _ = try await phone.response("1")
        let deviceID = try XCTUnwrap(reply.deviceId)
        let connected = await harness.server.status.connectedDeviceIDs
        XCTAssertEqual(connected, [deviceID])

        try await harness.server.revoke(deviceID)
        _ = try await phone.event(.revoked)
        try await phone.waitUntilClosed(.revoked)
        let again = await harness.server.acceptHandshake(RemoteHandshakeHello(name: "Pixel"), publicKey: key, channel: TestChannel(), path: .local)
        guard case let .refused(refused, code) = again else { return XCTFail("A removed key connected") }
        XCTAssertEqual(refused.error?.code, .unknownDevice)
        XCTAssertEqual(code, .revoked)
        // Nor does the secret it spent pair the same key again.
        let repaired = await harness.server.acceptHandshake(pairing, publicKey: key, channel: TestChannel(), path: .local)
        guard case let .refused(stillRefused, _) = repaired else { return XCTFail("A removed key paired again") }
        XCTAssertEqual(stillRefused.error?.code, .pairingUnavailable)
    }

    func testTurningTheRemoteOffClosesEveryConnection() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.server.shutdown(reason: "disabled")
        let awaited23 = try await phone.event(.closing).reason
        XCTAssertEqual(awaited23, "disabled")
        try await phone.waitUntilClosed(.unavailable)
    }

    func testTooManyConnectionsAreTurnedAway() async throws {
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        // Unproven connections make room for a new one: the oldest closes.
        var waiting: [TestChannel] = []
        for _ in 0..<8 {
            waiting.append(try await harness.authenticatedPhone(proving: false))
            clock.advance(by: 1)
        }
        _ = try await harness.authenticatedPhone(proving: false)
        try await waiting[0].waitUntilClosed(.unavailable)
        XCTAssertFalse(waiting[1].isClosed)
        // Eight proven ones turn the next one away.
        for _ in 0..<8 { _ = try await harness.authenticatedPhone() }
        let key = Data(RemoteRandom.bytes(32))
        _ = await harness.devices.addSecure(name: "Ninth", publicKey: key, platform: nil)
        let ninth = await harness.server.acceptHandshake(RemoteHandshakeHello(name: "Ninth"), publicKey: key, channel: TestChannel(), path: .local)
        guard case let .refused(reply, code) = ninth else { return XCTFail("A ninth connection was taken") }
        XCTAssertEqual(reply.error?.code, .unavailable)
        XCTAssertEqual(code, .unavailable)
    }
}

// MARK: - Harness

/// A clock tests move by hand.
final class RemoteTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_792_158_000)

    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A channel the test reads: every text the server sent, and how it closed.
final class TestChannel: RemoteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var closeCode: RemoteCloseCode?
    var id: UUID?

    func send(_ text: String) { lock.withLock { texts.append(text) } }
    func close(_ code: RemoteCloseCode) { lock.withLock { if closeCode == nil { closeCode = code } } }

    var isClosed: Bool { lock.withLock { closeCode != nil } }

    func response(_ id: String, timeout: TimeInterval = testWaitLimitSeconds) async throws -> RemoteResponse {
        try await waitFor(timeout: timeout, "response \(id)") {
            self.decoded(RemoteResponse.self).first { $0.re == id }
        }
    }

    func event(_ name: RemoteEvent.Name, after seq: Int = 0,
               timeout: TimeInterval = testWaitLimitSeconds) async throws -> RemoteEvent {
        try await waitFor(timeout: timeout, "event \(name)") {
            self.decoded(RemoteEvent.self).first { $0.event == name && ($0.seq ?? 0) > seq }
        }
    }

    /// Every event of that name received so far, in order.
    func events(_ name: RemoteEvent.Name) -> [RemoteEvent] {
        decoded(RemoteEvent.self).filter { $0.event == name }
    }

    /// The bytes the server sent so far.
    var sentBytes: Int { lock.withLock { texts.reduce(0) { $0 + $1.utf8.count } } }

    func waitUntilClosed(_ code: RemoteCloseCode, timeout: TimeInterval = testWaitLimitSeconds) async throws {
        let closed = try await waitFor(timeout: timeout, "close") { self.lock.withLock { self.closeCode } }
        XCTAssertEqual(closed, code)
    }

    private func decoded<Value: Decodable>(_ type: Value.Type) -> [Value] {
        lock.withLock { texts }.compactMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)) }
    }

    private func waitFor<Value>(timeout: TimeInterval, _ what: String, _ read: () -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut(description: "Timed out waiting for \(what): \(lock.withLock { texts })")
    }

    struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }
}

actor FakeBridge: RemoteBridge {
    static let snapshot = RemoteSnapshot(
        projects: [RemoteProject(id: "P", name: "Yardlet", kind: .project)],
        tasks: [
            RemoteTask(id: "A", title: "Approve the migration", harness: "claude-code", harnessName: "Claude Code",
                       projectId: "P", attention: .active, indicator: .running, running: true, lastActivityAt: 2),
            RemoteTask(id: "B", title: "Fix the footer", harness: "codex", harnessName: "Codex",
                       projectId: "P", attention: .unread, indicator: .unread, unread: true, lastActivityAt: 1)
        ],
        newTask: RemoteNewTask(harness: "codex", harnessName: "Codex"))

    private var handler: (@Sendable (RemoteBridgeChange) -> Void)?
    private var current = FakeBridge.snapshot
    private var conversations: [String: RemoteConversation] = [:]
    private var fullConversations: [String: RemoteConversation] = [:]
    private var earlier: [String: RemoteConversation] = [:]
    private var nextFailure: RemoteError?
    private(set) var commands: [RemoteCommand] = []
    private(set) var watchedTasks: Set<String> = []
    private(set) var preparedTasks: [String] = []
    private(set) var createdTasks: [(projectID: String, text: String)] = []
    private var details: [String: RemoteItemDetail] = [:]
    private var fileScopes: [String: RemoteFileScope] = [:]
    private var outputs: [String: [RemoteOutput]] = [:]
    /// Task A's browser tabs (§15.25), the picture a capture returns, and what reached them.
    private var tabs: [RemoteBrowserTab] = [RemoteBrowserTab(tabId: "T1", title: "Sign in", active: true),
                                            RemoteBrowserTab(tabId: "T2", title: "Docs")]
    var picture = Data("one".utf8)
    private(set) var watchedTabs: Set<RemoteTabWatch> = []
    private(set) var captures = 0
    /// When each capture began, and how long one takes.
    private(set) var captureStarts: [Date] = []
    var captureDelay: Duration = .zero
    private(set) var tabInputs: [RemoteTabInput] = []
    /// How long an input takes, and whether its permit still held when it was done.
    var inputDelay: Duration = .zero
    private(set) var permitsAtEnd: [Bool] = []
    /// How long listing a task's tabs takes (holding the connection's requests up meanwhile).
    var listDelay: Duration = .zero

    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) { self.handler = handler }
    func snapshot() -> RemoteSnapshot { current }
    func conversation(of taskID: String) -> RemoteConversation? { conversations[taskID] }
    func conversation(of taskID: String, detail: RemoteConversationDetail) -> RemoteConversation? {
        detail == .full ? fullConversations[taskID] ?? conversations[taskID] : conversations[taskID]
    }
    func prepareConversation(of taskID: String) { preparedTasks.append(taskID) }
    func loadEarlierConversation(of taskID: String) {
        if let earlier = earlier.removeValue(forKey: taskID) { conversations[taskID] = earlier }
    }
    func setWatchedTasks(_ taskIDs: Set<String>) { watchedTasks = taskIDs }
    func perform(_ command: RemoteCommand) -> RemoteError? {
        commands.append(command)
        defer { nextFailure = nil }
        return nextFailure
    }

    func createTask(_ start: RemoteTaskStart) -> Result<String, RemoteError> {
        createdTasks.append((start.projectID, start.text))
        return .success("NEW-\(createdTasks.count)")
    }
    func itemDetail(taskID: String, itemID: String) -> Result<RemoteItemDetail, RemoteError> {
        details["\(taskID)/\(itemID)"].map { .success($0) } ?? .failure(RemoteError(.notFound))
    }

    /// Until a task is given files, the bridge answers no files at all (§15.22).
    func taskOutputs(taskID: String) -> Result<[RemoteOutput], RemoteError> {
        guard !fileScopes.isEmpty else { return .failure(RemoteError(.unavailable)) }
        return outputs[taskID].map { .success($0) } ?? .failure(RemoteError(.notFound))
    }
    func fileScope(taskID: String) -> Result<RemoteFileScope, RemoteError> {
        guard !fileScopes.isEmpty else { return .failure(RemoteError(.unavailable)) }
        return fileScopes[taskID].map { .success($0) } ?? .failure(RemoteError(.notFound))
    }

    func browserTabs(taskID: String) async -> Result<[RemoteBrowserTab], RemoteError> {
        if listDelay > .zero { try? await Task.sleep(for: listDelay) }
        return taskID == "A" ? .success(tabs) : taskID == "B" ? .success([]) : .failure(RemoteError(.notFound))
    }
    func setWatchedTabs(_ watches: Set<RemoteTabWatch>) { watchedTabs = watches }
    func captureTab(taskID: String, tabID: String, maxWidth: Int, maxHeight: Int) async -> Result<RemoteTabFrame, RemoteError> {
        captures += 1
        captureStarts.append(Date())
        if captureDelay > .zero { try? await Task.sleep(for: captureDelay) }
        return .success(RemoteTabFrame(image: picture, width: maxWidth, height: maxWidth / 2, viewportWidth: 1280,
                                       viewportHeight: 640))
    }
    func tabInput(taskID: String, tabID: String, input: RemoteTabInput, permit: RemoteTabPermit) async -> RemoteError? {
        tabInputs.append(input)
        if inputDelay > .zero { try? await Task.sleep(for: inputDelay) }
        permitsAtEnd.append(permit.isValid)
        return nil
    }
    func setDelays(input: Duration = .zero, list: Duration = .zero, capture: Duration = .zero) {
        inputDelay = input
        listDelay = list
        captureDelay = capture
    }
    func setTabs(_ tabs: [RemoteBrowserTab]) { self.tabs = tabs }
    func setPicture(_ picture: Data) { self.picture = picture }

    func setDetail(_ detail: RemoteItemDetail, task: String, item: String) { details["\(task)/\(item)"] = detail }
    func setFiles(_ scope: RemoteFileScope, outputs: [RemoteOutput], for taskID: String) {
        fileScopes[taskID] = scope
        self.outputs[taskID] = outputs
    }
    func setSnapshot(_ snapshot: RemoteSnapshot) { current = snapshot }
    func setConversation(_ conversation: RemoteConversation?, for taskID: String, detail: RemoteConversationDetail = .basic) {
        if detail == .full { fullConversations[taskID] = conversation } else { conversations[taskID] = conversation }
    }
    func setEarlier(_ conversation: RemoteConversation, for taskID: String) { earlier[taskID] = conversation }
    func failNext(_ error: RemoteError) { nextFailure = error }
    func signal(_ change: RemoteBridgeChange) { handler?(change) }
}

/// A task's folders on disk (§15.22): `project` is its folder, `other` the project's other folder and
/// `outside/summary.pdf` its output. Beside them: a secret, a folder whose name starts like the task's, a link out
/// and a FIFO.
struct TaskFiles {
    /// With every link resolved: the temporary folder is behind one (/var is /private/var).
    let root: String
    var folder: String { root + "/project" }
    var summary: String { root + "/outside/summary.pdf" }
    var scope: RemoteFileScope {
        RemoteFileScope(folder: URL(filePath: folder, directoryHint: .isDirectory),
                        otherFolders: [URL(filePath: root + "/other", directoryHint: .isDirectory)],
                        outputs: [URL(filePath: summary)])
    }

    init() throws {
        let made = FileManager.default.temporaryDirectory.appending(path: "remote-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = try XCTUnwrap(RemoteFileReader.realPath(made.path(percentEncoded: false)))
        for (path, text) in [("project/notes.txt", "notes"), ("project/docs/report.md", "# Report"), ("other/data.csv", "a,b\n1,2\n"),
                             ("outside/secret.txt", "secret"), ("outside/summary.pdf", "%PDF-1.4\n"), ("project2/x.txt", "beside")] {
            let url = URL(filePath: root + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createSymbolicLink(atPath: root + "/project/latest.md", withDestinationPath: "docs/report.md")
        try FileManager.default.createSymbolicLink(atPath: root + "/project/escape.txt", withDestinationPath: "../outside/secret.txt")
        XCTAssertEqual(mkfifo(root + "/project/pipe", 0o600), 0)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

struct ServerHarness {
    let server: RemoteServer
    let bridge = FakeBridge()
    let devices = RemoteDeviceStore(fileURL: nil)
    let audit: RemoteAuditLog
    let auditURL: URL

    /// `serving` puts another bridge (the fixture's) behind the server in place of `bridge`.
    init(clock: RemoteTestClock = RemoteTestClock(), serving other: (any RemoteBridge)? = nil,
         configure: (inout RemoteServer.Configuration) -> Void = { _ in }) async throws {
        auditURL = FileManager.default.temporaryDirectory.appending(path: "remote-server-\(UUID().uuidString)/audit.log")
        audit = RemoteAuditLog(fileURL: auditURL)
        var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Test Mac", appVersion: "test"))
        configuration.tasksInterval = .milliseconds(10)
        configuration.conversationInterval = .milliseconds(10)
        configuration.sweepInterval = .seconds(3600)
        configuration.olderWait = 2
        configuration.windowLimits = .init(maxTurns: 10)
        configuration.tabFrameInterval = 0.02
        configuration.tabFrameIdleInterval = 0.08
        configure(&configuration)
        server = RemoteServer(configuration: configuration, bridge: other ?? bridge, devices: devices, audit: audit,
                              now: { clock.now })
        await server.start()
    }

    func send(_ text: String, on channel: TestChannel) async {
        guard let id = channel.id else { return }
        await server.receive(Data(text.utf8), on: id)
    }

    /// A paired phone's connection, handed over as its handshake would. `proving` sends its first message,
    /// which makes the connection count as the device's.
    func authenticatedPhone(proving: Bool = true) async throws -> TestChannel {
        let key = Data(RemoteRandom.bytes(32))
        _ = await devices.addSecure(name: "Phone", publicKey: key, platform: nil)
        let phone = TestChannel()
        guard case let .accepted(id, _) = await server.acceptHandshake(RemoteHandshakeHello(name: "Phone"), publicKey: key,
                                                                      channel: phone, path: .local) else {
            throw TestChannel.TimedOut(description: "The handshake was refused")
        }
        phone.id = id
        if proving {
            await send(#"{"id":"proof","type":"ping"}"#, on: phone)
            _ = try await phone.response("proof")
        }
        return phone
    }
}

/// Records notifications from the server actor without imposing a delivery queue of its own.
final class PermissionEvents: @unchecked Sendable {
    struct Value: Equatable { var device: String; var permissions: RemoteDevicePermissions }
    private let lock = NSLock()
    private var recorded: [Value] = []
    var values: [Value] { lock.withLock { recorded } }
    func append(_ device: String, _ permissions: RemoteDevicePermissions) {
        lock.withLock { recorded.append(Value(device: device, permissions: permissions)) }
    }
}

private actor PermissionChangeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
