import Foundation
import XCTest
@testable import NativeHarnessClient

/// Shared transcripts for the conversation projection's tests, built the way their own tests build
/// them (plan M5): the transcript builder's sequences, Claude's session frames and its Send now run,
/// the subagent reader's records, the visual fixtures, and the edge cases those do not reach.
enum TranscriptProjectionFixtures {
    static let request = TranscriptEntry(
        id: UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000001")!,
        content: .user(text: "Prepended request")
    )

    // MARK: Folding

    /// A turn whose work folds under its answer, a turn still going, and a turn a request holds open.
    static func folding() -> [(String, [TranscriptEntry])] {
        let user = TranscriptEntry(content: .user(text: "Check it"))
        let commentary = TranscriptEntry(content: .assistant(text: "I will inspect it.", isStreaming: false))
        let activity = TranscriptEntry(content: .activity(
            HarnessActivity(id: "read-1", kind: "read", title: "Read file", detail: nil), state: .completed
        ))
        let final = TranscriptEntry(content: .assistant(text: "It works.", isStreaming: false))
        let assistant = TranscriptEntry(content: .assistant(text: "Inspecting.", isStreaming: false))
        let permission = TranscriptEntry(content: .permission(
            PermissionRequest(id: "permission", title: "Run", detail: nil, command: "pwd"), state: .pending
        ))
        let waiting = TranscriptEntry(content: .assistant(text: "Waiting for you.", isStreaming: false))
        return [
            ("completed turn folds its work", [user, commentary, activity, final]),
            ("active turn", [user, assistant]),
            ("pending permission stays visible", [user, permission, waiting])
        ]
    }

    // MARK: TranscriptBuilderTests

    /// The transcript after each step of each `TranscriptBuilderTests` sequence.
    static func builderSequences() -> [(String, [TranscriptEntry])] {
        var snapshots: [(String, [TranscriptEntry])] = []
        func replay(_ name: String, from builder: TranscriptBuilder = TranscriptBuilder(),
                    _ steps: [(inout TranscriptBuilder) -> Void]) {
            var builder = builder
            snapshots.append(("\(name) #0", builder.entries))
            for (index, step) in steps.enumerated() {
                step(&builder)
                snapshots.append(("\(name) #\(index + 1)", builder.entries))
            }
        }
        let allowed = PermissionRequest(id: "allowed", title: "Allowed", detail: nil, command: nil)
        let pending = PermissionRequest(id: "canceled", title: "Canceled tool", detail: nil, command: nil)
        replay("turn completion expires the unanswered request", [
            { $0.apply(.permissionRequested(allowed)) }, { $0.resolvePermission(id: allowed.id, decision: .allow) },
            { $0.apply(.permissionRequested(pending)) }, { $0.apply(.turnCompleted) },
            { $0.resolvePermission(id: pending.id, decision: .allow) }
        ])
        let late = PermissionRequest(id: "pending", title: "No longer answerable", detail: nil, command: nil)
        replay("runtime end keeps the partial response", [
            { $0.apply(.permissionRequested(allowed)) }, { $0.resolvePermission(id: allowed.id, decision: .allow) },
            { $0.apply(.permissionRequested(late)) }, { $0.apply(.assistantDelta("Partial response 👩🏽‍💻")) },
            { $0.endRuntime() }, { $0.resolvePermission(id: late.id, decision: .allow) }
        ])
        let build = HarnessActivity(id: "activity", kind: "Bash", title: "Build", detail: nil)
        let run = PermissionRequest(id: "permission", title: "Run command", detail: nil, command: "swift test")
        replay("restored transcript", from: TranscriptBuilder(entries: [
            TranscriptEntry(content: .assistant(text: "partial", isStreaming: true)),
            TranscriptEntry(content: .activity(build, state: .running)),
            TranscriptEntry(content: .permission(run, state: .pending))
        ]), [])
        replay("assistant deltas", [
            { $0.apply(.assistantDelta("hel")) }, { $0.apply(.assistantDelta("lo")) },
            { $0.apply(.assistantMessageCompleted("hello")) }
        ])
        let tests = HarnessActivity(id: "tool-1", kind: "Bash", title: "Run tests", detail: "swift test")
        let command = PermissionRequest(id: "permission-1", title: "Run command", detail: nil, command: "swift test")
        replay("activity and permission in place", [
            { $0.apply(.activityStarted(tests)) }, { $0.apply(.activityCompleted(tests)) },
            { $0.apply(.permissionRequested(command)) }, { $0.resolvePermission(id: command.id, decision: .deny) }
        ])
        replay("request finishes the stream", [
            { $0.apply(.assistantDelta("answer")) }, { $0.appendUser("follow-up") }
        ])
        let read = HarnessActivity(id: "tool-1", kind: "read", title: "Read file", detail: nil)
        replay("work boundary before the final message", [
            { $0.apply(.assistantDelta("Inspecting.")) }, { $0.apply(.activityStarted(read)) },
            { $0.apply(.assistantDelta("Final answer.")) }, { $0.apply(.turnCompleted) }
        ])
        let list = HarnessActivity(id: "tool-1", kind: "list_dir", title: "list dir", detail: "permission check failed")
        replay("completed turn stops its tool", [
            { $0.apply(.activityStarted(list)) }, { $0.apply(.assistantDelta("I could not list that directory.")) },
            { $0.apply(.turnCompleted) }
        ])
        replay("failed turn stops its tool", [
            { $0.apply(.activityStarted(list)) },
            { $0.apply(.error(message: "Harness process exited without a terminal result", recoverable: true)) }
        ])
        replay("disconnect stops its tool", [{ $0.apply(.activityStarted(list)) }, { $0.endRuntime() }])
        replay("plans replace within a turn", [
            { $0.appendUser("first") }, { $0.apply(.planUpdated("[ ] Inspect")) },
            { $0.apply(.planUpdated("[x] Inspect\n[~] Implement")) }, { $0.appendUser("next") },
            { $0.apply(.planUpdated("[ ] Verify")) }
        ])
        return snapshots
    }

    // MARK: ClaudeSessionProjectionTests

    private static let agentStart = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent","name":"Agent","input":{"description":"Review","prompt":"Review the code"}}]}}"#
    private static let backgroundStart = #"{"type":"system","subtype":"task_started","task_id":"bg","tool_use_id":"agent","description":"Review","task_type":"local_agent","is_backgrounded":true}"#
    private static let agentAcknowledgement = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent","content":"Agent launched in the background"}]}}"#
    private static let successfulTurn = #"{"type":"result","is_error":false,"subtype":"success"}"#

    private struct Replay {
        let name: String
        var builder = TranscriptBuilder()
        var projection = ClaudeSessionProjection()
        var snapshots: [(String, [TranscriptEntry])] = []

        init(_ name: String) { self.name = name }

        mutating func user(_ text: String) {
            builder.appendUser(text)
            record()
        }

        mutating func frame(_ json: String) throws {
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(Data(json.utf8))) {
                builder.apply(payload)
            }
            record()
        }

        mutating func frames(_ frames: [String]) throws {
            for json in frames { try frame(json) }
        }

        mutating func apply(_ payload: HarnessEventPayload) {
            builder.apply(payload)
            record()
        }

        mutating func endRuntime() {
            builder.endRuntime()
            record()
        }

        mutating func record() {
            snapshots.append(("\(name) #\(snapshots.count + 1)", builder.entries))
        }
    }

    /// The frames of each `ClaudeSessionProjectionTests` case, replayed into the builder.
    static func claudeSessionFrames() throws -> [(String, [TranscriptEntry])] {
        var replays: [Replay] = []

        var product = Replay("product YHP route")
        product.user("Review")
        try product.frames([
            agentStart, backgroundStart, agentAcknowledgement,
            #"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"text","text":"Hidden child answer"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"list","name":"TaskList","input":{}}]}}"#,
            #"{"type":"user","tool_use_result":{"tasks":[{"id":"1","subject":"Read the code","status":"in_progress","blockedBy":[]}]},"message":{"content":[{"type":"tool_result","tool_use_id":"list","content":"Task list"}]}}"#,
            successfulTurn,
            #"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"status":"killed"}}"#
        ])
        replays.append(product)

        var nested = Replay("nested messages")
        nested.user("Review the code")
        try nested.frames([
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Main "}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Child answer"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Child thinking"}}}"#,
            #"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"text","text":"Child answer"},{"type":"tool_use","id":"child-tool","name":"Bash","input":{"command":"pwd"}}]}}"#,
            #"{"type":"user","parent_tool_use_id":"agent","message":{"content":[{"type":"tool_result","tool_use_id":"child-tool","content":"/tmp"}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}}"#
        ])
        replays.append(nested)

        var background = Replay("background agent")
        background.user("Review in the background")
        try background.frames([
            agentStart, backgroundStart, agentAcknowledgement, successfulTurn,
            #"{"type":"system","subtype":"task_progress","task_id":"bg","tool_use_id":"agent","description":"Review","last_tool_name":"Read","usage":{"tool_uses":4,"total_tokens":900,"duration_ms":1250}}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"bg","status":"failed","summary":"The check failed"}"#
        ])
        replays.append(background)

        var killed = Replay("killed task")
        try killed.frames([
            agentStart, backgroundStart, successfulTurn,
            #"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"status":"killed"}}"#
        ])
        replays.append(killed)

        // A turn that ends on an error leaves the background work running, as any turn end does.
        var errorTurn = Replay("error with background work")
        errorTurn.apply(.activityStarted(HarnessActivity(id: "bg", kind: "Agent", title: "Review", isBackground: true)))
        errorTurn.apply(.error(message: "API Error: 500", recoverable: true))
        replays.append(errorTurn)

        var lateAcknowledgement = Replay("late acknowledgement")
        try lateAcknowledgement.frames([
            agentStart, backgroundStart,
            #"{"type":"system","subtype":"task_notification","task_id":"bg","status":"failed","summary":"Timed out"}"#,
            agentAcknowledgement
        ])
        replays.append(lateAcknowledgement)

        var moved = Replay("moved to the background")
        try moved.frames([
            agentStart,
            #"{"type":"system","subtype":"task_started","task_id":"bg","tool_use_id":"agent","description":"Review","is_backgrounded":false,"task_type":"local_agent"}"#,
            #"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"is_backgrounded":true}}"#,
            successfulTurn
        ])
        moved.endRuntime()
        replays.append(moved)

        var latePatch = Replay("late background patch")
        try latePatch.frames([
            agentStart,
            #"{"type":"system","subtype":"task_started","task_id":"bg","tool_use_id":"agent","description":"Review","is_backgrounded":false}"#,
            successfulTurn,
            #"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"is_backgrounded":true}}"#
        ])
        replays.append(latePatch)

        var foreground = Replay("foreground agent result")
        foreground.user("Summarize the README with an agent")
        try foreground.frames([
            agentStart,
            #"{"type":"system","subtype":"task_started","task_id":"fg","tool_use_id":"agent","description":"Review","task_type":"local_agent","prompt":"Review the code"}"#,
            #"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"tool_use","id":"child-read","name":"Read","input":{"file_path":"README.md"}}]}}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"fg","tool_use_id":"agent","description":"Review","last_tool_name":"Read","usage":{"tool_uses":1,"total_tokens":900,"duration_ms":1200}}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"fg","tool_use_id":"agent","status":"completed","summary":"The code is fine.","usage":{"tool_uses":1,"total_tokens":1000,"duration_ms":3200}}"#,
            #"{"type":"user","tool_use_result":{"status":"completed","agentId":"child-agent","content":[{"type":"text","text":"The code is fine."}],"totalToolUseCount":1,"totalTokens":990,"totalDurationMs":3190},"message":{"content":[{"type":"tool_result","tool_use_id":"agent","content":[{"type":"text","text":"[Subagent hand-back] Framing for the model. The report follows:\n  The code is fine."}]}]}}"#,
            successfulTurn
        ])
        replays.append(foreground)

        var stops = Replay("foreground work stops")
        try stops.frames([agentStart, successfulTurn])
        stops.apply(.activityStarted(HarnessActivity(id: "background", kind: "Agent", title: "Review", isBackground: true)))
        stops.snapshots.append(("foreground work stops restored", TranscriptBuilder(entries: stops.builder.entries).entries))
        replays.append(stops)

        var todo = Replay("todo list")
        todo.user("Plan it")
        let todoStart = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"todo","name":"TodoWrite","input":{"todos":[{"content":"Read the code","status":"completed","activeForm":"Reading"},{"content":"Run checks","status":"in_progress","activeForm":"Checking"}]}}]}}"#
        try todo.frames([
            todoStart,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"todo","content":"Updated"}]}}"#,
            todoStart,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"todo","content":"Denied","is_error":true}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Planned."}]}}"#,
            successfulTurn
        ])
        replays.append(todo)

        return replays.flatMap(\.snapshots)
    }

    // MARK: ClaudeSendNowFrames

    /// The recorded Send now run, as `AppModel` builds it: the request, the command, the read
    /// follow-up's bubble when Claude starts it, the answer, and the turn Claude starts itself.
    static func sendNowFrames() throws -> [(String, [TranscriptEntry])] {
        var replay = Replay("send now")
        replay.user("Run the tests")
        try replay.frames([SendNowFrames.initFrame, SendNowFrames.toolUse, SendNowFrames.taskStarted,
                           SendNowFrames.backgroundTasksChanged, SendNowFrames.backgrounded, SendNowFrames.movedResult])
        replay.user(SendNowFrames.text)
        try replay.frames([SendNowFrames.answer, SendNowFrames.turnResult("message"),
                           SendNowFrames.backgroundTasksEmptied, SendNowFrames.taskCompleted, SendNowFrames.notification,
                           SendNowFrames.initFrame, SendNowFrames.notificationAnswer, SendNowFrames.notificationTurnResult])
        return replay.snapshots
    }

    // MARK: ClaudeSubagentTranscriptReaderTests

    private static let parent = "11111111-2222-4333-8444-555555555555"

    /// The records `ClaudeSubagentTranscriptReaderTests` reads: a child conversation, a partial
    /// child log, and three saved main conversations (parallel tool results, an Agent call, images).
    static func subagentReaderRecords() throws -> [(String, [TranscriptEntry])] {
        var result: [(String, [TranscriptEntry])] = []
        let reader = ClaudeSubagentTranscriptReader(configDirectory: URL(filePath: "/unused"))
        let request = JSONValue.object(["type": .string("user"), "uuid": .string("u"), "parentUuid": .null,
            "sessionId": .string(parent), "isSidechain": .bool(true), "message": .object(["content": .string("Child request")])])
        let child = try lines([request, message("dead", parentUUID: "u", text: "Abandoned child"),
                               message("live", parentUUID: "u", text: "Live child")])
        result.append(("child conversation", try reader.project(child, parentSessionID: parent).entries))
        let partial = try lines([message("one", parentUUID: "missing", text: "One"), message("two", parentUUID: "one", text: "Two")])
            + Data("{\"unfinished\":".utf8)
        result.append(("partial child log", try ClaudeSubagentTranscriptReader(configDirectory: URL(filePath: "/unused"),
            maximumEntries: 2).project(partial, parentSessionID: parent).entries))

        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).base64EncodedString()
        let mainLogs: [(String, [String])] = [
            ("parallel tool results", [
                #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Fix calc.py"}}"#,
                #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"Two fixes"}]}}"#,
                #"{"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"calc.py","old_string":"a - b","new_string":"a + b"}}]}}"#,
                #"{"type":"assistant","uuid":"a3","parentUuid":"a2","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"edit-2","name":"Edit","input":{"file_path":"calc.py","old_string":"/ n","new_string":"/ max(n, 1)"}}]}}"#,
                #"{"type":"user","uuid":"r1","parentUuid":"a2","sourceToolAssistantUUID":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-1","content":"Updated add"}]}}"#,
                #"{"type":"user","uuid":"r2","parentUuid":"a3","sourceToolAssistantUUID":"a3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-2","content":"Updated mean"}]}}"#,
                #"{"type":"user","uuid":"dup","parentUuid":"a3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-2","content":"Duplicate"}]}}"#,
                #"{"type":"user","uuid":"ghost","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"elsewhere","content":"Ghost"}]}}"#,
                #"{"type":"user","uuid":"rewound","parentUuid":"a2","message":{"role":"user","content":"Abandoned request"}}"#,
                #"{"type":"assistant","uuid":"a4","parentUuid":"r2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{"command":"python3 test_calc.py"}}]}}"#
            ]),
            ("saved agent call", [
                #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Summarize the README with an agent"}}"#,
                #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"Summarize README","prompt":"Read README.md","subagent_type":"Explore","run_in_background":false}}]}}"#,
                #"{"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_agent","content":[{"type":"text","text":"[Subagent hand-back] Framing for the model. The report follows:\n  A small sandbox."}]}]},"toolUseResult":{"status":"completed","agentId":"child-1","agentType":"Explore","content":[{"type":"text","text":"A small sandbox."}],"totalDurationMs":3190,"totalTokens":15383,"totalToolUseCount":1}}"#,
                #"{"type":"assistant","uuid":"a2","parentUuid":"r1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"The agent summarized it."}]}}"#
            ]),
            ("saved images", [
                #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"What is wrong here?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}}"#,
                #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"The margin."}]}}"#,
                #"{"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://example.invalid/a.png"}}]}}"#
            ])
        ]
        for (name, records) in mainLogs {
            let root = FileManager.default.temporaryDirectory.appending(path: "claude-equivalence-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appending(path: "projects/project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let text = records.map { $0.replacingOccurrences(of: #""uuid":"#, with: #""sessionId":"\#(parent)","uuid":"#) }
                .joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: project.appending(path: "\(parent).jsonl"))
            let snapshot = try ClaudeSubagentTranscriptReader(configDirectory: root).readConversation(sessionID: parent)
            result.append((name, try XCTUnwrap(snapshot).entries))
        }
        return result
    }

    private static func message(_ id: String, parentUUID: String, text: String) -> JSONValue {
        .object(["type": .string("assistant"), "uuid": .string(id), "parentUuid": .string(parentUUID),
            "sessionId": .string(parent), "parent_tool_use_id": .string("tool"),
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }

    private static func lines(_ values: [JSONValue]) throws -> Data {
        try values.reduce(into: Data()) { result, value in
            result.append(try JSONEncoder().encode(value))
            result.append(10)
        }
    }

    // MARK: Visual fixtures

    #if DEBUG
    struct VisualFixture {
        let name: String
        let entries: [TranscriptEntry]
        let harness: HarnessKind
        let status: SessionStatus
        let latestTurnIsComplete: Bool
    }

    /// The conversation and harness-transcript fixtures' transcripts, and the detached Codex
    /// reading cache the Codex fixture timeline writes.
    static func visualFixtures() throws -> [VisualFixture] {
        var fixtures: [VisualFixture] = []
        for scenario in [ConversationFixtures.conversation(), ConversationFixtures.harnessTranscripts()] {
            for session in scenario.sessions {
                guard let entries = scenario.transcripts[session.id] else { continue }
                fixtures.append(VisualFixture(
                    name: session.title, entries: entries, harness: session.harness,
                    status: session.status, latestTurnIsComplete: session.completionState == .completed
                ))
            }
        }
        let codex = CodexTranscriptSnapshotProjection.entries(from: ConversationFixtures.codexTimeline())
        XCTAssertFalse(codex.isEmpty)
        fixtures.append(VisualFixture(name: "detached Codex reading cache", entries: codex, harness: .codex,
                                      status: .ready, latestTurnIsComplete: true))
        return fixtures
    }
    #endif

    // MARK: Edge cases

    /// Cases the fixtures above do not reach: folding and its exceptions, several errors in one
    /// turn, requests answered before their call, bash and image-only requests, the head turn.
    static func edgeCases() -> [(String, [TranscriptEntry])] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var offset = 0.0
        func entry(_ content: TranscriptEntryContent) -> TranscriptEntry {
            offset += 1
            return TranscriptEntry(createdAt: start.addingTimeInterval(offset), content: content)
        }
        func user(_ text: String = "Do it") -> TranscriptEntry { entry(.user(text: text)) }
        func answer(_ text: String = "Done.") -> TranscriptEntry { entry(.assistant(text: text, isStreaming: false)) }
        func tool(_ id: String, _ state: TranscriptActivityState, background: Bool? = nil,
                  subtask: HarnessSubtaskReference? = nil) -> TranscriptEntry {
            entry(.activity(HarnessActivity(id: id, kind: "Bash", title: "Run \(id)", input: "echo \(id)",
                                            isBackground: background, subtask: subtask), state: state))
        }
        func request(_ id: String, _ state: TranscriptPermissionState, toolCallID: String? = nil,
                     structured: PermissionRequestStructure? = nil) -> TranscriptEntry {
            entry(.permission(PermissionRequest(id: id, title: "Run", detail: nil, command: "echo",
                                                structured: structured, toolCallID: toolCallID), state: state))
        }
        let limit = HarnessRateLimit(status: .rejected, window: .session)
        let question = PermissionQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")])
        return [
            ("approved call folds", [user(), tool("call", .completed), request("r", .allowed, toolCallID: "call"), answer()]),
            ("approved before its call", [user(), request("r", .allowed, toolCallID: "call"), tool("call", .completed), answer()]),
            ("approved request with no card keeps its own", [user(), request("r", .allowed, toolCallID: "missing"), answer()]),
            ("answered question keeps its card",
             [user(), request("q", .allowed, toolCallID: "call", structured: .questions([question])), tool("call", .completed), answer()]),
            ("denied and expired", [user(), request("d", .denied), request("e", .expired), answer()]),
            ("denied only", [user(), tool("a", .completed), request("d", .denied), answer()]),
            ("two errors in one turn", [user(), entry(.error(message: "retrying", recoverable: true)), answer("Partial"),
                                        entry(.error(message: "{\"error\":{\"message\":\"gone\"}}", recoverable: false))]),
            ("error then answer", [user(), entry(.error(message: "blip", recoverable: true)), answer()]),
            ("limit then error", [user(), answer("Working"), entry(.usageLimit(limit)),
                                  entry(.error(message: "exited", recoverable: false))]),
            ("limit last", [user(), answer("Working"), entry(.usageLimit(limit))]),
            ("failed tool keeps the work open", [user(), tool("f", .failed), answer()]),
            ("stopped tool keeps the work open", [user(), tool("s", .stopped), answer()]),
            ("background tool running", [user(), tool("bg", .running, background: true), answer()]),
            ("streaming answer", [user(), entry(.assistant(text: "Writ", isStreaming: true))]),
            ("streaming commentary then answer", [user(), entry(.assistant(text: "Look", isStreaming: true)), tool("a", .completed), answer()]),
            ("thinking", [user(), entry(.reasoning(text: "Hmm", isStreaming: true))]),
            ("settled thinking folds", [user(), entry(.reasoning(text: "Hmm", isStreaming: false)), answer()]),
            ("compactions", [entry(.compaction(.init(phase: .completed, tokensBefore: 9, tokensAfter: 3))), user(),
                             entry(.compaction(.init(phase: .started))), answer(), user("Again"),
                             entry(.compaction(.init(phase: .failed, message: "no"))), answer()]),
            ("settled compaction folds", [user(), entry(.compaction(.init(phase: .completed))), answer()]),
            ("bash and image-only requests", [
                user(ClaudeBashMessage.text(command: "ls", stdout: "a\nb")), answer("Two files."),
                entry(.user(text: "", images: [TranscriptImageAttachment(url: nil, name: "shot.png")])), answer(),
                user(ClaudeBashMessage.inputText(command: "sleep 9"))
            ]),
            ("plan before the first request", [entry(.plan("☐ Inspect")), user(), entry(.plan("◉ Inspect")), answer()]),
            ("plan only work", [user(), entry(.plan("[completed] Inspect")), answer()]),
            ("subtask", [user(), tool("agent", .completed, subtask: .init(taskID: "t", toolUseID: "agent")),
                         request("r", .allowed, toolCallID: "agent"), answer()]),
            ("head only", [answer("Context"), tool("a", .completed), entry(.error(message: "early", recoverable: true))]),
            ("pending request then answer", [user(), request("p", .pending), answer()]),
            ("answer then pending request", [user(), answer(), request("p", .pending)]),
            ("two requests in a row", [user("One"), user("Two"), answer()]),
            ("empty", [])
        ]
    }
}
