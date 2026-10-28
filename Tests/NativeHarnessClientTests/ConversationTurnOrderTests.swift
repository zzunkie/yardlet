import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A turn reads in the order it happened, by one rule for every harness (`ConversationTurnLayout`,
/// the Codex app 26.1016's `split-items-into-render-groups` and the `kk`, `Ak` and `Lk` of the block that
/// folds its work). 2026-10-23: a user reported that progress commentary pushed the streamed answer back
/// and broke the time order, seen on a Codex task that asked questions while it worked and took the person's replies into
/// the running turn: every answer-phase message was drawn under the work, so the questions sank under
/// the replies and notes written after them.
///
/// - Every message stays where it was written; only the answer that closes the turn is drawn under
///   the work.
/// - The work folds once the provider began to answer, while the turn runs too, unless the person
///   stopped it. Folded, it keeps in view the answers the turn went on past, the messages no finished
///   answer followed, and while it runs, what came after its latest answer.
/// - Harnesses differ only in how they classify a message: Codex by its phase and delivery, Claude
///   Code by where it stands.
///
/// Review images go to `.build/turn-order-qa/`.
@MainActor
final class ConversationTurnOrderTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private static let workspace = URL(filePath: "/tmp/yardlet-turn-order", directoryHint: .isDirectory)
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Codex, saved

    /// The task the person saw it in, as `thread/read` returns it: a question the provider asked while
    /// it went on working, the person's reply steered in, an answer, another steered message, and the
    /// closing answer.
    func testACodexTurnKeepsEachMessageWhereItWasWritten() throws {
        let turn = try project(codexTurn(finished: true))

        XCTAssertEqual(turn.prompt.map(\.id), ["u1"])
        XCTAssertEqual(turn.answers.map(\.id), ["a2"], "only the closing answer is drawn under the work")
        XCTAssertEqual(turn.work.map(\.id), ["m1", "t1", "q1", "t2", "u2", "m2", "t3", "a1", "u3", "m3", "t4"])
        XCTAssertEqual(drawnIDs(turn, folded: false), ["u1", "m1", "t1", "q1", "t2", "u2", "m2", "t3", "a1", "u3", "m3", "t4", "a2"],
                       ConversationDrawOrder.listing(turn, harness: .codex, folded: false))
        // What the provider said to the person stays a message to the person, not a working note.
        XCTAssertEqual(kind(of: "q1", in: turn), .answer(text: "Sign in again in the Apple Developer tab, then tell me.", isStreaming: false))
        XCTAssertEqual(kind(of: "a1", in: turn), .answer(text: "The certificate is issued.", isStreaming: false))
        XCTAssertEqual(kind(of: "m2", in: turn), .commentary(text: "Checking the page again.", isStreaming: false))
        // Folded as the Codex app folds it: the answer the turn went on past stays; the question asked
        // while it worked and the messages the closing answer followed fold with the work.
        XCTAssertTrue(turn.foldsWork)
        XCTAssertEqual(drawnIDs(turn, folded: true), ["u1", "a1", "a2"], ConversationDrawOrder.listing(turn, harness: .codex))
        // read_task reads the turn in the same order.
        XCTAssertEqual((turn.prompt + turn.notices + turn.work + turn.answers).map(\.id),
                       ["u1", "m1", "t1", "q1", "t2", "u2", "m2", "t3", "a1", "u3", "m3", "t4", "a2"])
        // Find reads every message in that order; what the fold hides opens the turn.
        let units = ConversationFindSource.conversation(ConversationPresentation(harness: .codex, turns: [turn])).units
        XCTAssertEqual(units.map(\.id), ["u1", "m1", "q1", "u2", "m2", "a1", "u3", "m3", "a2"])
        XCTAssertEqual(units.filter { $0.revealID != nil }.map(\.id), ["m1", "q1", "u2", "m2", "u3", "m3"])
    }

    /// A turn that ends on a question asks it last and has no answer, so nothing folds and its options
    /// are answered under it. An answer with reasoning that settled after it is still the closing
    /// answer, drawn under that reasoning, as the Codex app moves such a step above its answer. A turn
    /// the person stopped does not fold.
    func testTheClosingAnswerAQuestionAndAStoppedTurn() throws {
        var asking = codexTurn(finished: true)
        asking.items = Array(asking.items.prefix(4))
        let question = try project(asking)
        XCTAssertEqual(question.answers.map(\.id), [])
        XCTAssertEqual(question.work.last?.id, "q1")
        XCTAssertFalse(question.foldsWork, "no answer began")
        XCTAssertEqual(question.actions.questionsToAnswer.map(\.title), ["Sign in again in the Apple Developer tab, then tell me."])

        var reasoned = codexTurn(finished: true)
        reasoned.items.append(decoder.item(from: .object([
            "id": .string("r9"), "type": .string("reasoning"), "summary": .array([]), "content": .array([])
        ]), fallbackID: "r9", lifecycle: .completed))
        let closing = try project(reasoned)
        XCTAssertEqual(closing.answers.map(\.id), ["a2"])
        XCTAssertEqual(closing.work.last?.id, "r9")

        var stopped = codexTurn(finished: true)
        stopped.status = .interrupted
        XCTAssertFalse(try project(stopped).foldsWork, "the person stopped it, as the Codex app keeps a cancelled turn open")
    }

    /// A question Codex asked while it goes on working waits under the running turn for the person, as
    /// the Codex app offers it in its question panel (`y7t`) while the question itself stays where it was
    /// asked; the answer goes into the running turn, and once a reply names the question, it waits no
    /// more. Drawn in both appearances.
    func testAQuestionAskedWhileTheTurnRunsWaitsUnderTheTurn() throws {
        let directory = try WindowlessRender.directory("turn-order-qa")
        var asking = codexTurn(finished: false)
        asking.items = Array(asking.items.prefix(5))
        let questionID = CodexAsyncQuestionReply.itemID(messageID: "q1", index: 0)
        let waiting = try project(asking)
        XCTAssertEqual(waiting.actions.questionsToAnswer.map(\.itemID), [questionID])
        XCTAssertEqual(waiting.work.map(\.id), ["m1", "t1", "q1", "t2"], "the question stays where it was asked")

        var sentTo: [String] = []
        for appearance in WindowlessRender.Appearance.allCases {
            var thread = try XCTUnwrap(decoder.thread(from: .object(["id": .string("thread-order")])))
            thread.turns = [asking]
            let host = WindowlessRender.Host(
                ConversationTimeline(source: .codex(CodexTaskState(thread: thread), workspaceURL: Self.workspace,
                                                    historySelection: nil),
                                     actions: ConversationActions(answerQuestionWhileWorking: { sentTo.append($0) }))
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: 760, height: 900, alignment: .top).background(ParityTheme.canvas),
                size: NSSize(width: 760, height: 900), appearance: appearance
            )
            defer { host.close() }
            host.settle(passes: 10)
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "codex-question-running-\(appearance.suffix).png"))
            let texts = host.accessibilityElements().map(\.description)
            let question = try XCTUnwrap(texts.firstIndex { $0.contains("Sign in again in the Apple Developer tab") }, "\(texts)")
            let call = try XCTUnwrap(texts.lastIndex { $0.contains(L10n.string("Working")) }, "\(texts)")
            XCTAssertLessThan(question, call, "the question is drawn where it was asked, above the work after it")
            XCTAssertGreaterThan(texts.filter { $0.contains("Sign in again in the Apple Developer tab") }.count, 1,
                                 "the question waits under the turn as well:\n\(texts.joined(separator: "\n"))")
        }
        XCTAssertTrue(sentTo.isEmpty)

        let reply = CodexAsyncQuestionReply.message([.init(
            questionItemID: questionID, question: "Sign in again in the Apple Developer tab, then tell me.", answer: "Done"
        )])
        asking.items.append(decoder.item(from: Self.user("u9", reply), fallbackID: "u9", lifecycle: .completed))
        XCTAssertEqual(try project(asking).actions.questionsToAnswer, [], "a reply named it")
    }

    // MARK: - Codex, live

    /// The same turn as the App Server streams it. At every step the turn reads in the order the items
    /// came, the message being written last; once the answer streams the work folds, keeping what the
    /// Codex app keeps; and the turn's end moves nothing.
    func testACodexTurnReadsInOrderWhileItStreamsAndWhenItEnds() throws {
        let directory = try WindowlessRender.directory("turn-order-qa")
        var state = CodexTaskState()
        let reducer = CodexTaskReducer()
        var sequence: UInt64 = 0
        func send(_ method: String, _ params: [String: JSONValue]) {
            sequence += 1
            var params = params
            params["threadId"] = .string("thread-order")
            XCTAssertTrue(reducer.applyNotification(method: method, params: .object(params), sequence: sequence, to: &state),
                          method)
        }
        func turnValue(_ status: String) -> JSONValue {
            .object(["id": .string("turn-1"), "status": .string(status), "items": .array([])])
        }
        func started(_ item: JSONValue) { send("item/started", ["turnId": .string("turn-1"), "item": item]) }
        func completed(_ item: JSONValue) { send("item/completed", ["turnId": .string("turn-1"), "item": item]) }
        func delta(_ id: String, _ text: String) {
            send("item/agentMessage/delta", ["turnId": .string("turn-1"), "itemId": .string(id), "delta": .string(text)])
        }
        let items = Dictionary(uniqueKeysWithValues: codexItems().map { ($0["id"]?.stringValue ?? "", $0) })
        func item(_ id: String) -> JSONValue { items[id]! }
        func streaming(_ id: String) -> JSONValue {
            var value = item(id).objectValue ?? [:]
            value["text"] = .string("")
            return .object(value)
        }
        var drawnAtEachStep: [(stage: String, ids: [String])] = []
        func snapshot(_ stage: String, opened: [String], folded: [String]? = nil,
                      file: StaticString = #filePath, line: UInt = #line) throws {
            let turn = try XCTUnwrap(CodexConversationProjection.presentation(
                state, workspaceURL: Self.workspace, historySelection: nil
            ).turns.first, file: file, line: line)
            let ids = drawnIDs(turn, folded: false)
            XCTAssertEqual(ids, opened, "\(stage):\n" + ConversationDrawOrder.listing(turn, harness: .codex, folded: false),
                           file: file, line: line)
            XCTAssertEqual(turn.foldsWork, folded != nil, "\(stage) folds", file: file, line: line)
            if let folded {
                XCTAssertEqual(drawnIDs(turn, folded: true), folded,
                               "\(stage), folded:\n" + ConversationDrawOrder.listing(turn, harness: .codex), file: file, line: line)
            }
            drawnAtEachStep.append((stage, ids))
        }

        send("thread/started", ["thread": .object(["id": .string("thread-order")])])
        send("turn/started", ["turn": turnValue("inProgress")])
        completed(item("u1"))
        completed(item("m1"))
        started(item("t1"))
        completed(item("t1"))
        completed(item("q1"))
        started(item("t2"))
        try snapshot("question asked, call running", opened: ["u1", "m1", "t1", "q1", "live", "t2"])
        completed(item("t2"))
        completed(item("u2"))
        started(streaming("m2"))
        delta("m2", "Checking the page ")
        try snapshot("reply read, note streaming", opened: ["u1", "m1", "t1", "q1", "t2", "u2", "m2", "live"])
        delta("m2", "again.")
        completed(item("m2"))
        completed(item("t3"))
        started(streaming("a1"))
        delta("a1", "The certificate ")
        // The answer began: the work folds, and the message no finished answer followed stays in view.
        try snapshot("answer streaming", opened: ["u1", "m1", "t1", "q1", "t2", "u2", "m2", "t3", "a1", "live"],
                     folded: ["u1", "u2", "a1", "live"])
        delta("a1", "is issued.")
        completed(item("a1"))
        // Codex reads a steered message once the response it was writing ends.
        completed(item("u3"))
        started(streaming("m3"))
        delta("m3", "Making ")
        try snapshot("message read after the answer, note streaming",
                     opened: ["u1", "m1", "t1", "q1", "t2", "u2", "m2", "t3", "a1", "u3", "m3", "live"],
                     folded: ["u1", "a1", "u3", "m3", "live"])
        let streamingState = state
        delta("m3", "the key.")
        completed(item("m3"))
        completed(item("t4"))
        started(streaming("a2"))
        delta("a2", "Both are in Downloads.")
        completed(item("a2"))
        var finishedTurn = turnValue("completed").objectValue ?? [:]
        finishedTurn["durationMs"] = .integer(250_000)
        send("turn/completed", ["turn": .object(finishedTurn)])
        try snapshot("finished", opened: ["u1", "m1", "t1", "q1", "t2", "u2", "m2", "t3", "a1", "u3", "m3", "t4", "a2"],
                     folded: ["u1", "a1", "a2"])

        // Nothing drawn moved: every step's items keep their order in the finished turn.
        let finished = drawnAtEachStep.last!.ids
        for step in drawnAtEachStep.dropLast() {
            let kept = step.ids.filter { $0 != "live" }
            XCTAssertEqual(finished.filter(kept.contains), kept, "\(step.stage) moved when the turn ended")
        }

        // Drawn: the answer stays above the message read after it and the note it led to.
        for (stage, drawnState) in [("streaming", streamingState), ("finished", state)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(
                    ConversationTimeline(source: .codex(drawnState, workspaceURL: Self.workspace, historySelection: nil)),
                    size: NSSize(width: 760, height: 1_000), appearance: appearance
                )
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "codex-steps-\(stage)-\(appearance.suffix).png"))
                let texts = drawing.elements.map(\.description)
                let joined = texts.joined(separator: "\n")
                let answer = try XCTUnwrap(texts.firstIndex { $0.contains("The certificate is issued.") }, joined)
                XCTAssertFalse(joined.contains("Checking the page again."), "the notes fold:\n\(joined)")
                if stage == "streaming" {
                    let message = try XCTUnwrap(texts.firstIndex { $0.contains("Also make the API key.") }, joined)
                    let note = try XCTUnwrap(texts.firstIndex { $0.contains("Making") }, joined)
                    XCTAssertLessThan(answer, message, joined)
                    XCTAssertLessThan(message, note, joined)
                    // The question folds with the work; no reply named it, so it still waits under the turn.
                    let question = try XCTUnwrap(texts.firstIndex { $0.contains("Sign in again in the Apple Developer tab") }, joined)
                    XCTAssertGreaterThan(question, note, "it waits under the turn, not in the folded work:\n\(joined)")
                } else {
                    XCTAssertFalse(joined.contains("Sign in again in the Apple Developer tab"), "the question folds:\n\(joined)")
                    let closing = try XCTUnwrap(texts.firstIndex { $0.contains("Both are in Downloads.") }, joined)
                    XCTAssertLessThan(answer, closing, joined)
                    XCTAssertFalse(joined.contains("Also make the API key."), "the message folds under the answer:\n\(joined)")
                }
            }
        }
    }

    // MARK: - One rule for every harness

    /// The same turn in Codex and in Claude Code — notes, a call, an answer, a message read into the
    /// running turn, two calls with thinking between them, more notes and a call, and the closing answer
    /// — is laid out and folded alike, while it runs and once it ended, folded and opened. Folded while
    /// it runs, the two calls after the answer stay one summary line, as they are in the opened work,
    /// with the thinking (a Codex reasoning summary, Claude Code's thinking) inside it where it came and
    /// counted as no call; and the turn reads its time once, on the live line beside what it does now:
    /// the header only folds the work. Drawn in both appearances, both harnesses.
    func testCodexAndClaudeCodeLayOutAndFoldTheSameTurnAlike() throws {
        let directory = try WindowlessRender.directory("turn-order-qa")
        for finished in [false, true] {
            let stage = finished ? "finished" : "running"
            let codex = try project(sharedCodexTurn(finished: finished))
            let claude = try XCTUnwrap(TranscriptConversationProjection.presentation(
                from: sharedClaudeEntries(finished: finished), harness: .claudeCode,
                status: finished ? .ready : .running, latestTurnIsComplete: finished
            ).turns.first)
            for folded in [true, false] {
                let rows = { (turn: ConversationTurn, harness: HarnessKind) in
                    ConversationDrawOrder.rows(turn, harness: harness, folded: folded).map { "\($0.part) \($0.shape): \($0.text)" }
                }
                XCTAssertEqual(rows(codex, .codex), rows(claude, .claudeCode), "\(stage), folded \(folded)")
            }
            XCTAssertTrue(codex.foldsWork && claude.foldsWork, stage)
            XCTAssertEqual(ConversationDrawOrder.rows(codex, harness: .codex).map { "\($0.shape): \($0.text)" }, finished
                ? ["message: Issue the certificate, then make the API key.", "answer: The certificate is issued.",
                   "answer: Both are in Downloads."]
                : ["message: Issue the certificate, then make the API key.", "answer: The certificate is issued.",
                   "message: Also make the API key.", "call: swift run keygen", "reasoning: \(Self.thought)",
                   "call: ls Downloads", "commentary (streaming): Making the key.", "line: \(L10n.string("Working"))"])
            // The two calls the folded running turn keeps in view are one run in both, the thinking in it.
            let keptCalls = { (turn: ConversationTurn, harness: HarnessKind) -> [ConversationItem] in
                let live = ConversationLiveWork.make(turn, harness: harness, workspaceURL: nil)
                return ConversationWorkGrouping.runsKeptWhenFolded(turn, live: live).flatMap { run -> [ConversationItem] in
                    if case let .group(items) = run { return items }
                    return []
                }
            }
            let summaries = [
                "codex": ConversationWorkSummary.header(for: keptCalls(codex, .codex), harness: .codex).text,
                "claude-code": ConversationWorkSummary.header(for: keptCalls(claude, .claudeCode), harness: .claudeCode).text
            ]
            XCTAssertEqual(keptCalls(codex, .codex).map { ConversationDrawOrder.text(of: $0) },
                           finished ? [] : ["swift run keygen", Self.thought, "ls Downloads"], stage)
            XCTAssertEqual(keptCalls(claude, .claudeCode).map { ConversationDrawOrder.text(of: $0) },
                           keptCalls(codex, .codex).map { ConversationDrawOrder.text(of: $0) }, stage)

            for (harness, timeline) in [
                ("codex", ConversationTimeline(source: .codex(
                    CodexTaskState(thread: sharedCodexThread(finished: finished)), workspaceURL: Self.workspace, historySelection: nil
                ))),
                ("claude-code", ConversationTimeline(source: .transcript(
                    entries: sharedClaudeEntries(finished: finished), harness: .claudeCode,
                    status: finished ? .ready : .running, latestTurnIsComplete: finished
                )))
            ] {
                for appearance in WindowlessRender.Appearance.allCases {
                    let size = NSSize(width: 760, height: 900)
                    let folded = try ConversationDrawing.draw(timeline, size: size, appearance: appearance)
                    try WindowlessRender.writePNG(folded.capture.bitmap, to: directory.appending(
                        path: "\(harness)-\(stage)-folded-\(appearance.suffix).png"))
                    let texts = folded.elements.map(\.description).joined(separator: "\n")
                    XCTAssertFalse(texts.contains("Checking the certificate page."), "\(harness) \(stage) folds:\n\(texts)")
                    XCTAssertTrue(texts.contains("The certificate is issued."), "\(harness) \(stage):\n\(texts)")
                    XCTAssertEqual(texts.contains("Also make the API key."), !finished, "\(harness) \(stage):\n\(texts)")
                    if !finished {
                        // One summary line for the two calls, folded, not a line for each.
                        let summary = try XCTUnwrap(summaries[harness])
                        XCTAssertTrue(texts.contains(summary), "\(harness) \(stage) summary \(summary):\n\(texts)")
                        XCTAssertFalse(texts.contains("swift run keygen"), "\(harness) \(stage) folds the run:\n\(texts)")
                        XCTAssertFalse(texts.contains(Self.thought), "\(harness) \(stage) folds the thinking:\n\(texts)")
                        // The time is the live line's, and the header reads none while the turn runs; the
                        // thinking is no step.
                        XCTAssertTrue(folded.elements.contains { element in
                            [element.label, element.value].contains {
                                $0.hasPrefix(L10n.string("Working")) && $0.contains(L10n.format("%lld steps", Int64(3)))
                                    && ConversationDrawing.endsWithElapsedTime($0)
                            }
                        }, "\(harness) \(stage) live line reads the steps and the time:\n\(texts)")
                    }
                    let readsWorkTime = folded.elements.contains {
                        ConversationDrawing.isWorkTime($0.label) || ConversationDrawing.isWorkTime($0.value)
                    }
                    XCTAssertEqual(readsWorkTime, finished, "\(harness) \(stage) header reads a work time once it ended:\n\(texts)")

                    // Opened by the person: everything in the order it happened.
                    let host = WindowlessRender.Host(
                        timeline.environment(\.colorScheme, appearance.colorScheme)
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .background(ParityTheme.canvas),
                        size: size, appearance: appearance
                    )
                    defer { host.close() }
                    host.settle(passes: 10)
                    XCTAssertTrue(host.hosting.pressTurnHeader(), "\(harness) \(stage) has a header to open")
                    host.settle(passes: 10)
                    try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(
                        path: "\(harness)-\(stage)-opened-\(appearance.suffix).png"))
                    let opened = host.accessibilityElements().map(\.description)
                    let order = ["Issue the certificate", "Checking the certificate page.", "The certificate is issued.",
                                 "Also make the API key.", L10n.string("Thought process"), "ls Downloads",
                                 "Making the key."]
                        + (finished ? ["Both are in Downloads."] : [])
                    let positions = try order.map { text in
                        try XCTUnwrap(opened.firstIndex { $0.contains(text) }, "\(harness) \(stage) opened: \(text)\n\(opened)")
                    }
                    XCTAssertEqual(positions, positions.sorted(), "\(harness) \(stage) opened:\n\(opened.joined(separator: "\n"))")
                }
            }
        }
    }

    // MARK: - Claude Code, live

    /// Claude Code reads a message into its running turn at its next step, after the answer it was
    /// writing ended: the answer stays above the message, and the turn's end moves nothing. Once the
    /// closing answer follows the message, the message folds with the work.
    func testAClaudeTurnReadsInOrderWhileItStreamsAndWhenItEnds() throws {
        var session = ClaudeLiveTurn()
        session.send("Fix the build")
        session.stream("Looking at ", "the log.")
        session.call("toolu_1", "swift build")
        session.stream("Fixed: the import ", "was missing.")
        session.read("Also run the tests")
        session.delta("Running ")
        let streamingTurn = try session.turn(status: .running)
        XCTAssertEqual(session.drawn(streamingTurn), [
            "message: Fix the build", "commentary: Looking at the log.", "call: swift build",
            "answer: Fixed: the import was missing.", "message: Also run the tests", "commentary (streaming): Running "
        ], ConversationDrawOrder.listing(streamingTurn, harness: .claudeCode, folded: false))
        XCTAssertEqual(session.drawn(streamingTurn, folded: true), [
            "message: Fix the build", "answer: Fixed: the import was missing.", "message: Also run the tests",
            "commentary (streaming): Running "
        ], ConversationDrawOrder.listing(streamingTurn, harness: .claudeCode))
        session.delta("the tests.")
        session.complete("Running the tests.")
        session.call("toolu_2", "swift test")
        session.stream("All tests pass.")
        session.end()
        let finished = try session.turn(status: .ready)
        XCTAssertEqual(session.drawn(finished), [
            "message: Fix the build", "commentary: Looking at the log.", "call: swift build",
            "answer: Fixed: the import was missing.", "message: Also run the tests", "commentary: Running the tests.",
            "call: swift test", "answer: All tests pass."
        ], ConversationDrawOrder.listing(finished, harness: .claudeCode, folded: false))
        XCTAssertEqual(session.drawn(finished, folded: true), [
            "message: Fix the build", "answer: Fixed: the import was missing.", "answer: All tests pass."
        ])
    }

    /// A message read while an answer still streams (the CLI's lifecycle arriving between two deltas of
    /// one text, which 2.1.299 does not do: it reads a message at a step) cuts the text at the message
    /// while it streams; once the text completes, it is whole above the message, where it began, and the
    /// words that streamed under the message do not stay there as well.
    func testAClaudeMessageReadWhileAnAnswerStreamsKeepsTheAnswerWhole() throws {
        var session = ClaudeLiveTurn()
        session.send("Fix the build")
        session.call("toolu_1", "swift build")
        session.delta("Fixed: the import ")
        session.read("Also run the tests")
        session.delta("was missing.")
        session.complete("Fixed: the import was missing.")
        session.stream("Running the tests.")
        session.end()
        let turn = try session.turn(status: .ready)
        XCTAssertEqual(session.drawn(turn), [
            "message: Fix the build", "call: swift build", "answer: Fixed: the import was missing.",
            "message: Also run the tests", "answer: Running the tests."
        ], ConversationDrawOrder.listing(turn, harness: .claudeCode, folded: false))
    }

    // MARK: - Fixtures

    private func project(_ turn: CodexTurnState) throws -> ConversationTurn {
        var thread = try XCTUnwrap(decoder.thread(from: .object(["id": .string("thread-order")])))
        thread.turns = [turn]
        return try XCTUnwrap(CodexConversationProjection.presentation(
            CodexTaskState(thread: thread), workspaceURL: Self.workspace, historySelection: nil
        ).turns.first)
    }

    private func drawnIDs(_ turn: ConversationTurn, folded: Bool) -> [String] {
        ConversationDrawOrder.rows(turn, harness: .codex, folded: folded).map(\.id)
    }

    private func kind(of id: String, in turn: ConversationTurn) -> ConversationItemKind? {
        (turn.prompt + turn.work + turn.answers).first { $0.id == id }?.kind
    }

    private func codexTurn(finished: Bool) -> CodexTurnState {
        var turn: [String: JSONValue] = [
            "id": .string("turn-1"), "status": .string(finished ? "completed" : "inProgress"), "items": .array(codexItems())
        ]
        if finished { turn["durationMs"] = .integer(250_000) }
        return decoder.turn(from: .object(turn), fallbackID: "turn-1")!
    }

    private static func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private static func message(_ id: String, _ text: String, phase: String, asks: Bool = false) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase),
                 "memoryCitation": .null, "delivery": asks ? .string("async") : .null,
                 "questions": asks ? .array([.object(["title": .string(text), "options": .null])]) : .null])
    }

    /// A real Codex turn's shape (2026-10-22): calls, a question asked while the work went on, the
    /// person's reply, notes, an answer, another message read after it, and the closing answer.
    private func codexItems() -> [JSONValue] {
        func call(_ id: String, _ title: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("mcpToolCall"), "server": .string("cua_repl"), "tool": .string("js"),
                     "status": .string("completed"), "arguments": .object(["title": .string(title)]),
                     "result": .null, "error": .null])
        }
        return [
            Self.user("u1", "Issue the certificate, then make the API key."),
            Self.message("m1", "Checking the certificate page.", phase: "commentary"),
            call("t1", "Press Continue"),
            Self.message("q1", "Sign in again in the Apple Developer tab, then tell me.", phase: "final_answer", asks: true),
            call("t2", "Read the page"),
            Self.user("u2", "I'm signed in."),
            Self.message("m2", "Checking the page again.", phase: "commentary"),
            call("t3", "Download the certificate"),
            Self.message("a1", "The certificate is issued.", phase: "final_answer"),
            Self.user("u3", "Also make the API key."),
            Self.message("m3", "Making the key.", phase: "commentary"),
            call("t4", "Generate the key"),
            Self.message("a2", "Both are in Downloads.", phase: "final_answer")
        ]
    }

    // The scene both harnesses can tell: Claude Code sends no message while its work goes on, so the
    // question is Codex's alone and left out here.

    /// The thinking between the two calls: a Codex reasoning summary, Claude Code's thinking.
    private static let thought = "The key goes next to the certificate."

    private func sharedCodexThread(finished: Bool) -> CodexThreadState {
        var thread = decoder.thread(from: .object(["id": .string("thread-shared")]))!
        thread.turns = [sharedCodexTurn(finished: finished)]
        return thread
    }

    private func sharedCodexTurn(finished: Bool) -> CodexTurnState {
        func command(_ id: String, _ command: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("commandExecution"), "command": .string(command),
                     "cwd": .string(Self.workspace.path), "status": .string("completed"), "commandActions": .array([]),
                     "aggregatedOutput": .string("ok\n"), "exitCode": .integer(0)])
        }
        var items: [JSONValue] = [
            Self.user("u1", "Issue the certificate, then make the API key."),
            Self.message("m1", "Checking the certificate page.", phase: "commentary"),
            command("c1", "swift build"),
            Self.message("a1", "The certificate is issued.", phase: "final_answer"),
            Self.user("u2", "Also make the API key."),
            command("k1", "swift run keygen"),
            .object(["id": .string("r1"), "type": .string("reasoning"), "summary": .array([.string(Self.thought)]),
                     "content": .array([])]),
            command("k2", "ls Downloads"),
            Self.message("m2", "Making the key.", phase: "commentary")
        ]
        if finished {
            items += [command("c2", "swift test"), Self.message("a2", "Both are in Downloads.", phase: "final_answer")]
        }
        var turn: [String: JSONValue] = [
            "id": .string("turn-shared"), "status": .string(finished ? "completed" : "inProgress"), "items": .array(items)
        ]
        if finished { turn["durationMs"] = .integer(250_000) }
        var decoded = decoder.turn(from: .object(turn), fallbackID: "turn-shared")!
        if !finished { decoded.items[decoded.items.count - 1].lifecycle = .inProgress }
        return decoded
    }

    private func sharedClaudeEntries(finished: Bool) -> [TranscriptEntry] {
        func at(_ seconds: Double, _ content: TranscriptEntryContent, joins: Bool? = nil) -> TranscriptEntry {
            TranscriptEntry(createdAt: Self.start.addingTimeInterval(seconds), content: content, joinsRunningTurn: joins)
        }
        func bash(_ id: String, _ command: String) -> TranscriptEntryContent {
            .activity(HarnessActivity(id: id, kind: "Bash", title: "Bash", input: command, output: "ok\n"), state: .completed)
        }
        var entries = [
            at(0, .user(text: "Issue the certificate, then make the API key.")),
            at(10, .assistant(text: "Checking the certificate page.", isStreaming: false)),
            at(20, bash("toolu_1", "swift build")),
            at(60, .assistant(text: "The certificate is issued.", isStreaming: false)),
            at(70, .user(text: "Also make the API key."), joins: true),
            at(72, bash("toolu_k1", "swift run keygen")),
            at(73, .reasoning(text: Self.thought, isStreaming: false)),
            at(75, bash("toolu_k2", "ls Downloads")),
            at(80, .assistant(text: "Making the key.", isStreaming: !finished))
        ]
        if finished {
            entries += [at(200, bash("toolu_2", "swift test")), at(250, .assistant(text: "Both are in Downloads.", isStreaming: false))]
        }
        return entries
    }
}

/// A Claude Code turn as the app builds it from the CLI's stream: frames through the session's
/// projection into the transcript, and a message the CLI reports reading (`command_lifecycle`) added
/// where the report comes, as `AppModel.acceptFollowUpDelivery` adds it.
private struct ClaudeLiveTurn {
    private var projection = ClaudeSessionProjection()
    private var builder = TranscriptBuilder()

    mutating func send(_ text: String) { builder.appendUser(text) }

    mutating func read(_ text: String) { builder.appendUser(text, joinsRunningTurn: true) }

    mutating func delta(_ text: String) {
        frame(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#)
    }

    mutating func complete(_ text: String) {
        frame(#"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#)
    }

    /// The text streamed in parts, then completed.
    mutating func stream(_ parts: String...) {
        parts.forEach { delta($0) }
        complete(parts.joined())
    }

    mutating func call(_ id: String, _ command: String) {
        frame(#"{"type":"assistant","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)","description":"\#(command)"}}]}}"#)
        frame(#"{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#)
    }

    mutating func end() {
        frame(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#)
    }

    func turn(status: SessionStatus) throws -> ConversationTurn {
        try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: status, latestTurnIsComplete: status != .running
        ).turns.first)
    }

    /// The turn as it is drawn, one "shape: text" per item, opened unless `folded`.
    func drawn(_ turn: ConversationTurn, folded: Bool = false) -> [String] {
        ConversationDrawOrder.rows(turn, harness: .claudeCode, folded: folded)
            .filter { $0.part != "live" }
            .map { "\($0.shape): \($0.text)" }
    }

    private mutating func frame(_ text: String) {
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        for payload in projection.payloads(from: value) { builder.apply(payload) }
    }
}

private extension NSView {
    /// Presses the turn header's fold, as an assistive app would: the button labelled with the work
    /// time, or "Work details" where the turn reads none.
    func pressTurnHeader() -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        func isHeader(_ label: String) -> Bool {
            ConversationDrawing.isWorkTime(label) || label.hasPrefix(L10n.string("Work details"))
                || label.contains(L10n.format("Working for %lld seconds", Int64(0)).prefix(4))
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if let label = child.accessibilityLabel?() ?? nil, isHeader(label),
                   (child.accessibilityRole?() ?? nil) == NSAccessibility.Role.button { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(self)?.accessibilityPerformPress?() ?? false
    }
}
