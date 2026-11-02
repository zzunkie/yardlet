import Foundation

/// The Mac's mail connections, through `URLSessionStreamTask`: TLS from the start, or upgraded in place
/// after STARTTLS, with the server's certificate checked against the host's name as the system checks
/// it. Nothing is cached or written to disk.
struct LiveMailSockets: MailSocketOpening {
    func open(host: String, port: Int, tls: Bool) async throws -> any MailSocket {
        let socket = StreamMailSocket(host: host, port: port)
        if tls { try await socket.startTLS() }
        return socket
    }
}

final class StreamMailSocket: MailSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    /// How long a read waits for the server before the connection counts as gone.
    static let readTimeout: TimeInterval = 120

    init(host: String, port: Int) {
        session = URLSession(configuration: .ephemeral)
        task = session.streamTask(withHostName: host, port: port)
        task.resume()
    }

    func read() async throws -> Data {
        do {
            let (data, _) = try await task.readData(ofMinLength: 1, maxLength: 65_536, timeout: Self.readTimeout)
            return data ?? Data()
        } catch {
            throw Self.failure(error)
        }
    }

    func write(_ data: Data) async throws {
        do {
            try await task.write(data, timeout: 60)
        } catch {
            throw Self.failure(error)
        }
    }

    func startTLS() async throws {
        task.startSecureConnection()
    }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }

    private static func failure(_ error: Error) -> Error {
        let code = (error as? URLError)?.code
        return switch code {
        case .timedOut?: MailSocketFailure.timedOut
        case .networkConnectionLost?, .cancelled?: MailSocketFailure.closed
        default: MailSocketFailure.unreachable(error.localizedDescription)
        }
    }
}
