#if DEBUG
import Foundation

/// Long working conversations, as a Claude Code task and a Codex thread have them after a day of
/// work: requests, thinking, many tool calls (reads, searches, commands, edits), and answers with
/// headings, lists, code blocks and tables, in turns of very different heights. Nothing here reads or
/// writes the workspace it names. The tests and the performance bench (`PerfBenchFixture`) share them;
/// product builds never compile them.
enum LongConversationFixture {
    static let workspace = URL(filePath: "/tmp/yardlet-long-conversation", directoryHint: .isDirectory)
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// The request that opens turn `turn`.
    static func request(_ turn: Int, tag: String = "") -> String {
        "\(tag)Request \(turn): look at the parser module and fix the failing case."
    }

    /// A Claude Code conversation of `turns` finished turns. Every entry's ID is derived from `seed`
    /// and its place, so two calls with the same seed give the same conversation.
    static func claude(turns: Int, seed: String = "claude", tag: String = "") -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var offset = 0.0
        func add(_ content: TranscriptEntryContent, _ name: String) {
            offset += 3
            entries.append(TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "\(seed)|\(name)"),
                                           createdAt: start.addingTimeInterval(offset), content: content))
        }
        for turn in 0..<turns {
            add(.user(text: request(turn, tag: tag)), "\(turn)|user")
            add(.reasoning(text: "The failing case is the empty input. I should read the parser first.",
                           isStreaming: false), "\(turn)|thinking")
            add(.assistant(text: "I'll read the parser and run its tests.", isStreaming: false), "\(turn)|preamble")
            for call in 0..<toolCount(turn) {
                add(.activity(tool(turn: turn, call: call), state: .completed), "\(turn)|tool|\(call)")
            }
            add(.assistant(text: answer(turn), isStreaming: false), "\(turn)|answer")
        }
        return entries
    }

    /// The ID the conversation gives turn `turn` of `claude(turns:seed:)`: its request's.
    static func claudeTurnID(seed: String = "claude", turn: Int) -> String {
        NameBasedUUID.make(namespace: namespace, name: "\(seed)|\(turn)|user").uuidString
    }

    /// A Codex thread of `turns` finished turns, in the provider's own item shapes.
    static func codex(turns: Int, threadID: String = "thread-long", tag: String = "") -> CodexTaskState {
        codex(threadID: threadID, turns: (0..<turns).map { codexTurn($0, tag: tag) })
    }

    /// A Codex thread of exactly `turns`, in the provider's item shapes (`codexTurn`).
    static func codex(threadID: String, turns: [JSONValue]) -> CodexTaskState {
        CodexTaskState(thread: CodexTaskDecoder().thread(from: codexThread(threadID: threadID, turns: turns)))
    }

    /// The thread as the App Server describes it, not loaded (as a saved thread reads).
    static func codexThread(threadID: String, turns: [JSONValue]) -> JSONValue {
        .object([
            "id": .string(threadID), "preview": .string("Fix the parser"), "cwd": .string(workspace.path),
            "status": .object(["type": .string("notLoaded")]), "historyMode": .string("paginated"),
            "turns": .array(turns)
        ])
    }

    /// A Codex turn still running: its request, `calls` commands, and `paragraphs` of answer so far.
    static func runningCodexTurn(_ turn: Int, request text: String, calls: Int, paragraphs: Int) -> JSONValue {
        var items: [JSONValue] = [
            .object(["id": .string("user-\(turn)"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string(text)])])])
        ]
        for call in 0..<calls {
            items.append(.object([
                "id": .string("command-\(turn)-\(call)"), "type": .string("commandExecution"),
                "command": .string("swift test --filter ParserTests"), "cwd": .string(workspace.path),
                "status": .string("completed"), "aggregatedOutput": .string("Test Suite 'ParserTests' passed"),
                "exitCode": .integer(0), "durationMs": .integer(420)
            ]))
        }
        if paragraphs > 0 {
            let words = String(repeating: "Words that wrap across the line. ", count: 12)
            items.append(.object(["id": .string("answer-\(turn)"), "type": .string("agentMessage"),
                                  "text": .string((0..<paragraphs).map { "Paragraph \($0): " + words }
                                    .joined(separator: "\n\n"))]))
        }
        return .object(["id": .string("turn-\(turn)"), "status": .string("inProgress"), "items": .array(items),
                        "startedAt": .integer(Int64(1_800_000_000 + turn * 60))])
    }

    static func codexTurn(_ turn: Int, tag: String = "", status: String = "completed") -> JSONValue {
        var items: [JSONValue] = [
            .object(["id": .string("user-\(turn)"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string(request(turn, tag: tag))])])]),
            .object(["id": .string("reasoning-\(turn)"), "type": .string("reasoning"),
                     "summary": .array([.string("Reading the parser before changing it")]), "content": .array([])])
        ]
        for call in 0..<toolCount(turn) {
            if call % 4 == 3 {
                items.append(.object([
                    "id": .string("change-\(turn)-\(call)"), "type": .string("fileChange"), "status": .string("completed"),
                    "changes": .array([.object([
                        "path": .string(workspace.appending(path: "Sources/Parser\(call).swift").path),
                        "kind": .object(["type": .string("update")]),
                        "diff": .string("@@ -1,3 +1,4 @@\n func parse() {\n-    old()\n+    guard !input.isEmpty else { return }\n+    new()\n }\n")
                    ])])
                ]))
            } else {
                items.append(.object([
                    "id": .string("command-\(turn)-\(call)"), "type": .string("commandExecution"),
                    "command": .string(["rg -n parse Sources", "swift test --filter ParserTests", "sed -n 1,80p Sources/Parser.swift"][call % 3]),
                    "cwd": .string(workspace.path), "status": .string("completed"),
                    "aggregatedOutput": .string("Sources/Parser.swift:12: func parse()\nSources/Lexer.swift:40: parse(tokens)"),
                    "exitCode": .integer(0), "durationMs": .integer(420)
                ]))
            }
        }
        items.append(.object(["id": .string("answer-\(turn)"), "type": .string("agentMessage"),
                              "text": .string(answer(turn))]))
        return .object(["id": .string("turn-\(turn)"), "status": .string(status), "items": .array(items),
                        "startedAt": .integer(Int64(1_800_000_000 + turn * 60)),
                        "completedAt": .integer(Int64(1_800_000_000 + turn * 60 + 42)),
                        "durationMs": .integer(42_000)])
    }

    // MARK: - A Codex task with many saved cards

    /// Finished turns of `counts` commands each, every one with `outputLength` characters of build
    /// output, in the App Server's item shapes: a day of builds in one task.
    static func codexCommandTurns(_ counts: [Int], outputLength: Int) -> [JSONValue] {
        let output = String(repeating: "Compiling module\n", count: outputLength / 17)
        return counts.enumerated().map { turn, count in
            let request: JSONValue = .object([
                "id": .string("turn-\(turn)-request"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("Keep going")])])
            ])
            let commands: [JSONValue] = (0..<count).map { slot in
                .object([
                    "id": .string("call_\(turn)_\(slot)_0123456789abcdef"), "type": .string("commandExecution"),
                    "command": .string("swift build \(slot)"), "cwd": .string("/tmp/workspace"),
                    "status": .string("completed"), "aggregatedOutput": .string(output), "exitCode": .number(0)
                ])
            }
            return .object(["id": .string("turn-\(turn)"), "status": .string("completed"), "itemsView": .string("full"),
                            "items": .array([request] + commands)])
        }
    }

    /// The turn the bench's fake Codex (scripts/perf-bench/fake-codex.py) leaves after
    /// `perf stream <seconds> <commands>`: `commands` finished commands with 1,500 characters of output,
    /// then reasoning, commands with output and answers, each streamed for a few seconds, in turn for
    /// `seconds`.
    static func streamedCodexTurn(id turnID: String, commands: Int, seconds: Int) -> JSONValue {
        func text(_ length: Int, _ seed: String) -> String {
            let words = "\(seed) reads the module, checks the failing case and explains the change. "
            return String(String(repeating: words, count: length / words.count + 1).prefix(length))
        }
        func command(_ id: String, output: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("commandExecution"), "command": .string("swift build"),
                     "cwd": .string("/tmp/workspace"), "processId": .null, "source": .string("agent"),
                     "status": .string("completed"), "commandActions": .array([]),
                     "aggregatedOutput": .string(output), "exitCode": .integer(0), "durationMs": .null])
        }
        var items: [JSONValue] = [.object([
            "id": .string("\(turnID)-request"), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string("perf stream \(seconds) \(commands)")])])
        ])]
        items += (0..<commands).map { command("\(turnID)-done-\($0)", output: text(1_500, "\(turnID)-done-\($0)")) }
        // (kind, fragments a second, seconds), as the fake streams them.
        let pattern: [(String, Int, Int)] = [("reasoning", 20, 2), ("commandExecution", 40, 4), ("agentMessage", 30, 4),
                                             ("commandExecution", 40, 2), ("agentMessage", 30, 2)]
        var elapsed = 0
        var index = 0
        while elapsed < seconds {
            let (kind, rate, length) = pattern[index % pattern.count]
            let itemID = "\(turnID)-\(index)"
            let steps = rate * min(length, seconds - elapsed)
            let written = (1...steps).map { step in
                if kind == "commandExecution" { return "[\(step)/400] Compiling Module\(step).swift and linking its objects\n" }
                return step.isMultiple(of: 25) ? "\n\n- point \(step) " : "\(itemID)-\(step) streamed words, "
            }.joined()
            switch kind {
            case "reasoning":
                items.append(.object(["id": .string(itemID), "type": .string(kind), "summary": .array([.string(written)]),
                                      "content": .array([])]))
            case "agentMessage":
                items.append(.object(["id": .string(itemID), "type": .string(kind), "text": .string(written)]))
            default:
                items.append(command(itemID, output: written))
            }
            elapsed += length
            index += 1
        }
        return .object(["id": .string(turnID), "status": .string("completed"), "itemsView": .string("full"),
                        "items": .array(items), "startedAt": .integer(1_800_000_000)])
    }

    /// The cards Yardlet saved as the items of `turns` streamed in: every item but the requests.
    static func savedCards(of turns: [JSONValue]) -> [CodexPersistedTimelineItem] {
        turns.flatMap { turn -> [CodexPersistedTimelineItem] in
            let turnID = turn["id"]?.stringValue ?? ""
            return (turn["items"]?.arrayValue ?? []).compactMap { raw in
                guard raw["type"]?.stringValue != "userMessage", let id = raw["id"]?.stringValue else { return nil }
                return CodexPersistedTimelineItem(
                    turnID: turnID, item: CodexTaskDecoder().item(from: raw, fallbackID: id, lifecycle: .completed))
            }
        }
    }

    // MARK: - Claude Code's saved conversation

    /// The same kind of conversation as Claude Code writes it to `<config>/projects/<folder>/<id>.jsonl`
    /// (2.1.299 record shapes): a request, the answer's thinking, text and tool calls, each call's
    /// result, and the final text, chained by `parentUuid`.
    static func claudeRecords(turns: Int, sessionID: String, workspace: URL, tag: String = "") -> [JSONValue] {
        var records: [JSONValue] = []
        var parent: String?
        var clock = 0
        func record(_ type: String, _ content: JSONValue, uuid: String) {
            clock += 2
            var object: [String: JSONValue] = [
                "parentUuid": parent.map(JSONValue.string) ?? .null, "isSidechain": .bool(false),
                "userType": .string("external"), "cwd": .string(workspace.path(percentEncoded: false)),
                "sessionId": .string(sessionID), "version": .string("2.1.299"), "gitBranch": .string("main"),
                "type": .string(type), "uuid": .string(uuid),
                "timestamp": .string(String(format: "2026-10-17T%02d:%02d:%02d.000Z", 1 + clock / 3600 % 20,
                                            clock / 60 % 60, clock % 60))
            ]
            if type == "assistant" {
                object["message"] = .object([
                    "model": .string("claude-opus-5-5"), "id": .string("msg_\(uuid)"), "type": .string("message"),
                    "role": .string("assistant"), "content": content, "stop_reason": .null,
                    "usage": .object(["input_tokens": .integer(3), "output_tokens": .integer(200),
                                      "cache_read_input_tokens": .integer(40_000)])
                ])
            } else {
                object["message"] = .object(["role": .string("user"), "content": content])
            }
            records.append(.object(object))
            parent = uuid
        }
        func uuid(_ name: String) -> String {
            NameBasedUUID.make(namespace: namespace, name: "\(sessionID)|\(name)").uuidString.lowercased()
        }
        for turn in 0..<turns {
            record("user", .string(request(turn, tag: tag)), uuid: uuid("\(turn)|user"))
            record("assistant", .array([.object(["type": .string("thinking"), "signature": .string("s"),
                "thinking": .string("The failing case is the empty input. I should read the parser first.")])]),
                uuid: uuid("\(turn)|thinking"))
            record("assistant", .array([.object(["type": .string("text"),
                "text": .string("I'll read the parser and run its tests.")])]), uuid: uuid("\(turn)|preamble"))
            for call in 0..<toolCount(turn) {
                let activity = tool(turn: turn, call: call)
                let input = (try? JSONDecoder().decode(JSONValue.self, from: Data((activity.input ?? "{}").utf8)))
                    ?? .object([:])
                let toolID = "toolu_\(turn)_\(call)_\(sessionID.prefix(6))"
                record("assistant", .array([.object(["type": .string("tool_use"), "id": .string(toolID),
                    "name": .string(activity.kind), "input": input])]), uuid: uuid("\(turn)|call|\(call)"))
                record("user", .array([.object(["type": .string("tool_result"), "tool_use_id": .string(toolID),
                    "content": .string(activity.output ?? "")])]), uuid: uuid("\(turn)|result|\(call)"))
            }
            record("assistant", .array([.object(["type": .string("text"), "text": .string(answer(turn))])]),
                   uuid: uuid("\(turn)|answer"))
        }
        return records
    }

    /// Writes `records` where Claude Code keeps conversation `sessionID` of `workspace` under `config`.
    @discardableResult
    static func writeClaudeTranscript(_ records: [JSONValue], sessionID: String, config: URL,
                                      workspace: URL) throws -> URL {
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data()
        let encoder = JSONEncoder()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(10)
        }
        let file = folder.appending(path: "\(sessionID).jsonl")
        try data.write(to: file)
        return file
    }

    // MARK: - Pieces

    private static let namespace = UUID(uuidString: "6B1A2E58-31D4-4C33-9C69-5E3A4B0F1D27")!

    /// Most turns call a few tools; every fifth works through a dozen, every eleventh through thirty.
    static func toolCount(_ turn: Int) -> Int {
        turn % 11 == 0 ? 30 : (turn % 5 == 0 ? 12 : 3)
    }

    private static func tool(turn: Int, call: Int) -> HarnessActivity {
        let path = workspace.appending(path: "Sources/Parser\(call % 7).swift").path(percentEncoded: false)
        switch call % 4 {
        case 0:
            return HarnessActivity(id: "read-\(turn)-\(call)", kind: "Read", title: "Read",
                                   input: #"{"file_path":"\#(path)"}"#,
                                   output: (1...40).map { "\($0)\tlet line\($0) = parse(token\($0))" }.joined(separator: "\n"))
        case 1:
            return HarnessActivity(id: "grep-\(turn)-\(call)", kind: "Grep", title: "Grep",
                                   input: #"{"pattern":"func parse","path":"Sources"}"#,
                                   output: "Sources/Parser.swift\nSources/Lexer.swift\nSources/Tokens.swift")
        case 2:
            return HarnessActivity(id: "bash-\(turn)-\(call)", kind: "Bash", title: "Bash",
                                   input: #"{"command":"swift test --filter ParserTests","description":"Run the parser tests"}"#,
                                   output: "Test Suite 'ParserTests' passed\n\t Executed 14 tests, with 0 failures")
        default:
            return HarnessActivity(id: "edit-\(turn)-\(call)", kind: "Edit", title: "Edit",
                                   input: #"{"file_path":"\#(path)","old_string":"old()","new_string":"new()"}"#,
                                   output: "The file has been updated.",
                                   diff: HarnessActivityDiff(path: path, oldText: "    old()\n", newText: "    guard !input.isEmpty else { return }\n    new()\n"))
        }
    }

    /// Answers of very different lengths: a line, a few paragraphs with a list, or a long write-up
    /// with a code block and a table.
    static func answer(_ turn: Int) -> String {
        let paragraph = "The parser returned early on an empty input, so the lexer never saw the end token. "
            + String(repeating: "Some words that wrap across the line as an answer does. ", count: 5)
        switch turn % 7 {
        case 0:
            return """
            ## What changed in turn \(turn)

            \(paragraph)

            ```swift
            func parse(_ input: String) -> [Token] {
                guard !input.isEmpty else { return [.end] }
                var lexer = Lexer(input)
                var tokens: [Token] = []
                while let token = lexer.next() {
                    tokens.append(token)
                }
                return tokens + [.end]
            }
            ```

            | Case | Before | After |
            |---|---|---|
            | Empty input | crash | `[.end]` |
            | One token | `[.word]` | `[.word, .end]` |
            | Trailing space | `[.word]` | `[.word, .end]` |
            | Unicode | wrong offsets | right offsets |

            \(paragraph)

            - The lexer now always ends with `.end`.
            - The tests cover the empty input.
            - Nothing else in the module changed.

            \(paragraph)
            """
        case 3:
            return "Done in turn \(turn): the tests pass."
        default:
            return (0..<(2 + turn % 4)).map { _ in paragraph }.joined(separator: "\n\n")
                + "\n\n- Fixed the early return\n- Added a test\n- Ran the suite"
        }
    }
}
#endif
