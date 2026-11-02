import Foundation
import Testing
@testable import NativeHarnessClient

struct ACPToolCallStateTests {
    @Test func testAdapterPreservesCompletedStatusThroughLateOutputAndTurnCompletion() async throws {
        let transport = ToolPatchTransport()
        let adapter = ACPAdapter(kind: .grokBuild, executableURL: URL(filePath: "/unused"), transportFactory: { transport })
        let session = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: FileManager.default.temporaryDirectory, initialPrompt: nil
        ))
        let events = await adapter.events(for: session)
        try await adapter.send("fixture", to: session)
        do {
            let payloads = try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
                group.addTask {
                    var payloads: [HarnessEventPayload] = []
                    for await event in events {
                        payloads.append(event.payload)
                        if event.payload == .turnCompleted { return payloads }
                    }
                    return payloads
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                return try #require(await group.next())
            }
            var transcript = TranscriptBuilder()
            payloads.forEach { transcript.apply($0) }
            #expect(payloads.contains(.turnCompleted))
            #expect(transcript.entries.map(\.content) == [.activity(
                HarnessActivity(
                    id: "build", kind: "execute", title: "Build",
                    detail: "Build succeeded", output: "Build succeeded"
                ),
                state: .completed
            )])
            await adapter.close(session)
        } catch {
            await adapter.close(session)
            throw error
        }
    }

    @Test func testLateBackgroundOutputKeepsCompletedCardAfterTurnEnds() throws {
        let projector = ACPEventProjector()
        var state: ACPToolCallState?
        var transcript = TranscriptBuilder()
        for update: JSONValue in [
            .object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("build"),
                     "title": .string("Run build"), "kind": .string("execute")]),
            .object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("build"),
                     "status": .string("completed")]),
            .object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("build"),
                     "content": .array([.object(["type": .string("content"),
                        "content": .object(["type": .string("text"), "text": .string("Build succeeded")])])])])
        ] {
            let next: ACPToolCallState = try #require(projector.toolCall(from: update, previous: state))
            state = next
            transcript.apply(next.payload(isStart: update["sessionUpdate"]?.stringValue == "tool_call"))
        }
        transcript.apply(.turnCompleted)
        #expect(transcript.entries.map(\.content) == [.activity(
            HarnessActivity(
                id: "build", kind: "execute", title: "Run build",
                detail: "Build succeeded", output: "Build succeeded"
            ),
            state: .completed
        )])
    }

    @Test func testFailedToolAndMetadataPatchRemainFailed() throws {
        let projector = ACPEventProjector()
        let failed = try #require(projector.toolCall(from: .object([
            "toolCallId": .string("failed"), "status": .string("failed"),
            "title": .string("Read"), "kind": .string("read")
        ])))
        let patched = try #require(projector.toolCall(from: .object([
            "toolCallId": .string("failed"), "title": .string("Read failed")
        ]), previous: failed))
        var transcript = TranscriptBuilder()
        transcript.apply(patched.payload(isStart: false))
        transcript.apply(.turnCompleted)
        #expect(patched.activity.outcome == .failed)
        #expect(transcript.entries.first?.content == .activity(patched.activity, state: .failed))
    }

    @Test func testExplicitRunningUpdateReopensBackgroundWorkButOmissionDoesNot() throws {
        let projector = ACPEventProjector()
        let completed = try #require(projector.toolCall(from: .object([
            "toolCallId": .string("background"), "status": .string("completed")
        ])))
        let running = try #require(projector.toolCall(from: .object([
            "toolCallId": .string("background"), "status": .string("in_progress")
        ]), previous: completed))
        #expect(running.payload(isStart: false) == .activityUpdated(running.activity))
        var transcript = TranscriptBuilder()
        transcript.apply(running.payload(isStart: false))
        transcript.apply(.turnCompleted)
        #expect(transcript.entries.first?.content == .activity(running.activity, state: .stopped))
    }

    @Test func testInitialTerminalToolStatusIsRespected() throws {
        let payloads = ACPEventProjector().payloads(from: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("failed"),
            "status": .string("failed")
        ]))
        guard case let .activityCompleted(activity) = try #require(payloads.first) else {
            Issue.record("An initially failed tool must not be projected as running")
            return
        }
        #expect(activity.outcome == .failed)
    }
}

private actor ToolPatchTransport: ACPTransport {
    private let channel = AsyncStream<ACPRawFrame>.makeStream()
    func start(_ configuration: ACPLaunchConfiguration) {}
    func send(_ value: JSONValue) {}
    func messages() -> AsyncStream<ACPRawFrame> { channel.stream }
    func stop() { channel.continuation.finish() }

    func request(_ value: JSONValue, id: Int64) throws -> JSONValue {
        switch value["method"]?.stringValue {
        case "initialize":
            return .object(["protocolVersion": .integer(1), "agentCapabilities": .object([:])])
        case "session/new":
            return .object(["sessionId": .string("fixture")])
        case "session/prompt":
            for fields: [String: JSONValue] in [
                ["sessionUpdate": .string("tool_call"), "title": .string("Build"), "kind": .string("execute")],
                ["sessionUpdate": .string("tool_call_update"), "status": .string("completed")],
                ["sessionUpdate": .string("tool_call_update"), "content": .array([.object([
                    "type": .string("content"), "content": .object([
                        "type": .string("text"), "text": .string("Build succeeded")
                    ])
                ])])]
            ] {
                let update = fields.merging(["toolCallId": .string("build")]) { _, new in new }
                let frame: JSONValue = .object(["method": .string("session/update"), "params": .object([
                    "sessionId": .string("fixture"), "update": .object(update)
                ])])
                channel.continuation.yield(ACPRawFrame(value: frame, data: try JSONEncoder().encode(frame)))
            }
            return .object(["stopReason": .string("end_turn")])
        default:
            return .object([:])
        }
    }
}
