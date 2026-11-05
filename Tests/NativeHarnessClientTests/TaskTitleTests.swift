import XCTest
@testable import NativeHarnessClient

/// A thread Yardlet starts is named from its first request the way the official Codex app names
/// one: a short turn on an ephemeral read-only thread, then `thread/name/set`. A task is named again
/// from its recent conversation on request, by the smallest model its harness offers, on a side call
/// that keeps nothing (`RecentConversationTitle`).
final class TaskTitleTests: XCTestCase {
    private let request = "Run test_calc.py, find the failing tests, and fix calc.py."

    func testFirstRequestNamesTheThreadThroughAnEphemeralSideTurn() async throws {
        let transport = scriptedTransport(nameResponses: 1)
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
            namesNewThreads: true)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/yardlet-sandbox"), initialPrompt: request))

        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }
        await finishSideTurn(on: transport, finalMessage: #"{"title":"Fix failing calc.py tests"}"#)
        try await waitUntil { await transport.requestMethods.contains("thread/name/set") }

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), [
            "initialize", "thread/start", "turn/start",
            "model/list", "thread/start", "turn/start", "thread/unsubscribe", "thread/name/set"
        ])
        let sideThread = requests[4].params
        XCTAssertEqual(sideThread["ephemeral"]?.boolValue, true)
        XCTAssertEqual(sideThread["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(sideThread["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(sideThread["cwd"]?.stringValue, "/tmp/yardlet-sandbox")
        XCTAssertEqual(sideThread["model"]?.stringValue, CodexThreadTitle.preferredModel)
        let sideTurn = requests[5].params
        XCTAssertEqual(sideTurn["threadId"]?.stringValue, "title-thread")
        XCTAssertNotNil(sideTurn["outputSchema"])
        XCTAssertTrue(sideTurn["input"]?.arrayValue?.first?["text"]?.stringValue?.contains(request) == true)
        XCTAssertEqual(requests[6].params["threadId"]?.stringValue, "title-thread")
        XCTAssertEqual(requests[7].params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(requests[7].params["name"]?.stringValue, "Fix failing calc.py tests")

        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.name, "Fix failing calc.py tests")
        XCTAssertFalse(state.thread?.turns.contains { $0.id == "title-turn" } ?? false,
            "The side turn never reaches the task's own timeline")
    }

    func testANameThePersonSetsMeanwhileIsKept() async throws {
        let transport = scriptedTransport(nameResponses: 1)
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
            namesNewThreads: true)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: request))
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }

        try await adapter.setThreadName("Calculator", for: handle)
        await finishSideTurn(on: transport, finalMessage: #"{"title":"Fix failing calc.py tests"}"#)
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }
        try await Task.sleep(for: .milliseconds(50))

        let names = await transport.requests.filter { $0.method == "thread/name/set" }
        XCTAssertEqual(names.map { $0.params["name"]?.stringValue }, ["Calculator"])
    }

    func testFailedSideTurnLeavesTheThreadUnnamedAndLaterRequestsAlone() async throws {
        let transport = scriptedTransport(nameResponses: 0)
        await transport.enqueue(method: "turn/start", result: .object(["turn": .object(["id": .string("turn-2")])]))
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
            namesNewThreads: true)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: request))
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }

        await finishSideTurn(on: transport, finalMessage: nil, status: "failed")
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }
        try await adapter.send("And add a test for division", to: handle)
        try await Task.sleep(for: .milliseconds(50))

        let methods = await transport.requestMethods
        XCTAssertFalse(methods.contains("thread/name/set"))
        XCTAssertEqual(methods.filter { $0 == "thread/start" }.count, 2, "Only the first request is used for a name")
    }

    func testThreadNameUpdatesReachThePresentationState() {
        let reducer = CodexTaskReducer()
        var state = CodexTaskState.empty
        XCTAssertTrue(reducer.applySnapshot(.object(["id": .string("thread-1"), "turns": .array([])]), to: &state))
        XCTAssertTrue(reducer.applyNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .string("Fix calc tests")
        ]), sequence: 1, to: &state))
        XCTAssertEqual(state.thread?.name, "Fix calc tests")
        XCTAssertFalse(reducer.applyNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .string("Fix calc tests")
        ]), sequence: 2, to: &state))
        XCTAssertTrue(reducer.applyNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .null
        ]), sequence: 3, to: &state))
        XCTAssertNil(state.thread?.name)
    }

    func testTitleIsReadOnlyFromTheStructuredFinalMessage() {
        XCTAssertEqual(CodexThreadTitle.title(fromFinalMessage: #" {"title":"  Fix   calc tests "} "#), "Fix calc tests")
        XCTAssertNil(CodexThreadTitle.title(fromFinalMessage: "Fix calc tests"))
        XCTAssertNil(CodexThreadTitle.title(fromFinalMessage: #"{"title":"New task"}"#))
        XCTAssertNil(CodexThreadTitle.title(fromFinalMessage: nil))
        XCTAssertNil(CodexThreadTitle.request(from: [.localImage(URL(filePath: "/tmp/screen.png"))]))
        XCTAssertEqual(CodexThreadTitle.request(from: [.text("  Fix it \n")]), "Fix it")
    }

    // MARK: - Rename from Recent Conversation

    func testTheSmallestCurrentModelComesFromTheCatalog() {
        func claude(_ rows: [(String, String)]) -> [HarnessModelOption] {
            rows.map { HarnessModelOption(value: $0.0, name: $0.0, resolvedModel: $0.1) }
        }
        let listed = claude([("default", "claude-opus-5-5"), ("opus", "claude-opus-5-5"),
                            ("haiku", "claude-haiku-4-5-20251001"), ("claude-sonnet-4-6", "claude-sonnet-4-6")])
        XCTAssertEqual(RecentConversationTitle.claudeModel(from: listed), "haiku", "The CLI resolves its own alias")
        XCTAssertEqual(RecentConversationTitle.claudeModel(from: claude([("haiku", "claude-haiku-5-5"),
            ("claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001")])), "haiku")
        XCTAssertEqual(RecentConversationTitle.claudeModel(from: claude([("haiku", "claude-haiku-4-5-20251001"),
            ("claude-haiku-5-5", "claude-haiku-5-5")])), "claude-haiku-5-5", "A newer Haiku listed by name wins")
        XCTAssertEqual(RecentConversationTitle.claudeModel(from: []), "haiku")

        func codex(_ ids: [String]) -> [CodexModelOption] {
            ids.map { CodexModelOption(id: $0, model: $0, displayName: $0, defaultReasoningEffort: "medium",
                                       supportedReasoningEfforts: ["low"], isDefault: false) }
        }
        let today = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-luna"]
        XCTAssertEqual(RecentConversationTitle.codexModel(from: codex(today)), "gpt-6-luna")
        XCTAssertEqual(RecentConversationTitle.codexModel(from: codex(today + ["gpt-6.1-luna"])), "gpt-6.1-luna")
        XCTAssertNil(RecentConversationTitle.codexModel(from: codex(["gpt-6.1-sol"])))
    }

    func testTheExcerptHoldsTheLatestTurnsWordsWithinItsLimits() throws {
        func turn(_ index: Int, person: String?, answer: String?, work: Bool = false) -> ConversationTurn {
            var turn = ConversationTurn(id: "turn-\(index)", status: .completed, timing: ConversationTurnTiming())
            if let person { turn.prompt = [item("p\(index)", .userMessage(text: person, images: []))] }
            if let answer { turn.answers = [item("a\(index)", .answer(text: answer, isStreaming: false))] }
            if work { turn.work = [item("w\(index)", .commentary(text: "Reading files", isStreaming: false))] }
            return turn
        }
        let longAnswer = String(repeating: "긴 답변 ", count: 200)
        let turns = [
            turn(0, person: "Set up the sidebar search", answer: "Done."),
            turn(1, person: "Fix the failing calc tests", answer: "Fixed."),
            turn(2, person: nil, answer: nil, work: true),
            turn(3, person: "이제 작업 이름을 최근 대화로 다시 짓자", answer: longAnswer),
            turn(4, person: String(repeating: "x", count: 900), answer: nil),
            turn(5, person: "Show the row at work", answer: "The row shows a spinner.")
        ]
        let excerpt = try XCTUnwrap(RecentConversationTitle.excerpt(of: turns))
        XCTAssertFalse(excerpt.contains("sidebar search"), "Only the latest four turns with words are read")
        XCTAssertTrue(excerpt.hasPrefix("Person: Fix the failing calc tests\nAnswer: Fixed."))
        XCTAssertTrue(excerpt.hasSuffix("Person: Show the row at work\nAnswer: The row shows a spinner."))
        XCTAssertFalse(excerpt.contains("Reading files"), "Work is not part of it")
        XCTAssertTrue(excerpt.contains("Person: " + String(repeating: "x", count: 500) + "…\n"))
        XCTAssertTrue(excerpt.contains("Answer: " + longAnswer.trimmingCharacters(in: .whitespaces).prefix(300) + "…"))
        XCTAssertLessThanOrEqual(excerpt.count, RecentConversationTitle.excerptCharacterLimit)
        XCTAssertNil(RecentConversationTitle.excerpt(of: [turn(0, person: nil, answer: nil, work: true)]))

        let prompt = RecentConversationTitle.prompt(for: excerpt, structured: true)
        XCTAssertTrue(prompt.hasSuffix("Recent conversation:\n" + excerpt))
        XCTAssertTrue(prompt.contains("Answer only through the title field: plain text in the language of the conversation"))
        XCTAssertTrue(prompt.contains("at most 36 characters and about five words, leading with what is being done"))
        XCTAssertTrue(RecentConversationTitle.prompt(for: excerpt, structured: false).contains("Answer with the title alone:"))
    }

    func testCodexNamesATaskFromItsRecentConversationOnALeanSideThread() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "model/list": [.object(["data": .array(["gpt-6.1-sol", "gpt-5.6-luna", "gpt-6-luna"].map(model))])],
            "config/read": [.object(["config": .object(["mcp_servers": .object([
                "linear": .object(["command": .string("linear-mcp"), "enabled": .bool(true)]),
                "github": .object(["url": .string("https://example.com/mcp")]),
                "old": .object(["command": .string("old-mcp"), "enabled": .bool(false)])
            ])])])],
            "thread/start": [thread("title-thread")],
            "turn/start": [turn("title-turn")],
            "thread/unsubscribe": [.object([:])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
        let excerpt = "Person: Add a menu item that renames a task from its recent conversation"
        let suggestion = Task { try await adapter.suggestTaskTitle(fromRecentConversation: excerpt) }
        try await waitUntil { await transport.requestMethods.contains("turn/start") }
        await finishSideTurn(on: transport, finalMessage: #"{"title":"Rename tasks from recent talk"}"#)
        let title = try await suggestion.value
        XCTAssertEqual(title, "Rename tasks from recent talk")

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), [
            "initialize", "model/list", "config/read", "thread/start", "turn/start", "thread/unsubscribe"
        ], "Nothing is asked of a task's own thread")
        let folder = try XCTUnwrap(requests[2].params["cwd"]?.stringValue)
        XCTAssertTrue(folder.contains("Yardlet-TaskTitle-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "The empty folder goes with the call")
        let side = requests[3].params
        XCTAssertEqual(side["cwd"]?.stringValue, folder)
        XCTAssertEqual(side["model"]?.stringValue, "gpt-6-luna")
        XCTAssertEqual(side["ephemeral"]?.boolValue, true)
        XCTAssertEqual(side["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(side["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(side["baseInstructions"]?.stringValue, RecentConversationTitle.systemPrompt)
        let config = try XCTUnwrap(side["config"])
        XCTAssertEqual(config["mcp_servers.linear.enabled"]?.boolValue, false)
        XCTAssertEqual(config["mcp_servers.github.enabled"]?.boolValue, false)
        XCTAssertNil(config["mcp_servers.old.enabled"])
        XCTAssertEqual(config["features.hooks"]?.boolValue, false)
        XCTAssertEqual(config["include_environment_context"]?.boolValue, false)
        XCTAssertEqual(config["project_doc_max_bytes"], .integer(0))
        XCTAssertEqual(config["skills.include_instructions"]?.boolValue, false)
        let sideTurn = requests[4].params
        XCTAssertEqual(sideTurn["threadId"]?.stringValue, "title-thread")
        XCTAssertNotNil(sideTurn["outputSchema"])
        XCTAssertEqual(sideTurn["input"]?.arrayValue?.first?["text"]?.stringValue,
                       RecentConversationTitle.prompt(for: excerpt, structured: true))
    }

    func testClaudeCodeNamesATaskWithOnePrintRunThatKeepsNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = folder.appending(path: "claude")
        try """
            #!/bin/sh
            for argument in "$@"; do printf '%s\\n' "$argument"; done > "$FAKE_CLAUDE_RECORD/arguments"
            pwd > "$FAKE_CLAUDE_RECORD/folder"
            printf '%s' "$MAX_THINKING_TOKENS" > "$FAKE_CLAUDE_RECORD/thinking"
            cat > "$FAKE_CLAUDE_RECORD/input"
            printf '%s' "$FAKE_CLAUDE_ANSWER"
            exit "${FAKE_CLAUDE_STATUS:-0}"
            """.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let account = ["FAKE_CLAUDE_RECORD": folder.path, "CLAUDE_CONFIG_DIR": folder.appending(path: "account").path,
                       "FAKE_CLAUDE_ANSWER": #"{"type":"result","is_error":false,"result":"\"Rename tasks from recent talk\"\n","total_cost_usd":0.001}"#]
        let prompt = RecentConversationTitle.prompt(for: "Person: 최근 대화로 이름 다시 짓기", structured: false)

        let title = try await ClaudeTitleRequest.run(executableURL: claude, environment: account, model: "haiku", prompt: prompt)
        XCTAssertEqual(title, "Rename tasks from recent talk")
        let arguments = try String(contentsOf: folder.appending(path: "arguments"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(arguments, ["-p", "--model", "haiku", "--system-prompt", RecentConversationTitle.systemPrompt,
                                   "--tools", "", "--strict-mcp-config", "--safe-mode", "--disable-slash-commands",
                                   "--no-session-persistence", "--output-format", "json"])
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "input"), encoding: .utf8), prompt,
                       "The conversation goes in on standard input")
        let ranIn = try String(contentsOf: folder.appending(path: "folder"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ranIn.contains("Yardlet-TaskTitle-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ranIn), "The empty folder goes with the call")
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "thinking"), encoding: .utf8), "0",
                       "A few words need no thinking")

        var failing = account
        failing["FAKE_CLAUDE_ANSWER"] = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        failing["FAKE_CLAUDE_STATUS"] = "1"
        do {
            _ = try await ClaudeTitleRequest.run(executableURL: claude, environment: failing, model: "haiku", prompt: prompt)
            XCTFail("A failed run gives no name")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Not logged in"), error.localizedDescription)
        }
    }

    // MARK: - Fixtures

    private func item(_ id: String, _ kind: ConversationItemKind) -> ConversationItem {
        ConversationItem(id: id, kind: kind, phase: .completed, source: .transcript(TranscriptEntry(content: .plan(""))))
    }

    private func scriptedTransport(nameResponses: Int) -> FakeCodexTransport {
        FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [thread("thread-1"), thread("title-thread")],
            "turn/start": [turn("turn-1"), turn("title-turn")],
            "model/list": [.object(["data": .array([model("gpt-6-astra"), model(CodexThreadTitle.preferredModel)])])],
            "thread/unsubscribe": [.object([:])],
            "thread/name/set": Array(repeating: .object([:]), count: nameResponses)
        ])
    }

    private func finishSideTurn(on transport: FakeCodexTransport, finalMessage: String?, status: String = "completed") async {
        if let finalMessage {
            await transport.emit(method: "item/completed", params: .object([
                "threadId": .string("title-thread"), "turnId": .string("title-turn"),
                "item": .object(["id": .string("message"), "type": .string("agentMessage"), "text": .string(finalMessage)])
            ]))
        }
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string("title-thread"),
            "turn": .object(["id": .string("title-turn"), "status": .string(status)])
        ]))
    }

    private func thread(_ id: String) -> JSONValue { .object(["thread": .object(["id": .string(id)])]) }

    private func turn(_ id: String) -> JSONValue { .object(["turn": .object(["id": .string(id)])]) }

    private func model(_ id: String) -> JSONValue {
        .object(["id": .string(id), "model": .string(id), "displayName": .string(id),
                 "defaultReasoningEffort": .string("medium"), "hidden": .bool(false)])
    }
}
