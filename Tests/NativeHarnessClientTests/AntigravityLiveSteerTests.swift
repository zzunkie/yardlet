import Foundation
import XCTest
@testable import NativeHarnessClient

/// "Steer Antigravity turns": the plugin Yardlet adds and removes, its hook as `agy` runs it, and the
/// adapter's account of what the running turn read, as `agy acp` 1.5.17 reports an injected message.
final class AntigravityLiveSteerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "agy-live-steer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func plugin(enabled: Bool = true) -> AntigravityLiveSteer {
        AntigravityLiveSteer(folder: root.appending(path: AntigravityLiveSteer.pluginName, directoryHint: .isDirectory),
                             isEnabled: { enabled })
    }

#if !os(Windows)
    /// Runs the hook as Antigravity does: `sh -c` in the plugin folder, the payload on stdin.
    private func runHook(_ plugin: AntigravityLiveSteer, conversationID: String, rawByte: UInt8? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "./deliver.sh"]
        process.currentDirectoryURL = plugin.folder
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let payload = #"{"artifactDirectoryPath":"/tmp/brain","conversationId":"\#(conversationID)","hookEventName":"PreInvocation","#
            + #""invocationNum":1,"lastUserInput":"say \"conversationId\":\"other\"","workspacePaths":["/tmp/p"]}"#
        var bytes = Data(payload.utf8)
        // A byte that is not UTF-8, inside the user's input, as a terminal may pass on.
        if let rawByte, let at = bytes.range(of: Data("say".utf8)) { bytes.insert(rawByte, at: at.upperBound) }
        input.fileHandleForWriting.write(bytes)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The setting adds the plugin and removes it again, touching nothing else in the plugins folder;
    /// the hook answers `{}` unless Yardlet left a message for that conversation, which it hands over once.
    func testThePluginComesAndGoesWithTheSettingAndItsHookHandsOverAMessageOnce() throws {
        let other = root.appending(path: "someone-elses", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(#"{"name":"someone-elses"}"#.utf8).write(to: other.appending(path: "plugin.json"))

        let steer = plugin()
        try steer.reconcile()
        XCTAssertTrue(steer.isInstalled)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: steer.folder.appending(path: "deliver.sh").path(percentEncoded: false)))
        let hooks = try JSONSerialization.jsonObject(with: Data(contentsOf: steer.folder.appending(path: "hooks.json"))) as? [String: Any]
        XCTAssertNotNil((hooks?[AntigravityLiveSteer.pluginName] as? [String: Any])?["PreInvocation"])

        // The folder, its messages and its script are the person's alone.
        let id = "aa300aa2-9d6f-49bf-bce6-9d47606aeb41"
        XCTAssertEqual(try permissions(steer.folder), 0o700)
        XCTAssertEqual(try permissions(steer.folder.appending(path: "pending")), 0o700)
        XCTAssertEqual(try permissions(steer.folder.appending(path: "deliver.sh")), 0o700)
        XCTAssertEqual(try runHook(steer, conversationID: id), "{}")
        try steer.leave(["Also check the README", "Then say \"done\""], for: id)
        XCTAssertEqual(try permissions(steer.folder.appending(path: "pending/\(id).json")), 0o600)
        XCTAssertEqual(try runHook(steer, conversationID: "ff627fb7-d5e2-49b7-bb93-b0da137b79fd"), "{}")
        let handed = try runHook(steer, conversationID: id)
        let steps = (try JSONSerialization.jsonObject(with: Data(handed.utf8)) as? [String: Any])?["injectSteps"] as? [[String: String]]
        XCTAssertEqual(steps?.compactMap { $0["userMessage"] }, ["Also check the README", "Then say \"done\""])
        XCTAssertEqual(try runHook(steer, conversationID: id), "{}")
        XCTAssertNil(steer.takeBack(for: id), "the hook took the file")

        try steer.leave(["Stop after this"], for: id)
        XCTAssertEqual(steer.takeBack(for: id), ["Stop after this"])
        XCTAssertEqual(try runHook(steer, conversationID: id), "{}")
        try steer.leave(["Despite the byte"], for: id)
        XCTAssertTrue(try runHook(steer, conversationID: id, rawByte: 0xFF).contains("Despite the byte"))

        try plugin(enabled: false).reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: steer.folder.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appending(path: "plugin.json").path(percentEncoded: false)))

        // A folder of that name that is not Yardlet's stays, and nothing is written into it.
        try FileManager.default.createDirectory(at: steer.folder, withIntermediateDirectories: true)
        let foreign = Data(#"{"name":"\#(AntigravityLiveSteer.pluginName)"}"#.utf8)
        try foreign.write(to: steer.folder.appending(path: "plugin.json"))
        XCTAssertFalse(steer.isInstalled, "a manifest Yardlet did not write")
        XCTAssertThrowsError(try steer.install())
        XCTAssertThrowsError(try steer.leave(["Nope"], for: id))
        try plugin(enabled: false).reconcile()
        XCTAssertEqual(try Data(contentsOf: steer.folder.appending(path: "plugin.json")), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: steer.folder.appending(path: "hooks.json").path(percentEncoded: false)))

        // Nor is a link in its place followed, even to a copy of Yardlet's plugin.
        try FileManager.default.removeItem(at: steer.folder)
        let elsewhere = AntigravityLiveSteer(folder: other.appending(path: AntigravityLiveSteer.pluginName, directoryHint: .isDirectory),
                                             isEnabled: { true })
        try elsewhere.install()
        try FileManager.default.createSymbolicLink(at: steer.folder, withDestinationURL: elsewhere.folder)
        XCTAssertFalse(steer.isInstalled)
        XCTAssertThrowsError(try steer.install())
        try plugin(enabled: false).reconcile()
        XCTAssertTrue(elsewhere.isInstalled, "the link's target is left alone")
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
    }
#endif

    /// A message left for the running prompt is read where its `user_message_chunk` comes, once; one the
    /// hook never took goes back when the prompt ends, before the turn does, and one taken back is not
    /// read. Outside a prompt nothing is left: the message waits for the turn's end.
    func testWhatTheRunningTurnReadsJoinsItAndWhatItDidNotGoesBackBeforeItEnds() async throws {
        let steer = plugin()
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = ACPAdapter(kind: .antigravityCLI, executableURL: URL(filePath: "/tmp/agy"), launchArguments: ["acp"],
                                 liveSteer: steer, transportFactory: { transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
        let conversation = handle.providerSessionID
        let log = SteerPayloadLog()
        let collector = Task { for await event in await adapter.events(for: handle) { await log.append(event.payload) } }
        defer { collector.cancel() }

        do {
            try await adapter.sendFollowUp(HarnessUserInput(text: "Too early"), messageID: "m0", priority: .next, to: handle)
            XCTFail("A message was left with no prompt running")
        } catch is HarnessFollowUpNotNow {}

        try await adapter.send("Run the tests", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        try await adapter.sendFollowUp(HarnessUserInput(text: "Use Python instead"), messageID: "m1", priority: .next, to: handle)
        try await adapter.sendFollowUp(HarnessUserInput(text: "Skip the slow ones"), messageID: "m2", priority: .next, to: handle)
        let withdrawn = try await adapter.cancelFollowUp(messageID: "m2", in: handle)
        XCTAssertTrue(withdrawn)

        // The hook hands the file to the agent, which reports the message in two chunks.
        XCTAssertEqual(steer.takeBack(for: conversation), ["Use Python instead"])
        let cannotWithdraw = try await adapter.cancelFollowUp(messageID: "m1", in: handle)
        XCTAssertFalse(cannotWithdraw)
        for part in ["Use Python ", "instead"] {
            await transport.emit(userChunk(part, conversation: conversation))
        }
        let read = HarnessEventPayload.followUpDelivery(.init(messageID: "m1", state: .read, joinsRunningTurn: true))
        try await waitUntil { await log.payloads.contains(read) }
        let afterRead = try await adapter.cancelFollowUp(messageID: "m1", in: handle)
        XCTAssertFalse(afterRead, "read on the stream before the app heard of it")

        try await adapter.sendFollowUp(HarnessUserInput(text: "Then update the README"), messageID: "m3", priority: .next, to: handle)
        await transport.completePrompt()
        try await waitUntil { await log.payloads.contains(.turnCompleted) }
        let payloads = await log.payloads
        let returned = try XCTUnwrap(payloads.firstIndex(of: .followUpDelivery(.init(messageID: "m3", state: .returned))))
        XCTAssertLessThan(returned, try XCTUnwrap(payloads.firstIndex(of: .turnCompleted)))
        XCTAssertEqual(payloads.filter { if case .followUpDelivery = $0 { true } else { false } }.count, 2)
        XCTAssertNil(steer.takeBack(for: conversation), "nothing is left for the next turn")
    }

    /// A write that fails after the hook took the file puts back nothing the agent already has.
    func testAFailedWriteAfterTheHookTookTheFileLeavesNothingToReadTwice() async throws {
        let steer = plugin()
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = ACPAdapter(kind: .antigravityCLI, executableURL: URL(filePath: "/tmp/agy"), launchArguments: ["acp"],
                                 liveSteer: steer, transportFactory: { transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
        let log = SteerPayloadLog()
        let collector = Task { for await event in await adapter.events(for: handle) { await log.append(event.payload) } }
        defer { collector.cancel() }
        try await adapter.send("Run the tests", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        try await adapter.sendFollowUp(HarnessUserInput(text: "Use Python instead"), messageID: "m1", priority: .next, to: handle)
        XCTAssertEqual(steer.takeBack(for: handle.providerSessionID), ["Use Python instead"], "the hook takes it")

        // The folder stops being Yardlet's, so the next write fails.
        try Data(#"{"name":"\#(AntigravityLiveSteer.pluginName)"}"#.utf8).write(to: steer.folder.appending(path: "plugin.json"))
        do {
            try await adapter.sendFollowUp(HarnessUserInput(text: "Skip the slow ones"), messageID: "m2", priority: .next, to: handle)
            XCTFail("The write went through")
        } catch is HarnessFollowUpNotNow {
            XCTFail("A failed write is a failure, not a wait")
        } catch {}
        XCTAssertNil(steer.takeBack(for: handle.providerSessionID), "m1 is not left again")

        await transport.completePrompt()
        try await waitUntil { await log.payloads.contains(.turnCompleted) }
        let deliveries = await log.payloads.filter { if case .followUpDelivery = $0 { true } else { false } }
        XCTAssertEqual(deliveries, [.followUpDelivery(.init(messageID: "m1", state: .read, joinsRunningTurn: true))])
    }

    /// The agent reads messages in the order they were left: text that begins the first and equals a later
    /// one waits to be ruled out before it counts as the later one.
    func testChunksAreMatchedToTheMessagesInTheOrderTheyWereLeft() {
        var ledger = AntigravitySteerLedger()
        ledger.add(.init(messageID: "m1", text: "foo bar"))
        ledger.add(.init(messageID: "m2", text: "foo"))
        XCTAssertNil(ledger.read(chunk: "foo"))
        XCTAssertEqual(ledger.read(chunk: " bar"), "m1")
        XCTAssertEqual(ledger.read(chunk: "foo"), "m2")
        XCTAssertTrue(ledger.wasRead("m1") && ledger.wasRead("m2"))
        XCTAssertNil(ledger.read(chunk: "Another hook's words"))
    }

    /// The composer offers steering on an Antigravity task only while the setting is on.
    @MainActor
    func testTheComposerSteersAnAntigravityTaskOnlyWhileTheSettingIsOn() {
        for (on, policy) in [(true, FollowUpPolicy.antigravity), (false, .afterTurn)] {
            let options = ComposerSessionOptionsProjection.make(harness: .antigravityCLI, session: nil, providerCapabilities: nil,
                                                                providerUsage: nil, isAttached: true, antigravitySteers: on)
            XCTAssertEqual(options.followUp?.policy, policy)
        }
        let claude = ComposerSessionOptionsProjection.make(harness: .claudeCode, session: nil, providerCapabilities: nil,
                                                           providerUsage: nil, isAttached: true, antigravitySteers: true)
        XCTAssertEqual(claude.followUp?.policy, .claudeCode)
        XCTAssertEqual(FollowUpPolicy.antigravity.heldStatus, L10n.string("Delivered · Antigravity reads it at its next step"))
    }

    /// An app with "Steer Antigravity turns" on, whose Antigravity task's first prompt is running.
    @MainActor
    private func runningApp() async throws -> (AppModel, SessionRecord, FakeACPTransport, AntigravityLiveSteer, String) {
        UserDefaults.yardlet.set(true, forKey: AntigravityLiveSteer.preferenceKey)
        addTeardownBlock { UserDefaults.yardlet.removeObject(forKey: AntigravityLiveSteer.preferenceKey) }
        let steer = plugin()
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = ACPAdapter(kind: .antigravityCLI, executableURL: URL(filePath: "/usr/bin/true"), launchArguments: ["acp"],
                                 liveSteer: steer, transportFactory: { transport })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("AntigravityLiveSteer")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .antigravityCLI, workspaceURL: root,
                                                runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Steer")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")

        await model.send(HarnessUserInput(text: "Build the site"), to: task)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        try await waitUntil { model.store.sessions.first?.status == .running }
        let conversation = try XCTUnwrap(model.store.sessions.first?.providerSessionID)
        return (model, task, transport, steer, conversation)
    }

    /// A message that cannot join the running turn now (one with an image) waits where it was sent, behind
    /// what was queued before it.
    @MainActor
    func testAMessageThatCannotJoinTheTurnNowKeepsItsPlaceInTheQueue() async throws {
        let (model, task, _, steer, conversation) = try await runningApp()
        await model.submitFollowUp(HarnessUserInput(text: "Queued for later"), action: .queue, to: task)
        let image = HarnessUserInput(text: "Like this", images: [.init(url: root.appending(path: "shot.png"), mimeType: "image/png")])
        await model.submitFollowUp(image, action: .steer, to: task)
        let queue = model.followUps.queue(for: task.id)
        XCTAssertEqual(queue.map(\.draft.text), ["Queued for later", "Like this"])
        XCTAssertEqual(queue.map(\.state), [.pending, .pending])
        XCTAssertNil(steer.takeBack(for: conversation), "nothing was left for the hook")
    }

    /// In the app: a message the hook handed over shows once, inside the turn that read it, and one the
    /// turn ended without reading starts the next turn, also shown once.
    @MainActor
    func testTheAppShowsAReadMessageOnceAndStartsTheNextTurnWithOneTheTurnDidNotRead() async throws {
        let (model, task, transport, steer, conversation) = try await runningApp()

        await model.send(HarnessUserInput(text: "Then deploy it"), to: task)
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.sent])
        XCTAssertEqual(steer.takeBack(for: conversation), ["Then deploy it"], "the hook hands it to the agent")
        await transport.emit(userChunk("Then deploy it", conversation: conversation))
        try await waitUntil { model.followUps.queue(for: task.id).isEmpty }

        await model.send(HarnessUserInput(text: "And post the link"), to: task)
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.sent])
        await transport.completePrompt()
        try await waitUntil { await transport.pendingPromptCount == 1 && model.followUps.queue(for: task.id).isEmpty }
        let prompts = await transport.requestValues.filter { $0["method"]?.stringValue == "session/prompt" }
        XCTAssertEqual(prompts.compactMap { $0["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue },
                       ["Build the site", "And post the link"])
        await transport.completePrompt()
        try await waitUntil { model.store.sessions.first?.status == .ready }
        XCTAssertEqual(userLines(model, task), ["Build the site", "Then deploy it", "And post the link"])
    }

    @MainActor
    private func userLines(_ model: AppModel, _ task: SessionRecord) -> [String] {
        (model.transcriptBySessionID[task.id] ?? []).compactMap { entry in
            if case let .user(text, _) = entry.content { return text }
            return nil
        }
    }

    private func userChunk(_ text: String, conversation: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                 "params": .object(["sessionId": .string(conversation), "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)])
                 ])])])
    }
}

private actor SteerPayloadLog {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}
