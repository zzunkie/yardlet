import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Each subagent card and background agent row names its harness and the model the provider reported,
/// in the composer's names: "Claude · Opus 5.5" (2026-10-16 user decision; `HarnessModelLabel`). A
/// subagent's own background command is listed under its subagent's row. Drawn without a provider into
/// `.build/composer-stream-qa/`: `subagent-model-{light,dark}.png` (a Claude Code turn with a
/// running background agent and one that finished on another model, and a Codex child thread on its
/// thread's model) and `background-tasks-nested-{light,dark}.png` (the line above the composer with a
/// subagent's command under its row).
@MainActor
final class HarnessModelLabelTests: XCTestCase {
    /// The names Claude Code 2.1.291 lists (`initialize`), as Yardlet keeps them per account.
    static let claudeCatalog = [
        HarnessModelOption(value: "default", name: "Default (recommended)", resolvedModel: "claude-opus-5-5"),
        HarnessModelOption(value: "opus", name: "Opus 5.5", resolvedModel: "claude-opus-5-5"),
        HarnessModelOption(value: "sonnet", name: "Sonnet 5.5", resolvedModel: "claude-sonnet-5-5"),
        HarnessModelOption(value: "haiku", name: "Haiku 5.5", resolvedModel: "claude-haiku-5-5")
    ]
    static let codexCatalog = [
        CodexModelOption(id: "gpt-6-sol", model: "gpt-6-sol", displayName: "GPT-6-Sol", defaultReasoningEffort: "medium",
                         supportedReasoningEfforts: ["medium"], isDefault: true),
        CodexModelOption(id: "gpt-6-luna", model: "gpt-6-luna", displayName: "GPT-6-Luna", defaultReasoningEffort: "low",
                         supportedReasoningEfforts: ["low"], isDefault: false)
    ]
    static let claude = HarnessModelNames(harness: .claudeCode, claude: claudeCatalog)
    static let codex = HarnessModelNames(harness: .codex, codex: codexCatalog, threadModel: "gpt-6-sol")

    func testTheLabelNamesTheHarnessAndTheReportedModelInTheComposersWords() {
        XCTAssertEqual(Self.claude.label(model: "claude-opus-5-5"), L10n.format("%@ · %@", "Claude", "Opus 5.5"),
                       "A full ID reads as its alias row, never the Default row")
        XCTAssertEqual(Self.claude.label(model: "sonnet"), L10n.format("%@ · %@", "Claude", "Sonnet 5.5"))
        XCTAssertEqual(Self.claude.label(model: "claude-opus-4-6"), L10n.format("%@ · %@", "Claude", "Opus 4.6"),
                       "A model the list does not carry reads by its ID")
        XCTAssertEqual(Self.claude.label(model: "claude-opus-4-6[1m]"),
                       L10n.format("%@ · %@", "Claude", "Opus 4.6 (1M context)"),
                       "A 1M model the list does not carry reads as Claude Code labels it, not with its suffix")
        XCTAssertEqual(Self.claude.label(model: nil), "Claude", "Nothing reported, nothing guessed")
        XCTAssertEqual(Self.codex.label(model: "gpt-6-luna"), L10n.format("%@ · %@", "Codex", "GPT-6-Luna"))
        XCTAssertEqual(Self.codex.label(model: nil), L10n.format("%@ · %@", "Codex", "GPT-6-Sol"),
                       "A Codex child thread spawned without a model runs on its thread's")
    }

    private static func agent(_ id: String, _ title: String, task: String, model: String?, state: TranscriptActivityState,
                              output: String? = nil) -> TranscriptEntry {
        TranscriptEntry(content: .activity(
            HarnessActivity(id: id, kind: "Agent", title: title, input: "Read the parser and report", output: output,
                            isBackground: true,
                            subtask: HarnessSubtaskReference(taskID: task, toolUseID: id, taskType: "local_agent",
                                                             model: model)),
            state: state))
    }

    func testSubagentCardsReadTheirHarnessAndModelInBothAppearances() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let entries = [
            TranscriptEntry(content: .user(text: "Review the parser")),
            Self.agent("a1", "Review the parser", task: "t1", model: "claude-opus-5-5", state: .running),
            Self.agent("a2", "Check the lexer", task: "t2", model: "claude-haiku-5-5", state: .completed,
                       output: "No issues."),
            TranscriptEntry(content: .assistant(text: "Two agents are on it.", isStreaming: false))
        ]
        let codexCard = ConversationSubagentCard(
            subagent: ConversationSubagent(title: "spawn_agent", status: "inProgress", detail: nil,
                                           routes: [.codexThread("thread-child")], input: "Write the tests"),
            phase: .running, actions: ConversationActions())
        let size = NSSize(width: 820, height: 420)
        let captures = try WindowlessRender.hostedInBothAppearances("subagent-model", in: directory, size: size) { appearance in
            VStack(alignment: .leading, spacing: 12) {
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                         latestTurnIsComplete: false),
                                     actions: ConversationActions())
                    .environment(\.harnessModelNames, Self.claude)
                    .frame(height: 300)
                codexCard
                    .environment(\.harnessModelNames, Self.codex)
                    .padding(.horizontal, 24)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(
            VStack {
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                         latestTurnIsComplete: false),
                                     actions: ConversationActions())
                    .environment(\.harnessModelNames, Self.claude)
                codexCard.environment(\.harnessModelNames, Self.codex)
            }
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        // Assistive apps read the label with the card's title.
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for label in [L10n.format("%@ · %@", "Claude", "Opus 5.5"), L10n.format("%@ · %@", "Claude", "Haiku 5.5"),
                      L10n.format("%@ · %@", "Codex", "GPT-6-Sol")] {
            XCTAssertTrue(spoken.contains { $0.contains(label) }, "\(label): \(spoken)")
        }
    }

    func testTheLineListsASubagentsCommandUnderItsRowWithTheAgentsModel() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let entries = [
            TranscriptEntry(content: .user(text: "Review the parser")),
            Self.agent("a1", "Review the parser", task: "t1", model: "claude-opus-5-5", state: .running),
            TranscriptEntry(content: .activity(
                HarnessActivity(id: "b1", kind: "Task", title: "Build tests with send experiment", isBackground: true,
                                subtask: HarnessSubtaskReference(taskID: "tb1", toolUseID: "b1", taskType: "local_bash",
                                                                 ownedBySubagent: true, parentTaskID: "t1")),
                state: .running)),
            Self.agent("a2", "Check the lexer", task: "t2", model: "claude-sonnet-5-5", state: .running)
        ]
        let projection = BackgroundTasksProjection(entries: entries)
        XCTAssertEqual(projection.rows.map(\.id), ["a1", "b1", "a2"], "the command follows its subagent")
        XCTAssertEqual(projection.rows.map(\.depth), [0, 1, 0])
        let actions = HarnessActivityActions(open: { _ in }, stop: { _ in }, isStopping: { _ in false }, error: { _ in nil })
        let size = NSSize(width: 820, height: 200)
        _ = try WindowlessRender.hostedInBothAppearances("background-tasks-nested", in: directory, size: size) { appearance in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                BackgroundTasksBar(projection: projection, actions: actions, startsExpanded: true)
                    .padding(.horizontal, 24)
            }
            .environment(\.harnessModelNames, Self.claude)
            .frame(width: size.width, height: size.height)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
        }
        let host = WindowlessRender.Host(
            BackgroundTasksBar(projection: projection, actions: actions, startsExpanded: true)
                .environment(\.harnessModelNames, Self.claude)
                .frame(width: size.width, height: size.height),
            size: size)
        defer { host.close() }
        host.settle()
        let labels = host.accessibilityElements().map(\.label)
        XCTAssertTrue(labels.contains("Review the parser, " + L10n.format("%@ · %@", "Claude", "Opus 5.5")), "\(labels)")
        XCTAssertTrue(labels.contains("Check the lexer, " + L10n.format("%@ · %@", "Claude", "Sonnet 5.5")), "\(labels)")
        XCTAssertFalse(labels.contains { $0.hasPrefix("Build tests with send experiment, ") }, "a shell row names no model")
    }
}
