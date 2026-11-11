import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexProtocolTests: XCTestCase {
    private let codec = CodexRPCCodec()

    func testInitializeRequestUsesObservedAppServerEnvelope() throws {
        let request = CodexProtocol.initialize(id: 1, clientVersion: "0.0.1")
        let data = try codec.encodeLine(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["method"] as? String, "initialize")
        XCTAssertNil(object["jsonrpc"])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        XCTAssertEqual(data.last, 0x0A)
    }

    func testHistoryAndPaginationRequestsUseInstalledSchemaMethods() {
        let read = CodexProtocol.readThread(id: 1, threadID: "thread-1")
        XCTAssertEqual(read.method, "thread/read")
        XCTAssertEqual(read.params["includeTurns"]?.boolValue, true)

        let turns = CodexProtocol.listTurns(
            id: 2,
            threadID: "thread-1",
            cursor: "next",
            limit: 20,
            sortDirection: "asc",
            itemsView: "full"
        )
        XCTAssertEqual(turns.method, "thread/turns/list")
        XCTAssertEqual(turns.params["cursor"]?.stringValue, "next")
        XCTAssertEqual(turns.params["limit"]?.integerValue, 20)
        XCTAssertEqual(turns.params["itemsView"]?.stringValue, "full")

        let items = CodexProtocol.listItems(
            id: 3,
            threadID: "thread-1",
            turnID: "turn-1",
            cursor: "items",
            limit: 10
        )
        XCTAssertEqual(items.method, "thread/items/list")
        XCTAssertEqual(items.params["turnId"]?.stringValue, "turn-1")
        XCTAssertEqual(items.params["cursor"]?.stringValue, "items")

        let recent = CodexProtocol.recentThreads(
            id: 4,
            workspaceURL: URL(filePath: "/tmp/workspace"),
            cursor: "recent",
            limit: 12
        )
        XCTAssertEqual(recent.method, "thread/list")
        XCTAssertEqual(recent.params["cwd"]?.stringValue, "/tmp/workspace")
        XCTAssertEqual(recent.params["cursor"]?.stringValue, "recent")
        XCTAssertEqual(recent.params["limit"]?.integerValue, 12)
    }

    func testResumeRequestCanAskForBoundedInitialTurnsPage() {
        let request = CodexProtocol.resumeThread(
            id: 5,
            threadID: "thread-1",
            workspaceURL: URL(filePath: "/tmp/workspace"),
            excludeTurns: true,
            initialTurnsPage: .object([
                "sortDirection": .string("desc"),
                "itemsView": .string("full"),
                "limit": .integer(3)
            ])
        )

        XCTAssertEqual(request.method, "thread/resume")
        XCTAssertEqual(request.params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(request.params["excludeTurns"]?.boolValue, true)
        XCTAssertEqual(request.params["initialTurnsPage"]?["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(request.params["initialTurnsPage"]?["itemsView"]?.stringValue, "full")
        XCTAssertEqual(request.params["initialTurnsPage"]?["limit"]?.integerValue, 3)
    }

    func testAccountUsageRequestsUseTheLockedNullParamsEnvelope() {
        let rateLimits = CodexProtocol.accountRateLimits(id: 20)
        XCTAssertEqual(rateLimits.method, "account/rateLimits/read")
        XCTAssertEqual(rateLimits.params, .null)

        let usage = CodexProtocol.accountUsage(id: 21)
        XCTAssertEqual(usage.method, "account/usage/read")
        XCTAssertEqual(usage.params, .null)
    }

    func testConfigReadRequestUsesTheLockedWorkspaceAndLayerEnvelope() {
        let request = CodexProtocol.readConfig(
            id: 22,
            workspaceURL: URL(filePath: "/tmp/workspace"),
            includeLayers: true
        )
        XCTAssertEqual(request.method, "config/read")
        XCTAssertEqual(request.params["cwd"]?.stringValue, "/tmp/workspace")
        XCTAssertEqual(request.params["includeLayers"]?.boolValue, true)

        let global = CodexProtocol.readConfig(id: 23, workspaceURL: nil, includeLayers: false)
        XCTAssertEqual(global.params["cwd"], .null)
        XCTAssertEqual(global.params["includeLayers"]?.boolValue, false)
    }

    func testDecodeInitializeResponseFixture() throws {
        let fixture = Data(
            #"{"id":1,"result":{"userAgent":"Codex Desktop/0.147.0","codexHome":"/tmp/.codex","platformFamily":"unix","platformOs":"macos"}}"#.utf8
        )

        let message = try codec.decodeLine(fixture)

        XCTAssertEqual(message.id, .integer(1))
        XCTAssertEqual(message.result?["platformOs"]?.stringValue, "macos")
        XCTAssertNil(message.method)
    }

    func testDecodeStringServerRequestID() throws {
        let fixture = Data(
            #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1}}"#.utf8
        )

        let message = try codec.decodeLine(fixture)

        XCTAssertEqual(message.id, .string("approval-1"))
        XCTAssertEqual(message.method, "item/commandExecution/requestApproval")
    }

    func testAgentDeltaProjectsToCommonEventAndPreservesFixture() throws {
        let fixture = Data(
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"hello"}}"#.utf8
        )
        let message = try codec.decodeLine(fixture)
        let localSessionID = UUID()

        let envelope = try XCTUnwrap(
            CodexEventProjector().project(
                message,
                rawData: fixture,
                localSessionID: localSessionID,
                sequence: 3
            )
        )

        XCTAssertEqual(envelope.localSessionID, localSessionID)
        XCTAssertEqual(envelope.sequence, 3)
        XCTAssertEqual(envelope.payload, .assistantDelta("hello"))
        XCTAssertEqual(envelope.rawProviderEvent, fixture)
    }

    func testStartThreadFailsClosedInsteadOfBypassingPermissions() throws {
        let request = CodexProtocol.startThread(
            id: 2,
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        let data = try codec.encodeLine(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["permissions"] as? String, ":workspace")
        XCTAssertEqual(params["approvalsReviewer"] as? String, "user")
    }

    func testStartTurnEncodesSelectedCollaborationMode() throws {
        let preset = CodexCollaborationPreset(
            name: "Plan",
            mode: "plan",
            model: "gpt-5.6-codex",
            reasoningEffort: "high"
        )
        let request = CodexProtocol.startTurn(
            id: 8,
            threadID: "thread-1",
            prompt: "inspect",
            collaborationPreset: preset
        )

        XCTAssertEqual(request.params["collaborationMode"]?["mode"]?.stringValue, "plan")
        XCTAssertEqual(
            request.params["collaborationMode"]?["settings"]?["model"]?.stringValue,
            "gpt-5.6-codex"
        )
        XCTAssertEqual(
            request.params["collaborationMode"]?["settings"]?["reasoning_effort"]?.stringValue,
            "high"
        )
    }

    func testStructuredTurnInputAndSteerUseInstalledUserInputShapes() {
        let input: [CodexUserInput] = [
            .text("Inspect this context"),
            .localImage(URL(filePath: "/tmp/context.png"), detail: .high),
            .skill(name: "openai-docs", path: URL(filePath: "/tmp/skills/openai-docs/SKILL.md")),
            .mention(name: "src", path: URL(filePath: "/tmp/project/src"))
        ]
        let draft = CodexComposerDraft(inputs: input)
        XCTAssertEqual(draft.removingInput(at: 1).inputs, [input[0], input[2], input[3]])
        XCTAssertEqual(draft.removingInput(at: 99), draft)

        let start = CodexProtocol.startTurn(id: 10, threadID: "thread-1", input: input)
        XCTAssertEqual(start.method, "turn/start")
        let startInputs = start.params["input"]?.arrayValue ?? []
        XCTAssertEqual(startInputs.count, 4)
        XCTAssertEqual(startInputs[1]["type"]?.stringValue, "localImage")
        XCTAssertEqual(startInputs[1]["path"]?.stringValue, "/tmp/context.png")
        XCTAssertEqual(startInputs[1]["detail"]?.stringValue, "high")
        XCTAssertEqual(startInputs[2]["type"]?.stringValue, "skill")
        XCTAssertEqual(startInputs[3]["type"]?.stringValue, "mention")

        let steer = CodexProtocol.steerTurn(
            id: 11,
            threadID: "thread-1",
            expectedTurnID: "turn-1",
            input: [.text("Continue")]
        )
        XCTAssertEqual(steer.method, "turn/steer")
        XCTAssertEqual(steer.params["expectedTurnId"]?.stringValue, "turn-1")
        XCTAssertEqual(steer.params["input"]?.arrayValue?.first?["text"]?.stringValue, "Continue")
    }

    func testUnknownUserInputRoundTripsItsOriginalProviderEnvelope() throws {
        let raw: JSONValue = .object([
            "type": .string("futureInput"),
            "payload": .object([
                "source": .string("locked-runtime"),
                "items": .array([.string("keep-me")])
            ])
        ])
        let data = try JSONEncoder().encode(raw)
        let input = try JSONDecoder().decode(CodexUserInput.self, from: data)

        XCTAssertEqual(input, .unknown(raw))
        XCTAssertEqual(input.jsonValue, raw)

        let persisted = try JSONEncoder().encode(input)
        let restored = try JSONDecoder().decode(CodexUserInput.self, from: persisted)
        XCTAssertEqual(restored, input)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: persisted), raw)

        let suiteName = testDefaultsSuite("NativeHarnessClientTests.unknown-input")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let repository = UserDefaultsCodexQueueRepository(
            defaults: defaults,
            keyPrefix: "queue."
        )
        let sessionID = UUID()
        let queued = CodexQueuedSubmission(
            draft: CodexComposerDraft(inputs: [input])
        )
        repository.save([queued], for: sessionID)
        XCTAssertEqual(repository.load(for: sessionID), [queued])
    }

    func testTextElementsUseTheInstalledNestedByteRangeEnvelope() throws {
        let element = CodexTextElement(start: 4, end: 12, placeholder: "context")
        let input = CodexUserInput.text("Inspect", textElements: [element])
        let value = input.jsonValue

        XCTAssertEqual(
            value["text_elements"]?.arrayValue?.first?["byteRange"]?["start"]?.integerValue,
            4
        )
        XCTAssertEqual(
            value["text_elements"]?.arrayValue?.first?["byteRange"]?["end"]?.integerValue,
            12
        )
        XCTAssertEqual(
            value["text_elements"]?.arrayValue?.first?["placeholder"]?.stringValue,
            "context"
        )
        XCTAssertEqual(CodexUserInput.decode(value), input)

        let restored = try JSONDecoder().decode(
            CodexUserInput.self,
            from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(restored, input)
    }

    func testLocalAttachmentPickerMapsOnlySupportedNativeMedia() {
        let imageURL = URL(filePath: "/tmp/Context.HEIC")
        let audioURL = URL(filePath: "/tmp/voice.ogg")
        let unsupportedURL = URL(filePath: "/tmp/notes.pdf")

        XCTAssertEqual(CodexUserInput.localAttachmentKind(for: imageURL), .image)
        XCTAssertEqual(CodexUserInput.localAttachmentKind(for: audioURL), .audio)
        XCTAssertEqual(CodexUserInput.localAttachmentKind(for: unsupportedURL), .unsupported)
        XCTAssertEqual(
            CodexUserInput.localAttachment(for: imageURL),
            .localImage(imageURL.standardizedFileURL, detail: .auto)
        )
        XCTAssertEqual(
            CodexUserInput.localAttachment(for: audioURL),
            .localAudio(audioURL.standardizedFileURL)
        )
        XCTAssertNil(CodexUserInput.localAttachment(for: unsupportedURL))
    }

    func testLocalContextPickerProducesPathOnlyMentionEnvelopes() throws {
        let fileURL = URL(filePath: "/tmp/project/Sources/App.swift")
        let directoryURL = URL(filePath: "/tmp/project/Sources")
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/context"))

        XCTAssertEqual(
            CodexUserInput.localMention(for: fileURL),
            .mention(name: "App.swift", path: fileURL.standardizedFileURL)
        )
        XCTAssertEqual(
            CodexUserInput.localMention(for: directoryURL),
            .mention(name: "Sources", path: directoryURL.standardizedFileURL)
        )
        XCTAssertNil(CodexUserInput.localMention(for: remoteURL))
    }

    func testRemoteMediaPickerAcceptsOnlyCredentialFreeHTTPSURLs() throws {
        let image = try XCTUnwrap(
            CodexUserInput.remoteAttachment(
                for: "https://cdn.example.test/context.png?sig=redacted",
                kind: .image
            )
        )
        let audio = try XCTUnwrap(
            CodexUserInput.remoteAttachment(
                for: "https://cdn.example.test/voice.mp3",
                kind: .audio
            )
        )
        XCTAssertEqual(image, .image(
            URL(string: "https://cdn.example.test/context.png?sig=redacted")!,
            detail: .auto
        ))
        XCTAssertEqual(audio, .audio(URL(string: "https://cdn.example.test/voice.mp3")!))
        XCTAssertNil(CodexUserInput.remoteAttachment(for: "http://cdn.example.test/file.png", kind: .image))
        XCTAssertNil(CodexUserInput.remoteAttachment(for: "https://user:pass@cdn.example.test/file.png", kind: .image))
        XCTAssertNil(CodexUserInput.remoteAttachment(for: "/tmp/file.png", kind: .image))
    }

    func testCapabilityRequestsUseObservedAppServerMethodsAndWorkspace() {
        let workspace = URL(filePath: "/tmp/workspace")

        XCTAssertEqual(CodexProtocol.collaborationModes(id: 1).method, "collaborationMode/list")
        XCTAssertEqual(CodexProtocol.skills(id: 2, workspaceURL: workspace).method, "skills/list")
        XCTAssertEqual(
            CodexProtocol.skills(id: 2, workspaceURL: workspace).params["cwds"]?.arrayValue?.first?.stringValue,
            "/tmp/workspace"
        )
        XCTAssertEqual(CodexProtocol.plugins(id: 3, workspaceURL: workspace).method, "plugin/list")
        XCTAssertEqual(CodexProtocol.recentThreads(id: 4, workspaceURL: workspace).method, "thread/list")
        XCTAssertEqual(
            CodexProtocol.forkThread(id: 5, threadID: "thread-1", workspaceURL: workspace).method,
            "thread/fork"
        )
        XCTAssertEqual(CodexProtocol.reviewWorkingTree(id: 6, threadID: "thread-1").method, "review/start")
    }

    func testThreadActionRequestsUseObservedAppServerShapes() {
        let name = CodexProtocol.setThreadName(id: 7, threadID: "thread-1", name: "Renamed")
        XCTAssertEqual(name.method, "thread/name/set")
        XCTAssertEqual(name.params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(name.params["name"]?.stringValue, "Renamed")

        let archive = CodexProtocol.archiveThread(id: 8, threadID: "thread-1")
        XCTAssertEqual(archive.method, "thread/archive")
        XCTAssertEqual(archive.params["threadId"]?.stringValue, "thread-1")

        let delete = CodexProtocol.deleteThread(id: 9, threadID: "thread-1")
        XCTAssertEqual(delete.method, "thread/delete")
        XCTAssertEqual(delete.params["threadId"]?.stringValue, "thread-1")
    }

    func testThreadSearchRequestUsesInstalledSearchShape() {
        let request = CodexProtocol.searchThreads(
            id: 7,
            searchTerm: "approval",
            cursor: "next",
            limit: 12
        )

        XCTAssertEqual(request.method, "thread/search")
        XCTAssertEqual(request.params["archived"]?.boolValue, false)
        XCTAssertEqual(request.params["limit"]?.integerValue, 12)
        XCTAssertEqual(request.params["searchTerm"]?.stringValue, "approval")
        XCTAssertEqual(request.params["sortKey"]?.stringValue, "updated_at")
        XCTAssertEqual(request.params["cursor"]?.stringValue, "next")
    }

    func testThreadSearchOccurrencesRequestUsesLockedShape() {
        let request = CodexProtocol.searchOccurrences(
            id: 8,
            threadID: "thread-1",
            searchTerm: "approval",
            cursor: "turn-cursor",
            limit: 12
        )

        XCTAssertEqual(request.method, "thread/searchOccurrences")
        XCTAssertEqual(request.params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(request.params["searchTerm"]?.stringValue, "approval")
        XCTAssertEqual(request.params["cursor"]?.stringValue, "turn-cursor")
        XCTAssertEqual(request.params["limit"]?.integerValue, 12)
    }

    func testCapabilityProjectorMapsModesSkillsPluginsAndHistory() throws {
        let projector = CodexCapabilityProjector()
        let modes = projector.modes(from: .object([
            "data": .array([.object([
                "name": .string("Plan"),
                "mode": .string("plan"),
                "model": .string("gpt-5.6-codex"),
                "reasoning_effort": .string("high")
            ])])
        ]))
        XCTAssertEqual(modes.first?.mode, "plan")

        let skills = projector.skills(from: .object([
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
        ]))
        XCTAssertEqual(skills.first?.displayName, "OpenAI Docs")
        XCTAssertEqual(skills.first?.enabled, true)

        let plugins = projector.plugins(from: .object([
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
        ]))
        XCTAssertEqual(plugins.first?.id, "github")
        XCTAssertEqual(plugins.first?.installed, true)

        let threads = projector.threads(from: .object([
            "data": .array([.object([
                "id": .string("thread-1"),
                "cwd": .string("/tmp/workspace"),
                "updatedAt": .integer(1_700_000_000),
                "name": .string("Restore UI"),
                "preview": .string("preview")
            ])])
        ]))
        XCTAssertEqual(threads.first?.title, "Restore UI")
        XCTAssertEqual(threads.first?.workspaceURL.path, "/tmp/workspace")

        let page = projector.recentThreadsPage(from: .object([
            "data": .array([.object([
                "id": .string("thread-2"),
                "cwd": .string("/tmp/workspace"),
                "updatedAt": .integer(1_700_000_001),
                "preview": .string("next")
            ])]),
            "nextCursor": .string("recent-next")
        ]))
        XCTAssertEqual(page.threads.map(\.id), ["thread-2"])
        XCTAssertEqual(page.nextCursor, "recent-next")
    }

    func testCapabilityProjectorMapsHistoryOccurrencesAndUTF16Range() {
        let page = CodexCapabilityProjector().searchOccurrencesPage(from: .object([
            "data": .array([.object([
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "snippet": .string("Approval is required"),
                "snippetMatchRange": .object([
                    "start": .integer(0),
                    "end": .integer(8)
                ]),
                "turnCursor": .string("cursor-1")
            ])]),
            "nextCursor": .string("next")
        ]))

        XCTAssertEqual(page.occurrences.count, 1)
        XCTAssertEqual(page.occurrences.first?.turnID, "turn-1")
        XCTAssertEqual(page.occurrences.first?.itemID, "item-1")
        XCTAssertEqual(page.occurrences.first?.snippetMatchRange, CodexTextRange(start: 0, end: 8))
        XCTAssertEqual(page.nextCursor, "next")
    }

    func testCapabilityProjectorMapsNestedThreadSearchResultsAndCursor() {
        let projector = CodexCapabilityProjector()
        let page = projector.searchPage(from: .object([
            "data": .array([.object([
                "thread": .object([
                    "id": .string("thread-search"),
                    "cwd": .string("/tmp/workspace"),
                    "updatedAt": .integer(1_700_000_000),
                    "name": .string("Approval task"),
                    "preview": .string("Need approval")
                ]),
                "snippet": .string("approval required")
            ])]),
            "nextCursor": .string("cursor-2")
        ]))

        XCTAssertEqual(page.matches.count, 1)
        XCTAssertEqual(page.matches.first?.thread.id, "thread-search")
        XCTAssertEqual(page.matches.first?.snippet, "approval required")
        XCTAssertEqual(page.nextCursor, "cursor-2")
    }

    func testPlanUpdateProjectsStatusAndExplanation() throws {
        let fixture = Data(
            #"{"method":"turn/plan/updated","params":{"threadId":"thread-1","turnId":"turn-1","explanation":"Focused slice","plan":[{"step":"Inspect schema","status":"completed"},{"step":"Wire UI","status":"inProgress"},{"step":"Verify","status":"pending"}]}}"#.utf8
        )
        let message = try codec.decodeLine(fixture)
        let envelope = try XCTUnwrap(
            CodexEventProjector().project(
                message,
                rawData: fixture,
                localSessionID: UUID(),
                sequence: 4
            )
        )

        XCTAssertEqual(
            envelope.payload,
            .planUpdated("Focused slice\n\n[x] Inspect schema\n[~] Wire UI\n[ ] Verify")
        )
        XCTAssertEqual(envelope.rawProviderEvent, fixture)
    }

    func testActivityProjectorKeepsUsefulCodexItemIdentityAndDetail() {
        let command = CodexActivityProjector().project(.object([
            "id": .string("item-command"),
            "type": .string("commandExecution"),
            "command": .string("swift test")
        ]))
        XCTAssertEqual(command, HarnessActivity(
            id: "item-command",
            kind: "commandExecution",
            title: "Run command",
            detail: "swift test"
        ))

        let subagent = CodexActivityProjector().project(.object([
            "id": .string("item-agent"),
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawn_agent"),
            "prompt": .string("Review the adapter")
        ]))
        XCTAssertEqual(subagent?.kind, "collabAgentToolCall")
        XCTAssertEqual(subagent?.title, "spawn_agent")
        XCTAssertEqual(subagent?.detail, "Review the adapter")

        XCTAssertNil(CodexActivityProjector().project(.object([
            "id": .string("message"),
            "type": .string("agentMessage")
        ])))
    }
}
