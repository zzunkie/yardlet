import Foundation
import XCTest
@testable import NativeHarnessClient

/// Runs Yardlet's own Codex adapter against a real App Server on a copy of a saved thread, and
/// records every request, response, and notification. Nothing here starts a model turn: the probe
/// only resumes, which reads the thread and applies its settings in the copy.
///
/// `CODEX_HOME` must name a scratch home (a copy of the rollout, never `auth.json`); the probe
/// refuses the user's own `~/.codex`.
final class CodexResumeProbeLiveTests: XCTestCase {
    private struct Probe {
        let binaryURL: URL
        let threadID: String
        let workspaceURL: URL
        let recordURL: URL?
    }

    private func probe() throws -> Probe {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["NHC_CODEX_PROBE_BINARY"],
              let threadID = environment["NHC_CODEX_PROBE_THREAD"],
              let workspace = environment["NHC_CODEX_PROBE_WORKSPACE"] else {
            throw XCTSkip("Set NHC_CODEX_PROBE_BINARY, NHC_CODEX_PROBE_THREAD and NHC_CODEX_PROBE_WORKSPACE")
        }
        guard let home = environment["CODEX_HOME"], !home.isEmpty else {
            throw XCTSkip("Set CODEX_HOME to a scratch home holding a copy of the thread")
        }
        let userHome = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex").standardizedFileURL.path(percentEncoded: false)
        let scratch = URL(filePath: home).standardizedFileURL.path(percentEncoded: false)
        guard scratch.trimmingCharacters(in: ["/"]) != userHome.trimmingCharacters(in: ["/"]) else {
            throw XCTSkip("The probe never runs against the user's own Codex home")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(filePath: home).appending(path: "auth.json").path),
                       "The scratch home must not hold credentials")
        return Probe(
            binaryURL: URL(filePath: binary),
            threadID: threadID,
            workspaceURL: URL(filePath: workspace),
            recordURL: environment["NHC_CODEX_PROBE_RECORD"].map { URL(filePath: $0) }
        )
    }

    /// The resume Yardlet sends (bootstrap page, the Yardlet MCP server's `config`, the
    /// project's other roots) is accepted, and every frame it brings decodes.
    func testResumeWithYardletParametersDecodesEveryFrame() async throws {
        let probe = try probe()
        let log = LiveWireLog()
        let transport = RecordingCodexTransport(
            inner: CodexProcessTransport(executableURL: probe.binaryURL, requestTimeout: .seconds(120)),
            log: log
        )
        let adapter = CodexAdapter(executableURL: probe.binaryURL, transport: transport)
        let localSessionID = UUID()
        await adapter.setAdditionalWorkspaceRoots([FileManager.default.temporaryDirectory], for: localSessionID)
        await adapter.setAgentToolServer(
            AgentToolServerLaunch(command: "/usr/bin/true", environment: ["YARDLET_PROBE": "1"]),
            for: localSessionID
        )
        let started = Date()
        let handle = try await adapter.resumeSession(
            providerSessionID: probe.threadID,
            localSessionID: localSessionID,
            workspaceURL: probe.workspaceURL
        )
        let elapsed = Date().timeIntervalSince(started)
        try await Task.sleep(for: .seconds(3))
        let state = try await adapter.presentationState(for: handle)
        await log.note("resume took \(String(format: "%.2f", elapsed)) s; turns=\(state.thread?.turns.count ?? -1)")
        await log.write(to: probe.recordURL)
        XCTAssertEqual(handle.providerSessionID, probe.threadID)
        XCTAssertFalse(state.thread?.turns.isEmpty ?? true, "The bootstrap page should bring the latest turns")
        let decodeErrors = await log.incomingMethods.filter { $0 == "transport/decodeError" }
        XCTAssertTrue(decodeErrors.isEmpty, "Every App Server frame should decode")
        await adapter.close(handle)
        await transport.stop()
    }

    /// Another App Server that has the thread open (the Codex app's, in the user's case) makes
    /// Yardlet's resume fail with the provider's own reason, and Yardlet says why.
    func testResumeOfAThreadAnotherAppServerHoldsSaysWhy() async throws {
        let probe = try probe()
        let holder = CodexProcessTransport(executableURL: probe.binaryURL, requestTimeout: .seconds(120))
        _ = try await holder.request(CodexProtocol.initialize(id: 1, clientVersion: "probe-holder"))
        _ = try await holder.request(CodexProtocol.resumeThread(
            id: 2, threadID: probe.threadID, workspaceURL: probe.workspaceURL, excludeTurns: true
        ))

        let log = LiveWireLog()
        let transport = RecordingCodexTransport(
            inner: CodexProcessTransport(executableURL: probe.binaryURL, requestTimeout: .seconds(120)),
            log: log
        )
        let adapter = CodexAdapter(executableURL: probe.binaryURL, transport: transport)
        do {
            _ = try await adapter.resumeSession(
                providerSessionID: probe.threadID,
                localSessionID: UUID(),
                workspaceURL: probe.workspaceURL
            )
            XCTFail("A thread another App Server writes must not resume here")
        } catch let error as CodexThreadHeldElsewhere {
            await log.note("resume refused: \(error.localizedDescription)")
            XCTAssertTrue(error.providerMessage.contains("already has an active writer"), error.providerMessage)
        }
        await log.write(to: probe.recordURL)
        let resumes = await log.outgoingMethods.filter { $0 == "thread/resume" }
        XCTAssertEqual(resumes.count, 1, "A refused resume is not asked again for the whole history")
        await transport.stop()
        await holder.stop()
    }
}

extension LiveWireLog {
    /// Every line as JSON, one per line, for reading the run afterwards.
    func write(to url: URL?) {
        guard let url else { return }
        let text = lines.compactMap { line -> String? in
            let value: JSONValue = .object([
                "at": .number(line.at), "channel": .string(line.channel),
                "direction": .string(line.direction), "value": line.value
            ])
            return (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
        try? Data((text + "\n").utf8).write(to: url)
    }

    /// The `method` of every frame the App Server sent.
    var incomingMethods: [String] {
        lines.filter { $0.channel == "codex" && $0.direction == "in" }.compactMap { $0.value["method"]?.stringValue }
    }

    /// The `method` of every request Yardlet sent.
    var outgoingMethods: [String] {
        lines.filter { $0.channel == "codex" && $0.direction == "out" }.compactMap { $0.value["method"]?.stringValue }
    }
}

/// One cheap real turn, steered once, on a new thread in the sandbox folder, through Yardlet's
/// adapter and the user's normal Codex login. It records what the current App Server sends during
/// a turn so every notification and item it brings can be checked against Yardlet's reading of
/// them. It never resumes a saved thread.
final class CodexTurnProbeLiveTests: XCTestCase {
    func testOneSteeredTurnOnANewSandboxThreadEndsWithoutAnError() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["NHC_CODEX_TURN_PROBE_BINARY"],
              let workspace = environment["NHC_CODEX_TURN_PROBE_WORKSPACE"],
              let model = environment["NHC_CODEX_TURN_PROBE_MODEL"] else {
            throw XCTSkip("Set NHC_CODEX_TURN_PROBE_BINARY, NHC_CODEX_TURN_PROBE_WORKSPACE and NHC_CODEX_TURN_PROBE_MODEL")
        }
        let workspaceURL = URL(filePath: workspace)
        guard workspaceURL.lastPathComponent == "yardlet-sandbox" else {
            throw XCTSkip("The turn probe runs only in the yardlet-sandbox folder")
        }
        let log = LiveWireLog()
        let binaryURL = URL(filePath: binary)
        let transport = RecordingCodexTransport(
            inner: CodexProcessTransport(executableURL: binaryURL, requestTimeout: .seconds(60)), log: log
        )
        let adapter = CodexAdapter(executableURL: binaryURL, transport: transport)
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(localSessionID: UUID(), workspaceURL: workspaceURL, initialPrompt: nil)
        )
        let catalog = try await adapter.modelCatalog(for: handle)
        await log.note("models: \(catalog.models.map(\.model).joined(separator: ", "))")
        _ = try await adapter.selectModel(
            CodexModelSelection(model: model, reasoningEffort: environment["NHC_CODEX_TURN_PROBE_EFFORT"] ?? "low"),
            for: handle
        )
        let events = await adapter.events(for: handle)
        let collected = Task { () -> [HarnessEventPayload] in
            var payloads: [HarnessEventPayload] = []
            for await event in events {
                payloads.append(event.payload)
                if event.payload == .turnCompleted { break }
            }
            return payloads
        }
        try await adapter.submit(
            CodexComposerDraft(inputs: [.text(
                "Run the shell command `sleep 6` in this folder, then reply with exactly PROBE_DONE. Do nothing else."
            )]),
            submission: .start, to: handle
        )
        // Steer while the command runs, as a follow-up sent during a turn does.
        var steered = false
        for _ in 0..<200 where !steered {
            try await Task.sleep(for: .milliseconds(100))
            let state = try await adapter.presentationState(for: handle)
            if let turnID = state.activeTurnID,
               state.thread?.turns.last?.items.contains(where: { $0.raw["type"]?.stringValue == "commandExecution" }) == true {
                try await adapter.submit(
                    CodexComposerDraft(inputs: [.text("Also put the word STEERED on a second line.")]),
                    submission: .steer(expectedTurnID: turnID), to: handle
                )
                steered = true
            }
        }
        let payloads = try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw HarnessAdapterError.invalidProviderEvent("The probe turn did not finish")
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
        let state = try await adapter.presentationState(for: handle)
        await log.note("thread \(handle.providerSessionID); steered \(steered); status \(String(describing: state.thread?.turns.last?.status))")
        await log.write(to: environment["NHC_CODEX_TURN_PROBE_RECORD"].map { URL(filePath: $0) })

        let errors = payloads.compactMap { payload -> String? in
            if case let .error(message, _, _) = payload { return message }
            return nil
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertTrue(steered, "The turn should have been steered while its command ran")
        XCTAssertEqual(state.thread?.turns.last?.status, .completed)
        let decodeErrors = await log.incomingMethods.filter { $0 == "transport/decodeError" }
        XCTAssertTrue(decodeErrors.isEmpty)
        await adapter.close(handle)
        await transport.stop()
    }
}
