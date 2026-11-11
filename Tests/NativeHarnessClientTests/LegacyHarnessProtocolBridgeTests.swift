import Foundation
import XCTest
@testable import NativeHarnessClient

final class LegacyHarnessProtocolBridgeTests: XCTestCase {
    func testCodexBridgePreservesRichInputSteerPlanApprovalAndActivity() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object([
                "thread": .object(["id": .string("codex-thread-1")])
            ])],
            "turn/start": [.object([
                "turn": .object(["id": .string("codex-provider-turn-1")])
            ])],
            "turn/steer": [.object([:])],
            "turn/interrupt": [.object([:])],
            "thread/turns/list": [.object([
                "data": .array([.object([
                    "id": .string("codex-history-turn"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([])
                ])]),
                "nextCursor": .string("turn-next"),
                "backwardsCursor": .string("turn-head")
            ])],
            "thread/items/list": [.object([
                "data": .array([.object([
                    "turnId": .string("codex-history-turn"),
                    "item": .object([
                        "id": .string("codex-history-item"),
                        "type": .string("contextCompaction")
                    ])
                ])]),
                "nextCursor": .string("item-next"),
                "backwardsCursor": .string("item-head")
            ])],
            "thread/list": [.object([
                "data": .array([.object([
                    "id": .string("codex-recent-thread"),
                    "cwd": .string("/tmp/codex-yhp-workspace"),
                    "updatedAt": .integer(1_700_000_000),
                    "name": .string("Recent task"),
                    "preview": .string("recent")
                ])]),
                "nextCursor": .string("recent-next")
            ])],
            "thread/search": [.object([
                "data": .array([.object([
                    "thread": .object([
                        "id": .string("codex-search-thread"),
                        "cwd": .string("/tmp/codex-yhp-workspace"),
                        "updatedAt": .integer(1_700_000_001),
                        "name": .string("Search task"),
                        "preview": .string("approval")
                    ]),
                    "snippet": .string("approval required")
                ])]),
                "nextCursor": .string("search-next")
            ])],
            "thread/searchOccurrences": [.object([
                "data": .array([.object([
                    "turnId": .string("codex-history-turn"),
                    "itemId": .string("codex-history-item"),
                    "snippet": .string("approval required"),
                    "snippetMatchRange": .object([
                        "start": .integer(0),
                        "end": .integer(8)
                    ]),
                    "turnCursor": .string("history-cursor")
                ])]),
                "nextCursor": .string("occurrence-next")
            ])],
            "collaborationMode/list": [
                .object(["data": .array([.object([
                    "name": .string("Plan"),
                    "mode": .string("plan"),
                    "model": .string("gpt-5.6-codex"),
                    "reasoning_effort": .string("high")
                ])])]),
                .object(["data": .array([.object([
                    "name": .string("Plan"),
                    "mode": .string("plan"),
                    "model": .string("gpt-5.6-codex"),
                    "reasoning_effort": .string("high")
                ])])])
            ],
            "thread/fork": [.object(["thread": .object([
                "id": .string("codex-thread-forked"),
                "forkedFromId": .string("codex-thread-1"),
                "status": .object(["type": .string("idle")])
            ])])],
            "review/start": [.object([
                "turn": .object(["id": .string("codex-review-provider-turn")])
            ])],
            "thread/name/set": [.object([:])],
            "thread/archive": [.object([:])],
            "thread/delete": [.object([:])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let manifest = HarnessProtocolCompatibilityManifest.codex()
        let bridge = LegacyHarnessProtocolBridge(adapter: adapter, manifest: manifest)
        let localSessionID = UUID()
        let config = HarnessProtocolSessionConfig(
            workspacePath: "/tmp/codex-yhp-workspace",
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )

        XCTAssertTrue(manifest.supports(.turnSteer))
        XCTAssertTrue(manifest.supports(.images))
        XCTAssertTrue(manifest.supports(.plans))
        XCTAssertFalse(manifest.supports(.reasoning))
        XCTAssertFalse(manifest.supports(.usage))
        XCTAssertFalse(manifest.supports(.subagents))

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-create",
                method: .sessionCreate,
                typedParams: HarnessProtocolCreateSessionParams(
                    localSessionID: localSessionID,
                    config: config,
                    initialPrompt: []
                )
            )
        )
        let presentationResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-presentation-read",
                method: .codexPresentationRead,
                typedParams: HarnessProtocolCodexPresentationReadParams(
                    localSessionID: localSessionID,
                    refresh: false
                )
            )
        )
        let presentation = try decode(
            HarnessProtocolCodexPresentationSnapshot.self,
            from: try XCTUnwrap(presentationResponse.result)
        )
        XCTAssertEqual(presentation.thread?.id, "codex-thread-1")

        let turnsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-turns-load",
                method: .codexTurnsLoad,
                typedParams: HarnessProtocolCodexTurnsLoadParams(
                    localSessionID: localSessionID,
                    cursor: nil,
                    limit: 20
                )
            )
        )
        let turnPage = try decode(
            HarnessProtocolCodexTurnPage.self,
            from: try XCTUnwrap(turnsResponse.result)
        )
        XCTAssertEqual(turnPage.turns.first?.id, "codex-history-turn")
        XCTAssertEqual(turnPage.nextCursor, "turn-next")
        XCTAssertEqual(turnPage.backwardsCursor, "turn-head")

        let itemsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-items-load",
                method: .codexItemsLoad,
                typedParams: HarnessProtocolCodexItemsLoadParams(
                    localSessionID: localSessionID,
                    turnID: "codex-history-turn",
                    cursor: nil,
                    limit: 20
                )
            )
        )
        let itemPage = try decode(
            HarnessProtocolCodexItemPage.self,
            from: try XCTUnwrap(itemsResponse.result)
        )
        XCTAssertEqual(itemPage.entries.first?.item.id, "codex-history-item")
        XCTAssertEqual(itemPage.entries.first?.item.type, "contextCompaction")
        XCTAssertEqual(itemPage.nextCursor, "item-next")

        let recentResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-history-recent",
                method: .codexHistoryRecent,
                typedParams: HarnessProtocolCodexHistoryParams(
                    workspacePath: "/tmp/codex-yhp-workspace",
                    cursor: nil,
                    limit: 30
                )
            )
        )
        let recent = try decode(
            HarnessProtocolCodexRecentThreadsPage.self,
            from: try XCTUnwrap(recentResponse.result)
        )
        XCTAssertEqual(recent.threads.first?.id, "codex-recent-thread")
        XCTAssertEqual(recent.nextCursor, "recent-next")

        let searchResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-history-search",
                method: .codexHistorySearch,
                typedParams: HarnessProtocolCodexHistorySearchParams(
                    workspacePath: "/tmp/codex-yhp-workspace",
                    query: "approval",
                    cursor: nil,
                    limit: 30
                )
            )
        )
        let search = try decode(
            HarnessProtocolCodexThreadSearchPage.self,
            from: try XCTUnwrap(searchResponse.result)
        )
        XCTAssertEqual(search.matches.first?.thread.id, "codex-search-thread")
        XCTAssertEqual(search.matches.first?.snippet, "approval required")

        let occurrencesResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-history-occurrences",
                method: .codexHistoryOccurrences,
                typedParams: HarnessProtocolCodexHistoryOccurrencesParams(
                    providerSessionID: "codex-thread-1",
                    query: "approval",
                    cursor: nil,
                    limit: 30
                )
            )
        )
        let occurrences = try decode(
            HarnessProtocolCodexSearchOccurrencesPage.self,
            from: try XCTUnwrap(occurrencesResponse.result)
        )
        XCTAssertEqual(occurrences.occurrences.first?.itemID, "codex-history-item")
        XCTAssertEqual(occurrences.occurrences.first?.snippetMatchRange.end, 8)

        let controlsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-controls-read",
                method: .codexControlsRead,
                typedParams: HarnessProtocolCodexControlsReadParams(
                    localSessionID: localSessionID
                )
            )
        )
        let controls = try decode(
            HarnessProtocolCodexControlsCatalog.self,
            from: try XCTUnwrap(controlsResponse.result)
        )
        let planModeID = try XCTUnwrap(controls.collaborationModes.first?.id)
        XCTAssertEqual(controls.collaborationModes.first?.mode, "plan")
        XCTAssertEqual(
            Set(controls.runLocations.map(\.id)),
            Set(CodexRunLocation.allCases.map(\.rawValue))
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-collaboration-set",
                method: .codexCollaborationSet,
                typedParams: HarnessProtocolCodexCollaborationSetParams(
                    localSessionID: localSessionID,
                    modeID: planModeID
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-run-location-set",
                method: .codexRunLocationSet,
                typedParams: HarnessProtocolCodexRunLocationSetParams(
                    localSessionID: localSessionID,
                    runLocationID: CodexRunLocation.readOnly.rawValue
                )
            )
        )
        let forkedLocalSessionID = UUID()
        let forkResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-fork",
                method: .codexSessionFork,
                typedParams: HarnessProtocolCodexForkParams(
                    localSessionID: localSessionID,
                    newLocalSessionID: forkedLocalSessionID
                )
            )
        )
        let forked = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(forkResponse.result)
        )
        XCTAssertEqual(forked.providerSessionID, "codex-thread-forked")

        let recorder = ProtocolEventRecorder()
        let collector = Task {
            for await event in await bridge.events(for: localSessionID) {
                await recorder.append(event)
            }
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-send",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: localSessionID,
                    clientMessageID: "codex-client-turn-1",
                    content: [
                        .text("inspect"),
                        .file(path: "/tmp/context.png", mimeType: "image/png")
                    ]
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-steer",
                method: .sessionSteer,
                typedParams: HarnessProtocolTurnSteerParams(
                    localSessionID: localSessionID,
                    expectedTurnID: "codex-client-turn-1",
                    clientMessageID: "codex-steer-message-1",
                    content: [.text("continue")],
                    clearPendingPermissions: false
                )
            )
        )
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), [
            "initialize", "thread/start", "thread/turns/list", "thread/items/list",
            "thread/list", "thread/search", "thread/searchOccurrences",
            "collaborationMode/list", "collaborationMode/list", "thread/fork",
            "turn/start", "turn/steer"
        ])
        let submittedInputs = requests[10].params["input"]?.arrayValue ?? []
        XCTAssertEqual(submittedInputs[1]["type"]?.stringValue, "localImage")
        XCTAssertEqual(
            requests[11].params["expectedTurnId"]?.stringValue,
            "codex-provider-turn-1"
        )

        await transport.emit(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "itemId": .string("codex-message-1"),
                "delta": .string("working")
            ])
        )
        await transport.emit(
            method: "turn/plan/updated",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "explanation": .string("Plan"),
                "plan": .array([
                    .object(["step": .string("Inspect"), "status": .string("inProgress")])
                ])
            ])
        )
        let usageBreakdown: JSONValue = .object([
            "inputTokens": .integer(4),
            "cachedInputTokens": .integer(1),
            "cacheWriteInputTokens": .integer(2),
            "outputTokens": .integer(5),
            "reasoningOutputTokens": .integer(3),
            "totalTokens": .integer(15)
        ])
        await transport.emit(
            method: "thread/tokenUsage/updated",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "tokenUsage": .object([
                    "total": usageBreakdown,
                    "last": usageBreakdown,
                    "modelContextWindow": .integer(200_000)
                ])
            ])
        )
        await transport.emit(
            method: "item/started",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "item": .object([
                    "id": .string("codex-command-1"),
                    "type": .string("commandExecution"),
                    "command": .string("swift test")
                ])
            ])
        )
        await transport.emitServerRequest(
            id: .integer(77),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "itemId": .string("codex-command-1"),
                "command": .string("swift test"),
                "reason": .string("Run verification")
            ])
        )
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .permissionRequested }
        }
        let permissions = await recorder.events.compactMap(\.payload.permission)
        let permission = try XCTUnwrap(permissions.last)
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-approve",
                method: .permissionRespond,
                typedParams: HarnessProtocolPermissionResponseParams(
                    localSessionID: localSessionID,
                    requestID: permission.id,
                    selectedActionID: "allow",
                    behavior: .allow,
                    updatedInput: nil,
                    message: nil,
                    interrupt: false
                )
            )
        )
        let sentResponses = await transport.sentResponses
        XCTAssertEqual(
            sentResponses.last?.result["decision"]?.stringValue,
            "accept"
        )

        await transport.emitServerRequest(
            id: .integer(78),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "itemId": .string("codex-question-1"),
                "questions": .array([.object([
                    "id": .string("environment"),
                    "header": .string("Environment"),
                    "question": .string("Which environment?")
                ])])
            ])
        )
        try await waitUntil {
            let response = try? await bridge.handle(
                HarnessProtocolRequest(
                    id: "codex-presentation-pending-request",
                    method: .codexPresentationRead,
                    typedParams: HarnessProtocolCodexPresentationReadParams(
                        localSessionID: localSessionID,
                        refresh: false
                    )
                )
            )
            guard let result = response?.result,
                  let snapshot = try? HarnessProtocolPayloadCodec().decode(
                    HarnessProtocolCodexPresentationSnapshot.self,
                    from: result
                  ) else { return false }
            return snapshot.serverRequests.contains {
                $0.id == "i:78" && $0.kind == "toolUserInput" && $0.resolution == "pending"
            }
        }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-tool-input-response",
                method: .codexServerRequestRespond,
                typedParams: HarnessProtocolCodexServerRequestRespondParams(
                    localSessionID: localSessionID,
                    requestID: "i:78",
                    response: HarnessProtocolCodexServerResponse(
                        kind: .toolUserInput,
                        decision: nil,
                        permissions: nil,
                        scope: nil,
                        strictAutoReview: nil,
                        answers: ["environment": ["Preview"]],
                        action: nil,
                        content: nil,
                        contentItems: nil,
                        success: nil
                    )
                )
            )
        )
        let typedResponses = await transport.sentResponses
        XCTAssertEqual(
            typedResponses.last?.result["answers"]?["environment"]?["answers"]?
                .arrayValue?.first?.stringValue,
            "Preview"
        )

        await transport.emitServerRequest(
            id: .integer(79),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turnId": .string("codex-provider-turn-1"),
                "itemId": .string("codex-question-2"),
                "questions": .array([])
            ])
        )
        try await waitUntil {
            let response = try? await bridge.handle(
                HarnessProtocolRequest(
                    id: "codex-presentation-mismatched-request",
                    method: .codexPresentationRead,
                    typedParams: HarnessProtocolCodexPresentationReadParams(
                        localSessionID: localSessionID,
                        refresh: false
                    )
                )
            )
            guard let result = response?.result,
                  let snapshot = try? HarnessProtocolPayloadCodec().decode(
                    HarnessProtocolCodexPresentationSnapshot.self,
                    from: result
                  ) else { return false }
            return snapshot.serverRequests.contains {
                $0.id == "i:79" && $0.resolution == "pending"
            }
        }
        let responseCountBeforeMismatch = await transport.sentResponses.count
        let mismatchedResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-mismatched-server-response",
                method: .codexServerRequestRespond,
                typedParams: HarnessProtocolCodexServerRequestRespondParams(
                    localSessionID: localSessionID,
                    requestID: "i:79",
                    response: HarnessProtocolCodexServerResponse(
                        kind: .dynamicToolCall,
                        decision: nil,
                        permissions: nil,
                        scope: nil,
                        strictAutoReview: nil,
                        answers: nil,
                        action: nil,
                        content: nil,
                        contentItems: [],
                        success: true
                    )
                )
            )
        )
        XCTAssertTrue(mismatchedResponse.error?.message.contains("does not match") == true)
        let responseCountAfterMismatch = await transport.sentResponses.count
        XCTAssertEqual(responseCountAfterMismatch, responseCountBeforeMismatch)
        let pendingAfterMismatchResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-presentation-after-mismatch",
                method: .codexPresentationRead,
                typedParams: HarnessProtocolCodexPresentationReadParams(
                    localSessionID: localSessionID,
                    refresh: false
                )
            )
        )
        let pendingAfterMismatch = try decode(
            HarnessProtocolCodexPresentationSnapshot.self,
            from: try XCTUnwrap(pendingAfterMismatchResponse.result)
        )
        XCTAssertTrue(pendingAfterMismatch.serverRequests.contains {
            $0.id == "i:79" && $0.resolution == "pending"
        })
        let nativeHandle = HarnessSessionHandle(
            harness: .codex,
            localSessionID: localSessionID,
            providerSessionID: "codex-thread-1",
            workspaceURL: URL(filePath: "/tmp/codex-yhp-workspace")
        )
        let nativePresentation = try await adapter.presentationState(for: nativeHandle)
        XCTAssertEqual(
            HarnessProtocolCodexPresentationEquivalence.differences(
                native: nativePresentation,
                projected: pendingAfterMismatch,
                localSessionID: localSessionID
            ),
            []
        )
        XCTAssertEqual(
            HarnessProtocolCodexPresentationEquivalence.differences(
                native: nativePresentation,
                projected: pendingAfterMismatch,
                localSessionID: UUID()
            ),
            ["localSessionID"]
        )

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-interrupt",
                method: .sessionInterrupt,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        await transport.emit(
            method: "turn/completed",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turn": .object([
                    "id": .string("codex-provider-turn-1"),
                    "status": .string("interrupted")
                ])
            ])
        )
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .turnCanceled }
        }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-review-start",
                method: .codexReviewStart,
                typedParams: HarnessProtocolCodexReviewStartParams(
                    localSessionID: localSessionID,
                    clientTurnID: "codex-review-client-turn"
                )
            )
        )
        await transport.emit(
            method: "turn/completed",
            params: .object([
                "threadId": .string("codex-thread-1"),
                "turn": .object([
                    "id": .string("codex-review-provider-turn"),
                    "status": .string("completed")
                ])
            ])
        )
        try await waitUntil {
            await recorder.events.contains { event in
                event.payload.kind == .turnCompleted
                    && event.payload.turnID == "codex-review-client-turn"
            }
        }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-rename",
                method: .codexThreadRename,
                typedParams: HarnessProtocolCodexThreadRenameParams(
                    localSessionID: localSessionID,
                    name: "Renamed through YHP"
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-archive",
                method: .codexThreadArchive,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-delete",
                method: .codexThreadDelete,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        let events = await recorder.events
        XCTAssertTrue(events.contains { $0.payload.text == "working" })
        XCTAssertTrue(events.contains { $0.payload.kind == .planUpdated })
        XCTAssertTrue(events.contains { $0.payload.kind == .toolCallUpdated })
        XCTAssertTrue(events.contains { $0.payload.kind == .permissionResolved })
        XCTAssertEqual(
            try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: localSessionID,
                events: events
            ).acceptedEventCount,
            events.count
        )

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-close",
                method: .sessionClose,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        let stopCountAfterSource = await transport.stopCount
        XCTAssertEqual(stopCountAfterSource, 0)
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "codex-close-fork",
                method: .sessionClose,
                typedParams: HarnessProtocolSessionReference(
                    localSessionID: forkedLocalSessionID
                )
            )
        )
        let finalStopCount = await transport.stopCount
        XCTAssertEqual(finalStopCount, 1)
        collector.cancel()
    }

    func testPiRPCBridgePreservesIndependentSessionsControlsAndEvents() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let resumedID = UUID()
        let firstTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-yhp-first.jsonl")
        let secondTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-yhp-second.jsonl")
        let resumedTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-yhp-new.jsonl")
        let transports = [
            firstID: firstTransport,
            secondID: secondTransport,
            resumedID: resumedTransport
        ]
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { localSessionID in
                transports[localSessionID] ?? resumedTransport
            }
        )
        let manifest = HarnessProtocolCompatibilityManifest.piRPC(.pi)
        let bridge = LegacyHarnessProtocolBridge(adapter: adapter, manifest: manifest)
        let firstConfig = HarnessProtocolSessionConfig(
            workspacePath: "/tmp/pi-yhp-first-workspace",
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )
        let secondConfig = HarnessProtocolSessionConfig(
            workspacePath: "/tmp/pi-yhp-second-workspace",
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )

        XCTAssertTrue(manifest.supports(.structuredPermissions))
        XCTAssertTrue(manifest.supports(.structuredActivities))
        // pi's RPC prompt carries `images`, so the manifest no longer withholds the capability.
        XCTAssertTrue(manifest.supports(.images))
        XCTAssertFalse(manifest.supports(.subagents))

        let firstCreate = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-create-first",
                method: .sessionCreate,
                typedParams: HarnessProtocolCreateSessionParams(
                    localSessionID: firstID,
                    config: firstConfig,
                    initialPrompt: []
                )
            )
        )
        let secondCreate = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-create-second",
                method: .sessionCreate,
                typedParams: HarnessProtocolCreateSessionParams(
                    localSessionID: secondID,
                    config: secondConfig,
                    initialPrompt: []
                )
            )
        )
        let firstSession = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(firstCreate.result)
        )
        let secondSession = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(secondCreate.result)
        )
        XCTAssertEqual(firstSession.providerSessionID, "/tmp/pi-yhp-first.jsonl")
        XCTAssertEqual(secondSession.providerSessionID, "/tmp/pi-yhp-second.jsonl")
        XCTAssertNotEqual(firstSession.providerSessionID, secondSession.providerSessionID)
        let firstConfiguration = await firstTransport.configuration
        let secondConfiguration = await secondTransport.configuration
        XCTAssertEqual(firstConfiguration?.workspaceURL.path, "/tmp/pi-yhp-first-workspace")
        XCTAssertEqual(secondConfiguration?.workspaceURL.path, "/tmp/pi-yhp-second-workspace")

        let imageResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-document-unsupported",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: firstID,
                    clientMessageID: "pi-document-turn",
                    content: [.inlineData(mimeType: "application/pdf", base64Data: "aGVsbG8=")]
                )
            )
        )
        XCTAssertNil(imageResponse.result)
        XCTAssertEqual(imageResponse.error?.code, "yardlet.compat.adapter_error")
        let requestTypesAfterImage = await firstTransport.requestTypes
        XCTAssertFalse(requestTypesAfterImage.contains("prompt"))

        let optionsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-options-read",
                method: .compatibilityOptionsRead,
                typedParams: HarnessProtocolSessionOptionsReadParams(localSessionID: firstID)
            )
        )
        let options = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(optionsResponse.result)
        )
        XCTAssertEqual(Set(options.options.map(\.id)), ["model", "thinking", "autoCompaction"])
        XCTAssertEqual(
            options.options.first(where: { $0.id == "thinking" })?.currentValue,
            "medium"
        )

        let setResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-thinking-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: firstID,
                    optionID: "thinking",
                    value: "high"
                )
            )
        )
        let updatedOptions = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(setResponse.result)
        )
        XCTAssertEqual(
            updatedOptions.options.first(where: { $0.id == "thinking" })?.currentValue,
            "high"
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-model-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: firstID,
                    optionID: "model",
                    value: "anthropic|sonnet"
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-auto-compaction-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: firstID,
                    optionID: "autoCompaction",
                    value: "false"
                )
            )
        )

        let actionsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-actions-read",
                method: .compatibilityActionsRead,
                typedParams: HarnessProtocolSessionActionsReadParams(localSessionID: firstID)
            )
        )
        let actions = try decode(
            HarnessProtocolSessionActionCatalog.self,
            from: try XCTUnwrap(actionsResponse.result)
        )
        XCTAssertEqual(actions.actions.map(\.id), [ProviderCapabilityActionID.compact])
        let invalidActionResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-action-invalid",
                method: .compatibilityActionPerform,
                typedParams: HarnessProtocolSessionActionPerformParams(
                    localSessionID: firstID,
                    actionID: "unknown-action"
                )
            )
        )
        XCTAssertNil(invalidActionResponse.result)
        XCTAssertEqual(invalidActionResponse.error?.code, "yardlet.compat.adapter_error")
        let requestTypesAfterInvalidAction = await firstTransport.requestTypes
        XCTAssertFalse(requestTypesAfterInvalidAction.contains("compact"))
        let compactResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-compact",
                method: .compatibilityActionPerform,
                typedParams: HarnessProtocolSessionActionPerformParams(
                    localSessionID: firstID,
                    actionID: ProviderCapabilityActionID.compact
                )
            )
        )
        let compactResult = try decode(
            HarnessProtocolSessionActionCatalog.self,
            from: try XCTUnwrap(compactResponse.result)
        )
        XCTAssertNotNil(compactResult.message)
        let controlRequestTypes = await firstTransport.requestTypes
        XCTAssertTrue(controlRequestTypes.contains("set_model"))
        XCTAssertTrue(controlRequestTypes.contains("set_thinking_level"))
        XCTAssertTrue(controlRequestTypes.contains("set_auto_compaction"))
        XCTAssertTrue(controlRequestTypes.contains("compact"))

        let firstRecorder = ProtocolEventRecorder()
        let secondRecorder = ProtocolEventRecorder()
        let firstCollector = Task {
            for await event in await bridge.events(for: firstID) {
                await firstRecorder.append(event)
            }
        }
        let secondCollector = Task {
            for await event in await bridge.events(for: secondID) {
                await secondRecorder.append(event)
            }
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-send-first",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: firstID,
                    clientMessageID: "pi-turn-first",
                    content: [.text("first")]
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-send-second",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: secondID,
                    clientMessageID: "pi-turn-second",
                    content: [.text("second")]
                )
            )
        )
        await firstTransport.emit(.object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string("ONE")
            ])
        ]))
        await secondTransport.emit(.object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string("TWO")
            ])
        ]))
        await firstTransport.emit(.object([
            "type": .string("tool_execution_start"),
            "toolCallId": .string("pi-tool-1"),
            "toolName": .string("bash"),
            "args": .object(["command": .string("swift test")])
        ]))
        await firstTransport.emit(.object([
            "type": .string("extension_ui_request"),
            "id": .string("pi-confirm-1"),
            "method": .string("confirm"),
            "title": .string("Run tests"),
            "message": .string("Continue?")
        ]))
        try await waitUntil {
            await firstRecorder.events.contains { $0.payload.kind == .permissionRequested }
        }
        let permissionEvents = await firstRecorder.events.compactMap(\.payload.permission)
        let permission = try XCTUnwrap(permissionEvents.last)
        XCTAssertEqual(permission.actions.map(\.id), ["allow", "deny"])
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-permission-allow",
                method: .permissionRespond,
                typedParams: HarnessProtocolPermissionResponseParams(
                    localSessionID: firstID,
                    requestID: permission.id,
                    selectedActionID: "allow",
                    behavior: .allow,
                    updatedInput: nil,
                    message: nil,
                    interrupt: false
                )
            )
        )
        let permissionResponses = await firstTransport.sentMessages
        XCTAssertTrue(permissionResponses.contains { message in
            message["id"]?.stringValue == "pi-confirm-1"
                && message["confirmed"]?.boolValue == true
        })

        await firstTransport.emit(.object([
            "type": .string("agent_end"),
            "isTerminal": .bool(true)
        ]))
        await secondTransport.emit(.object([
            "type": .string("agent_end"),
            "isTerminal": .bool(true)
        ]))
        try await waitUntil {
            let firstCompleted = await firstRecorder.events.contains {
                $0.payload.kind == .turnCompleted
            }
            let secondCompleted = await secondRecorder.events.contains {
                $0.payload.kind == .turnCompleted
            }
            return firstCompleted && secondCompleted
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-send-cancel",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: secondID,
                    clientMessageID: "pi-turn-cancel",
                    content: [.text("cancel")]
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-interrupt",
                method: .sessionInterrupt,
                typedParams: HarnessProtocolSessionReference(localSessionID: secondID)
            )
        )
        try await waitUntil {
            await secondRecorder.events.contains { event in
                event.payload.kind == .turnCanceled
                    && event.payload.turnID == "pi-turn-cancel"
            }
        }

        let firstEvents = await firstRecorder.events
        let secondEvents = await secondRecorder.events
        XCTAssertTrue(firstEvents.contains { $0.payload.text == "ONE" })
        XCTAssertFalse(firstEvents.contains { $0.payload.text == "TWO" })
        XCTAssertTrue(secondEvents.contains { $0.payload.text == "TWO" })
        XCTAssertFalse(secondEvents.contains { $0.payload.text == "ONE" })
        XCTAssertTrue(firstEvents.contains { $0.payload.kind == .toolCallUpdated })
        XCTAssertTrue(firstEvents.contains { $0.payload.kind == .permissionResolved })
        XCTAssertEqual(
            try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: firstID,
                events: firstEvents
            ).acceptedEventCount,
            firstEvents.count
        )
        XCTAssertEqual(
            try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: secondID,
                events: secondEvents
            ).acceptedEventCount,
            secondEvents.count
        )

        let resumeResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "pi-resume",
                method: .sessionResume,
                typedParams: HarnessProtocolResumeSessionParams(
                    localSessionID: resumedID,
                    providerSessionID: "/tmp/pi-yhp-existing.jsonl",
                    config: firstConfig
                )
            )
        )
        let resumed = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(resumeResponse.result)
        )
        XCTAssertEqual(resumed.providerSessionID, "/tmp/pi-yhp-existing.jsonl")
        let resumedRequestTypes = await resumedTransport.requestTypes
        XCTAssertTrue(resumedRequestTypes.contains("switch_session"))

        for localSessionID in [firstID, secondID, resumedID] {
            _ = try await bridge.handle(
                HarnessProtocolRequest(
                    id: "pi-close-\(localSessionID.uuidString)",
                    method: .sessionClose,
                    typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
                )
            )
        }
        let firstStopCount = await firstTransport.stopCount
        let secondStopCount = await secondTransport.stopCount
        let resumedStopCount = await resumedTransport.stopCount
        XCTAssertEqual(firstStopCount, 1)
        XCTAssertEqual(secondStopCount, 1)
        XCTAssertEqual(resumedStopCount, 1)
        firstCollector.cancel()
        secondCollector.cancel()
    }

    func testClaudeBridgePreservesControlsPermissionsLifecycleAndCrash() async throws {
        let createdID = UUID()
        let resumedID = UUID()
        let createdTransport = FakeClaudeTransport()
        let resumedTransport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { localSessionID in
                localSessionID == createdID ? createdTransport : resumedTransport
            }
        )
        let manifest = HarnessProtocolCompatibilityManifest.claude()
        let bridge = LegacyHarnessProtocolBridge(adapter: adapter, manifest: manifest)
        let config = HarnessProtocolSessionConfig(
            workspacePath: "/tmp/claude-yhp-workspace",
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )

        XCTAssertTrue(manifest.supports(.structuredPermissions))
        XCTAssertTrue(manifest.supports(.structuredActivities))
        XCTAssertTrue(manifest.supports(.plans))
        // stream-json carries a base64 image block beside the text block.
        XCTAssertTrue(manifest.supports(.images))
        XCTAssertFalse(manifest.supports(.subagents))

        let createResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-create",
                method: .sessionCreate,
                typedParams: HarnessProtocolCreateSessionParams(
                    localSessionID: createdID,
                    config: config,
                    initialPrompt: []
                )
            )
        )
        let created = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(createResponse.result)
        )
        XCTAssertEqual(created.localSessionID, createdID)

        let imageResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-image-unsupported",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: createdID,
                    clientMessageID: "claude-image-turn",
                    content: [.file(path: "/tmp/image.png", mimeType: "image/png")]
                )
            )
        )
        XCTAssertNil(imageResponse.result)
        XCTAssertEqual(imageResponse.error?.code, "yardlet.compat.adapter_error")
        let sentAfterImage = await createdTransport.sentValues
        XCTAssertTrue(sentAfterImage.isEmpty)

        let optionsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-options-read",
                method: .compatibilityOptionsRead,
                typedParams: HarnessProtocolSessionOptionsReadParams(localSessionID: createdID)
            )
        )
        let options = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(optionsResponse.result)
        )
        XCTAssertEqual(
            Set(options.options.map(\.id)),
            ["model", "permissionMode", ClaudeLaunchOption.chromeIntegration]
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-model-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: createdID,
                    optionID: "model",
                    value: "opus"
                )
            )
        )
        let modeResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-mode-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: createdID,
                    optionID: "permissionMode",
                    value: "plan"
                )
            )
        )
        let updatedOptions = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(modeResponse.result)
        )
        XCTAssertEqual(
            updatedOptions.options.first(where: { $0.id == "model" })?.currentValue,
            "opus"
        )
        XCTAssertEqual(
            updatedOptions.options.first(where: { $0.id == "permissionMode" })?.currentValue,
            "plan"
        )
        XCTAssertEqual(
            updatedOptions.options.first(where: { $0.id == "permissionMode" })?.choices.map(\.id),
            ClaudePermissionMode.selectable
        )

        let recorder = ProtocolEventRecorder()
        let collector = Task {
            for await event in await bridge.events(for: createdID) {
                await recorder.append(event)
            }
        }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-send",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: createdID,
                    clientMessageID: "claude-turn",
                    content: [.text("hello")]
                )
            )
        )
        await createdTransport.emit(.object([
            "type": .string("stream_event"),
            "event": .object([
                "type": .string("content_block_delta"),
                "delta": .object([
                    "type": .string("text_delta"),
                    "text": .string("world")
                ])
            ])
        ]))
        await createdTransport.emit(.object([
            "type": .string("assistant"),
            "message": .object([
                "content": .array([
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("claude-tool-1"),
                        "name": .string("Bash"),
                        "input": .object(["command": .string("git status")])
                    ])
                ])
            ])
        ]))
        await createdTransport.emit(.object([
            "type": .string("control_request"),
            "request_id": .string("claude-permission-1"),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string("Bash"),
                "input": .object(["command": .string("git status")]),
                "title": .string("Run command")
            ])
        ]))
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .permissionRequested }
        }
        let permissions = await recorder.events.compactMap(\.payload.permission)
        let permission = try XCTUnwrap(permissions.last)
        XCTAssertEqual(permission.input?.stringValue, "git status")
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-deny",
                method: .permissionRespond,
                typedParams: HarnessProtocolPermissionResponseParams(
                    localSessionID: createdID,
                    requestID: permission.id,
                    selectedActionID: "deny",
                    behavior: .deny,
                    updatedInput: nil,
                    message: nil,
                    interrupt: false
                )
            )
        )
        let sentAfterPermission = await createdTransport.sentValues
        XCTAssertTrue(sentAfterPermission.contains { value in
            value["response"]?["request_id"]?.stringValue == "claude-permission-1"
                && value["response"]?["response"]?["behavior"]?.stringValue == "deny"
        })
        await createdTransport.emit(.object([
            "type": .string("result"),
            "is_error": .bool(false)
        ]))
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .turnCompleted }
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-send-cancel",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: createdID,
                    clientMessageID: "claude-turn-cancel",
                    content: [.text("cancel")]
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-interrupt",
                method: .sessionInterrupt,
                typedParams: HarnessProtocolSessionReference(localSessionID: createdID)
            )
        )
        await createdTransport.emit(.object([
            "type": .string("result"),
            "is_error": .bool(false)
        ]))
        try await waitUntil {
            await recorder.events.contains { event in
                event.payload.kind == .turnCanceled
                    && event.payload.turnID == "claude-turn-cancel"
            }
        }
        let createdEvents = await recorder.events
        XCTAssertTrue(createdEvents.contains { $0.payload.text == "world" })
        XCTAssertTrue(createdEvents.contains { $0.payload.kind == .toolCallUpdated })
        XCTAssertTrue(createdEvents.contains { $0.payload.kind == .permissionResolved })
        XCTAssertEqual(
            try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: createdID,
                events: createdEvents
            ).acceptedEventCount,
            createdEvents.count
        )

        let resumeResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-resume",
                method: .sessionResume,
                typedParams: HarnessProtocolResumeSessionParams(
                    localSessionID: resumedID,
                    providerSessionID: created.providerSessionID,
                    config: config
                )
            )
        )
        let resumed = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(resumeResponse.result)
        )
        XCTAssertEqual(resumed.providerSessionID, created.providerSessionID)
        let resumedConfiguration = await resumedTransport.configuration
        XCTAssertEqual(resumedConfiguration?.resumesExistingSession, true)
        let resumedRecorder = ProtocolEventRecorder()
        let resumedCollector = Task {
            for await event in await bridge.events(for: resumedID) {
                await resumedRecorder.append(event)
            }
        }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "claude-send-crash",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: resumedID,
                    clientMessageID: "claude-turn-crash",
                    content: [.text("crash")]
                )
            )
        )
        await resumedTransport.crash()
        try await waitUntil {
            await resumedRecorder.events.contains { event in
                event.payload.kind == .turnFailed
                    && event.payload.turnID == "claude-turn-crash"
            }
        }
        let resumedEvents = await resumedRecorder.events
        XCTAssertEqual(
            try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: resumedID,
                events: resumedEvents
            ).acceptedEventCount,
            resumedEvents.count
        )

        for localSessionID in [createdID, resumedID] {
            _ = try await bridge.handle(
                HarnessProtocolRequest(
                    id: "claude-close-\(localSessionID.uuidString)",
                    method: .sessionClose,
                    typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
                )
            )
        }
        let createdStopCount = await createdTransport.stopCount
        let resumedStopCount = await resumedTransport.stopCount
        XCTAssertEqual(createdStopCount, 1)
        XCTAssertEqual(resumedStopCount, 1)
        collector.cancel()
        resumedCollector.cancel()
    }

    func testACPBridgePreservesExactPermissionsOptionsAndSharedLifetime() async throws {
        let transport = FakeACPTransport(exposesConfig: true)
        let adapter = ACPAdapter(
            kind: .openCode,
            executableURL: URL(filePath: "/tmp/fake-opencode"),
            launchArguments: ["acp"],
            transportFactory: { transport }
        )
        let manifest = HarnessProtocolCompatibilityManifest.acp(.openCode)
        let bridge = LegacyHarnessProtocolBridge(adapter: adapter, manifest: manifest)
        let localSessionID = UUID()
        let config = HarnessProtocolSessionConfig(
            workspacePath: "/tmp/acp-yhp-workspace",
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-create",
                method: .sessionCreate,
                typedParams: HarnessProtocolCreateSessionParams(
                    localSessionID: localSessionID,
                    config: config,
                    initialPrompt: []
                )
            )
        )
        let recorder = ProtocolEventRecorder()
        let collector = Task {
            for await event in await bridge.events(for: localSessionID) {
                await recorder.append(event)
            }
        }

        let optionsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "options-read",
                method: .compatibilityOptionsRead,
                typedParams: HarnessProtocolSessionOptionsReadParams(
                    localSessionID: localSessionID
                )
            )
        )
        let options = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(optionsResponse.result)
        )
        XCTAssertEqual(options.options.first?.id, "mode")
        XCTAssertEqual(options.options.first?.currentValue, "ask")
        XCTAssertEqual(options.options.first?.choices.map(\.id), ["ask", "code"])

        let setResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "options-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: localSessionID,
                    optionID: "mode",
                    value: "code"
                )
            )
        )
        let updatedOptions = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(setResponse.result)
        )
        XCTAssertEqual(updatedOptions.options.first?.currentValue, "code")

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-send",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: localSessionID,
                    clientMessageID: "acp-turn",
                    content: [.text("hello")]
                )
            )
        )
        try await waitUntil { await transport.requestMethods.contains("session/prompt") }
        await transport.emit(acpUpdate(
            providerSessionID: "acp-session-1",
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("world")
                ])
            ])
        ))
        await transport.emit(acpUpdate(
            providerSessionID: "acp-session-1",
            update: .object([
                "sessionUpdate": .string("plan"),
                "entries": .array([
                    .object([
                        "status": .string("in_progress"),
                        "content": .string("Implement ACP bridge")
                    ])
                ])
            ])
        ))
        await transport.emit(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("permission-rpc-exact"),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string("acp-session-1"),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Run command"),
                    "kind": .string("execute"),
                    "rawInput": .object(["command": .string("swift test")])
                ]),
                "options": .array([
                    permissionOption("allow-once", "Allow once", "allow_once"),
                    permissionOption("allow-always", "Always allow", "allow_always"),
                    permissionOption("reject-once", "Reject once", "reject_once"),
                    permissionOption("reject-always", "Always reject", "reject_always")
                ])
            ])
        ]))
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .permissionRequested }
        }
        let recordedPermissions = await recorder.events.compactMap(\.payload.permission)
        let permission = try XCTUnwrap(recordedPermissions.last)
        XCTAssertEqual(
            permission.actions.map(\.id),
            ["allow-once", "allow-always", "reject-once", "reject-always"]
        )
        XCTAssertEqual(permission.actions[1].behavior, .allow)
        XCTAssertEqual(permission.actions[1].role, .secondary)

        let invalidPermissionResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "permission-invalid",
                method: .permissionRespond,
                typedParams: HarnessProtocolPermissionResponseParams(
                    localSessionID: localSessionID,
                    requestID: permission.id,
                    selectedActionID: "allow-always",
                    behavior: .deny,
                    updatedInput: nil,
                    message: nil,
                    interrupt: false
                )
            )
        )
        XCTAssertNil(invalidPermissionResponse.result)
        XCTAssertEqual(
            invalidPermissionResponse.error?.code,
            "yardlet.compat.adapter_error"
        )
        let beforeValidPermission = await transport.sentMessages
        XCTAssertFalse(beforeValidPermission.contains { message in
            message["result"]?["outcome"]?["optionId"]?.stringValue == "allow-always"
        })

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "permission-response",
                method: .permissionRespond,
                typedParams: HarnessProtocolPermissionResponseParams(
                    localSessionID: localSessionID,
                    requestID: permission.id,
                    selectedActionID: "allow-always",
                    behavior: .allow,
                    updatedInput: nil,
                    message: nil,
                    interrupt: false
                )
            )
        )
        let sent = await transport.sentMessages
        XCTAssertTrue(sent.contains { message in
            message["result"]?["outcome"]?["optionId"]?.stringValue == "allow-always"
        })

        await transport.completePrompt()
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .turnCompleted }
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-send-cancel",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: localSessionID,
                    clientMessageID: "acp-turn-cancel",
                    content: [.text("cancel")]
                )
            )
        )
        try await waitUntil { await transport.pendingPromptCount == 1 }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-interrupt",
                method: .sessionInterrupt,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        await transport.completePrompt()
        try await waitUntil {
            await recorder.events.contains { event in
                event.payload.kind == .turnCanceled
                    && event.payload.turnID == "acp-turn-cancel"
            }
        }

        let events = await recorder.events
        XCTAssertTrue(events.contains { $0.payload.kind == .assistantDelta })
        XCTAssertTrue(events.contains { $0.payload.kind == .planUpdated })
        XCTAssertEqual(
            try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: localSessionID,
                events: events
            ).acceptedEventCount,
            events.count
        )

        let resumedID = UUID()
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-resume",
                method: .sessionResume,
                typedParams: HarnessProtocolResumeSessionParams(
                    localSessionID: resumedID,
                    providerSessionID: "existing-acp-session",
                    config: config
                )
            )
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-close-first",
                method: .sessionClose,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        let stopCountAfterFirstClose = await transport.stopCount
        XCTAssertEqual(stopCountAfterFirstClose, 0)
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "acp-close-second",
                method: .sessionClose,
                typedParams: HarnessProtocolSessionReference(localSessionID: resumedID)
            )
        )
        let finalStopCount = await transport.stopCount
        XCTAssertEqual(finalStopCount, 1)
        collector.cancel()
    }

    /// The provider's end reaches the bridge on two streams. The last presentation is what ends a turn it left running,
    /// so it crosses even when the events get there first, and only then does the protocol's stream end.
    func testTheLastPresentationCrossesAfterTheEventsEnd() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let bridge = LegacyHarnessProtocolBridge(adapter: adapter, manifest: HarnessProtocolCompatibilityManifest.codex())
        let localSessionID = UUID()
        _ = try await bridge.handle(HarnessProtocolRequest(
            id: "create", method: .sessionCreate,
            typedParams: HarnessProtocolCreateSessionParams(
                localSessionID: localSessionID,
                config: HarnessProtocolSessionConfig(workspacePath: "/tmp/codex-yhp-workspace", modelID: nil, modeID: nil,
                                                     featureValues: [:], extensionValues: [:]),
                initialPrompt: [])))
        let recorder = ProtocolEventRecorder()
        let collector = Task {
            for await event in await bridge.events(for: localSessionID) { await recorder.append(event) }
        }
        await adapter.finishEvents(for: localSessionID, keepingPresentation: true)
        // Long enough for the event relay to reach its end, which shows nowhere a test could wait on. The
        // test holds in either order; the pause makes it the order this test is about.
        try await Task.sleep(for: .milliseconds(200))
        var last = CodexTaskState.empty
        last.lastAppliedSequence = 7
        await adapter.emitPresentation(last, for: localSessionID)
        await adapter.finishPresentation(for: localSessionID)
        await collector.value

        let presented = try await recorder.events.compactMap(\.payload.extensionEvent)
            .filter { $0.name == HarnessProtocolCodexPresentationEvent.updated }
            .map { try decode(HarnessProtocolCodexPresentationSnapshot.self, from: $0.payload) }
        XCTAssertEqual(presented.last?.lastAppliedSequence, 7)
    }

    func testStructuredHeadlessBridgePreservesLifecycleAndConforms() async throws {
        let fixture = try makeAntigravityFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(
            kind: .antigravityCLI,
            executableURL: fixture.executable
        )
        let manifest = HarnessProtocolCompatibilityManifest.structuredHeadless(.antigravityCLI)
        let bridge = LegacyHarnessProtocolBridge(
            adapter: adapter,
            manifest: manifest,
            interruptEventPolicy: .synthesizeCanceled
        )
        let localSessionID = UUID()
        let config = HarnessProtocolSessionConfig(
            workspacePath: fixture.root.path(percentEncoded: false),
            modelID: nil,
            modeID: nil,
            featureValues: [:],
            extensionValues: [:]
        )

        XCTAssertFalse(manifest.supports(.subagents))
        XCTAssertFalse(manifest.supports(.plans))
        let runtimeResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "runtime",
                method: .runtimeProbe,
                typedParams: HarnessProtocolEmptyParams()
            )
        )
        let runtime = try decode(
            HarnessProtocolRuntimeInfo.self,
            from: try XCTUnwrap(runtimeResponse.result)
        )
        XCTAssertEqual(runtime.capabilities, manifest.capabilities)

        let createResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "create",
                method: .sessionCreate,
                typedParams: HarnessProtocolCreateSessionParams(
                    localSessionID: localSessionID,
                    config: config,
                    initialPrompt: []
                )
            )
        )
        let created = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(createResponse.result)
        )
        XCTAssertEqual(created.localSessionID, localSessionID)

        let optionsResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "headless-options-read",
                method: .compatibilityOptionsRead,
                typedParams: HarnessProtocolSessionOptionsReadParams(
                    localSessionID: localSessionID
                )
            )
        )
        let options = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(optionsResponse.result)
        )
        // The effort is the chosen model's own, so it shows once a model with efforts is chosen.
        XCTAssertEqual(
            Set(options.options.map(\.id)),
            ["model", "agent", "permissionMode", "sandbox"]
        )
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "headless-model-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: localSessionID,
                    optionID: "model",
                    value: "agy-pro"
                )
            )
        )
        let setResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "headless-reasoning-set",
                method: .compatibilityOptionsSet,
                typedParams: HarnessProtocolSessionOptionSetParams(
                    localSessionID: localSessionID,
                    optionID: "reasoningEffort",
                    value: "high"
                )
            )
        )
        let updatedOptions = try decode(
            HarnessProtocolSessionOptionCatalog.self,
            from: try XCTUnwrap(setResponse.result)
        )
        XCTAssertEqual(
            updatedOptions.options.first(where: { $0.id == "reasoningEffort" })?.currentValue,
            "high"
        )

        let recorder = ProtocolEventRecorder()
        let collector = Task {
            for await event in await bridge.events(for: localSessionID) {
                await recorder.append(event)
            }
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "slow",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: localSessionID,
                    clientMessageID: "turn-slow",
                    content: [.text("slow")]
                )
            )
        )
        try await waitUntil {
            await recorder.events.contains { $0.payload.status == .running }
        }
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "interrupt",
                method: .sessionInterrupt,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        try await waitUntil {
            let events = await recorder.events
            guard let canceled = events.first(where: { $0.payload.kind == .turnCanceled }) else {
                return false
            }
            return events.contains {
                $0.sequence > canceled.sequence && $0.payload.status == .ready
            }
        }

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "send",
                method: .sessionSend,
                typedParams: HarnessProtocolTurnSubmitParams(
                    localSessionID: localSessionID,
                    clientMessageID: "turn-complete",
                    content: [.text("hello")]
                )
            )
        )
        try await waitUntil {
            await recorder.events.contains { $0.payload.kind == .turnCompleted }
        }

        let events = await recorder.events
        XCTAssertEqual(events.filter { $0.payload.kind == .sessionStarted }.count, 1)
        XCTAssertTrue(events.contains { event in
            event.payload.extensionEvent?.name == "session.provider_identity_updated"
        })
        XCTAssertTrue(events.contains { event in
            event.payload.kind == .assistantDelta && event.rawProviderEvent != nil
        })
        let report = try HarnessProtocolConformanceKit.validate(
            manifest: manifest,
            localSessionID: localSessionID,
            events: events
        )
        XCTAssertEqual(report.acceptedEventCount, events.count)

        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "close",
                method: .sessionClose,
                typedParams: HarnessProtocolSessionReference(localSessionID: localSessionID)
            )
        )
        collector.cancel()

        let resumedID = UUID()
        let resumeResponse = try await bridge.handle(
            HarnessProtocolRequest(
                id: "resume",
                method: .sessionResume,
                typedParams: HarnessProtocolResumeSessionParams(
                    localSessionID: resumedID,
                    providerSessionID: "agy-existing",
                    config: config
                )
            )
        )
        let resumed = try decode(
            HarnessProtocolSessionDescriptor.self,
            from: try XCTUnwrap(resumeResponse.result)
        )
        XCTAssertEqual(resumed.providerSessionID, "agy-existing")
        _ = try await bridge.handle(
            HarnessProtocolRequest(
                id: "close-resumed",
                method: .sessionClose,
                typedParams: HarnessProtocolSessionReference(localSessionID: resumedID)
            )
        )
    }

    private func makeAntigravityFixture() throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-yhp-headless-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-headless")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' 'fixture 1.0.0'
          exit 0
        fi
        if [ "$1" = "models" ]; then
          printf '%s\\n' 'agy-pro-high Antigravity Pro (High)' 'agy-pro-low Antigravity Pro (Low)'
          exit 0
        fi
        if [ "$1" = "agents" ]; then
          printf '%s\\n' 'reviewer Review Agent'
          exit 0
        fi
        if [ "$2" = "/model" ]; then
          printf '%s\\n' '{"event":"result","result":{"conversation_id":"","status":"SUCCESS","response":""}}'
          exit 0
        fi
        if [ "$2" = "slow" ]; then
          trap 'exit 130' INT TERM
          while :; do sleep 1; done
        fi
        printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
        printf '%s\\n' '{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"ready"}}'
        printf '%s\\n' '{"event":"result","result":{"conversation_id":"agy-conversation","status":"SUCCESS","response":"ready"}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (root, executable)
    }

    private func acpUpdate(providerSessionID: String, update: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(providerSessionID),
                "update": update
            ])
        ])
    }

    private func permissionOption(_ id: String, _ name: String, _ kind: String) -> JSONValue {
        .object([
            "optionId": .string(id),
            "name": .string(name),
            "kind": .string(kind)
        ])
    }

    private func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from value: JSONValue
    ) throws -> T {
        try HarnessProtocolPayloadCodec().decode(type, from: value)
    }
}

private actor ProtocolEventRecorder {
    private(set) var events: [HarnessProtocolEventEnvelope] = []
    func append(_ event: HarnessProtocolEventEnvelope) { events.append(event) }
}
