import Foundation
import XCTest
@testable import NativeHarnessClient

/// A mail server played from a transcript, for the IMAP and SMTP clients' tests. Each transcript line is
/// one line on the wire, CRLF added: `S:` what the server sends, `C:` what the client must write, and
/// `T:` where the client must start TLS; blank lines are left out. The server's bytes are handed out in
/// chunks of `chunkSize`, or a turn at a time. A client that writes other bytes, or reads when it should
/// write, fails the test and finds the connection closed.
final class ScriptedMailSocket: MailSocket, @unchecked Sendable {
    private enum Step {
        case server([UInt8])
        case client([UInt8])
        case startTLS
    }

    private let lock = NSLock()
    private let steps: [Step]
    private let chunkSize: Int?
    private var step = 0
    private var offset = 0
    private var failed: [String] = []
    private var closed = false

    init(_ transcript: String, chunkSize: Int? = nil) {
        var steps: [Step] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            var content = line.dropFirst(2)
            if content.first == " " { content = content.dropFirst() }
            let bytes = Array(content.utf8) + [0x0D, 0x0A]
            switch (line.prefix(2), steps.last) {
            case let ("S:", .server(previous)?): steps[steps.count - 1] = .server(previous + bytes)
            case ("S:", _): steps.append(.server(bytes))
            case let ("C:", .client(previous)?): steps[steps.count - 1] = .client(previous + bytes)
            case ("C:", _): steps.append(.client(bytes))
            case ("T:", _): steps.append(.startTLS)
            default: preconditionFailure("A transcript line starts with S:, C: or T:, not \(line)")
            }
        }
        self.steps = steps
        self.chunkSize = chunkSize
    }

    /// What went wrong, in the order it happened; empty when the client kept to the script.
    var failures: [String] { lock.withLock { failed } }
    /// Whether every line of the script was sent and written.
    var isFinished: Bool { lock.withLock { step == steps.count } }
    var isClosed: Bool { lock.withLock { closed } }

    func read() async throws -> Data {
        lock.withLock {
            guard failed.isEmpty, !closed, step < steps.count else { return Data() }
            switch steps[step] {
            case let .server(bytes):
                let end = min(bytes.count, offset + (chunkSize ?? bytes.count))
                let chunk = Data(bytes[offset..<end])
                offset = end
                if offset == bytes.count { advance() }
                return chunk
            case let .client(bytes):
                fail("The client waited for the server but should have written \(Self.show(bytes[offset...]))")
                return Data()
            case .startTLS:
                fail("The client waited for the server but should have started TLS")
                return Data()
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            guard failed.isEmpty else { return }
            for byte in data {
                guard step < steps.count, case let .client(expected) = steps[step] else {
                    fail("The client wrote \(Self.show(data[...])) where the script has it write nothing")
                    return
                }
                guard expected[offset] == byte else {
                    fail("The client wrote \(Self.show(data[...])) where the script has \(Self.show(expected[offset...]))")
                    return
                }
                offset += 1
                if offset == expected.count { advance() }
            }
        }
    }

    func startTLS() async throws {
        lock.withLock {
            guard step < steps.count, case .startTLS = steps[step] else {
                fail("The client started TLS where the script does not")
                return
            }
            advance()
        }
    }

    func close() {
        lock.withLock { closed = true }
    }

    private func advance() {
        step += 1
        offset = 0
    }

    private func fail(_ message: String) {
        failed.append(message)
        XCTFail(message)
    }

    /// Up to the first line end, for a readable failure.
    private static func show<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let line = text.components(separatedBy: "\r\n").first ?? text
        return "“\(line)”"
    }
}

/// Hands out one scripted socket and records where each connection went: `host:port tls` or
/// `host:port plain`.
final class ScriptedMailOpener: MailSocketOpening, @unchecked Sendable {
    private let lock = NSLock()
    private let socket: ScriptedMailSocket
    private var connections: [String] = []

    init(_ socket: ScriptedMailSocket) {
        self.socket = socket
    }

    var opened: [String] { lock.withLock { connections } }

    func open(host: String, port: Int, tls: Bool) async throws -> any MailSocket {
        lock.withLock { connections.append("\(host):\(port) \(tls ? "tls" : "plain")") }
        return socket
    }
}
