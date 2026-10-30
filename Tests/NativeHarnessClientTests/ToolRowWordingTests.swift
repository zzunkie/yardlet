import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Tool rows in each provider's own words (2026-10-15): a Codex command
/// as the Codex app words it from what the App Server parsed it into (`commandActions`), its shell
/// wrapper taken off; a Claude Code call as the Claude app's Code screen words it; and the summary
/// of a run of calls in each one's words. English and Korean are both read from the catalogs; the
/// Korean is each app's own.
@MainActor
final class ToolRowWordingTests: XCTestCase {
    private let en: ConversationLineWording.Localize = { L10n.string($0, languageCode: "en") }
    private let ko: ConversationLineWording.Localize = { L10n.string($0, languageCode: "ko") }

    // MARK: - Codex rows

    func testCodexReadsAFileByItsName() {
        let read = ConversationCommandAction.read(name: "Parser.swift", path: "/repo/Sources/Parser.swift",
                                                  command: "sed -n '1,200p' Sources/Parser.swift")
        XCTAssertEqual(ConversationLineWording.codex(read, phase: .completed, localize: en),
                       ConversationLineWords(verb: "Read", trailing: "Parser.swift"))
        XCTAssertEqual(ConversationLineWording.codex(read, phase: .completed, localize: ko),
                       ConversationLineWords(leading: "Parser.swift", verb: "읽음"))
        XCTAssertEqual(ConversationLineWording.codex(read, phase: .running, localize: en).text, "Reading Parser.swift")
        XCTAssertEqual(ConversationLineWording.codex(read, phase: .running, localize: ko).text, "읽는 중인 Parser.swift")
        // A failed or stopped read is still a finished one to the Codex app.
        XCTAssertEqual(ConversationLineWording.codex(read, phase: .failed, localize: en).text, "Read Parser.swift")
        XCTAssertEqual(ConversationLineWording.codex(.read(name: " ./a.swift ", path: nil, command: "cat ./a.swift"),
                                                     phase: .completed, localize: en).text, "Read a.swift")
    }

    func testCodexSearchesForTheQueryInThePath() {
        let both = ConversationCommandAction.search(query: "TODO", path: "./Sources", command: "rg TODO Sources")
        XCTAssertEqual(ConversationLineWording.codex(both, phase: .completed, localize: en),
                       ConversationLineWords(verb: "Searched", trailing: "for TODO in Sources"))
        XCTAssertEqual(ConversationLineWording.codex(both, phase: .completed, localize: ko),
                       ConversationLineWords(leading: "Sources에서 TODO", verb: "검색함"))
        XCTAssertEqual(ConversationLineWording.codex(both, phase: .running, localize: en).text,
                       "Searching for TODO in Sources")
        XCTAssertEqual(ConversationLineWording.codex(both, phase: .running, localize: ko).text, "Sources에서 TODO 검색 중")

        let query = ConversationCommandAction.search(query: "parseArray", path: nil, command: "rg parseArray")
        XCTAssertEqual(ConversationLineWording.codex(query, phase: .completed, localize: en).text, "Searched for parseArray")
        XCTAssertEqual(ConversationLineWording.codex(query, phase: .completed, localize: ko).text, "parseArray 검색함")

        let files = ConversationCommandAction.search(query: nil, path: nil, command: "rg --files")
        XCTAssertEqual(ConversationLineWording.codex(files, phase: .completed, localize: en).text, "Searched for files")
        XCTAssertEqual(ConversationLineWording.codex(files, phase: .running, localize: ko).text, "파일 검색 중")
    }

    func testCodexListsFilesInTheFolder() {
        let folder = ConversationCommandAction.listFiles(path: "Sources", command: "ls Sources")
        XCTAssertEqual(ConversationLineWording.codex(folder, phase: .completed, localize: en).text,
                       "Listed files in Sources")
        XCTAssertEqual(ConversationLineWording.codex(folder, phase: .completed, localize: ko).text,
                       "Sources에 파일 목록 작성함")
        XCTAssertEqual(ConversationLineWording.codex(folder, phase: .running, localize: en).text,
                       "Listing files in Sources")
        let here = ConversationCommandAction.listFiles(path: nil, command: "ls")
        XCTAssertEqual(ConversationLineWording.codex(here, phase: .completed, localize: en).text, "Listed files")
        XCTAssertEqual(ConversationLineWording.codex(here, phase: .completed, localize: ko).text, "파일 목록 작성함")
    }

    /// An unrecognized command reads as its inner command on one line: "Ran …", "Running …",
    /// "Stopped …". A failed one ran, as the Codex app words it; its exit code is in its details.
    func testCodexRunsAnUnknownCommand() {
        let unknown = ConversationCommandAction.unknown(command: "python3 - <<'PY'\nprint(1)\nPY")
        XCTAssertEqual(ConversationLineWording.codex(unknown, phase: .completed, localize: en),
                       ConversationLineWords(verb: "Ran", trailing: "python3 - <<'PY' print(1) PY"))
        XCTAssertEqual(ConversationLineWording.codex(unknown, phase: .completed, localize: ko),
                       ConversationLineWords(leading: "python3 - <<'PY' print(1) PY", verb: "실행됨"))
        XCTAssertEqual(ConversationLineWording.codex(unknown, phase: .running, localize: en).text,
                       "Running python3 - <<'PY' print(1) PY")
        XCTAssertEqual(ConversationLineWording.codex(unknown, phase: .running, localize: ko).text,
                       "python3 - <<'PY' print(1) PY 실행 중")
        XCTAssertEqual(ConversationLineWording.codex(unknown, phase: .stopped, localize: en).text,
                       "Stopped python3 - <<'PY' print(1) PY")
        XCTAssertEqual(ConversationLineWording.codex(unknown, phase: .failed, localize: en).text,
                       "Ran python3 - <<'PY' print(1) PY")
        XCTAssertEqual(ConversationLineWording.codex(.unknown(command: "  "), phase: .completed, localize: en).text,
                       "Ran command")
        XCTAssertEqual(ConversationLineWording.codex(.unknown(command: ""), phase: .running, localize: ko).text,
                       "명령 실행 중")
    }

    /// The App Server's `commandActions`, in order: a command it split reads one line each.
    func testCodexCommandActionsReadAsOneLineEach() {
        let actions = ConversationCommandAction.actions(from: [
            .object(["type": .string("read"), "command": .string("cat a.swift"), "name": .string("a.swift"),
                     "path": .string("/repo/a.swift")]),
            .object(["type": .string("read"), "command": .string("cat b.swift"), "name": .string("b.swift"),
                     "path": .string("/repo/b.swift")]),
            .object(["type": .string("listFiles"), "command": .string("ls"), "path": .null]),
            .object(["type": .string("search"), "command": .string("rg x"), "query": .string("x"), "path": .null]),
            .object(["type": .string("format"), "command": .string("swift format")]),
            .object(["command": .string("no type")])
        ])
        XCTAssertEqual(actions, [
            .read(name: "a.swift", path: "/repo/a.swift", command: "cat a.swift"),
            .read(name: "b.swift", path: "/repo/b.swift", command: "cat b.swift"),
            .listFiles(path: nil, command: "ls"),
            .search(query: "x", path: nil, command: "rg x"),
            .unknown(command: "swift format")
        ])
        let command = ConversationCommand(command: "/bin/zsh -lc 'cat a.swift && cat b.swift'", status: "completed",
                                          actions: Array(actions.prefix(2)))
        XCTAssertEqual(ConversationLineWording.command(command, phase: .completed, harness: .codex, localize: en).map(\.text),
                       ["Read a.swift", "Read b.swift"])
    }

    // MARK: - The wrapper

    func testTheWrapperComesOffOnlyInItsExactShape() {
        let wrapped: [(String, String)] = [
            ("/bin/zsh -lc 'echo hi'", "echo hi"),
            (#"/bin/zsh -lc "sed -n '1,200p' Sources/Parser.swift""#, "sed -n '1,200p' Sources/Parser.swift"),
            ("/bin/bash -lc 'swift test'", "swift test"),
            ("zsh -lc ls", "ls"),
            ("bash -lc git-status", "git-status"),
            (#"/bin/zsh -lc 'python3 - <<'"'"'PY'"'"'"# + "\nprint(1)\nPY'", "python3 - <<'PY'\nprint(1)\nPY"),
            (#"/bin/zsh -lc 'it'\''s'"#, "it's"),
            (#"/bin/zsh -lc "echo \"hi\" \$HOME \\ \`date\`""#, #"echo "hi" $HOME \ `date`"#)
        ]
        for (command, inner) in wrapped {
            XCTAssertEqual(CodexShellCommand.innerScript(of: command), inner, command)
            XCTAssertEqual(CodexShellCommand.displayed(command), inner, command)
        }
        let lookAlikes = [
            "/bin/zsh -c 'echo hi'",            // not a login shell's -lc
            "/bin/sh -lc 'echo hi'",            // not one of the four shells
            "/usr/local/bin/zsh -lc 'echo hi'", // another zsh
            "/bin/zsh  -lc 'echo hi'",          // two spaces
            "/bin/zsh -lcx 'echo hi'",          // another flag
            "/bin/zsh -lc 'echo hi' extra",     // a second word
            "/bin/zsh -lc 'echo hi'; rm -rf x", // more after it
            "/bin/zsh -lc echo hi",             // two words
            "/bin/zsh -lc 'echo hi",            // unclosed
            "/bin/zsh -lc \"echo $HOME\"",      // an expansion
            "/bin/zsh -lc \"echo `date`\"",     // a substitution
            "/bin/zsh -lc a|b",                 // a pipe
            "/bin/zsh -lc ''",                  // nothing inside
            "/bin/zsh -lc ",                    // no word
            "echo /bin/zsh -lc 'echo hi'",      // not at the start
            "swift test"
        ]
        for command in lookAlikes {
            XCTAssertNil(CodexShellCommand.innerScript(of: command), command)
            XCTAssertEqual(CodexShellCommand.displayed(command), command, command)
        }
    }

    /// A command the App Server sent no actions for (declined, or from before it parsed them) reads
    /// as its inner command too, and a look-alike as it is.
    func testACommandWithoutActionsReadsItsInnerCommand() {
        func words(_ command: String) -> String {
            ConversationLineWording.command(ConversationCommand(command: command, status: "completed"),
                                            phase: .completed, harness: .codex, localize: en).map(\.text).joined()
        }
        XCTAssertEqual(words("/bin/zsh -lc 'swift build'"), "Ran swift build")
        XCTAssertEqual(words("/bin/zsh -c 'swift build'"), "Ran /bin/zsh -c 'swift build'")
        // A script given arguments after it is not the wrapper: it reads as it is.
        XCTAssertEqual(words(#"/bin/zsh -lc 'echo "$1"' _ hi"#), #"Ran /bin/zsh -lc 'echo "$1"' _ hi"#)
        // A command the model wrapped in a login shell itself comes off it the same way.
        XCTAssertEqual(ConversationLineWording.codex(.unknown(command: "bash -lc 'cd Sources && make'"),
                                                     phase: .completed, localize: en).text, "Ran cd Sources && make")
    }

    // MARK: - "Run in terminal"

    /// The terminal gets the command exactly as it ran, wrapper and all, while the line reads its
    /// inner command; opened, the line shows the whole command, its output and exit code.
    func testRunInTerminalHandsOffTheCommandAsItRan() throws {
        let original = #"/bin/zsh -lc "rg -n 'TODO' Sources | head -5""#
        let command = ConversationCommand(command: original, workingDirectory: "/tmp/yardlet", status: "failed",
                                          output: "Sources/A.swift:3: TODO\n", exitCode: 2,
                                          actions: [.unknown(command: "rg -n 'TODO' Sources | head -5")])
        var ran: [String] = []
        let line = ConversationWorkLine(
            item: ConversationItem(id: "c1", kind: .command(command), phase: .failed,
                                   source: .transcript(TranscriptEntry(content: .plan(""))), copyDetails: "details"),
            harness: .codex, workspaceURL: URL(filePath: "/tmp/yardlet"), runInTerminal: { ran.append($0) }
        )
        let host = WindowlessRender.Host(line.frame(width: 640, height: 220, alignment: .top),
                                         size: NSSize(width: 640, height: 220), appearance: .light)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        let words = ConversationLineWording.codex(.unknown(command: "rg -n 'TODO' Sources | head -5"), phase: .failed)
        XCTAssertTrue(elements.contains(label: words.text, value: L10n.string("Expanded")), "a failed one opens: \(elements)")
        XCTAssertTrue(elements.contains { $0.label == original || $0.value == original }, "the whole command: \(elements)")
        XCTAssertTrue(elements.contains { $0.label == L10n.format("Exit code %lld", 2) || $0.value == L10n.format("Exit code %lld", 2) },
                      "\(elements)")
        XCTAssertEqual(host.hosting.pressElements(labelled: L10n.string("Run in terminal")), 1, "\(elements)")
        XCTAssertEqual(ran, [original])
    }

    // MARK: - Claude Code's rows

    /// Each tool as Claude Code words it, read from the input text Yardlet's Claude projector writes.
    func testClaudeWordsEachTool() {
        let cases: [(String, [String: Any], ConversationItemPhase, String, String)] = [
            ("Read", ["file_path": "/repo/Sources/Parser.swift", "offset": 10], .completed,
             "Read Parser.swift", "읽기 Parser.swift"),
            ("Read", ["file_path": "/repo/Sources/Parser.swift"], .running, "Reading Parser.swift", "읽는 중 Parser.swift"),
            ("Read", ["file_path": "/repo/missing.swift"], .failed, "Failed to read missing.swift", "읽기 실패 missing.swift"),
            ("Write", ["file_path": "/repo/notes.md"], .completed, "Created notes.md", "생성됨 notes.md"),
            ("Edit", ["file_path": "/repo/calc.py", "old_string": "a"], .completed, "Edited calc.py", "수정됨 calc.py"),
            ("MultiEdit", ["file_path": "/repo/calc.py", "edits": [["old_string": "a", "new_string": "b"]]], .running,
             "Editing calc.py", "편집 중 calc.py"),
            ("NotebookEdit", ["notebook_path": "/repo/plots.ipynb", "new_source": "x"], .completed,
             "Edited plots.ipynb", "수정됨 plots.ipynb"),
            ("Grep", ["pattern": "TODO", "path": "Sources", "output_mode": "content"], .completed,
             "Searched TODO", "검색됨 TODO"),
            ("Glob", ["pattern": "**/*.swift"], .running, "Searching **/*.swift", "검색 중 **/*.swift"),
            ("LS", ["path": "/repo/Sources"], .completed, "Listed /repo/Sources", "목록에 표시됨 /repo/Sources"),
            ("WebFetch", ["url": "https://example.com/docs", "prompt": "Summarize"], .completed,
             "Fetched https://example.com/docs", "가져옴 https://example.com/docs"),
            ("WebSearch", ["query": "swift regex lookbehind"], .running, "Searching web swift regex lookbehind",
             "웹 검색 중 swift regex lookbehind"),
            ("Task", ["prompt": "Look\n\nat it", "subagent_type": "general", "description": "Run the parser tests"],
             .completed, "Ran the parser tests", "Ran the parser tests"),
            ("Agent", ["prompt": "Look", "subagent_type": "general"], .completed, "Ran agent", "에이전트 실행함"),
            ("Skill", ["skill": "commit"], .completed, "Ran skill /commit", "Skill 실행됨 /commit"),
            ("TodoWrite", ["todos": [["content": "Fix", "status": "pending"]]], .completed, "Updated todos", "할 일 업데이트됨"),
            ("TodoWrite", ["todos": [Any]()], .completed, "Cleared todos", "할 일 지워짐"),
            ("TodoWrite", ["todos": [Any]()], .running, "Updating todos", "할 일 업데이트 중"),
            ("mcp__github__create_issue", ["title": "Bug"], .completed, "Used github: create issue",
             "github: create issue 사용함"),
            ("mcp__claude_in_chrome__read_page", [:], .running, "Using claude in chrome: read page",
             "claude in chrome: read page 사용 중"),
            ("mcp__cfc3bc76-3f36-46d1-98e8-b71c77635d40__slack_read_channel", [:], .completed,
             "Used slack read channel", "slack read channel 사용함"),
            ("TaskOutput", ["task_id": "1"], .completed, "Used TaskOutput", "TaskOutput 사용함")
        ]
        for (name, input, phase, english, korean) in cases {
            let item = Self.claudeItem(name, input, phase: phase)
            guard case let .tool(tool) = item.kind else { XCTFail("\(name): \(item.kind)"); continue }
            XCTAssertEqual(ConversationLineWording.claudeTool(tool, phase: phase, localize: en)?.text, english, name)
            XCTAssertEqual(ConversationLineWording.claudeTool(tool, phase: phase, localize: ko)?.text, korean, name)
        }
    }

    /// Bash reads its description, its verb conjugated, or "Ran" and the command without one.
    func testClaudeShellCallsReadTheirDescription() {
        func words(_ input: [String: Any], _ phase: ConversationItemPhase, _ localize: @escaping ConversationLineWording.Localize)
            -> String {
            let item = Self.claudeItem("Bash", input, phase: phase)
            guard case let .command(command) = item.kind else { return "not a command: \(item.kind)" }
            return ConversationLineWording.command(command, phase: phase, harness: .claudeCode, localize: localize)
                .map(\.text).joined()
        }
        let described: [String: Any] = ["command": "swift test 2>&1 | tail -20", "description": "Run the tests"]
        XCTAssertEqual(words(described, .running, en), "Running the tests")
        XCTAssertEqual(words(described, .completed, en), "Ran the tests")
        XCTAssertEqual(words(described, .stopped, en), "Run the tests")
        XCTAssertEqual(words(described, .failed, en), "Failed to run the tests")
        XCTAssertEqual(words(described, .failed, ko), "run the tests 실패")
        let noun: [String: Any] = ["command": "git status", "description": "Git status check"]
        XCTAssertEqual(words(noun, .completed, en), "Git status check")
        XCTAssertEqual(words(noun, .failed, en), "Failed to run Git status check")
        XCTAssertEqual(words(noun, .failed, ko), "실행 실패 Git status check")
        let bare: [String: Any] = ["command": "swift build\nswift test"]
        XCTAssertEqual(words(bare, .completed, en), "Ran swift build")
        XCTAssertEqual(words(bare, .completed, ko), "실행됨 swift build")
        XCTAssertEqual(words(bare, .running, en), "Running swift build")
        XCTAssertEqual(words(bare, .failed, en), "Failed to run swift build")
        // A command's last paragraph that looks like fields is still the command.
        let yaml: [String: Any] = ["command": "cat <<EOF\n\ndescription: not a field\nEOF"]
        XCTAssertEqual(words(yaml, .completed, en), "Ran cat <<EOF")
    }

    func testClaudeConjugatesTheVerbsItKnows() {
        let cases: [(String, String?, String?, String?)] = [
            ("Run the tests", "Running the tests", "Ran the tests", "run the tests"),
            ("Build and run tests", "Building and running tests", "Built and ran tests", "build and run tests"),
            ("Read the file then fix it", "Reading the file then fixing it", "Read the file then fixed it", nil),
            ("Commit and push", "Committing and pushing", "Committed and pushed", nil),
            ("Re-run the tests", "Re-running the tests", "Re-ran the tests", "re-run the tests"),
            ("Stop the server", "Stopping the server", "Stopped the server", nil),
            ("Copy files", "Copying files", "Copied files", nil),
            ("Check that the build works", "Checking that the build works", "Checked that the build works", nil),
            ("List files and output results", "Listing files and output results", "Listed files and output results", nil),
            ("Run tests and check it passes", "Running tests and check it passes", "Ran tests and check it passes", nil),
            ("  Install deps", "  Installing deps", "  Installed deps", nil),
            ("git status", nil, nil, nil),
            ("Ran tests", nil, nil, nil),
            ("RUN tests", nil, nil, nil),
            ("Review the fix", nil, nil, nil)
        ]
        for (description, running, done, infinitive) in cases {
            let forms = ClaudeDescriptionVerbs.forms(of: description)
            XCTAssertEqual(forms?.running, running, description)
            XCTAssertEqual(forms?.done, done, description)
            if let infinitive { XCTAssertEqual(forms?.infinitive, infinitive, description) }
        }
    }

    // MARK: - Summaries

    func testCodexSummaryNamesWhatWasDoneInItsOrder() {
        let work = [
            Self.codexCommand("c1", [.read(name: "a.swift", path: "/r/a.swift", command: "cat a.swift")]),
            Self.codexCommand("c2", [.search(query: "x", path: nil, command: "rg x")]),
            Self.fileChange("f1", ["/r/a.swift"]),
            Self.codexCommand("c3", [.unknown(command: "swift build")]),
            Self.codexCommand("c4", [.unknown(command: "swift test")])
        ]
        XCTAssertEqual(ConversationWorkSummary.title(for: work, harness: .codex, localize: en),
                       "Edited a file, read files, ran commands")
        XCTAssertEqual(ConversationWorkSummary.title(for: work, harness: .codex, localize: ko),
                       "파일 수정함, 파일을 읽음, 명령을 실행함")
        let reads = Array(work.prefix(2))
        XCTAssertEqual(ConversationWorkSummary.title(for: reads, harness: .codex, localize: en), "Read files")
        XCTAssertEqual(ConversationWorkSummary.title(for: reads, harness: .codex, localize: ko), "파일을 읽었습니다")
        XCTAssertEqual(ConversationWorkSummary.title(for: [work[3], Self.fileChange("f2", ["/r/a", "/r/b"])],
                                                     harness: .codex, localize: en),
                       "Edited files, ran a command")
        let tools = [Self.tool("m1", .mcp), Self.tool("w1", .webSearch), Self.tool("i1", .imageView)]
        XCTAssertEqual(ConversationWorkSummary.title(for: tools, harness: .codex, localize: en),
                       "Called a tool, searched the web")
        XCTAssertEqual(ConversationWorkSummary.title(for: tools, harness: .codex, localize: ko), "도구 호출함, 웹 검색함")
        XCTAssertEqual(ConversationWorkSummary.title(for: [Self.tool("i1", .imageView), Self.tool("i2", .sleep)],
                                                     harness: .codex, localize: ko), "완료됨")
    }

    /// While a command in the run works, the Codex group reads that command's line.
    func testCodexGroupReadsItsRunningCommand() {
        let running = [
            Self.codexCommand("c1", [.read(name: "a.swift", path: nil, command: "cat a.swift")]),
            Self.codexCommand("c2", [.unknown(command: "swift test")], phase: .running)
        ]
        XCTAssertEqual(ConversationWorkSummary.header(for: running, harness: .codex, localize: en).text, "Running swift test")
        XCTAssertEqual(ConversationWorkSummary.header(for: running, harness: .codex, localize: ko).text, "swift test 실행 중")
        let reading = [running[1].with(phase: .completed),
                       Self.codexCommand("c3", [.read(name: "b.swift", path: nil, command: "cat b.swift")], phase: .running)]
        XCTAssertEqual(ConversationWorkSummary.header(for: reading, harness: .codex, localize: en).text, "Reading b.swift")
        let editing = [running[1].with(phase: .completed), Self.fileChange("f1", ["/r/a"], phase: .running)]
        XCTAssertEqual(ConversationWorkSummary.header(for: editing, harness: .codex, localize: ko).text, "파일 수정 중")
        XCTAssertEqual(ConversationWorkSummary.header(for: Array(reading.prefix(1)) + [running[0]], harness: .codex,
                                                      localize: en).text, "Read files, ran a command")
    }

    /// Claude Code counts each kind, files by distinct path, most first; past three kinds it names
    /// two and counts the rest as tools.
    func testClaudeSummaryCountsEachKindMostFirst() {
        let work = [
            Self.claudeItem("Read", ["file_path": "/r/a.swift"], phase: .completed),
            Self.claudeItem("Read", ["file_path": "/r/a.swift"], phase: .completed),
            Self.claudeItem("Read", ["file_path": "/r/b.swift"], phase: .completed),
            Self.claudeItem("Bash", ["command": "swift build"], phase: .completed),
            Self.claudeItem("Bash", ["command": "swift test"], phase: .completed),
            Self.claudeItem("Bash", ["command": "git diff"], phase: .completed),
            Self.claudeItem("Grep", ["pattern": "TODO"], phase: .completed)
        ]
        XCTAssertEqual(ConversationWorkSummary.title(for: work, harness: .claudeCode, localize: en),
                       "Ran 3 commands, read 2 files, searched files")
        XCTAssertEqual(ConversationWorkSummary.title(for: work, harness: .claudeCode, localize: ko),
                       "명령 3개 실행함, 2개 파일 읽음, 파일 검색함")
        let more = work + [
            Self.claudeItem("Glob", ["pattern": "*.md"], phase: .completed),
            Self.claudeItem("mcp__github__create_issue", ["title": "x"], phase: .completed),
            Self.claudeItem("WebFetch", ["url": "https://example.com"], phase: .completed)
        ]
        XCTAssertEqual(ConversationWorkSummary.title(for: more, harness: .claudeCode, localize: en),
                       "Ran 3 commands, read 2 files, and 4 more tools")
        XCTAssertEqual(ConversationWorkSummary.title(for: more, harness: .claudeCode, localize: ko),
                       "명령 3개 실행함, 2개 파일 읽음 외 도구 4개 더")
        let edits = [Self.fileChange("e1", ["/r/a.swift"]), Self.fileChange("e2", ["/r/a.swift"]),
                     Self.claudeItem("Agent", ["prompt": "x", "subagent_type": "g"], phase: .completed),
                     Self.claudeItem("TodoWrite", ["todos": [Any]()], phase: .completed)]
        XCTAssertEqual(ConversationWorkSummary.title(for: edits, harness: .claudeCode, localize: en),
                       "Edited a file, ran an agent, updated the plan")
    }

    /// Any other harness keeps Yardlet's words, in the order the calls came.
    func testOtherHarnessesKeepTheirSummary() {
        let work = [
            Self.tool("t1", .activity("read")),
            Self.tool("t2", .activity("execute")),
            Self.tool("t3", .activity("read"))
        ]
        XCTAssertEqual(ConversationWorkSummary.title(for: work, harness: .openCode, localize: en),
                       "Read 2 files, used a tool")
        let command = ConversationCommand(command: "/bin/zsh -lc 'ls'", status: "completed")
        XCTAssertEqual(ConversationLineWording.command(command, phase: .completed, harness: .openCode, localize: en)
            .map(\.text), ["Ran /bin/zsh -lc 'ls'"])
    }

    // MARK: - Renders

    /// Codex and Claude Code rows and summaries, light and dark, into `.build/tool-wording-qa/`: a
    /// finished run folded into its summary and opened, and a running one.
    func testTheRowsRender() throws {
        let folder = try WindowlessRender.directory("tool-wording-qa")
        let size = NSSize(width: 760, height: 980)
        try WindowlessRender.hostedInBothAppearances("rows", in: folder, size: size, passes: 10) { appearance in
            ToolWordingShowcase()
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
    }

    // MARK: - Fixtures

    /// A Claude Code call as Yardlet's Claude projector reads its `tool_use` block, then projects it.
    static func claudeItem(_ name: String, _ input: [String: Any], phase: ConversationItemPhase) -> ConversationItem {
        let arguments = try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: input))
        let block: JSONValue = .object(["type": .string("tool_use"), "id": .string("toolu-\(name)-\(UUID().uuidString)"),
                                        "name": .string(name), "input": arguments])
        let frame: JSONValue = .object(["type": .string("assistant"),
                                        "message": .object(["content": .array([block])])])
        let started = ClaudeEventProjector().payloads(from: frame).compactMap { payload -> HarnessActivity? in
            if case let .activityStarted(activity) = payload { return activity }
            return nil
        }.first!
        return ConversationItem(
            id: started.id,
            kind: ConversationActivityProjection.kind(started, harness: .claudeCode, phase: phase, isApproved: false),
            phase: phase, source: .transcript(TranscriptEntry(content: .plan("")))
        )
    }

    /// A Codex command as the App Server sends it: the parts it parsed, inside the login shell.
    static func codexCommand(_ id: String, _ actions: [ConversationCommandAction],
                             phase: ConversationItemPhase = .completed) -> ConversationItem {
        let script = actions.map { action in
            switch action {
            case let .read(_, _, command), let .listFiles(_, command), let .search(_, _, command),
                 let .unknown(command): command
            }
        }.joined(separator: " && ")
        let command = "/bin/zsh -lc \"" + script.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return ConversationItem(id: id, kind: .command(ConversationCommand(command: command, status: "completed",
                                                                           actions: actions)),
                                phase: phase, source: .transcript(TranscriptEntry(content: .plan(""))))
    }

    static func fileChange(_ id: String, _ paths: [String], phase: ConversationItemPhase = .completed) -> ConversationItem {
        let rows = paths.map {
            ConversationFileChangeProjection.row(for: HarnessActivityDiff(path: $0, oldText: "a", newText: "b"),
                                                 phase: phase, workspaceURL: nil)
        }
        return ConversationItem(id: id, kind: .fileChange(ConversationFileChange(rows: rows, handoffs: [])), phase: phase,
                                source: .transcript(TranscriptEntry(content: .plan(""))))
    }

    static func tool(_ id: String, _ kind: ConversationTool.Kind) -> ConversationItem {
        ConversationItem(id: id, kind: .tool(ConversationTool(kind: kind, name: "")), phase: .completed,
                         source: .transcript(TranscriptEntry(content: .plan(""))))
    }
}

private extension ConversationItem {
    func with(phase: ConversationItemPhase) -> ConversationItem {
        var copy = self
        copy.phase = phase
        return copy
    }
}

/// The rows to look at: each provider's finished run opened under its summary, and a running run.
private struct ToolWordingShowcase: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Codex", harness: .codex, finished: Self.codexFinished, running: Self.codexRunning)
            section("Claude Code", harness: .claudeCode, finished: Self.claudeFinished, running: Self.claudeRunning)
        }
        .padding(24)
    }

    private func section(_ title: String, harness: HarnessKind, finished: [ConversationItem],
                         running: [ConversationItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            group(finished, harness: harness)
            group(running, harness: harness)
        }
    }

    private func group(_ items: [ConversationItem], harness: HarnessKind) -> some View {
        ConversationWorkGroup(items: items, harness: harness, startsOpen: true) { item in
            ConversationWorkLine(item: item, harness: harness, workspaceURL: URL(filePath: "/tmp/yardlet"),
                                 runInTerminal: { _ in })
        }
    }

    static var codexFinished: [ConversationItem] {
        [
            ToolRowWordingTests.codexCommand("c1", [
                .read(name: "Parser.swift", path: "/tmp/yardlet/Sources/Parser.swift", command: "sed -n '1,200p' Sources/Parser.swift"),
                .read(name: "Lexer.swift", path: "/tmp/yardlet/Sources/Lexer.swift", command: "sed -n '1,120p' Sources/Lexer.swift")
            ]),
            ToolRowWordingTests.codexCommand("c2", [.search(query: "parseArray", path: "Sources",
                                                            command: "rg -n parseArray Sources")]),
            ToolRowWordingTests.codexCommand("c3", [.listFiles(path: "Tests", command: "ls Tests")]),
            ToolRowWordingTests.fileChange("f1", ["/tmp/yardlet/Sources/Parser.swift"]),
            ConversationItem(id: "c4", kind: .command(ConversationCommand(
                command: "/bin/zsh -lc \"python3 - <<'PY'\nimport json\nprint(json.dumps({'ok': True}))\nPY\"",
                status: "completed", output: "{\"ok\": true}\n", exitCode: 0)),
                phase: .completed, source: .transcript(TranscriptEntry(content: .plan(""))))
        ]
    }

    static var codexRunning: [ConversationItem] {
        [
            ToolRowWordingTests.codexCommand("c5", [.search(query: "TODO", path: nil, command: "rg TODO")]),
            ToolRowWordingTests.codexCommand("c6", [.unknown(command: "swift test --filter ParserTests")],
                                             phase: .running)
        ]
    }

    static var claudeFinished: [ConversationItem] {
        [
            ToolRowWordingTests.claudeItem("Read", ["file_path": "/tmp/yardlet/Sources/Parser.swift"], phase: .completed),
            ToolRowWordingTests.claudeItem("Grep", ["pattern": "parseArray", "path": "Sources"], phase: .completed),
            ToolRowWordingTests.claudeItem("Glob", ["pattern": "Tests/**/*.swift"], phase: .completed),
            ToolRowWordingTests.claudeItem("WebFetch", ["url": "https://www.json.org/json-en.html", "prompt": "Grammar"],
                                           phase: .completed),
            ToolRowWordingTests.claudeItem("Bash", ["command": "swift test --filter ParserTests",
                                                    "description": "Run the parser tests"], phase: .completed),
            ToolRowWordingTests.claudeItem("mcp__github__create_issue", ["title": "Trailing commas"], phase: .completed)
        ]
    }

    static var claudeRunning: [ConversationItem] {
        [
            ToolRowWordingTests.claudeItem("TodoWrite", ["todos": [["content": "Fix", "status": "in_progress"]]],
                                           phase: .completed),
            ToolRowWordingTests.claudeItem("Bash", ["command": "swift build", "description": "Build and run the app"],
                                           phase: .running)
        ]
    }
}

private extension NSView {
    /// Presses every accessibility element labelled `label`, as an assistive app would.
    func pressElements(labelled label: String) -> Int {
        WindowlessRender.withAccessibilityTree {
            var found: [AnyObject] = []
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityLabel?() ?? nil) == label { found.append(child) }
                    visit(child)
                }
            }
            visit(self)
            return found.filter { $0.accessibilityPerformPress?() ?? false }.count
        }
    }
}
