import Foundation

/// A WebSocket frame put back together from the pieces the transport handed it over in. Foundation outside Apple's
/// platforms hands each piece libcurl reads of a frame over as a message of its own
/// (`WebSocketURLProtocol.didReceive(data:)` reads the frame's kind from `curl_ws_meta` and drops `bytesleft`), so a
/// frame that arrives in parts reaches Yardlet as several messages, one right after another. A piece does not read as
/// a frame: a Noise frame does not decrypt, a relay message is not JSON. So bytes that do not read are held, and the
/// next message of the same kind is joined to them and read again, until they read or pass the frame's limit (§13).
/// Apple's Foundation hands over whole frames, and there a frame that does not read is refused at once.
public struct RemoteFramePieces: Sendable {
    /// Whether this platform's WebSocket hands a frame over in pieces.
    #if canImport(Darwin)
    public static let platformSplitsFrames = false
    #else
    public static let platformSplitsFrames = true
    #endif

    public enum Outcome: Equatable, Sendable {
        /// The bytes read as a frame.
        case read
        /// They did not, and are held for the next piece.
        case held
        /// They did not, and no piece is to come: the frame is refused.
        case unreadable
    }

    /// The bytes passed the limit before they read.
    public struct TooLong: Error {}

    public let limit: Int
    public let joinsPieces: Bool
    private var held = Data()

    public init(limit: Int, joinsPieces: Bool = Self.platformSplitsFrames) {
        self.limit = limit
        self.joinsPieces = joinsPieces
    }

    /// Joins `piece` to the bytes held and reads them with `read`, which says whether they make a frame. `read` must
    /// leave what it reads with as it was when they do not: a Noise cipher moves its nonce only for a frame that
    /// decrypts.
    public mutating func add(_ piece: Data, read: (Data) throws -> Bool) throws -> Outcome {
        let bytes = held.isEmpty ? piece : held + piece
        held = Data()
        guard bytes.count <= limit else { throw TooLong() }
        if try read(bytes) { return .read }
        guard joinsPieces, bytes.count < limit else { return .unreadable }
        held = bytes
        return .held
    }
}
