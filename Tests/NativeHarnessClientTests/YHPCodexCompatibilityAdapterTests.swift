import Foundation
import XCTest
@testable import NativeHarnessClient

final class YHPCodexCompatibilityAdapterTests: XCTestCase {
    func testSlowProductConsumerSkipsObsoleteSnapshotsAfterCompletion() async throws {
        let transport = FakeCodexTransport(responses: baseResponses())
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let handle = try await routed.createSession(.init(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let stream = try await routed.presentationStates(for: handle)
        try await routed.send("Local test", to: handle)
        for delta in ["one\n", "two\n", "three"] {
            await transport.emit(method: "item/agentMessage/delta", params: .object([
                "threadId": .string("codex-thread-1"), "turnId": .string("provider-turn-1"),
                "itemId": .string("dense-answer"), "delta": .string(delta)
            ]))
        }
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string("codex-thread-1"),
            "turn": .object(["id": .string("provider-turn-1"), "status": .string("completed")])
        ]))
        try await waitUntil {
            (try? await routed.presentationState(for: handle).thread?.turns.last?.status) == .completed
        }
        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest?.thread?.turns.last?.status, .completed)
        XCTAssertTrue(latest?.thread?.turns.last?.items.contains {
            if case let .agentMessage(message) = $0.content { return message.text == "one\ntwo\nthree" }
            return false
        } == true)
        await routed.close(handle)
        let remaining = await iterator.next()
        XCTAssertNil(remaining)
    }

    func testStreamedTextCrossesYHPBeforeCompletionAndSurvivesTransportEnd() async throws {
        let transport = FakeCodexTransport(responses: baseResponses())
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let handle = try await routed.createSession(.init(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/codex-yhp-product"), initialPrompt: nil))
        let stream = try await routed.presentationStates(for: handle)
        let recorder = CodexYHPPresentationRecorder()
        let collection = Task { for await state in stream { await recorder.append(state) } }
        defer { collection.cancel() }
        try await routed.send("Local test", to: handle)
        await transport.emit(method: "item/started", params: .object([
            "threadId": .string("codex-thread-1"), "turnId": .string("provider-turn-1"),
            "item": .object(["id": .string("answer"), "type": .string("agentMessage"),
                             "phase": .string("final_answer"), "text": .string("Beginning")])
        ]))
        await transport.emit(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("codex-thread-1"), "turnId": .string("provider-turn-1"),
            "itemId": .string("answer"), "delta": .string(" 한글 👩🏽‍💻 appended")
        ]))
        try await waitUntil {
            await recorder.states.contains { state in
                state.thread?.turns.last?.items.contains {
                    if case let .agentMessage(message) = $0.content {
                        return message.text == "Beginning 한글 👩🏽‍💻 appended" && $0.lifecycle == .inProgress
                    }
                    return false
                } == true
            }
        }
        await transport.stop()
        try await waitUntil { await recorder.states.last?.thread?.turns.last?.status == .failed }
        let state = try await routed.presentationState(for: handle)
        XCTAssertTrue(state.thread?.turns.last?.items.contains {
            if case let .agentMessage(message) = $0.content { return message.text == "Beginning 한글 👩🏽‍💻 appended" }
            return false
        } == true)
        await routed.close(handle)
    }

    func testStreamedReasoningAndCommandOutputCrossYHPAndSurviveTransportEnd() async throws {
        let transport = FakeCodexTransport(responses: baseResponses())
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let handle = try await routed.createSession(.init(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/codex-yhp-product"), initialPrompt: nil))
        let stream = try await routed.presentationStates(for: handle)
        let recorder = CodexYHPPresentationRecorder()
        let collection = Task { for await state in stream { await recorder.append(state) } }
        defer { collection.cancel() }
        try await routed.send("Local test", to: handle)
        let turn: [String: JSONValue] = [
            "threadId": .string("codex-thread-1"), "turnId": .string("provider-turn-1")
        ]
        await transport.emit(method: "item/started", params: .object(turn.merging([
            "item": .object(["id": .string("thinking"), "type": .string("reasoning"),
                             "summary": .array([]), "content": .array([])])
        ]) { $1 }))
        await transport.emit(method: "item/reasoning/summaryTextDelta", params: .object(turn.merging([
            "itemId": .string("thinking"), "delta": .string("Planning"), "summaryIndex": .integer(0)
        ]) { $1 }))
        await transport.emit(method: "item/reasoning/textDelta", params: .object(turn.merging([
            "itemId": .string("thinking"), "delta": .string("raw 한글"), "contentIndex": .integer(0)
        ]) { $1 }))
        await transport.emit(method: "item/started", params: .object(turn.merging([
            "item": .object(["id": .string("build"), "type": .string("commandExecution"),
                             "command": .string("swift build"), "cwd": .string("/tmp/codex-yhp-product"),
                             "status": .string("inProgress"), "aggregatedOutput": .null])
        ]) { $1 }))
        for delta in ["Compiling\n", "Linking\n"] {
            await transport.emit(method: "item/commandExecution/outputDelta", params: .object(turn.merging([
                "itemId": .string("build"), "delta": .string(delta)
            ]) { $1 }))
        }

        @Sendable func streamed(_ state: CodexTaskState?) -> Bool {
            let items = state?.thread?.turns.last?.items ?? []
            let reasoningStreamed = items.contains {
                guard case let .reasoning(summary, content) = $0.content else { return false }
                return summary == [.string("Planning")] && content == [.string("raw 한글")]
            }
            let outputStreamed = items.contains {
                guard case let .commandExecution(command) = $0.content else { return false }
                return command.aggregatedOutput == "Compiling\nLinking\n"
            }
            return reasoningStreamed && outputStreamed
        }
        try await waitUntil { await recorder.states.contains(where: streamed) }
        let live = try await routed.presentationState(for: handle)
        let build = try XCTUnwrap(live.thread?.turns.last?.items.first { $0.id == "build" })
        XCTAssertEqual(build.lifecycle, .inProgress)
        // YHP keeps the provider frame as raw; streamed text crosses as the rendered payload.
        XCTAssertEqual(build.raw["aggregatedOutput"], .null)

        await transport.stop()
        try await waitUntil {
            (try? await routed.presentationState(for: handle).thread?.turns.last?.status) == .failed
        }
        let ended = try await routed.presentationState(for: handle)
        let stopped = try XCTUnwrap(ended.thread?.turns.last?.items.first { $0.id == "build" })
        guard case let .commandExecution(command) = stopped.content else {
            return XCTFail("stopped command should remain a command card")
        }
        XCTAssertEqual(command.status, "interrupted")
        XCTAssertEqual(command.aggregatedOutput, "Compiling\nLinking\n")
        await routed.close(handle)
    }

    func testPatchUpdatesAndTheTurnDiffCrossYHP() async throws {
        let transport = FakeCodexTransport(responses: baseResponses())
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let handle = try await routed.createSession(.init(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/codex-yhp-product"), initialPrompt: nil))
        let stream = try await routed.presentationStates(for: handle)
        let recorder = CodexYHPPresentationRecorder()
        let collection = Task { for await state in stream { await recorder.append(state) } }
        defer { collection.cancel() }
        try await routed.send("Local test", to: handle)
        let turn: [String: JSONValue] = [
            "threadId": .string("codex-thread-1"), "turnId": .string("provider-turn-1")
        ]
        await transport.emit(method: "item/started", params: .object(turn.merging([
            "item": .object(["id": .string("patch"), "type": .string("fileChange"),
                             "changes": .array([]), "status": .string("inProgress")])
        ]) { $1 }))
        let patch: JSONValue = .array([.object([
            "path": .string("Sources/App.swift"),
            "kind": .object(["type": .string("update"), "move_path": .null]),
            "diff": .string("@@ -1 +1 @@\n-old\n+new 한글\n")
        ])])
        await transport.emit(method: "item/fileChange/patchUpdated", params: .object(turn.merging([
            "itemId": .string("patch"), "changes": patch
        ]) { $1 }))
        let turnDiff = "diff --git a/Sources/App.swift b/Sources/App.swift\n--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1 +1 @@\n-old\n+new 한글\n"
        await transport.emit(method: "turn/diff/updated", params: .object(turn.merging([
            "diff": .string(turnDiff)
        ]) { $1 }))

        @Sendable func streamed(_ state: CodexTaskState?) -> Bool {
            let items = state?.thread?.turns.last?.items ?? []
            let patched = items.contains {
                guard case let .fileChange(change) = $0.content else { return false }
                return change.changes == patch.arrayValue && $0.lifecycle == .inProgress
            }
            return patched && state?.thread?.turns.last?.diff == turnDiff
        }
        try await waitUntil { await recorder.states.contains(where: streamed) }
        let live = try await routed.presentationState(for: handle)
        let card = try XCTUnwrap(live.thread?.turns.last?.items.first { $0.id == "patch" })
        // YHP keeps the provider frame as raw; the streamed patch crosses as the rendered payload.
        XCTAssertEqual(card.raw["changes"], .array([]))
        await routed.close(handle)
    }

    func testCodexYHPRoutePreservesRichComposerPresentationAndServerRequests() async throws {
        let directTransport = FakeCodexTransport(responses: baseResponses())
        let routedTransport = FakeCodexTransport(responses: baseResponses())
        let direct = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: directTransport
        )
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(
                executableURL: URL(filePath: "/tmp/fake-codex"),
                transport: routedTransport
            ),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let localSessionID = UUID()
        let workspace = URL(filePath: "/tmp/codex-yhp-product")
        let request = CreateHarnessSessionRequest(
            localSessionID: localSessionID,
            workspaceURL: workspace,
            initialPrompt: nil
        )
        let directHandle = try await direct.createSession(request)
        let routedHandle = try await routed.createSession(request)
        XCTAssertEqual(routedHandle, directHandle)

        let presentationStream = try await routed.presentationStates(for: routedHandle)
        let recorder = CodexYHPPresentationRecorder()
        let presentationTask = Task {
            for await state in presentationStream {
                await recorder.append(state)
            }
        }

        let futureInput: JSONValue = .object([
            "type": .string("futureAttachment"),
            "providerData": .object(["opaque": .bool(true)])
        ])
        let draft = CodexComposerDraft(inputs: [
            .text(
                "Inspect the attached context",
                textElements: [CodexTextElement(start: 0, end: 7, placeholder: "context")]
            ),
            .localAudio(URL(filePath: "/tmp/context.m4a")),
            .skill(name: "review", path: URL(filePath: "/tmp/review/SKILL.md")),
            .mention(name: "Notes.swift", path: URL(filePath: "/tmp/Notes.swift")),
            .unknown(futureInput)
        ])
        try await direct.submit(draft, submission: .start, to: directHandle)
        try await routed.submit(draft, submission: .start, to: routedHandle)

        let directRequests = await directTransport.requests
        let routedRequests = await routedTransport.requests
        let directStart = try XCTUnwrap(
            directRequests.last(where: { $0.method == "turn/start" })
        )
        let routedStart = try XCTUnwrap(
            routedRequests.last(where: { $0.method == "turn/start" })
        )
        XCTAssertEqual(routedStart.params["input"], directStart.params["input"])
        XCTAssertEqual(
            routedStart.params["input"]?.arrayValue?.last,
            futureInput
        )
        let routedActiveTurnID = await routed.activeTurnID(for: routedHandle)
        let directActiveTurnID = await direct.activeTurnID(for: directHandle)
        XCTAssertEqual(routedActiveTurnID, directActiveTurnID)

        try await direct.submit(
            CodexComposerDraft(inputs: [.text("Keep the existing turn")]),
            submission: .steer(expectedTurnID: "provider-turn-1"),
            to: directHandle
        )
        try await routed.submit(
            CodexComposerDraft(inputs: [.text("Keep the existing turn")]),
            submission: .steer(expectedTurnID: "provider-turn-1"),
            to: routedHandle
        )
        let directRequestsAfterSteer = await directTransport.requests
        let routedRequestsAfterSteer = await routedTransport.requests
        let directSteer = try XCTUnwrap(
            directRequestsAfterSteer.last(where: { $0.method == "turn/steer" })
        )
        let routedSteer = try XCTUnwrap(
            routedRequestsAfterSteer.last(where: { $0.method == "turn/steer" })
        )
        XCTAssertEqual(routedSteer.params, directSteer.params)

        let turnStarted: JSONValue = .object([
            "threadId": .string("codex-thread-1"),
            "turn": .object([
                "id": .string("provider-turn-1"),
                "status": .string("inProgress"),
                "itemsView": .string("full"),
                "items": .array([])
            ])
        ])
        await directTransport.emit(method: "turn/started", params: turnStarted)
        await routedTransport.emit(method: "turn/started", params: turnStarted)

        let serverRequestParams: JSONValue = .object([
            "threadId": .string("codex-thread-1"),
            "turnId": .string("provider-turn-1"),
            "itemId": .string("question-1"),
            "questions": .array([.object([
                "id": .string("environment"),
                "header": .string("Environment"),
                "question": .string("Which environment?")
            ])])
        ])
        await directTransport.emitServerRequest(
            id: .integer(91),
            method: "item/tool/requestUserInput",
            params: serverRequestParams
        )
        await routedTransport.emitServerRequest(
            id: .integer(91),
            method: "item/tool/requestUserInput",
            params: serverRequestParams
        )

        try await waitUntil {
            let directState = try? await direct.presentationState(for: directHandle)
            let routedState = try? await routed.presentationState(for: routedHandle)
            return directState?.serverRequestsByID["i:91"] != nil
                && routedState?.serverRequestsByID["i:91"] != nil
        }
        let directState = try await direct.presentationState(for: directHandle)
        let routedState = try await routed.presentationState(for: routedHandle)
        XCTAssertEqual(routedState, directState)
        let pending = try XCTUnwrap(routedState.serverRequestsByID["i:91"])
        let pendingRecord = CodexPendingServerRequest(pending)
        let routedAnswerable = await routed.answerablePendingServerRequestIDs(
            [pendingRecord],
            for: routedHandle
        )
        let directAnswerable = await direct.answerablePendingServerRequestIDs(
            [pendingRecord],
            for: directHandle
        )
        XCTAssertEqual(routedAnswerable, directAnswerable)
        let mismatched = CodexPendingServerRequest(CodexServerRequestState(
            id: pending.id,
            method: "different/method",
            kind: pending.kind,
            threadID: pending.threadID,
            turnID: pending.turnID,
            itemID: pending.itemID,
            params: pending.params,
            resolution: .pending
        ))
        let mismatchedAnswerable = await routed.answerablePendingServerRequestIDs(
            [mismatched],
            for: routedHandle
        )
        XCTAssertTrue(mismatchedAnswerable.isEmpty)

        let response = CodexServerRequestResponse.toolUserInput(
            answers: ["environment": ["Preview"]]
        )
        try await direct.respond(to: "i:91", response: response, in: directHandle)
        try await routed.respond(to: "i:91", response: response, in: routedHandle)
        let routedResponse = await routedTransport.sentResponses.last?.result
        let directResponse = await directTransport.sentResponses.last?.result
        XCTAssertEqual(routedResponse, directResponse)
        try await waitUntil { await recorder.states.count >= 2 }

        presentationTask.cancel()
        await direct.close(directHandle)
        await routed.close(routedHandle)
    }

    func testActiveTurnSurvivesPresentationThatPredatesItsStart() async throws {
        let directTransport = FakeCodexTransport(responses: baseResponses())
        let routedTransport = FakeCodexTransport(responses: baseResponses())
        let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: directTransport)
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: routedTransport),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let request = CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/codex-yhp-product"), initialPrompt: nil)
        let directHandle = try await direct.createSession(request)
        let routedHandle = try await routed.createSession(request)
        try await direct.send("Start a turn", to: directHandle)
        try await routed.send("Start a turn", to: routedHandle)

        // Until `turn/started` arrives the presentation has no turn, so a presentation applied now
        // predates the turn `turn/start` answered. A late subscriber also replays every
        // presentation kept from before the turn started.
        let renamed: JSONValue = .object([
            "threadId": .string("codex-thread-1"), "threadName": .string("Renamed")
        ])
        await directTransport.emit(method: "thread/name/updated", params: renamed)
        await routedTransport.emit(method: "thread/name/updated", params: renamed)
        let stream = try await routed.presentationStates(for: routedHandle)
        let recorder = CodexYHPPresentationRecorder()
        let collection = Task { for await state in stream { await recorder.append(state) } }
        defer { collection.cancel() }
        try await waitUntil {
            let directName = try? await direct.presentationState(for: directHandle).thread?.name
            let routedRenamed = await recorder.states.contains { $0.thread?.name == "Renamed" }
            return directName == "Renamed" && routedRenamed
        }
        let directActiveTurnID = await direct.activeTurnID(for: directHandle)
        let routedActiveTurnID = await routed.activeTurnID(for: routedHandle)
        XCTAssertEqual(directActiveTurnID, "provider-turn-1")
        XCTAssertEqual(routedActiveTurnID, "provider-turn-1")

        let completed: JSONValue = .object([
            "threadId": .string("codex-thread-1"),
            "turn": .object(["id": .string("provider-turn-1"), "status": .string("completed")])
        ])
        await directTransport.emit(method: "turn/completed", params: completed)
        await routedTransport.emit(method: "turn/completed", params: completed)
        try await waitUntil {
            let directEnded = await direct.activeTurnID(for: directHandle) == nil
            let routedEnded = await routed.activeTurnID(for: routedHandle) == nil
            return directEnded && routedEnded
        }
        await direct.close(directHandle)
        await routed.close(routedHandle)
    }

    func testCodexYHPRoutePreservesCapabilitiesPaginationAndThreadActions() async throws {
        let transport = FakeCodexTransport(responses: capabilityResponses())
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(
                executableURL: URL(filePath: "/tmp/fake-codex"),
                transport: transport
            ),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let workspace = URL(filePath: "/tmp/codex-yhp-product")
        let handle = try await routed.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: workspace,
            initialPrompt: nil
        ))

        let modes = try await routed.collaborationModes()
        XCTAssertEqual(modes.map(\.name), ["Plan"])
        let skills = try await routed.skills(in: workspace)
        XCTAssertEqual(skills.map(\.name), ["openai-docs"])
        let plugins = try await routed.plugins(in: workspace)
        XCTAssertEqual(plugins.map(\.id), ["github"])

        let recent = try await routed.recentThreadsPage(
            in: workspace,
            cursor: nil,
            limit: 30
        )
        XCTAssertEqual(recent.threads.map(\.id), ["recent-thread"])
        XCTAssertEqual(recent.nextCursor, "recent-next")
        let search = try await routed.searchThreads(
            in: workspace,
            searchTerm: "approval",
            cursor: nil,
            limit: 30
        )
        XCTAssertEqual(search.matches.map(\.thread.id), ["search-thread"])
        let occurrences = try await routed.searchOccurrences(
            threadID: "search-thread",
            searchTerm: "approval",
            cursor: nil,
            limit: 30
        )
        XCTAssertEqual(occurrences.occurrences.map(\.itemID), ["search-item"])

        let turns = try await routed.loadTurns(for: handle, cursor: nil, limit: 20)
        XCTAssertEqual(turns.turns.map(\.id), ["history-turn"])
        let items = try await routed.loadItems(
            for: handle,
            turnID: "history-turn",
            cursor: nil,
            limit: 20
        )
        XCTAssertEqual(items.entries.map(\.item.id), ["history-item"])

        try await routed.selectCollaborationMode(try XCTUnwrap(modes.first), for: handle)
        try await routed.selectRunLocation(.approveForMe, for: handle)
        try await routed.setThreadName("Renamed", for: handle)
        try await routed.archiveThread(handle)

        let forked = try await routed.fork(handle, newLocalSessionID: UUID())
        XCTAssertEqual(forked.providerSessionID, "codex-thread-forked")
        try await routed.startWorkingTreeReview(in: handle)
        try await routed.deleteThread(handle)

        let methods = await transport.requestMethods
        for expected in [
            "collaborationMode/list", "skills/list", "plugin/list", "thread/list",
            "thread/search", "thread/searchOccurrences", "thread/turns/list",
            "thread/items/list", "thread/name/set", "thread/archive", "thread/fork",
            "review/start", "thread/delete"
        ] {
            XCTAssertTrue(methods.contains(expected), "Missing provider operation \(expected)")
        }

        await routed.close(forked)
        await routed.close(handle)
    }

    private func baseResponses() -> [String: [JSONValue]] {
        [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("codex-thread-1")],
            "turn/start": [.object([
                "turn": .object(["id": .string("provider-turn-1")])
            ])],
            "turn/steer": [.object([:])]
        ]
    }

    private func capabilityResponses() -> [String: [JSONValue]] {
        [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("codex-thread-1")],
            "collaborationMode/list": [
                collaborationModesResult(),
                collaborationModesResult()
            ],
            "skills/list": [.object([
                "data": .array([.object([
                    "skills": .array([.object([
                        "name": .string("openai-docs"),
                        "path": .string("/tmp/openai-docs/SKILL.md"),
                        "enabled": .bool(true),
                        "scope": .string("user"),
                        "interface": .object([
                            "displayName": .string("OpenAI Docs"),
                            "shortDescription": .string("Official docs")
                        ])
                    ])])
                ])])
            ])],
            "plugin/list": [.object([
                "marketplaces": .array([.object([
                    "name": .string("Curated"),
                    "plugins": .array([.object([
                        "id": .string("github"),
                        "name": .string("github"),
                        "installed": .bool(true),
                        "enabled": .bool(true),
                        "availability": .string("AVAILABLE")
                    ])])
                ])])
            ])],
            "thread/list": [.object([
                "data": .array([.object([
                    "id": .string("recent-thread"),
                    "cwd": .string("/tmp/codex-yhp-product"),
                    "updatedAt": .integer(1_700_000_000),
                    "name": .string("Recent"),
                    "preview": .string("recent preview")
                ])]),
                "nextCursor": .string("recent-next")
            ])],
            "thread/search": [.object([
                "data": .array([.object([
                    "thread": .object([
                        "id": .string("search-thread"),
                        "cwd": .string("/tmp/codex-yhp-product"),
                        "updatedAt": .integer(1_700_000_001),
                        "name": .string("Search"),
                        "preview": .string("approval")
                    ]),
                    "snippet": .string("approval required")
                ])])
            ])],
            "thread/searchOccurrences": [.object([
                "data": .array([.object([
                    "turnId": .string("history-turn"),
                    "itemId": .string("search-item"),
                    "snippet": .string("approval required"),
                    "snippetMatchRange": .object([
                        "start": .integer(0),
                        "end": .integer(8)
                    ]),
                    "turnCursor": .string("turn-cursor")
                ])])
            ])],
            "thread/turns/list": [.object([
                "data": .array([.object([
                    "id": .string("history-turn"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([])
                ])])
            ])],
            "thread/items/list": [.object([
                "data": .array([.object([
                    "turnId": .string("history-turn"),
                    "item": .object([
                        "id": .string("history-item"),
                        "type": .string("contextCompaction")
                    ])
                ])])
            ])],
            "thread/name/set": [.object([:])],
            "thread/archive": [.object([:])],
            "thread/fork": [.object([
                "thread": .object([
                    "id": .string("codex-thread-forked"),
                    "forkedFromId": .string("codex-thread-1"),
                    "status": .object(["type": .string("idle")])
                ])
            ])],
            "review/start": [.object([
                "turn": .object(["id": .string("review-turn")])
            ])],
            "thread/delete": [.object([:])]
        ]
    }

    private func collaborationModesResult() -> JSONValue {
        .object([
            "data": .array([.object([
                "name": .string("Plan"),
                "mode": .string("plan"),
                "model": .string("gpt-5.6-codex"),
                "reasoning_effort": .string("high")
            ])])
        ])
    }

    private func threadResult(_ id: String) -> JSONValue {
        .object([
            "thread": .object([
                "id": .string(id),
                "cwd": .string("/tmp/codex-yhp-product"),
                "preview": .string(""),
                "status": .object(["type": .string("idle")]),
                "turns": .array([])
            ])
        ])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied)
    }
}

private actor CodexYHPPresentationRecorder {
    private(set) var states: [CodexTaskState] = []

    func append(_ state: CodexTaskState) {
        states.append(state)
    }
}
