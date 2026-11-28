import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Claude's `AskUserQuestion` card as the conversation draws it, under the window's
/// monochrome tint, light and dark.
@MainActor
final class QuestionCardRenderingTests: XCTestCase {
    static let questions = [
        PermissionQuestion(
            question: "Which parts should the release notes cover?", header: "Scope",
            options: [
                PermissionQuestionOption(label: "Composer", description: "Return, ⌘Return and the queue"),
                PermissionQuestionOption(label: "Streaming", description: "The live line while a turn runs"),
                PermissionQuestionOption(label: "Question card", description: "Option and button text"),
                PermissionQuestionOption(label: "Subagents", description: "Harness and model on each card")
            ],
            allowsMultipleSelections: true),
        PermissionQuestion(
            question: "Who will read them?", header: "Audience",
            options: [
                PermissionQuestionOption(label: "The team", description: "Engineers who build Yardlet"),
                PermissionQuestionOption(label: "Reviewers", description: "People checking the change"),
                PermissionQuestionOption(label: "Everyone", description: "A short public summary"),
                PermissionQuestionOption(label: "Only me", description: "Notes to keep")
            ],
            allowsMultipleSelections: true)
    ]

    static func request(state: ConversationRequestState) -> ConversationRequest {
        let permission = PermissionRequest(
            id: "ask", title: "Claude has questions", detail: nil, command: nil,
            structured: .questions(questions), toolCallID: "ask-tool")
        let entry = TranscriptEntry(content: .permission(permission, state: state == .pending ? .pending : .allowed))
        // Answered, the card reads as the answers the provider recorded.
        let recorded = state == .pending ? nil : picked.answers(for: ConversationRequestForm.choices(questions).questionSteps)
        return ConversationRequest(
            id: "ask", title: permission.title, form: .choices(questions), state: state,
            responses: state == .pending ? ConversationRequestResponses.questions : [],
            toolCallID: "ask-tool", recordedAnswers: recorded, source: .transcript(entry))
    }

    static var picked: ConversationRequestFormInput {
        var input = ConversationRequestFormInput()
        input.selections[questions[0].question] = ["Composer", "Question card"]
        input.selections[questions[1].question] = ["The team"]
        return input
    }

    /// The card in the conversation's column, under the shell's tint as `MainWindow` sets it.
    static func card(_ request: ConversationRequest, input: ConversationRequestFormInput = .init(),
                     appearance: WindowlessRender.Appearance) -> some View {
        ConversationRequestCard(request: request,
                                actions: ConversationActions(answer: { _, _ in }), input: input)
            .padding(20)
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 640, height: 760, alignment: .top)
            .background(ParityTheme.canvas)
            .tint(Color.primary)
            // Drawn as in the key window, where a prominent button takes its tint.
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    func testTheQuestionCardReadsInBothAppearances() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let states: [(String, ConversationRequest, ConversationRequestFormInput)] = [
            ("pending", Self.request(state: .pending), .init()),
            ("pending-picked", Self.request(state: .pending), Self.picked),
            ("answered", Self.request(state: .answered), Self.picked)
        ]
        for (name, request, input) in states {
            try WindowlessRender.hostedInBothAppearances("question-card-\(name)", in: directory,
                                                         size: NSSize(width: 640, height: 760)) {
                Self.card(request, input: input, appearance: $0)
            }
        }
    }

    /// No control on a waiting request's panel draws a focus ring (2026-11-20: a person saw one on the question
    /// card and had asked for none): SwiftUI makes no ring view for the question form, its options and buttons, an
    /// approval's answers or a plan's buttons, and the plan's field draws none of AppKit's.
    func testNoControlOnAWaitingRequestDrawsAFocusRing() throws {
        let bash = PermissionRequest(id: "bash", title: "Bash", detail: "Deploy the site", command: "npm run deploy",
                                     toolCallID: "bash")
        let plan = PermissionRequest(id: "plan", title: "Review the plan", detail: nil, command: nil,
                                     structured: .plan("# Plan"), toolCallID: "plan")
        let requests = try [bash, plan].map { permission in
            let entries = [TranscriptEntry(content: .user(text: "Go")),
                           TranscriptEntry(content: .permission(permission, state: .pending))]
            return try XCTUnwrap(TranscriptConversationProjection.presentation(
                from: entries, harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false)
                .turns.last?.requests.first)
        } + [Self.request(state: .pending)]
        for request in requests {
            let host = WindowlessRender.Host(Self.card(request, appearance: .light), size: NSSize(width: 640, height: 760))
            defer { host.close() }
            host.settle()
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let all = views(host.hosting)
            XCTAssertEqual(all.filter { String(describing: type(of: $0)).contains("FocusRing") }.count, 0,
                           "\(request.id): a control draws a focus ring")
            XCTAssertTrue(all.compactMap { $0 as? NSTextField }.filter(\.isEditable).allSatisfy { $0.focusRingType == .none },
                          "\(request.id): a field draws a focus ring")
        }
    }

    /// One question whose second option carries a multi-line preview, as Claude Code's
    /// `AskUserQuestion` sends a mockup to compare.
    static let previewQuestions = [
        PermissionQuestion(
            question: "Which layout should the settings page use?", header: "Layout",
            options: [
                PermissionQuestionOption(label: "Sidebar", description: "Sections listed on the left"),
                PermissionQuestionOption(label: "Tabs", description: "One tab per section", preview: """
                    ```
                    ┌─ General ─┬─ Accounts ─┬─ Advanced ─┐
                    │                                     │
                    │  Theme         [ System       ▾ ]   │
                    │  Font size     [ 13           ▾ ]   │
                    │  Start at login               [x]   │
                    └─────────────────────────────────────┘
                    ```
                    Each section keeps to **one screen**; the tabs stay in view.
                    """),
                PermissionQuestionOption(label: "Single page", description: "Every setting on one scroll")
            ],
            allowsCustomAnswer: true)
    ]

    /// A turn that ends on the question, waiting or answered with "Tabs", as a task shows it.
    static func previewConversation(answered: Bool) -> [TranscriptEntry] {
        var entries = [
            TranscriptEntry(content: .user(text: "Redo the settings page")),
            TranscriptEntry(content: .assistant(text: "Two layouts fit. Pick one; the preview shows it.", isStreaming: false))
        ]
        if answered {
            let record = HarnessAnsweredQuestions(questions: previewQuestions, answers: [
                PermissionQuestionAnswer(question: previewQuestions[0].question, selectedLabels: ["Tabs"])
            ])
            entries.append(TranscriptEntry(content: .activity(
                HarnessActivity(id: "toolu_ask", kind: ClaudeAnswerableTool.askUserQuestion, title: "AskUserQuestion",
                                answeredQuestions: record),
                state: .completed)))
        } else {
            let permission = PermissionRequest(
                id: "ask", title: "Claude has a question", detail: nil, command: nil,
                structured: .questions(previewQuestions), toolCallID: "toolu_ask")
            entries.append(TranscriptEntry(content: .permission(permission, state: .pending)))
        }
        return entries
    }

    func testAnOptionsPreviewShowsBesideTheOptionsOrUnderThePickedOne() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let states: [(name: String, answered: Bool, picksTabs: Bool, width: CGFloat)] = [
            ("wide", false, true, 900), ("wide-none", false, false, 900),
            ("narrow", false, true, 560), ("answered", true, false, 900)
        ]
        for state in states {
            for appearance in WindowlessRender.Appearance.allCases {
                let size = NSSize(width: state.width, height: 820)
                let host = WindowlessRender.Host(
                    TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
                                         entries: Self.previewConversation(answered: state.answered),
                                         sessionStatus: state.answered ? .ready : .waitingForApproval,
                                         actions: ConversationActions(answer: { _, _ in }))
                        .frame(width: size.width, height: size.height)
                        .background(ParityTheme.canvas)
                        .tint(Color.primary)
                        .environment(\.controlActiveState, .key)
                        .environment(\.colorScheme, appearance.colorScheme),
                    size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                if state.picksTabs {
                    XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Tabs"))
                    host.settle()
                }
                try WindowlessRender.writePNG(
                    try host.capture().bitmap,
                    to: directory.appending(path: "question-card-preview-\(state.name)-\(appearance.suffix).png"))
            }
        }
    }

    /// Skip on the last question sends the answers on the first click, also when the form could
    /// not be sent before it: here the one question takes only words, and none are typed.
    func testSkipOnTheLastQuestionSendsOnTheFirstClick() throws {
        final class Replies { var sent: [String] = [] }
        let replies = Replies()
        let questions = [CodexAsyncQuestion(title: "Anything else before I start?", options: [], itemID: "q-1")]
        let directory = try WindowlessRender.directory("composer-stream-qa")
        try WindowlessRender.hostedInBothAppearances("question-card-skip", in: directory,
                                                     size: NSSize(width: 640, height: 240)) { appearance in
            Self.codexCard(questions, onAnswer: { _ in }, appearance: appearance)
        }
        let host = WindowlessRender.Host(Self.codexCard(questions, onAnswer: { replies.sent.append($0) },
                                                        appearance: .light),
                                         size: NSSize(width: 640, height: 240), appearance: .light)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Skip")))
        host.settle(passes: 2)
        XCTAssertEqual(replies.sent.count, 1)
    }

    private static func codexCard(_ questions: [CodexAsyncQuestion], onAnswer: @escaping (String) -> Void,
                                  appearance: WindowlessRender.Appearance) -> some View {
        CodexQuestionOptions(questions: questions, onAnswer: onAnswer)
            .padding(20)
            .frame(width: 640, height: 240, alignment: .top)
            .background(ParityTheme.canvas)
            .tint(Color.primary)
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, appearance.colorScheme)
    }
}
