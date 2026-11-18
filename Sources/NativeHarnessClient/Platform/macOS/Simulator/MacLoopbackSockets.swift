import Foundation
import Network

/// The Mac's loopback connections for the scrcpy session's adb tunnel, through Network.framework with Nagle's
/// algorithm off: a drag sends a small control message for each move, which would otherwise wait for the last
/// one's acknowledgement.
struct LiveLoopbackSockets: LoopbackSocketOpening {
    func open(port: Int) async throws -> any LoopbackSocket {
        try await NetworkLoopbackSocket.connect(port: port)
    }
}

final class NetworkLoopbackSocket: LoopbackSocket, @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    static func connect(port: Int) async throws -> NetworkLoopbackSocket {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw ScrcpyProtocolError("Bad port \(port)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: NWParameters(tls: nil, tcp: tcp))
        let resumed = Resumed()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.take() { continuation.resume() }
                case let .failed(error), let .waiting(error):
                    // Waiting is a refused connection that Network.framework would try again: it fails here.
                    connection.cancel()
                    if resumed.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.take() { continuation.resume(throwing: ScrcpyProtocolError("Connection cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "Yardlet loopback socket"))
        }
        return NetworkLoopbackSocket(connection)
    }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    // The other end closed.
                    _ = isComplete
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func close() {
        connection.cancel()
    }

    /// Lets the connection's first final state resume the wait, and no later one.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}
