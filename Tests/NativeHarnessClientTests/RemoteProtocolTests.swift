import Foundation
import XCTest
@testable import YardletRemote

/// The phone remote's wire contract (docs/REMOTE_PROTOCOL.md) without a connection: requests decode
/// and encode back the same, responses and events are the documented JSON, devices are kept by their
/// public keys in a file only the person reads, Tailscale and LAN addresses are told apart, and a
/// conversation window pages whole turns and describes updates as changes a client can apply.
final class RemoteProtocolTests: XCTestCase {
    // MARK: - Requests

    func testEveryRequestDecodesWhatItEncodes() throws {
        let requests: [RemoteRequest] = [
            .snapshot,
            .subscribeTask(taskID: "T1"),
            .loadOlder(taskID: "T1", cursor: "t:turn-3"),
            .unsubscribeTask(taskID: "T1"),
            .ping,
            .sendMessage(taskID: "T1", text: "Run the tests again"),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .allowOnce),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .deny),
            .stopTurn(taskID: "T1"),
            .markRead(taskID: "T1"),
            .answerQuestion(taskID: "T1", requestID: "q", answers: [RemoteQuestionAnswer(questionId: "a", options: ["Grid"]),
                                                                     RemoteQuestionAnswer(questionId: "b", skipped: true)]),
            .reviewPlan(taskID: "T1", requestID: "p", decision: .keepPlanning, reason: "Smaller steps"),
            .createTask(RemoteTaskStart(projectID: "P", text: "Add a toggle")),
            .createTask(RemoteTaskStart(projectID: "P", text: "", harness: "codex", settings: ["model": "gpt-6"], worktree: true,
                                        images: [RemoteImage(type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))])),
            .sendMessage(taskID: "T1", text: "Like this", images: [RemoteImage(type: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))],
                         followUp: .queue),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .allowForSession),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .deny, note: "Run only the unit tests"),
            .newTaskOptions(projectID: "P", harness: nil),
            .newTaskOptions(projectID: "P", harness: "antigravity-cli", settings: ["model": "gemini-3-pro"]),
            .limitAccounts(taskID: "T1"),
            .continueWithAccount(taskID: "T1", accountID: "conn-2"),
            .setAutoContinue(taskID: "T1", enabled: true),
            .actOnQueued(taskID: "T1", itemID: "queued:1", action: .stopAndSend),
            .answerHandoff(taskID: "T1", requestID: "h", answer: .decline),
            .chooseAnswer(taskID: "T1", requestID: "r", choice: "1"),
            .chooseAnswer(taskID: "T1", requestID: "r", choice: "0", note: "Not now",
                          values: ["repo": .text("acme/web"), "private": .flag(true), "count": .number(3), "teams": .list(["web"])]),
            .uploadFile(RemoteUploadPart(uploadID: "6F9619FF-8B86-D011-B42D-00C04FC964FF", name: "a.pdf", mediaType: "application/pdf",
                                         size: 3, offset: 0, data: Data([1, 2, 3]))),
            .sendMessage(taskID: "T1", text: "", files: ["6F9619FF-8B86-D011-B42D-00C04FC964FF"]),
            .registerPush(provider: "fcm", token: "t"),
            .unregisterPush,
            .forgetDevice,
            .itemDetail(taskID: "T1", itemID: "i:1"),
            .actOnSuggestion(taskID: "T1", suggestionID: "task_1", action: .start),
            .setPinned(taskID: "T1", pinned: false),
            .archiveTask(taskID: "T1"),
            .answerLink(requestID: "L", approve: true),
            .revealLink(nonce: Data(repeating: 9, count: 32)),
            .scheduledTasks,
            .runScheduledTask(scheduleID: "S"),
            .setScheduledTaskEnabled(scheduleID: "S", enabled: false),
            .taskOutputs(taskID: "T1"),
            .readFile(taskID: "T1", path: "reports/crash-notes.txt", offset: 4_194_304)
        ]
        for (index, request) in requests.enumerated() {
            let envelope = RemoteRequestEnvelope(id: "\(index)", request: request)
            XCTAssertEqual(try RemoteRequestEnvelope.decode(envelope.encoded()).get(), envelope, "\(request)")
        }
    }

    func testTheDocumentedRequestsDecode() throws {
        let markRead = try decode(#"{"id": "17", "type": "markRead", "taskId": "4C1F"}"#)
        XCTAssertEqual(markRead, RemoteRequestEnvelope(id: "17", request: .markRead(taskID: "4C1F")))
        let answer = try decode(#"{"id":"8","type":"answerApproval","taskId":"T","requestId":"toolu_01","answer":"allowOnce","extra":true}"#)
        XCTAssertEqual(answer.request, .answerApproval(taskID: "T", requestID: "toolu_01", answer: .allowOnce))
        let reveal = try decode(#"{"id":"1","type":"revealLink","nonce":"\#(RemoteEncoding.base64url(Data(repeating: 1, count: 32)))"}"#)
        XCTAssertEqual(reveal.request, .revealLink(nonce: Data(repeating: 1, count: 32)))

        // §15.21's requests decode as written and encode back to the same JSON.
        let schedules: [(String, RemoteRequest)] = [
            (#"{"id": "31", "type": "scheduledTasks"}"#, .scheduledTasks),
            (#"{"id": "32", "type": "runScheduledTask", "scheduleId": "6B0E…"}"#, .runScheduledTask(scheduleID: "6B0E…")),
            (#"{"id": "33", "type": "setScheduledTaskEnabled", "scheduleId": "6B0E…", "enabled": false}"#,
             .setScheduledTaskEnabled(scheduleID: "6B0E…", enabled: false))
        ]
        for (json, request) in schedules {
            let envelope = try decode(json)
            XCTAssertEqual(envelope.request, request)
            XCTAssertTrue(envelope.request.isCommand == (request != .scheduledTasks), json)
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.encoded()) as? NSDictionary)
            XCTAssertEqual(written, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary))
        }
        XCTAssertEqual(try? RemoteRequestEnvelope.decode(Data(#"{"id":"34","type":"setScheduledTaskEnabled","scheduleId":"S"}"#.utf8)).get(),
                       nil, "enabled is required")
    }

    func testTheDocumentedScheduleListDecodes() throws {
        let json = #"""
        {"re": "31", "ok": true, "schedules": [
          {"id": "6B0E…", "name": "Morning check", "when": "Every day at 9:00 AM", "enabled": true, "running": false,
           "nextRunAt": 1792200000000, "status": "Next run tomorrow at 9:00 AM", "projectName": "acme-web",
           "harnessName": "Codex",
           "lastRun": {"at": 1792158000000, "outcome": "started", "taskId": "4C1F…", "line": "Last run today at 9:00 AM"}}]}
        """#
        let response = try JSONDecoder().decode(RemoteResponse.self, from: Data(json.utf8))
        let schedule = try XCTUnwrap(response.schedules?.first)
        XCTAssertEqual(schedule, RemoteSchedule(
            id: "6B0E…", name: "Morning check", when: "Every day at 9:00 AM", enabled: true, running: false,
            nextRunAt: 1_792_200_000_000, status: "Next run tomorrow at 9:00 AM", projectName: "acme-web", harnessName: "Codex",
            lastRun: RemoteSchedule.Run(at: 1_792_158_000_000, outcome: .started, taskId: "4C1F…", line: "Last run today at 9:00 AM")))
        // Written back, it is the same JSON.
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteJSON.encoder.encode(response)) as? NSDictionary)
        XCTAssertEqual(written, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary))
        // An outcome a later Mac adds reads as a failure.
        let later = try JSONDecoder().decode(RemoteSchedule.Run.self, from: Data(#"{"at": 1, "outcome": "deferred", "line": "x"}"#.utf8))
        XCTAssertEqual(later.outcome, .failed)
    }

    /// §15.22 as the contract writes it: both requests read and write back the same JSON and are not commands, and both
    /// answers decode and encode back the same, the part's bytes as base64.
    func testTheDocumentedTaskFilesDecode() throws {
        let requests: [(String, RemoteRequest)] = [
            (#"{"id": "34", "type": "taskOutputs", "taskId": "4C1F…"}"#, .taskOutputs(taskID: "4C1F…")),
            (#"{"id": "35", "type": "readFile", "taskId": "4C1F…", "path": "/Users/example/Desktop/report.pdf", "offset": 0}"#,
             .readFile(taskID: "4C1F…", path: "/Users/example/Desktop/report.pdf", offset: 0))
        ]
        for (json, request) in requests {
            let envelope = try decode(json)
            XCTAssertEqual(envelope.request, request)
            XCTAssertFalse(envelope.request.isCommand, json)
            XCTAssertEqual(envelope.request.taskID, "4C1F…")
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.encoded()) as? NSDictionary)
            XCTAssertEqual(written, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary))
        }
        for json in [#"{"id":"36","type":"readFile","taskId":"T","offset":0}"#,
                     #"{"id":"37","type":"readFile","taskId":"T","path":"","offset":0}"#,
                     #"{"id":"38","type":"readFile","taskId":"T","path":"a.txt"}"#,
                     #"{"id":"39","type":"readFile","taskId":"T","path":"a.txt","offset":-1}"#,
                     #"{"id":"40","type":"taskOutputs"}"#] {
            guard case let .failure(failure) = RemoteRequestEnvelope.decode(Data(json.utf8)) else { return XCTFail(json) }
            XCTAssertEqual(failure.error.code, .badRequest, json)
        }

        let outputs = #"""
        {"re": "34", "ok": true, "outputs": [
          {"path": "/Users/example/Desktop/report.pdf", "name": "report.pdf", "size": 482113, "writtenAt": 1792158000000}]}
        """#
        let listing = try JSONDecoder().decode(RemoteResponse.self, from: Data(outputs.utf8))
        XCTAssertEqual(listing.outputs, [RemoteOutput(path: "/Users/example/Desktop/report.pdf", name: "report.pdf",
                                                      size: 482_113, writtenAt: 1_792_158_000_000)])
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteJSON.encoder.encode(listing)) as? NSDictionary)
        XCTAssertEqual(listed, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(outputs.utf8)) as? NSDictionary))

        // The contract's placeholder stands for the part's bytes in base64.
        let bytes = Data("%PDF-1.4\n".utf8)
        let part = #"""
        {"re": "35", "ok": true, "path": "/Users/example/Desktop/report.pdf", "name": "report.pdf",
         "mediaType": "application/pdf", "size": 482113, "offset": 0, "data": "<base64 of up to 4 MiB>",
         "modifiedAt": 1792158000000}
        """#.replacingOccurrences(of: "<base64 of up to 4 MiB>", with: bytes.base64EncodedString())
        let read = try JSONDecoder().decode(RemoteResponse.self, from: Data(part.utf8))
        XCTAssertEqual(read.path, "/Users/example/Desktop/report.pdf")
        XCTAssertEqual(read.name, "report.pdf")
        XCTAssertEqual(read.mediaType, "application/pdf")
        XCTAssertEqual(read.size, 482_113)
        XCTAssertEqual(read.offset, 0)
        XCTAssertEqual(read.data, bytes)
        XCTAssertEqual(read.modifiedAt, 1_792_158_000_000)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteJSON.encoder.encode(read)) as? NSDictionary)
        XCTAssertEqual(written, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(part.utf8)) as? NSDictionary))
    }

    func testRequestsThatCannotBeReadSayWhy() {
        func failure(_ json: String) -> RemoteRequestEnvelope.DecodingFailure? {
            guard case let .failure(failure) = RemoteRequestEnvelope.decode(Data(json.utf8)) else { return nil }
            return failure
        }
        XCTAssertEqual(failure("[1, 2]")?.error.code, .badRequest)
        XCTAssertEqual(failure("not json")?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"type":"snapshot"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":"3","type":"launchMissiles"}"#), .init(id: "3", error: RemoteError(.unknownType, "Unknown type launchMissiles")))
        XCTAssertEqual(failure(#"{"id":"4","type":"markRead"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":"5","type":"answerApproval","taskId":"T","requestId":"r","answer":"allowAlways"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":6,"type":"ping"}"#)?.error.code, .badRequest)
        // Protocol 1's requests are gone.
        XCTAssertEqual(failure(#"{"id":"7","type":"hello","token":"x"}"#), .init(id: "7", error: RemoteError(.unknownType, "Unknown type hello")))
        XCTAssertEqual(failure(#"{"id":"8","type":"revealLink","nonce":"AAAA"}"#)?.error.code, .badRequest)
    }

    // MARK: - Responses and events

    func testResponsesAndEventsAreTheDocumentedJSON() throws {
        XCTAssertEqual(RemoteJSON.string(RemoteResponse(re: "17")), #"{"ok":true,"re":"17"}"#)
        XCTAssertEqual(RemoteJSON.string(RemoteResponse.failure("18", RemoteError(.notFound, "No task"))),
                       #"{"error":{"code":"notFound","message":"No task"},"ok":false,"re":"18"}"#)
        var event = RemoteEvent(.conversation)
        event.seq = 5
        event.taskId = "T"
        var item = RemoteItem(id: "i:91AA", turnId: "3F2A", kind: .assistant)
        item.role = "answer"
        item.text = "All **12** tests pass."
        item.streaming = true
        event.changes = [.remove("req:toolu_01"), .upsert(item, after: "i:5D0C")]
        XCTAssertEqual(RemoteJSON.string(event), #"{"changes":[{"id":"req:toolu_01","op":"remove"},{"after":"i:5D0C","item":{"id":"i:91AA","kind":"assistant","role":"answer","streaming":true,"text":"All **12** tests pass.","turnId":"3F2A"},"op":"upsert"}],"event":"conversation","seq":5,"taskId":"T"}"#)

        let task = RemoteTask(id: "T", title: "Approve", harness: "claude-code", harnessName: "Claude Code", projectId: "P",
                              attention: .waiting, indicator: .awaitingApproval, pendingRequest: .approval,
                              running: true, lastActivityAt: 1_792_158_000_000, parentTaskId: "Q")
        var snapshot = RemoteResponse(re: "2")
        snapshot.projects = [RemoteProject(id: "chats", name: "Chats", kind: .chats)]
        snapshot.tasks = [task]
        let data = try RemoteJSON.encoder.encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(RemoteResponse.self, from: data), snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap((object["tasks"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["attention"] as? String, "waiting")
        XCTAssertEqual(first["indicator"] as? String, "awaitingApproval")
        XCTAssertEqual(first["lastActivityAt"] as? Int64, 1_792_158_000_000)
        XCTAssertEqual(first["unread"] as? Bool, false)
    }

    func testEveryErrorCodeIsDocumented() throws {
        let document = try String(contentsOf: Self.protocolDocument, encoding: .utf8)
        for code in RemoteErrorCode.allCases {
            XCTAssertTrue(document.contains("| `\(code.rawValue)` |"), "\(code.rawValue) is missing from the error table")
        }
        for name in ["tasksChanged", "attention", "conversation", "conversationReset", "conversationEnded", "revoked", "closing",
                     "linked", "linkRefused", "linkRequest", "linkResolved", "schedulesChanged"] {
            XCTAssertTrue(document.contains("\"event\": \"\(name)\""), name)
        }
        XCTAssertTrue(document.contains("port **\(RemoteProtocol.securePort)**"))
        XCTAssertTrue(document.contains("prologue the 16 ASCII bytes `\(String(decoding: RemoteNoise.prologue, as: UTF8.self))`"))
    }

    // MARK: - Pairing

    func testDevicesAreKeptByPublicKeyInAFileOnlyThePersonReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-devices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "devices.json")
        let store = RemoteDeviceStore(fileURL: file)
        let key = Data(repeating: 4, count: 32)
        let device = await store.addSecure(name: "Pixel 9", publicKey: key, platform: "android")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let reopened = RemoteDeviceStore(fileURL: file)
        let known = await reopened.authenticate(publicKey: key, name: nil)
        XCTAssertEqual(known?.id, device.id)
        let stranger = await reopened.authenticate(publicKey: Data(repeating: 5, count: 32), name: nil)
        XCTAssertNil(stranger)
        await reopened.remove(device.id)
        let removed = await reopened.authenticate(publicKey: key, name: nil)
        XCTAssertNil(removed)
    }

    // MARK: - Addresses

    func testTailscaleAndLANAddressesAreToldApart() {
        XCTAssertTrue(RemoteAddressSelection.isTailscale("100.64.0.0"))
        XCTAssertTrue(RemoteAddressSelection.isTailscale("100.127.255.255"))
        XCTAssertTrue(RemoteAddressSelection.isTailscale("fd7a:115c:a1e0::1234"))
        // Outside Tailscale's ranges: CGNAT's neighbours, another ULA, a malformed address.
        XCTAssertFalse(RemoteAddressSelection.isTailscale("100.128.0.1"))
        XCTAssertFalse(RemoteAddressSelection.isTailscale("100.63.255.255"))
        XCTAssertFalse(RemoteAddressSelection.isTailscale("fd7a:115c:a1e1::1"))
        XCTAssertFalse(RemoteAddressSelection.isTailscale("100.100.100.100.1"))
        XCTAssertTrue(RemoteAddressSelection.isPrivateLAN("192.168.0.12"))
        XCTAssertTrue(RemoteAddressSelection.isPrivateLAN("10.0.0.4"))
        XCTAssertFalse(RemoteAddressSelection.isPrivateLAN("100.64.12.34"))
    }

    func testTheSystemInterfacesIncludeLoopback() {
        // Reads only; nothing binds.
        XCTAssertTrue(RemoteAddressSelection.systemInterfaces().contains { $0.address == "127.0.0.1" })
    }

    // MARK: - Messages and limits

    func testAFilesNameKeepsNoPathAndNoHiddenStart() {
        XCTAssertEqual(RemoteUploadStore.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(RemoteUploadStore.safeName("C:\\Users\\me\\..\\report.pdf"), "report.pdf")
        XCTAssertEqual(RemoteUploadStore.safeName(".zshrc"), "zshrc")
        XCTAssertEqual(RemoteUploadStore.safeName("a:b\u{0007}.txt"), "ab.txt")
        XCTAssertEqual(RemoteUploadStore.safeName("..."), "file")
        let long = RemoteUploadStore.safeName(String(repeating: "x", count: 200) + ".pdf")
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        let combining = RemoteUploadStore.safeName("e" + String(repeating: "\u{0301}", count: 1_000) + ".txt")
        XCTAssertLessThanOrEqual(combining.utf8.count, 200, "A file system name holds 255 bytes")
        XCTAssertTrue(combining.hasSuffix(".txt"))
    }

    func testAnUploadIDIsNeverReusedAndWhatNoMessageTookGoesAtTheNextStart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "remote-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = RemoteUploadStore(directory: directory)
        let now = Date()
        let taken = UUID().uuidString, left = UUID().uuidString
        for id in [taken, left] {
            XCTAssertEqual(try store.receive(RemoteUploadPart(uploadID: id, name: "a.txt", size: 2, offset: 0, data: Data("hi".utf8)),
                                             from: "phone", now: now).get(), 2)
        }
        let file = try store.files([taken], from: "phone").get()[0]
        XCTAssertEqual(store.files([taken], from: "other").map { _ in true }, .failure(RemoteError(.notFound, "An upload is not finished or has expired")))
        store.release([taken])
        // The same ID again, from any device, is refused and leaves the taken file alone.
        let reuse = store.receive(RemoteUploadPart(uploadID: taken, name: "a.txt", size: 2, offset: 0, data: Data("no".utf8)),
                                  from: "other", now: now)
        XCTAssertEqual((try? reuse.get()), nil)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "hi")
        // A new run keeps what a message took and removes the rest.
        _ = RemoteUploadStore(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: left).path))
    }

    func testMessagesTheMacWouldNotSendAreRefused() {
        XCTAssertEqual(RemoteServer.validateMessage("   ")?.code, .emptyMessage)
        XCTAssertEqual(RemoteServer.validateMessage(String(repeating: "a", count: 32_001))?.code, .tooLarge)
        XCTAssertEqual(RemoteServer.validateMessage("/clear")?.code, .unsupportedCommand)
        XCTAssertEqual(RemoteServer.validateMessage("  /model gpt-5 ")?.code, .unsupportedCommand)
        XCTAssertEqual(RemoteServer.validateMessage("/review:pr 12")?.code, .unsupportedCommand)
        XCTAssertNil(RemoteServer.validateMessage("/Users/me/project/README.md is outdated"))
        XCTAssertNil(RemoteServer.validateMessage("Run the tests again"))
        XCTAssertNil(RemoteServer.validateMessage("/ alone"))
    }

    func testRatesRefillAndCommandsHaveTheirOwnBucket() {
        let start = Date(timeIntervalSince1970: 0)
        var limiter = RemoteRateLimiter(now: start)
        for _ in 0..<10 { XCTAssertTrue(limiter.admit(isCommand: true, now: start)) }
        XCTAssertFalse(limiter.admit(isCommand: true, now: start))
        XCTAssertTrue(limiter.admit(isCommand: false, now: start))
        XCTAssertTrue(limiter.admit(isCommand: true, now: start.addingTimeInterval(3.1)))
        var reads = RemoteRateLimiter(now: start)
        for _ in 0..<30 { XCTAssertTrue(reads.admit(isCommand: false, now: start)) }
        XCTAssertFalse(reads.admit(isCommand: false, now: start))
        XCTAssertEqual(reads.refusedInARow, 1)
        XCTAssertTrue(reads.admit(isCommand: false, now: start.addingTimeInterval(0.2)))
        XCTAssertEqual(reads.refusedInARow, 0)
    }

    func testTheAuditLogKeepsTypesAndTasksAndTrims() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "remote-audit-\(UUID().uuidString)/audit.log")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = RemoteAuditLog(fileURL: file, keptLines: 8)
        for index in 0..<30 { log.record(device: "D", type: "markRead", task: "T\(index)", result: "ok") }
        let entries = log.entries()
        XCTAssertLessThanOrEqual(entries.count, 10)
        XCTAssertEqual(entries.last?.task, "T29")
        XCTAssertEqual(entries.last?.type, "markRead")
    }

    // MARK: - Summaries

    func testASummaryIsOneShortLineWithSecretsMasked() {
        XCTAssertEqual(RemoteSummary.line(["Bash", "Run the migration tests"]), "Bash: Run the migration tests")
        XCTAssertEqual(RemoteSummary.line(["Question", nil, "Which layout?\nGrid or list"]), "Question: Which layout?")
        XCTAssertEqual(RemoteSummary.line(["Bash", "Bash"]), "Bash")
        XCTAssertNil(RemoteSummary.line([nil, "  "]))
        let long = RemoteSummary.line(["Bash", String(repeating: "echo hello ", count: 40)])
        XCTAssertEqual(long?.count, RemoteSummary.limit)
        XCTAssertEqual(long?.last, "…")

        let masked = RemoteSummary.line(["Bash", #"curl -H "Authorization: Bearer sk-live-4f9a8b7c6d5e" https://deploy:hunter2@example.test/api"#])
        XCTAssertNotNil(masked)
        XCTAssertFalse(masked!.contains("sk-live-4f9a8b7c6d5e"), masked!)
        XCTAssertFalse(masked!.contains("hunter2"), masked!)
        let assignments = RemoteSummary.masked("export GITHUB_TOKEN=ghp_abc123 API_KEY: \"s3cr3t\" --password hunter2 ls")
        XCTAssertFalse(assignments.contains("ghp_abc123") || assignments.contains("s3cr3t") || assignments.contains("hunter2"), assignments)
        XCTAssertTrue(assignments.hasSuffix("ls"))
        XCTAssertEqual(RemoteSummary.masked("key 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddcc"), "key •••")
        XCTAssertEqual(RemoteSummary.masked("swift test --filter RemoteServerTests"), "swift test --filter RemoteServerTests")
        XCTAssertEqual(RemoteSummary.masked("cat /Users/me/project2/Sources/Remote/RemoteServer.swift"),
                       "cat /Users/me/project2/Sources/Remote/RemoteServer.swift")
    }

    // MARK: - Conversation window

    func testAPageIsWholeTurnsFromTheLatestAndOlderPagesComeBefore() {
        let conversation = RemoteConversation(turns: (1...25).map { Self.turn("t\($0)", items: 3) })
        var window = RemoteConversationWindow(limits: .init(maxTurns: 10, maxItems: 1_000))
        let page = window.open(conversation)
        XCTAssertEqual(Set(page.items.map(\.turnId)).count, 10)
        XCTAssertEqual(page.items.first?.turnId, "t16")
        XCTAssertEqual(page.items.last?.turnId, "t25")
        XCTAssertEqual(page.cursor, "t:t16")
        XCTAssertTrue(page.hasOlder)

        guard case let .page(older) = window.older("t:t16", in: conversation) else { return XCTFail() }
        XCTAssertEqual(older.items.first?.turnId, "t6")
        XCTAssertEqual(older.items.last?.turnId, "t15")
        guard case let .page(oldest) = window.older("t:t6", in: conversation) else { return XCTFail() }
        XCTAssertEqual(oldest.items.first?.turnId, "t1")
        XCTAssertFalse(oldest.hasOlder)
        XCTAssertNil(oldest.cursor)
        XCTAssertEqual(window.older("t:t16", in: conversation), .invalidCursor)
        XCTAssertEqual(window.sent.count, 75)
    }

    func testAPageStopsAtItsItemLimitButKeepsOneTurnWhole() {
        let conversation = RemoteConversation(turns: [Self.turn("a", items: 5), Self.turn("b", items: 300)], hasEarlier: true)
        var window = RemoteConversationWindow(limits: .init(maxTurns: 10, maxItems: 120))
        let page = window.open(conversation)
        XCTAssertEqual(page.items.count, 300)
        XCTAssertEqual(page.cursor, "t:b")
        guard case let .page(older) = window.older("t:b", in: conversation) else { return XCTFail() }
        XCTAssertEqual(older.items.count, 5)
        XCTAssertTrue(older.hasOlder)
        XCTAssertEqual(window.older("t:a", in: conversation), .needsProvider)
    }

    func testUpdatesAreChangesThatReproduceTheConversation() throws {
        var turns = (1...4).map { Self.turn("t\($0)", items: 3) }
        var window = RemoteConversationWindow()
        var client = window.open(RemoteConversation(turns: turns)).items

        // Streaming: an item changes in place, a new one arrives, a request moves into the work.
        turns[3].items[1].text = "streamed further"
        var answer = RemoteItem(id: "i:t4-answer", turnId: "t4", kind: .assistant)
        answer.text = "Done"
        turns[3].items.append(answer)
        let moved = turns[3].items.remove(at: 2)
        turns[3].items.insert(moved, at: 0)
        turns.append(Self.turn("t5", items: 2))
        guard case let .changes(changes) = window.update(RemoteConversation(turns: turns)) else { return XCTFail() }
        client = Self.strictlyApplying(changes, to: client)
        XCTAssertEqual(client, turns.flatMap(\.items))
        XCTAssertTrue(changes.contains { $0.op == .upsert && $0.item?.id == "i:t4-1" && $0.after == "i:t4-0" })

        XCTAssertEqual(window.update(RemoteConversation(turns: turns)), .unchanged)

        // An item goes away.
        turns[1].items.remove(at: 1)
        guard case let .changes(removal) = window.update(RemoteConversation(turns: turns)) else { return XCTFail() }
        XCTAssertEqual(removal, [.remove("i:t2-1")])
        client = client.applying(removal)
        XCTAssertEqual(client, turns.flatMap(\.items))
    }

    func testAWindowWhoseStartIsGoneIsSentAgainWhole() {
        let turns = (1...3).map { Self.turn("t\($0)", items: 2) }
        var window = RemoteConversationWindow()
        _ = window.open(RemoteConversation(turns: turns))
        let reread = (1...3).map { Self.turn("r\($0)", items: 2) }
        guard case let .reset(page) = window.update(RemoteConversation(turns: reread)) else { return XCTFail() }
        XCTAssertEqual(page.items, reread.flatMap(\.items))
    }

    func testTheLongestRunInOrderStaysPut() {
        XCTAssertEqual(RemoteConversationWindow.longestIncreasingRun([3, 0, 1, 4, 2, 5]), [0, 1, 2, 5])
        XCTAssertEqual(RemoteConversationWindow.longestIncreasingRun([]), [])
        XCTAssertNil(RemoteConversationWindow.changes(from: [Self.item("a"), Self.item("a")], to: []))
    }

    // MARK: - Helpers

    static func turn(_ id: String, items count: Int) -> RemoteTurn {
        RemoteTurn(id: id, items: (0..<count).map { index in
            var item = RemoteItem(id: "i:\(id)-\(index)", turnId: id, kind: index == 0 ? .user : .activity)
            item.text = "\(id) item \(index)"
            return item
        })
    }

    static func item(_ id: String) -> RemoteItem { RemoteItem(id: id, turnId: "t", kind: .notice) }

    /// The changes applied as §5.3 says, failing when an `upsert` names an `after` the client does
    /// not hold: the server must never send one.
    static func strictlyApplying(_ changes: [RemoteChange], to items: [RemoteItem],
                                 file: StaticString = #filePath, line: UInt = #line) -> [RemoteItem] {
        var items = items
        for change in changes {
            // An item new to the client goes after one it holds once the changes before are applied.
            if change.op == .upsert, let item = change.item, !items.contains(where: { $0.id == item.id }),
               let after = change.after {
                XCTAssertTrue(items.contains { $0.id == after },
                              "after \(after) names an item the client does not hold", file: file, line: line)
            }
            items = items.applying([change])
        }
        return items
    }

    static let protocolDocument = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "docs/REMOTE_PROTOCOL.md")

    private func decode(_ json: String) throws -> RemoteRequestEnvelope {
        try RemoteRequestEnvelope.decode(Data(json.utf8)).get()
    }
}
