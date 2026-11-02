import Foundation
import XCTest
@testable import YardletRemote

/// The remote server over channels the test holds (no sockets, no Noise: a channel is handed over as its
/// handshake would hand it): connections that never prove themselves, removed devices and their pairing,
/// connection limits, devices paired with protocol 1 dropped from the file, snapshots and their change and
/// attention events, conversation pages and changes, and commands reaching the bridge with their audit
/// lines — never the message text.
final class RemoteServerTests: XCTestCase {
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

        await harness.server.revoke(deviceID)
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
    private var earlier: [String: RemoteConversation] = [:]
    private var nextFailure: RemoteError?
    private(set) var commands: [RemoteCommand] = []
    private(set) var watchedTasks: Set<String> = []
    private(set) var preparedTasks: [String] = []
    private(set) var createdTasks: [(projectID: String, text: String)] = []
    private var details: [String: RemoteItemDetail] = [:]
    private var fileScopes: [String: RemoteFileScope] = [:]
    private var outputs: [String: [RemoteOutput]] = [:]

    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) { self.handler = handler }
    func snapshot() -> RemoteSnapshot { current }
    func conversation(of taskID: String) -> RemoteConversation? { conversations[taskID] }
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

    func setDetail(_ detail: RemoteItemDetail, task: String, item: String) { details["\(task)/\(item)"] = detail }
    func setFiles(_ scope: RemoteFileScope, outputs: [RemoteOutput], for taskID: String) {
        fileScopes[taskID] = scope
        self.outputs[taskID] = outputs
    }
    func setSnapshot(_ snapshot: RemoteSnapshot) { current = snapshot }
    func setConversation(_ conversation: RemoteConversation?, for taskID: String) { conversations[taskID] = conversation }
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
    init(clock: RemoteTestClock = RemoteTestClock(), serving other: (any RemoteBridge)? = nil) async throws {
        auditURL = FileManager.default.temporaryDirectory.appending(path: "remote-server-\(UUID().uuidString)/audit.log")
        audit = RemoteAuditLog(fileURL: auditURL)
        var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Test Mac", appVersion: "test"))
        configuration.tasksInterval = .milliseconds(10)
        configuration.conversationInterval = .milliseconds(10)
        configuration.sweepInterval = .seconds(3600)
        configuration.olderWait = 2
        configuration.windowLimits = .init(maxTurns: 10)
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
