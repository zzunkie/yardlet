import Foundation

enum CLIVerification: Equatable, Sendable {
    case passed
    case failed(String)
}

/// Whether Yardlet can still drive a harness CLI. A check never starts a model turn, opens a
/// conversation, or signs in; tests pass a fake.
protocol CLIVerifying: Sendable {
    func canVerify(_ harness: HarnessKind) -> Bool
    func verify(_ harness: HarnessKind, executable: URL) async -> CLIVerification
}

/// The checks Yardlet runs before and after a CLI update (product document 13.22):
///
/// - Codex: App Server `initialize` and `thread/list` with `limit` 1, Yardlet's own requests.
/// - Claude Code: `--version`, then the stream-json `initialize` control request Yardlet sends
///   before every session (the same exchange the usage check makes).
/// - Antigravity CLI: `agy models`, which must list a model, and from the version Yardlet runs over
///   ACP (`AntigravityTransport`), ACP `initialize` on `agy acp` as well.
/// - ACP harnesses: `--version`, then ACP `initialize` (no session).
///
/// Other harnesses have no check, so Yardlet does not update them on its own.
struct CLIVerificationProbe: CLIVerifying {
    var codexEnvironment: CodexEnvironmentManager?
    var timeout: Duration = .seconds(45)

    func canVerify(_ harness: HarnessKind) -> Bool {
        harness == .codex || harness == .claudeCode || harness == .antigravityCLI
            || HarnessCatalog.descriptor(for: harness)?.transport == .acp
    }

    func verify(_ harness: HarnessKind, executable: URL) async -> CLIVerification {
        switch harness {
        case .codex: return await codex(executable)
        case .claudeCode: return await claude(executable)
        case .antigravityCLI:
            let listed = await antigravity(executable)
            guard listed == .passed else { return listed }
            let version = await CLIProcess.run(CLICommand(executable: executable, arguments: ["--version"],
                                                          timeout: CLIUpdatePlan.versionTimeout))
            let reported = version.succeeded ? CLIVersion.parse(version.stdout + "\n" + version.stderr) : nil
            guard AntigravityTransport.servesACP(version: reported) else { return .passed }
            return await acp(executable, arguments: HarnessCatalog.descriptor(for: .antigravityCLI)?.launchArguments ?? ["acp"])
        default:
            guard let descriptor = HarnessCatalog.descriptor(for: harness), descriptor.transport == .acp else {
                return .failed(L10n.string("Yardlet has no check for this CLI"))
            }
            return await acp(executable, arguments: descriptor.launchArguments)
        }
    }

    private func codex(_ executable: URL) async -> CLIVerification {
        var environment = RuntimeProcessEnvironment.values(executableURL: executable)
        if let codexEnvironment, let values = try? await codexEnvironment.processEnvironment(scope: .native).values {
            environment = values
        }
        let encoder = JSONEncoder()
        guard var initialize = try? encoder.encode(CodexProtocol.initialize(id: 1, clientVersion: Self.clientVersion)),
              var list = try? encoder.encode(CodexProtocol.interactiveThreads(id: 2, limit: 1)) else {
            return .failed(L10n.string("Yardlet could not write its request"))
        }
        initialize.append(0x0A)
        list.append(0x0A)
        return await CLIProcess.exchange(
            executable: executable,
            arguments: HarnessCatalog.descriptor(for: .codex)?.launchArguments ?? ["app-server", "--stdio"],
            environment: environment,
            steps: [
                .init(line: initialize) { value in
                    Self.answer(value, id: 1) { $0["platformOs"]?.stringValue != nil }
                },
                .init(line: list) { value in
                    Self.answer(value, id: 2) { $0["data"]?.arrayValue != nil }
                }
            ],
            timeout: timeout)
    }

    private func claude(_ executable: URL) async -> CLIVerification {
        let version = await CLIProcess.run(CLICommand(executable: executable, arguments: ["--version"],
                                                      timeout: CLIUpdatePlan.versionTimeout))
        guard version.succeeded, CLIVersion.parse(version.stdout) != nil else {
            return .failed(L10n.format("--version failed: %@", version.failureSummary))
        }
        let line = Data((#"{"type":"control_request","request_id":"yardlet-check","request":{"subtype":"initialize"}}"# + "\n").utf8)
        return await CLIProcess.exchange(
            executable: executable,
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--strict-mcp-config"],
            environment: RuntimeProcessEnvironment.values(executableURL: executable, overrides: ["NO_COLOR": "1"]),
            steps: [.init(line: line) { value in
                guard value["type"]?.stringValue == "control_response",
                      value["response"]?["request_id"]?.stringValue == "yardlet-check" else { return nil }
                return value["response"]?["subtype"]?.stringValue == "success"
                    ? .passed
                    : .failed(value["response"]?["error"]?.stringValue ?? L10n.string("initialize was refused"))
            }],
            timeout: timeout)
    }

    private func antigravity(_ executable: URL) async -> CLIVerification {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Yardlet-CLICheck-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = await CLIProcess.run(CLICommand(executable: executable, arguments: ["models"], timeout: timeout),
                                          currentDirectory: folder)
        guard result.succeeded else { return .failed(result.failureSummary) }
        return StructuredHeadlessAdapter.catalogChoices(in: result.stdout).isEmpty
            ? .failed(L10n.string("agy models listed no model"))
            : .passed
    }

    private func acp(_ executable: URL, arguments: [String]) async -> CLIVerification {
        let version = await CLIProcess.run(CLICommand(executable: executable, arguments: ["--version"],
                                                      timeout: CLIUpdatePlan.versionTimeout))
        guard version.succeeded else { return .failed(L10n.format("--version failed: %@", version.failureSummary)) }
        guard let line = try? ACPWireCodec().encodeLine(ACPProtocol.initialize(id: 1)) else {
            return .failed(L10n.string("Yardlet could not write its request"))
        }
        return await CLIProcess.exchange(
            executable: executable, arguments: arguments,
            environment: RuntimeProcessEnvironment.values(executableURL: executable, overrides: ["NO_COLOR": "1"]),
            steps: [.init(line: line) { value in
                Self.answer(value, id: 1) { $0["protocolVersion"] != nil }
            }],
            timeout: timeout)
    }

    /// The JSON-RPC answer to `id`: passed when its result looks as expected, failed on an error.
    private static func answer(_ value: JSONValue, id: Int64, expected: (JSONValue) -> Bool) -> CLIVerification? {
        guard value["id"]?.integerValue == id else { return nil }
        if let error = value["error"] {
            return .failed(error["message"]?.stringValue ?? L10n.string("The CLI refused the request"))
        }
        guard let result = value["result"], expected(result) else {
            return .failed(L10n.string("The CLI answered in a form Yardlet does not know"))
        }
        return .passed
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }
}
