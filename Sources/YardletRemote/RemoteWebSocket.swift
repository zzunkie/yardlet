import Crypto
import Foundation

/// The WebSocket of a direct path (RFC 6455, §11.1) for a listener that has only a byte stream: the server's side of
/// the opening handshake, and its frames. The Mac's listener has Network.framework's WebSocket and shares only the
/// handshake's rules with these; the Windows listener (`RemoteWinsockListener`) speaks the WebSocket over Winsock with
/// them, and `RemoteWebSocketReader` reads the client's frames back into messages.
public enum RemoteWebSocket {
    /// Added to an accepted handshake's answer.
    public static let acceptedHeader = (name: "X-Yardlet-Remote", value: String(RemoteProtocol.secureVersion))
    /// The most an opening request may hold, up to its blank line.
    public static let maxRequestBytes = 8 * 1024

    /// A browser always sends Origin; a web page must not reach the remote.
    public static func isFromBrowser(_ headerNames: some Sequence<String>) -> Bool {
        headerNames.contains { $0.caseInsensitiveCompare("Origin") == .orderedSame }
    }

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (RFC 6455 §4.2.2).
    public static func acceptValue(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    public enum Opening: Equatable, Sendable {
        /// The request is not all in yet.
        case incomplete
        /// The answer to send, and what the client sent after its request: the start of its first frame.
        case accepted(response: Data, rest: Data)
        /// HTTP 400, as the Mac refuses: the answer to send before closing.
        case refused(response: Data)
    }

    /// Reads a client's opening request from what it has sent so far. A phone's is a GET upgrade to a version 13
    /// WebSocket with a 16-byte key and no Origin; anything else is refused.
    public static func open(_ received: Data) -> Opening {
        guard let end = received.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return received.count > maxRequestBytes ? .refused(response: refusal) : .incomplete
        }
        guard received.distance(from: received.startIndex, to: end.upperBound) <= maxRequestBytes,
              let key = upgradeKey(String(decoding: received[..<end.lowerBound], as: UTF8.self))
        else { return .refused(response: refusal) }
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptValue(for: key))\r\n\(acceptedHeader.name): \(acceptedHeader.value)\r\n\r\n"
        return .accepted(response: Data(response.utf8), rest: Data(received[end.upperBound...]))
    }

    private static let refusal = Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)

    private static func upgradeKey(_ head: String) -> String? {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1" else { return nil }
        // By lowercased name; a header sent twice keeps both values.
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(), default: []]
                .append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        func tokens(_ name: String) -> [String] {
            (headers[name] ?? []).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        guard !isFromBrowser(headers.keys), tokens("upgrade").contains("websocket"), tokens("connection").contains("upgrade"),
              headers["sec-websocket-version"] == ["13"], let key = headers["sec-websocket-key"], key.count == 1,
              Data(base64Encoded: key[0])?.count == 16
        else { return nil }
        return key[0]
    }

    public enum Opcode: UInt8, Sendable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    /// A server's frame: whole and unmasked, its length in the fewest bytes.
    public static func frame(_ opcode: Opcode, _ payload: Data = Data()) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case ..<126:
            frame.append(UInt8(payload.count))
        case ...0xFFFF:
            frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            frame.append(127)
            frame += stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: payload.count >> $0) }
        }
        return frame + payload
    }

    /// A close frame naming `code`.
    public static func closeFrame(_ code: UInt16) -> Data {
        frame(.close, Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }
}

/// A client's frames read back into whole messages (RFC 6455 §5), as Network.framework hands them to the Mac's listener:
/// each frame masked, a message perhaps in fragments with control frames between them, and the bytes cut wherever the
/// socket's reads cut them. A message holds at most 65,535 bytes (§11.1), and a frame whose header names more, or the
/// 64-bit length no such frame needs, closes with 1009 before anything of it is kept.
public struct RemoteWebSocketReader: Sendable {
    public enum Event: Equatable, Sendable {
        /// A whole binary message.
        case binary(Data)
        /// A ping, to answer with a pong of the same bytes.
        case ping(Data)
        /// The client closed, naming this code; the listener answers with a close and ends the connection.
        case close(UInt16?)
        /// The connection is to close with this code: a frame RFC 6455 does not allow (1002), a text frame (1003), a
        /// message over the limit (1009). Nothing is read after it.
        case refused(RemoteCloseCode)
    }

    public static let limit = RemoteNoise.maxMessageLength
    private var buffer: [UInt8] = []
    /// A binary message's fragments so far.
    private var message: Data?
    private var ended = false

    public init() {}

    /// What the bytes received make, joined to those held; a frame not all in yet is held for the next.
    public mutating func read(_ bytes: some Sequence<UInt8>) -> [Event] {
        guard !ended else { return [] }
        buffer.append(contentsOf: bytes)
        var events: [Event] = []
        var start = 0
        while let frame = next(at: start) {
            start += frame.length
            guard let event = frame.event else { continue }
            events.append(event)
            switch event {
            case .close, .refused:
                ended = true
                buffer = []
                return events
            case .binary, .ping:
                break
            }
        }
        buffer.removeFirst(start)
        return events
    }

    /// The frame at `start` and its length, its event nil where it makes none yet (a fragment, a pong); nil while
    /// it is not all in.
    private mutating func next(at start: Int) -> (event: Event?, length: Int)? {
        let available = buffer.count - start
        guard available >= 2 else { return nil }
        let first = buffer[start], second = buffer[start + 1]
        let isFinal = first & 0x80 != 0
        let shortLength = Int(second & 0x7F)
        // No extension is agreed, so the reserved bits are clear, and a client masks every frame.
        guard first & 0x70 == 0, second & 0x80 != 0, let opcode = RemoteWebSocket.Opcode(rawValue: first & 0x0F) else {
            return (.refused(.protocolError), 0)
        }
        switch opcode {
        case .text:
            return (.refused(.unsupportedData), 0)
        case .close, .ping, .pong:
            // A control frame is never in fragments, and its length fits the first byte.
            guard isFinal, shortLength <= 125 else { return (.refused(.protocolError), 0) }
        case .binary:
            guard message == nil else { return (.refused(.protocolError), 0) }
        case .continuation:
            guard message != nil else { return (.refused(.protocolError), 0) }
        }
        guard shortLength != 127 else { return (.refused(.messageTooBig), 0) }
        var length = shortLength
        var header = 2
        if shortLength == 126 {
            guard available >= 4 else { return nil }
            length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            header = 4
        }
        if opcode == .binary || opcode == .continuation, (message?.count ?? 0) + length > Self.limit {
            return (.refused(.messageTooBig), 0)
        }
        let total = header + 4 + length
        guard available >= total else { return nil }
        let mask = Array(buffer[start + header..<start + header + 4])
        var payload = Data(buffer[start + header + 4..<start + total])
        payload.withUnsafeMutableBytes { bytes in
            for index in bytes.indices { bytes[index] ^= mask[index & 3] }
        }
        switch opcode {
        case .binary, .continuation:
            message = (message ?? Data()) + payload
            guard isFinal, let whole = message else { return (nil, total) }
            message = nil
            return (.binary(whole), total)
        case .ping:
            return (.ping(payload), total)
        case .close:
            return (.close(payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil), total)
        case .pong, .text:
            return (nil, total)
        }
    }
}
