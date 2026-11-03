import Foundation
import YardletRemote

/// This platform has no terminal host yet.
@MainActor
final class RemoteTerminalBridge {
    static let isAvailable = false
    func open(model: AppModel, task: SessionRecord, terminalID: String, columns: Int, rows: Int,
              permit: RemoteTerminalPermit, output: @escaping @Sendable (RemoteTerminalUpdate) async -> Void) -> RemoteError? {
        RemoteError(.unavailable)
    }
    func input(taskID: String, terminalID: String, data: Data, permit: RemoteTerminalPermit) -> RemoteError? { RemoteError(.unavailable) }
    func resize(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit) -> RemoteError? { RemoteError(.unavailable) }
    func status(taskID: String, terminalID: String, permit: RemoteTerminalPermit) -> Result<RemoteTerminalStatus, RemoteError> { .failure(RemoteError(.unavailable)) }
    func close(taskID: String, terminalID: String) {}
}
