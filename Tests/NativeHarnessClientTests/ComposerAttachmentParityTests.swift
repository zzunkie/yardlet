import Foundation
import XCTest
@testable import NativeHarnessClient

/// The composer's `+` and `@` follow the protocol, not the harness name. These
/// pin the wire shape each harness receives, the ACP negotiation, and what happens on a harness
/// that cannot carry an attachment at all.
final class ComposerAttachmentParityTests: XCTestCase {
    private func makeImage(_ name: String, bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-attachment-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeExecutable(_ name: String, version: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: name)
        try Data("#!/bin/sh\necho '\(version)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return url
    }

    // MARK: - Neutral input

    func testMentionsBecomePathLinesAndUnsupportedInputsAreReportedNotDropped() throws {
        let image = try makeImage("shot.png")
        let audio = URL(filePath: "/tmp/note.wav")
        let draft = CodexComposerDraft(inputs: [
            .text("look here"),
            .localImage(image, detail: .auto),
            .mention(name: "Package.swift", path: URL(filePath: "/repo/Package.swift")),
            .localAudio(audio),
            .skill(name: "review", path: URL(filePath: "/repo/.codex/skills/review"))
        ])

        let projection = HarnessUserInput.projecting(draft)

        XCTAssertEqual(projection.input.text, "look here")
        XCTAssertEqual(projection.input.images.map(\.mimeType), ["image/png"])
        XCTAssertEqual(projection.input.promptText, "look here\n@/repo/Package.swift")
        XCTAssertFalse(projection.carriesEverything)
        XCTAssertEqual(projection.unsupported, [
            .localAudio(audio.standardizedFileURL),
            .skill(name: "review", path: URL(filePath: "/repo/.codex/skills/review"))
        ])
    }

    func testTextOnlyInputProjectsToTheSamePromptTheTextSendAlwaysUsed() {
        let input = HarnessUserInput(text: "  hello  ")
        XCTAssertEqual(input.promptText, "hello")
        XCTAssertEqual(input.transcriptImages, [])
        XCTAssertFalse(input.hasAttachments)
    }

    // MARK: - Wire shapes

    func testTextOnlySubmissionsKeepEachHarnessWireShape() {
        let claude = ClaudeProtocol.userMessage(text: "hello", images: [], sessionID: "session-1")
        XCTAssertEqual(claude, ClaudeProtocol.userMessage("hello", sessionID: "session-1"))
        XCTAssertEqual(claude["message"]?["content"]?.stringValue, "hello")

        let acp = ACPProtocol.prompt(
            id: 1,
            providerSessionID: "acp-1",
            text: "hello",
            images: []
        )
        XCTAssertEqual(acp, ACPProtocol.prompt(id: 1, providerSessionID: "acp-1", text: "hello"))
        let acpBlocks = acp["params"]?["prompt"]?.arrayValue ?? []
        XCTAssertEqual(acpBlocks.count, 1)
        XCTAssertEqual(acpBlocks.first?["type"]?.stringValue, "text")

        let pi = PiRPCProtocol.prompt(id: "prompt-1", text: "hello", images: [])
        XCTAssertEqual(pi, PiRPCProtocol.prompt(id: "prompt-1", text: "hello"))
        XCTAssertNil(pi["images"])
    }

    func testClaudeSendsABase64ImageBlockBesideTheTextBlock() async throws {
        let image = try makeImage("shot.png")
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )

        try await adapter.send(
            HarnessUserInput(
                text: "describe this",
                images: [HarnessUserInput.ImageAttachment(url: image, mimeType: "image/png")],
                mentions: [URL(filePath: "/repo/README.md")]
            ),
            to: handle
        )

        let sent = await transport.sentValues
        let message = try XCTUnwrap(sent.last)
        let content = try XCTUnwrap(message["message"]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.first?["type"]?.stringValue, "text")
        XCTAssertEqual(content.first?["text"]?.stringValue, "describe this\n@/repo/README.md")
        XCTAssertEqual(content.last?["type"]?.stringValue, "image")
        XCTAssertEqual(content.last?["source"]?["type"]?.stringValue, "base64")
        XCTAssertEqual(content.last?["source"]?["media_type"]?.stringValue, "image/png")
        XCTAssertEqual(
            content.last?["source"]?["data"]?.stringValue,
            try Data(contentsOf: image).base64EncodedString()
        )
        await adapter.close(handle)
    }

    func testACPSendsAnImageBlockOnlyWhenTheAgentAdvertisedPromptImages() async throws {
        let image = try makeImage("diagram.jpg", bytes: [0xFF, 0xD8, 0xFF])
        let advertising = FakeACPTransport(advertisesImagePrompts: true)
        let advertisingAdapter = ACPAdapter(
            kind: .grokBuild,
            executableURL: try makeExecutable("grok", version: "grok 1.0.30"),
            transport: advertising
        )
        let advertisingHandle = try await advertisingAdapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        let attachment = HarnessUserInput(
            text: "review",
            images: [HarnessUserInput.ImageAttachment(url: image, mimeType: "image/jpeg")]
        )

        try await advertisingAdapter.send(attachment, to: advertisingHandle)
        try await waitUntil { await advertising.requestMethods.contains("session/prompt") }
        let advertisingRequests = await advertising.requestValues
        let prompt = try XCTUnwrap(
            advertisingRequests.last { $0["method"]?.stringValue == "session/prompt" }
        )
        let blocks = try XCTUnwrap(prompt["params"]?["prompt"]?.arrayValue)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?["text"]?.stringValue, "review")
        XCTAssertEqual(blocks.last?["type"]?.stringValue, "image")
        XCTAssertEqual(blocks.last?["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertEqual(
            blocks.last?["data"]?.stringValue,
            try Data(contentsOf: image).base64EncodedString()
        )
        // The negotiated answer, not the family default, is what the probe reports afterwards.
        let advertisedRuntime = try await advertisingAdapter.probeRuntime()
        XCTAssertTrue(advertisedRuntime.capabilities.acceptsImages)

        let silent = FakeACPTransport()
        let silentAdapter = ACPAdapter(
            kind: .kimiCode,
            executableURL: URL(filePath: "/tmp/fake-kimi"),
            transport: silent
        )
        let silentHandle = try await silentAdapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        do {
            try await silentAdapter.send(attachment, to: silentHandle)
            XCTFail("Expected an agent without promptCapabilities.image to refuse the attachment")
        } catch let error as HarnessAdapterError {
            guard case let .capabilityUnavailable(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Kimi Code"))
        }
        let silentMethods = await silent.requestMethods
        XCTAssertFalse(silentMethods.contains("session/prompt"))

        await advertisingAdapter.close(advertisingHandle)
        await silentAdapter.close(silentHandle)
    }

    func testPiSendsImagesBesideTheMessage() async throws {
        let image = try makeImage("shot.png")
        let sessionFile = "/tmp/pi-sessions/\(UUID().uuidString).jsonl"
        let transport = FakePiRPCTransport(sessionFile: sessionFile)
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/pi-workspace"),
                initialPrompt: nil
            )
        )

        try await adapter.send(
            HarnessUserInput(
                text: "look",
                images: [HarnessUserInput.ImageAttachment(url: image, mimeType: "image/png")]
            ),
            to: handle
        )
        try await waitUntil { await transport.requestTypes.contains("prompt") }

        let piRequests = await transport.requestValues
        let prompt = try XCTUnwrap(
            piRequests.last { $0["type"]?.stringValue == "prompt" }
        )
        XCTAssertEqual(prompt["message"]?.stringValue, "look")
        let images = try XCTUnwrap(prompt["images"]?.arrayValue)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?["type"]?.stringValue, "image")
        XCTAssertEqual(images.first?["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(
            images.first?["data"]?.stringValue,
            try Data(contentsOf: image).base64EncodedString()
        )
        await adapter.close(handle)
    }

    // MARK: - Harnesses that cannot carry an attachment

    func testAHarnessWithoutImageInputRefusesTheAttachmentInsteadOfSendingTextOnly() async throws {
        let adapter = TextOnlyStubAdapter(kind: .cursorAgent)
        let handle = HarnessSessionHandle(
            harness: .cursorAgent,
            localSessionID: UUID(),
            providerSessionID: "cursor-1",
            workspaceURL: URL(filePath: "/tmp/workspace")
        )

        do {
            try await adapter.send(
                HarnessUserInput(
                    text: "look",
                    images: [
                        HarnessUserInput.ImageAttachment(
                            url: URL(filePath: "/tmp/shot.png"),
                            mimeType: "image/png"
                        )
                    ]
                ),
                to: handle
            )
            XCTFail("Expected a harness without image input to refuse the attachment")
        } catch let error as HarnessAdapterError {
            guard case let .capabilityUnavailable(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Cursor"))
        }
        let sent = await adapter.sentPrompts
        XCTAssertTrue(sent.isEmpty)

        // Text-only input on the same adapter is the send it always was.
        try await adapter.send(HarnessUserInput(text: "hello"), to: handle)
        let afterText = await adapter.sentPrompts
        XCTAssertEqual(afterText, ["hello"])
    }

    // MARK: - Protocol boundary

    func testYHPCarriesAnAttachmentToTheLegacyAdapterAndWithholdsImagesWhenTheRuntimeDoesNot()
        async throws {
        let carrying = RecordingImageAdapter(kind: .pi, acceptsImages: true)
        let adapter = YHPCompatibilityAdapter(
            adapter: carrying,
            manifest: HarnessProtocolCompatibilityManifest.piRPC(.pi)
        )
        let localID = UUID()
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localID,
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        try await adapter.send(
            HarnessUserInput(
                text: "look",
                images: [
                    HarnessUserInput.ImageAttachment(
                        url: URL(filePath: "/tmp/shot.png"),
                        mimeType: "image/png"
                    )
                ],
                mentions: [URL(filePath: "/repo/README.md")]
            ),
            to: handle
        )

        let carriedInputs = await carrying.sentInputs
        let received = try XCTUnwrap(carriedInputs.last)
        XCTAssertEqual(received.text, "look\n@/repo/README.md")
        XCTAssertEqual(received.images.map(\.mimeType), ["image/png"])
        XCTAssertEqual(
            received.images.map { $0.url.path(percentEncoded: false) },
            ["/tmp/shot.png"]
        )
        let carryingRuntime = try await adapter.probeRuntime()
        XCTAssertTrue(carryingRuntime.capabilities.acceptsImages)

        // The manifest says the family can carry an image; the wrapped runtime says whether this
        // agent does. A silent agent must not be reported as image-capable.
        let silent = RecordingImageAdapter(kind: .kimiCode, acceptsImages: false)
        let silentAdapter = YHPCompatibilityAdapter(
            adapter: silent,
            manifest: HarnessProtocolCompatibilityManifest.acp(.kimiCode)
        )
        let silentRuntime = try await silentAdapter.probeRuntime()
        XCTAssertFalse(silentRuntime.capabilities.acceptsImages)
    }

    // MARK: - Composer gate

    func testComposerAttachmentControlsFollowTheProtocolNotTheHarnessName() {
        for harness in [HarnessKind.codex, .claudeCode, .pi, .museCode] {
            XCTAssertEqual(
                HarnessComposerInputPolicy(harness: harness).imageSupport,
                .always,
                "\(harness) carries image input"
            )
            XCTAssertTrue(HarnessComposerInputPolicy(harness: harness).showsAttachmentControl)
            XCTAssertTrue(HarnessComposerInputPolicy(harness: harness).showsMentionControl)
        }
        for harness in [HarnessKind.grokBuild, .openCode, .antigravityCLI, .kimiCode, .hermes] {
            XCTAssertEqual(
                HarnessComposerInputPolicy(harness: harness).imageSupport,
                .negotiated,
                "\(harness) negotiates image input with its agent"
            )
            // Before the agent answers, the control stays: the answer is the agent's to give.
            XCTAssertTrue(HarnessComposerInputPolicy(harness: harness).showsAttachmentControl)
            XCTAssertTrue(HarnessComposerInputPolicy(harness: harness).showsMentionControl)
        }
        for harness in [HarnessKind.cursorAgent] {
            let policy = HarnessComposerInputPolicy(harness: harness)
            XCTAssertEqual(policy.imageSupport, .unavailable, "\(harness) has no image input")
            XCTAssertFalse(policy.showsAttachmentControl)
            XCTAssertFalse(policy.showsMentionControl)
        }
        // Only Codex has an audio envelope, so only its picker may return one.
        XCTAssertTrue(HarnessComposerInputPolicy(harness: .codex).acceptsAudioAttachments)
        XCTAssertFalse(HarnessComposerInputPolicy(harness: .claudeCode).acceptsAudioAttachments)
    }

    func testTheNegotiatedImageAnswerReachesTheSessionCapabilityStateAndDecidesThePlusButton()
        async throws {
        // Before the agent answers, the control stays and `@` stays with it.
        let unasked = HarnessComposerInputPolicy(harness: .kimiCode, negotiatedImageInput: nil)
        XCTAssertTrue(unasked.showsAttachmentControl)
        XCTAssertTrue(unasked.showsMentionControl)

        let silent = FakeACPTransport()
        let silentAdapter = ACPAdapter(
            kind: .kimiCode,
            executableURL: URL(filePath: "/tmp/fake-kimi"),
            transport: silent
        )
        let silentHandle = try await silentAdapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        let silentState = try await silentAdapter.providerCapabilities(for: silentHandle)
        XCTAssertEqual(silentState.acceptsImageInput, false)

        let refusing = HarnessComposerInputPolicy(
            harness: .kimiCode,
            negotiatedImageInput: silentState.acceptsImageInput
        )
        XCTAssertFalse(refusing.showsAttachmentControl, "A settled no takes `+` away")
        XCTAssertTrue(
            refusing.showsMentionControl,
            "A mention travels as a path line, so a settled no does not take `@`"
        )

        // An attachment the composer still holds is reported, never quietly dropped.
        let image = try makeImage("shot.png")
        let draft = CodexComposerDraft(inputs: [.text("ship it"), .localImage(image, detail: .auto)])
        guard case let .refuse(notice) = refusing.submission(for: draft) else {
            return XCTFail("Expected an agent that declined images to refuse the attachment")
        }
        XCTAssertEqual(notice, refusing.attachmentRefusalNotice)

        let advertising = FakeACPTransport(advertisesImagePrompts: true)
        let advertisingAdapter = ACPAdapter(
            kind: .kimiCode,
            executableURL: URL(filePath: "/tmp/fake-kimi"),
            transport: advertising
        )
        let advertisingHandle = try await advertisingAdapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        let advertisingState = try await advertisingAdapter.providerCapabilities(
            for: advertisingHandle
        )
        XCTAssertEqual(advertisingState.acceptsImageInput, true)
        let carrying = HarnessComposerInputPolicy(
            harness: .kimiCode,
            negotiatedImageInput: advertisingState.acceptsImageInput
        )
        XCTAssertTrue(carrying.showsAttachmentControl)
        guard case .send = carrying.submission(for: draft) else {
            return XCTFail("Expected an agent that advertised images to carry the attachment")
        }

        // A family that carries images by transport ignores a negotiated answer entirely.
        XCTAssertTrue(
            HarnessComposerInputPolicy(harness: .claudeCode, negotiatedImageInput: false)
                .showsAttachmentControl
        )

        await silentAdapter.close(silentHandle)
        await advertisingAdapter.close(advertisingHandle)
    }

    func testTheACPRouteTheAppShipsCarriesTheNegotiatedImageAnswerAcrossYHP() async throws {
        let transport = FakeACPTransport()
        let routed: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(
                kind: .kimiCode,
                executableURL: URL(filePath: "/tmp/fake-kimi"),
                transport: transport
            ),
            manifest: HarnessProtocolCompatibilityManifest.acp(.kimiCode)
        )
        let localSessionID = UUID()
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )

        let reporting = try XCTUnwrap(routed as? any HarnessImageInputReporting)
        let answer = await reporting.acceptsImageInput(for: localSessionID)
        XCTAssertEqual(answer, false, "The wrapper must not swallow the agent's own answer")

        let provider = try XCTUnwrap(routed as? any ProviderCapabilityProviding)
        let state = try await provider.providerCapabilities(for: handle)
        XCTAssertEqual(
            state.acceptsImageInput,
            false,
            "The YHP option catalog is rebuilt, so the answer has to be laid back on"
        )
        await routed.close(handle)
    }

    func testARestoredAttachmentOnAHarnessWithoutImageInputIsReportedNotDropped() throws {
        let image = try makeImage("shot.png")
        let draft = CodexComposerDraft(inputs: [
            .text("ship it"),
            .localImage(image, detail: .auto)
        ])

        let refused = HarnessComposerInputPolicy(harness: .cursorAgent).submission(for: draft)
        guard case let .refuse(notice) = refused else {
            return XCTFail("Expected Cursor Agent to refuse a restored image attachment")
        }
        XCTAssertEqual(
            notice,
            L10n.format(
                "%@ cannot send this attachment. Remove it to send the message.",
                HarnessKind.cursorAgent.displayName
            )
        )

        // The same draft is a normal turn on a harness whose protocol carries the image.
        guard case let .send(input) = HarnessComposerInputPolicy(harness: .claudeCode)
            .submission(for: draft) else {
            return XCTFail("Expected Claude Code to carry the image attachment")
        }
        XCTAssertEqual(input.text, "ship it")
        XCTAssertEqual(input.images.map(\.mimeType), ["image/png"])

        // Text alone still sends on a harness that has no attachment surface at all.
        guard case let .send(textOnly) = HarnessComposerInputPolicy(harness: .cursorAgent)
            .submission(for: CodexComposerDraft(inputs: [.text("ship it")])) else {
            return XCTFail("Expected a text-only draft to send everywhere")
        }
        XCTAssertEqual(textOnly.promptText, "ship it")

        // A mention is preserved as a path line rather than refused.
        guard case let .send(mentioned) = HarnessComposerInputPolicy(harness: .cursorAgent)
            .submission(for: CodexComposerDraft(inputs: [
                .text("ship it"),
                .mention(name: "README.md", path: URL(filePath: "/repo/README.md"))
            ])) else {
            return XCTFail("Expected a mention to travel as text")
        }
        XCTAssertEqual(mentioned.promptText, "ship it\n@/repo/README.md")
    }
}

/// An adapter that never overrode the neutral send, so it exercises the default projection.
private actor TextOnlyStubAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind
    private(set) var sentPrompts: [String] = []

    init(kind: HarnessKind) { self.kind = kind }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(filePath: "/tmp/stub"),
            version: "stub",
            capabilities: .unavailable,
            fingerprint: "stub"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "stub-session",
            workspaceURL: request.workspaceURL
        )
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: workspaceURL
        )
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        sentPrompts.append(prompt)
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {}

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func close(_ session: HarnessSessionHandle) async {}
}

/// An adapter whose protocol carries attachments, used to observe what crosses YHP.
private actor RecordingImageAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind
    private let acceptsImages: Bool
    private var continuations: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
    private(set) var sentPrompts: [String] = []
    private(set) var sentInputs: [HarnessUserInput] = []

    init(kind: HarnessKind, acceptsImages: Bool) {
        self.kind = kind
        self.acceptsImages = acceptsImages
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(filePath: "/tmp/stub"),
            version: "stub",
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: true,
                acceptsImages: acceptsImages,
                hasSubagents: false
            ),
            fingerprint: "stub"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "stub-session",
            workspaceURL: request.workspaceURL
        )
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: workspaceURL
        )
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        sentPrompts.append(prompt)
    }

    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        sentInputs.append(input)
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {}

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let pair = AsyncStream<HarnessEventEnvelope>.makeStream()
        continuations[session.localSessionID] = pair.continuation
        return pair.stream
    }

    func close(_ session: HarnessSessionHandle) async {
        continuations.removeValue(forKey: session.localSessionID)?.finish()
    }
}
