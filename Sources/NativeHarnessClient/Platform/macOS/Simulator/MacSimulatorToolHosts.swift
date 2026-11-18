import Foundation
import YardletSimulatorHostProtocol

/// The simulator hosts the agent's tools attach devices in: one helper per Xcode, started on the first tool and
/// ending a minute after the tools let go of its last device.
@MainActor
final class MacSimulatorToolHosts: SimulatorHostAttaching {
    static let shared = MacSimulatorToolHosts()

    /// The helper's executable; QA points it elsewhere.
    var executable = SimulatorHostProcess.bundledExecutable
    private var clients: [String: SimulatorHostClient] = [:]
    private var attachedIn: [UUID: SimulatorHostClient] = [:]

    func attachForTools(_ device: UUID, with toolchain: SimulatorToolchain) async throws
        -> (client: SimulatorHostClient, screen: SimulatorScreen) {
        let client = client(for: toolchain)
        if let previous = attachedIn[device], previous !== client { previous.detach(device) }
        if let screen = client.screens[device] {
            attachedIn[device] = client
            return (client, screen)
        }
        let screen = try await client.attach(device)
        attachedIn[device] = client
        return (client, screen)
    }

    func releaseForTools(_ device: UUID) {
        attachedIn.removeValue(forKey: device)?.detach(device)
    }

    /// Settings › General › Simulator turned off: the helpers end.
    func endAll() {
        for client in clients.values { client.terminate() }
        clients = [:]
        attachedIn = [:]
    }

    private func client(for toolchain: SimulatorToolchain) -> SimulatorHostClient {
        if let client = clients[toolchain.directory] { return client }
        let client = SimulatorHostClient(developerDirectory: URL(filePath: toolchain.directory, directoryHint: .isDirectory),
                                         executable: executable)
        clients[toolchain.directory] = client
        return client
    }
}
