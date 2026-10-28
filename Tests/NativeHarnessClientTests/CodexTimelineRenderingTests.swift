import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Codex turns as the timeline draws them, rendered in a test window that is never shown:
/// a stopped turn and its command card, a command streaming output, a Plan mode turn with its
/// implement question, and the notices the App Server sends beside a turn. The images go to
/// `.build/codex-timeline-qa` for review.
@MainActor
final class CodexTimelineRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()

    func testAStoppedTurnReadsAsStoppedInItsHeaderAndCommandCard() throws {
        let output = (1...30).map { "Test Case 'ReducerTests.test\($0)' passed (0.0\($0 % 10) seconds)." }
            .joined(separator: "\n") + "\n"
        let state = thread([
            turn("turn-1", status: "completed", durationMs: 41_000, items: [
                user("u1", "Run the tests"),
                command("c0", "swift test --filter Reducer", status: "completed", output: "All 30 tests passed.\n", exitCode: 0),
                answer("a1", "All 30 tests pass.")
            ]),
            turn("turn-2", status: "interrupted", durationMs: 22_000, items: [
                user("u2", "Run the full suite again"),
                command("c1", "swift test --build-system native", status: "interrupted", output: output)
            ])
        ])
        try render(timeline(state), height: 300, name: "stopped-turn")

        // The folded work of both turns, card by card.
        try render(commandCards(state).padding(24), height: 420, name: "stopped-command-card")
    }

    func testARunningCommandShowsItsLatestLinesAsTheyStream() throws {
        var state = thread([
            turn("turn-1", status: "inProgress", items: [user("u1", "Build the app")])
        ])
        let reducer = CodexTaskReducer()
        var sequence: UInt64 = 0
        func apply(_ method: String, _ params: [String: JSONValue]) {
            sequence += 1
            var params = params
            params["threadId"] = .string("thread-qa")
            params["turnId"] = .string("turn-1")
            XCTAssertTrue(reducer.applyNotification(method: method, params: .object(params), sequence: sequence, to: &state))
        }
        apply("item/started", ["item": command("c1", "swift build --build-system native", status: "inProgress", output: nil)])
        for index in 1...640 {
            apply("item/commandExecution/outputDelta", [
                "itemId": .string("c1"), "delta": .string("[\(index)/640] Compiling NativeHarnessClient File\(index).swift\n")
            ])
        }
        guard case let .commandExecution(live) = state.thread?.turns.first?.items.last?.content else {
            return XCTFail("the running command should keep its card")
        }
        XCTAssertTrue(CodexCommandOutputWindow(live.aggregatedOutput ?? "").text
            .hasSuffix("[640/640] Compiling NativeHarnessClient File640.swift"))
        try render(timeline(state), height: 420, name: "running-command")
    }

    func testAPlanModeTurnShowsItsPlanCardAndAsksToImplementIt() throws {
        let plan = """
        # Show stopped turns

        1. Replace **Worked for** with *You stopped after* on interrupted turns.
        2. Read `Stopped` on interrupted command cards.
        3. Cover both with focused tests.
        """
        var planTurn = turn("turn-1", status: "completed", durationMs: 95_000, items: [
            user("u1", "Plan a fix for how stopped turns read"),
            .object(["id": .string("p1"), "type": .string("plan"), "text": .string(plan)]),
            answer("a1", "This keeps the change to the timeline and its projection.")
        ])
        planTurn.items.append(notice("n1", kind: "modelRerouted", message: "gpt-5.5-mini", reason: "highRiskCyberActivity"))
        planTurn.items.append(notice("n2", kind: "warning", message: "Under-development features enabled: memories"))
        try render(timeline(thread([planTurn]), onImplementPlan: { _ in }), height: 640, name: "plan-turn")
    }

    func testAStreamingPlanReadsAsWritingAndTheImplementRequestShowsAsTheChoice() throws {
        var state = thread([
            turn("turn-1", status: "completed", durationMs: 30_000, items: [
                user("u1", "Plan the fix"),
                .object(["id": .string("p1"), "type": .string("plan"), "text": .string("# Plan\n1. Fix it")])
            ]),
            turn("turn-2", status: "completed", durationMs: 12_000, items: [
                user("u2", CodexPlanImplementation.request(for: "# Plan\n1. Fix it")),
                answer("a2", "Fixed.")
            ]),
            turn("turn-3", status: "inProgress", items: [user("u3", "Plan the next step")])
        ])
        state.thread?.turns[2].items.append(decoder.item(
            from: .object(["id": .string("p3"), "type": .string("plan"), "text": .string("# Next\n1. Measure the")]),
            fallbackID: "p3", lifecycle: .inProgress
        ))
        try render(timeline(state, onImplementPlan: { _ in }), height: 560, name: "writing-plan")
    }

    /// A Codex message that asks with options (`request_user_input_async`) reads as its question, and
    /// its options are the question card's, as the Codex app asks it, not a list in the answer. The
    /// card sends the Codex app's reply message, and once the thread holds it the question turn reads
    /// as what was answered, the reply's bubble as the answer rather than its JSON.
    func testAnAsyncQuestionReadsAsItsTitleAndAnswersWithItsOptions() throws {
        let title = "The 1.03GB archive is ready, but Google asks to confirm the password right before the download. Tell me once you have signed in."
        let message: JSONValue = .object([
            "id": .string("a1"), "type": .string("agentMessage"), "phase": .string("final_answer"),
            "text": .string(title + "\n- Download sign-in done\n- Download later"),
            "questions": .array([.object(["title": .string(title),
                                          "options": .array([.string("Download sign-in done"), .string("Download later")])])])
        ])
        let state = thread([turn("turn-1", status: "completed", durationMs: 20_000, items: [
            user("u1", "Then let's download it here"), message
        ])])
        let presentation = CodexConversationProjection.presentation(
            state, workspaceURL: URL(filePath: "/Users/me/yardlet"), historySelection: nil)
        let latest = try XCTUnwrap(presentation.turns.last)
        XCTAssertEqual(latest.actions.questionsToAnswer.map(\.options), [["Download sign-in done", "Download later"]])
        XCTAssertEqual(latest.actions.questionsToAnswer.map(\.itemID), [#"["request_user_input_async","a1",0]"#],
                       "The question is known by the Codex app's ID for it")
        XCTAssertNil(latest.actions.answeredQuestions)
        // Sent while the work went on, the question never closes the turn: it stays in the work where it
        // was asked, in an answer's shape (`ConversationTurnLayout`), and a turn that ends on it does not fold.
        XCTAssertEqual(latest.answers, [])
        XCTAssertFalse(latest.foldsWork)
        let shown = latest.work.compactMap { item -> String? in
            if case let .answer(text, _) = item.kind { text } else { nil }
        }
        XCTAssertEqual(shown, [title], "The message reads as the question, without the options as a list")

        var answers: [String] = []
        let view = TaskConversationView(
            harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"), entries: [], codexTaskState: state,
            actions: ConversationActions(retryTurn: { _ in }, answerQuestion: { answers.append($0) }))
        try render(view, height: 420, name: "async-question")

        // The card starts on the first option and sends the Codex app's reply for the one it holds.
        var input = ConversationRequestFormInput()
        input.preselect(latest.actions.questionsToAnswer.map(ConversationQuestionStep.init))
        input.toggle("Download later", for: ConversationQuestionStep(latest.actions.questionsToAnswer[0]))
        let reply = CodexQuestionOptions.reply(latest.actions.questionsToAnswer, input: input)
        XCTAssertEqual(reply, "<send_user_message_question_reply>\n"
            + #"[{"questionItemId":"[\"request_user_input_async\",\"a1\",0]","question":""# + title
            + #"","answer":"Download later"}]"# + "\n</send_user_message_question_reply>")

        // Once the thread holds the reply, the next turn starts from it: the question turn reads as its
        // answer, and the reply's bubble as the answer, not its JSON.
        let answered = thread([
            turn("turn-1", status: "completed", items: [user("u1", "Then let's download it here"), message]),
            turn("turn-2", status: "inProgress", items: [user("u2", reply)])
        ])
        let next = CodexConversationProjection.presentation(
            answered, workspaceURL: URL(filePath: "/Users/me/yardlet"), historySelection: nil)
        XCTAssertTrue(next.turns.allSatisfy { $0.actions.questionsToAnswer.isEmpty })
        let record = try XCTUnwrap(next.turns.first?.actions.answeredQuestions)
        XCTAssertEqual(record.answers, [#"["request_user_input_async","a1",0]"#: ConversationQuestionAnswer(options: ["Download later"])])
        XCTAssertEqual(next.turns.last?.prompt.compactMap(\.sentText), ["Download later"])
        XCTAssertNil(next.turns.last?.actions.editDraft, "A reply's JSON goes back in no composer")
        try render(TaskConversationView(
            harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"), entries: [], codexTaskState: answered,
            actions: ConversationActions(retryTurn: { _ in }, answerQuestion: { answers.append($0) })),
            height: 520, name: "async-question-answered")

        // A reply Yardlet sent before it wrote the Codex app's reads back too; any other message is no
        // answer, and the questions no longer wait.
        let legacy = CodexConversationProjection.presentation(thread([
            turn("turn-1", status: "completed", items: [user("u1", "Then let's download it here"), message]),
            turn("turn-2", status: "completed", items: [user("u2", "Download sign-in done")])
        ]), workspaceURL: URL(filePath: "/Users/me/yardlet"), historySelection: nil)
        XCTAssertEqual(legacy.turns.first?.actions.answeredQuestions?.answers.values.map(\.options), [["Download sign-in done"]])
        let movedOn = CodexConversationProjection.presentation(thread([
            turn("turn-1", status: "completed", items: [user("u1", "Then let's download it here"), message]),
            turn("turn-2", status: "completed", items: [user("u2", "Wait, let's do something else first")])
        ]), workspaceURL: URL(filePath: "/Users/me/yardlet"), historySelection: nil)
        XCTAssertNil(movedOn.turns.first?.actions.answeredQuestions)
        XCTAssertTrue(movedOn.turns.allSatisfy { $0.actions.questionsToAnswer.isEmpty })
    }

    // MARK: - Fixtures

    /// The timeline as a task draws it.
    private func timeline(_ state: CodexTaskState, onImplementPlan: ((String) -> Void)? = nil) -> some View {
        TaskConversationView(
            harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"), entries: [], codexTaskState: state,
            actions: ConversationActions(retryTurn: { _ in }, implementCodexPlan: onImplementPlan)
        )
    }

    /// The command cards of every turn, as the conversation draws them inside a turn's work.
    private func commandCards(_ state: CodexTaskState) -> some View {
        let workspace = URL(filePath: "/Users/me/yardlet")
        let presentation = CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
        let context = ConversationItemContext(harness: .codex, workspaceURL: workspace, actions: ConversationActions())
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(presentation.turns, id: \.id) { turn in
                ForEach(turn.work.filter { if case .command = $0.kind { true } else { false } }) { item in
                    ConversationItemView(item: item, isTurnFinished: turn.status.isTerminal, context: context)
                }
            }
        }
    }

    private func thread(_ turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-qa")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }

    private func turn(_ id: String, status: String, durationMs: Int64? = nil, items: [JSONValue]) -> CodexTurnState {
        var value: [String: JSONValue] = ["id": .string(id), "status": .string(status), "items": .array(items)]
        if let durationMs { value["durationMs"] = .integer(durationMs) }
        return decoder.turn(from: .object(value), fallbackID: id)!
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func answer(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")])
    }

    private func command(_ id: String, _ command: String, status: String, output: String?, exitCode: Int64? = nil) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string(command),
            "cwd": .string("/Users/me/yardlet"), "status": .string(status), "commandActions": .array([]),
            "aggregatedOutput": output.map(JSONValue.string) ?? .null,
            "exitCode": exitCode.map(JSONValue.integer) ?? .null
        ])
    }

    private func notice(_ id: String, kind: String, message: String, reason: String? = nil) -> CodexItemState {
        var raw: [String: JSONValue] = [
            "id": .string(id), "type": .string(CodexNoticeItem.itemType),
            "kind": .string(kind), "message": .string(message)
        ]
        raw["reason"] = reason.map(JSONValue.string)
        return decoder.item(from: .object(raw), fallbackID: id, lifecycle: .completed)
    }

    private func render<Content: View>(_ content: Content, height: CGFloat, name: String) throws {
        let captures = try WindowlessRender.hostedInBothAppearances(
            name, in: WindowlessRender.directory("codex-timeline-qa"), size: NSSize(width: 760, height: height)
        ) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 760, height: height, alignment: .top)
                .background(ParityTheme.canvas)
        }
        for capture in captures {
            XCTAssertEqual(capture.bitmap.pixelsWide, Int(760 * capture.backingScaleFactor))
        }
    }
}
