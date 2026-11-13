import Foundation

/// Signing in to a harness on the Linux host (docs/LINUX_HOST.md, "Signing in to the harnesses"), where no browser
/// opens: `yardlet host login HARNESS` asks the running host, which knows which install its tasks start and with which
/// account folder. Each harness keeps its own login; Yardlet runs only the harness's own sign-in and reads the result.
/// Codex signs in with its device code through its App Server (`CodexBrowserSignIn.runDeviceCode`): the host answers
/// with the address to open and the code to enter on any device, and the sign-in ends in the host. Every other
/// harness, and a Codex whose App Server starts no device-code sign-in (`codex login --device-auth` then), runs its own
/// sign-in command (`HarnessAccountBroker.loginCommand`) in the person's terminal: Claude Code prints its address and
/// takes the code pasted back there. The login is read again when the sign-in ends.
@MainActor
final class LinuxHostSignIn {
    enum Phase: String, Codable {
        case waiting
        case signedIn
        case failed
    }

    private let model: AppModel
    private var codexSignIns: [HarnessKind: CodexBrowserSignIn] = [:]
    private var phases: [HarnessKind: (phase: Phase, reason: String?)] = [:]

    init(model: AppModel) {
        self.model = model
    }

    /// The harness a person names: its id (`claude-code`), or its command (`claude`).
    static func harness(named name: String) -> HarnessDescriptor? {
        HarnessCatalog.builtIns.first { $0.id.rawValue == name }
            ?? HarnessCatalog.builtIns.first { $0.executableName == name }
    }

    /// The account a new task with `harness` starts on, as the Mac's new task reads it.
    func account(_ harness: HarnessKind) -> AccountChoice? {
        let connections = model.connections
        return connections.choices(for: [harness]).first { $0.connection?.id == connections.selection[harness] }
    }

    func start(_ descriptor: HarnessDescriptor) async -> HostControlReply {
        let harness = descriptor.id
        guard let executable = model.runtimeSelections.selectedURL(for: harness) else {
            return .failure("\(descriptor.displayName) is not installed for this account, or not on the PATH the host found. "
                + "Install it, then restart the host.")
        }
        let connection = account(harness)?.connection
        if harness == .codex, connection == nil {
            if let reply = await startCodexDeviceCode(executable) { return reply }
        }
        let broker = connection.map { HarnessAccountBroker(connection: $0) }
            ?? HarnessAccountBroker(codexEnvironmentManager: model.codexEnvironmentManager)
        guard let command = await broker.loginCommand(for: harness, executableURL: executable) else {
            return .failure("\(descriptor.displayName) has no sign-in Yardlet can start.")
        }
        // No browser opens here: Codex's own command signs in with a device code too.
        let arguments = harness == .codex && command.arguments == ["login"] ? ["login", "--device-auth"] : command.arguments
        return HostControlReply(signIn: HostSignIn(
            command: [command.executableURL.path(percentEncoded: false)] + arguments, environment: command.environment,
            message: command.startupMessage?.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Codex's device-code sign-in in the host, or nil when its App Server starts none.
    private func startCodexDeviceCode(_ executable: URL) async -> HostControlReply? {
        await codexSignIns[.codex]?.cancel()
        let signIn = CodexBrowserSignIn(executableURL: executable, environmentManager: model.codexEnvironmentManager)
        codexSignIns[.codex] = signIn
        phases[.codex] = (.waiting, nil)
        let (shown, show) = AsyncStream<(URL, String)>.makeStream()
        Task {
            let outcome = await signIn.runDeviceCode { address, code in show.yield((address, code)) }
            show.finish()
            guard codexSignIns[.codex] === signIn else { return }
            codexSignIns[.codex] = nil
            switch outcome {
            case .signedIn:
                await reread(.codex)
                phases[.codex] = (.signedIn, nil)
            case let .failed(reason):
                phases[.codex] = (.failed, reason)
            case .cancelled:
                phases[.codex] = (.failed, "The sign-in was cancelled.")
            case .unavailable:
                phases[.codex] = nil
            }
        }
        for await (address, code) in shown {
            return HostControlReply(signIn: HostSignIn(address: address.absoluteString, code: code, state: .waiting))
        }
        return nil
    }

    /// Where a sign-in the host runs stands, and the login's reading when none runs.
    func state(_ descriptor: HarnessDescriptor) -> HostControlReply {
        let harness = descriptor.id
        if let phase = phases[harness] {
            return HostControlReply(signIn: HostSignIn(state: phase.phase, reason: phase.reason))
        }
        return HostControlReply(signIn: HostSignIn(state: account(harness)?.snapshot?.state == .signedIn ? .signedIn : .failed))
    }

    func cancel(_ descriptor: HarnessDescriptor) async {
        guard let signIn = codexSignIns.removeValue(forKey: descriptor.id) else { return }
        phases[descriptor.id] = (.failed, "The sign-in was cancelled.")
        await signIn.cancel()
    }

    /// Reads the login again once a sign-in in the terminal has ended.
    func check(_ descriptor: HarnessDescriptor) async -> HostControlReply {
        phases[descriptor.id] = nil
        await reread(descriptor.id)
        return state(descriptor)
    }

    private func reread(_ harness: HarnessKind) async {
        guard let choice = account(harness) else { return }
        await model.connections.check(choice, policy: .restart, runtimeSelections: model.runtimeSelections)
    }
}

/// A sign-in as `yardlet host login` shows it: Codex's address and code, or the command to run in the terminal, and
/// how it stands.
struct HostSignIn: Codable, Equatable {
    /// Where to sign in, on any device, and the code to enter there.
    var address: String?
    var code: String?
    /// The harness's own sign-in command, to run in the person's terminal, with what it needs in its environment.
    var command: [String]?
    var environment: [String: String]?
    var message: String?
    var state: LinuxHostSignIn.Phase?
    var reason: String?
}
