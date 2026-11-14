import Foundation

@MainActor
final class RemoteTerminalHosting: TerminalHosting {
    let stream: RemoteTerminalStream
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onReady: (() -> Void)?
    /// The shell's size the host took, before the output written at it.
    var onResize: ((TerminalGrid) -> Void)?
    var workspaceURL: URL? { stream.workspaceURL }
    var processID: Int32? { nil }
    var foregroundProcessGroup: Int32? { nil }
    var isAtPrompt: Bool? { stream.foreground?.isAtPrompt }
    func refreshPromptState() async -> Bool? { await stream.readForeground()?.isAtPrompt }
    var isReady: Bool { stream.phase == .running }
    var statusMessage: String? {
        switch stream.phase {
        case .opening: L10n.string("Connecting…")
        case let .failed(message): message
        default: nil
        }
    }

    init(stream: RemoteTerminalStream) {
        self.stream = stream
        stream.onOutput = { [weak self] data in self?.onOutput?(Array(data)[...]) }
        stream.onResize = { [weak self] columns, rows in self?.onResize?(TerminalGrid(columns: columns, rows: rows)) }
        stream.onReady = { [weak self] in self?.onReady?() }
        stream.onExit = { [weak self] in self?.onExit?($0) }
    }
    func start() { stream.start() }
    func send(_ bytes: ArraySlice<UInt8>) { stream.send(Data(bytes)) }
    func resize(columns: Int, rows: Int) { stream.resize(columns: columns, rows: rows) }
    func stop() { stream.stop() }
}
