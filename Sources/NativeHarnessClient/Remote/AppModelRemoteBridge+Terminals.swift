import Foundation
import YardletRemote

extension AppModelRemoteBridge {
    func openTerminal(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit,
                      output: @escaping @Sendable (RemoteTerminalUpdate) async -> Void) async -> RemoteError? {
        guard let model, let task = session(taskID) else { return RemoteError(.notFound) }
        return terminals.open(model: model, task: task, terminalID: terminalID, columns: columns, rows: rows, permit: permit, output: output)
    }
    func attachTerminal(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit,
                        output: @escaping @Sendable (RemoteTerminalUpdate) async -> Void) async -> RemoteError? {
        terminals.attach(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows, permit: permit, output: output)
    }
    func detachTerminal(taskID: String, terminalID: String, permit: RemoteTerminalPermit,
                        ended: @escaping @Sendable () async -> Void) async {
        terminals.detach(taskID: taskID, terminalID: terminalID, permit: permit, ended: ended)
    }
    func terminalInput(taskID: String, terminalID: String, data: Data, permit: RemoteTerminalPermit) async -> RemoteError? {
        terminals.input(taskID: taskID, terminalID: terminalID, data: data, permit: permit)
    }
    func terminalResize(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit) async -> RemoteError? {
        terminals.resize(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows, permit: permit)
    }
    func terminalStatus(taskID: String, terminalID: String, permit: RemoteTerminalPermit) async -> Result<RemoteTerminalStatus, RemoteError> {
        terminals.status(taskID: taskID, terminalID: terminalID, permit: permit)
    }
    func closeTerminal(taskID: String, terminalID: String) async { terminals.close(taskID: taskID, terminalID: terminalID) }
}
