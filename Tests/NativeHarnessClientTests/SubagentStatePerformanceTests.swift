import Foundation
import XCTest
@testable import NativeHarnessClient

/// Long Codex subagents streaming states into the app, as `startAgentRun` hands each state to
/// `acceptAgentRun`: one subagent of four streams while the others hold long finished work, each
/// latest turn hundreds of MCP cards with large results; the streaming one's latest turn goes on
/// past its answer with larger MCP results and notes. Per state the app reads whether its
/// subagents wait on the person, the window reads the requests they hold (`sessionToolRequests`),
/// and the streaming subagent's card reads its line (`progressLine`); its latest answer is read when
/// a tool asks for it (`currentAnswer`).
/// Building the states is not measured; every result read is kept, so none is optimized away.
@MainActor
final class SubagentStatePerformanceTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let workspace = URL(filePath: "/tmp/yardlet-subagent-performance", directoryHint: .isDirectory)
    private let runCount = 4
    private let cardsPerLatestTurn = 300
    private let earlierTurns = 3
    private let cardsPerEarlierTurn = 50
    private let resultCharacters = 4_000
    private let streamedResultCharacters = 64_000
    private let streamedStates = 40

    func testAStreamingSubagentStateReadsWhatItWaitsOnWithoutDrawingItsCards() throws {
        let host = SessionRecord(harness: .claudeCode, workspaceURL: workspace, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                                 title: "Host", status: .waitingForApproval)
        let defaults = UserDefaults(suiteName: testDefaultsSuite("SubagentStatePerformanceTests"))!
        let model = AppModel(
            store: SessionStore(sessions: [host], repository: InMemorySessionRepository(sessions: [host])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false),
            systemNotificationCenter: QuietNotifications(),
            restoresIndexOnLaunch: false
        )
        model.sessionTools = SessionToolCenter(defaults: defaults)
        let runs = (0..<runCount).map { index in
            let run = AgentRun(callerID: host.id, hostTaskID: host.id, harness: .codex, model: "gpt-5.5",
                               prompt: "Survey part \(index)", workspaceURL: workspace, depth: 1,
                               startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
            run.state = .running
            model.sessionTools.add(run)
            return run
        }
        for (index, run) in runs.enumerated() {
            var state = longThread(id: "run-\(index)")
            // One of the others waits on the person, so the host keeps waiting throughout.
            if index == 1 {
                state.approvalsByID["waiting"] = CodexApprovalState(
                    id: "waiting", method: "item/commandExecution/requestApproval", threadID: "run-1",
                    turnID: "latest", itemID: nil, resolution: .pending, raw: nil)
            }
            model.acceptAgentRun(state, in: run)
        }
        XCTAssertEqual(model.sessionToolRequests(in: host.id).map(\.id), ["waiting"])

        // The states the first subagent streams: its latest turn goes on past its answer, by a card
        // with a large result, then a note.
        var states: [CodexTaskState] = []
        var streaming = longThread(id: "run-0")
        for step in 0..<streamedStates {
            let id = "streamed-\(step)"
            let item = step.isMultiple(of: 2)
                ? mcp(id, result: String(repeating: "r", count: streamedResultCharacters))
                : message(id, "Reading part \(step) of the survey.", phase: "commentary")
            streaming.thread?.turns[earlierTurns].items.append(decoder.item(from: item, fallbackID: id, lifecycle: .completed))
            states.append(streaming)
        }

        let clock = ContinuousClock()
        var accept: [Duration] = []
        var held: [Duration] = []
        var line: [Duration] = []
        var kept = 0
        for state in states {
            accept.append(clock.measure { model.acceptAgentRun(state, in: runs[0]) })
            held.append(clock.measure { kept += model.sessionToolRequests(in: host.id).count })
            line.append(clock.measure { kept += runs[0].progressLine?.count ?? 0 })
        }
        XCTAssertEqual(runs[0].state, .running)
        XCTAssertEqual(runs[0].progressLine, "Reading part \(streamedStates - 1) of the survey.")
        XCTAssertEqual(runs[0].currentAnswer, "Surveyed run-0.")
        XCTAssertGreaterThan(kept, 0)

        func median(_ times: [Duration]) -> Duration { times.sorted()[times.count / 2] }
        print(String(format: "[perf] subagent states: %d runs × (%d + %d×%d cards, %d-character MCP results), %d states "
                     + "(%d-character MCP results streamed); per state median / max: acceptAgentRun %.3f / %.3f ms, "
                     + "sessionToolRequests %.3f / %.3f ms, progressLine %.3f / %.3f ms",
                     runCount, cardsPerLatestTurn, earlierTurns, cardsPerEarlierTurn, resultCharacters, streamedStates,
                     streamedResultCharacters, median(accept).milliseconds, accept.max()!.milliseconds,
                     median(held).milliseconds, held.max()!.milliseconds, median(line).milliseconds, line.max()!.milliseconds))
        PerfBenchRecord.write("subagent-states-\(runCount)-runs", [
            "acceptAgentRunMedianMs": median(accept).milliseconds, "acceptAgentRunMaxMs": accept.max()!.milliseconds,
            "sessionToolRequestsMedianMs": median(held).milliseconds, "progressLineMedianMs": median(line).milliseconds
        ])
        XCTAssertLessThan(median(accept), .milliseconds(20), "A subagent's state does not draw its cards")
        XCTAssertLessThan(median(held), .milliseconds(20), "The held requests do not draw any subagent's cards")
        XCTAssertLessThan(median(line), .milliseconds(20), "The card's line does not draw the turn's cards")
    }

    // MARK: - Fixtures

    /// Earlier finished turns and a latest running turn of MCP cards with large results, ending on
    /// an answer it said to the person.
    private func longThread(id: String) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string(id)]))!
        let result = String(repeating: "x", count: resultCharacters)
        func turn(_ turnID: String, cards: Int, status: String, last: [JSONValue]) -> CodexTurnState {
            let items = [user("\(turnID)-user", "Survey \(id)")]
                + (0..<cards).map { mcp("\(turnID)-card-\($0)", result: result) }
                + last
            return decoder.turn(from: .object(["id": .string(turnID), "status": .string(status), "items": .array(items)]),
                                fallbackID: turnID)!
        }
        thread.turns = (0..<earlierTurns).map {
            turn("earlier-\($0)", cards: cardsPerEarlierTurn, status: "completed", last: [message("earlier-\($0)-answer", "Done.", phase: "final_answer")])
        } + [turn("latest", cards: cardsPerLatestTurn, status: "inProgress", last: [
            .object(["id": .string("latest-said"), "type": .string("agentMessage"), "text": .string("Surveyed \(id)."),
                     "phase": .string("final_answer")])
        ])]
        return CodexTaskState(thread: thread)
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func message(_ id: String, _ text: String, phase: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }

    private func mcp(_ id: String, result: String) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("mcpToolCall"), "server": .string("docs"), "tool": .string("search"),
            "arguments": .object(["query": .string(id), "paths": .array((0..<20).map { .string("/tmp/docs/page-\($0).md") })]),
            "status": .string("completed"),
            "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(result)])]),
                "structuredContent": .object(["hits": .array((0..<20).map { .object(["rank": .integer(Int64($0)), "text": .string(id)]) })])
            ]),
            "error": .null, "durationMs": .integer(120)
        ])
    }
}

private final class QuietNotifications: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
