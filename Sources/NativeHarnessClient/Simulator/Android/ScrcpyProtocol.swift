import Foundation

/// The scrcpy server Yardlet runs on an Android device for its screen and input (scrcpy, Apache-2.0). Its protocol
/// changes from version to version and the server refuses a client of another one, so Yardlet pins one release and
/// speaks that release's protocol (`doc/develop.md`, `app/src/control_msg.c`, `app/src/demuxer.c` at the tag).
enum ScrcpyServer {
    static let version = "5.0.1"
    /// The release's `scrcpy-server-v5.0.1`, as GitHub and the release's SHA256SUMS.txt give it.
    static let sha256 = "764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
    static let byteCount = 733_930
    static let releaseURL = "https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1"
    /// The 64-byte device name the server sends first on the first socket.
    static let deviceNameLength = 64

    /// The device's server socket for one session: `scrcpy_` and the session's 31-bit ID in eight hex digits.
    static func socketName(scid: UInt32) -> String { "scrcpy_" + hex(scid) }

    /// Where the server goes on the device, a name for each session. The server removes the file as it starts.
    static func devicePath(scid: UInt32) -> String { "/data/local/tmp/yardlet-scrcpy-\(hex(scid)).jar" }

    /// `adb shell`'s arguments that start the server: video in H.264 at most `maxSize` on its longer side, no audio,
    /// control on, the device's clipboard sent only when asked, over a forward tunnel (the device listens, Yardlet
    /// connects, so Yardlet opens no listening port).
    static func shellArguments(scid: UInt32, video: ScrcpyVideoOptions) -> [String] {
        ["shell", "CLASSPATH=\(devicePath(scid: scid))", "app_process", "/", "com.genymobile.scrcpy.Server", version,
         "scid=\(hex(scid))", "log_level=warn", "audio=false", "tunnel_forward=true", "video_codec=h264",
         "max_size=\(video.maxSize)", "video_bit_rate=\(video.bitRate)", "clipboard_autosync=false"]
    }

    private static func hex(_ value: UInt32) -> String {
        let digits = String(value & 0x7FFF_FFFF, radix: 16)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}

/// The stream's size and rate: its longer side at most 1,280 pixels and 4 to 8 Mbps, which keep a panel sharp
/// without making the device's encoder the bottleneck.
struct ScrcpyVideoOptions: Equatable, Sendable {
    var maxSize: Int
    var bitRate: Int

    init(maxSize: Int = 1280, bitRate: Int = 8_000_000) {
        self.maxSize = min(max(maxSize, 320), 1280)
        self.bitRate = min(max(bitRate, 4_000_000), 8_000_000)
    }
}

/// `MotionEvent` actions a touch sends.
enum ScrcpyTouchAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case move = 2
}

/// `KeyEvent` actions.
enum ScrcpyKeyAction: UInt8, Sendable {
    case down = 0
    case up = 1
}

/// A point on the device's screen, in the pixels of the video frame the client shows: the server drops an event
/// whose screen size is not its current frame's.
struct ScrcpyPosition: Equatable, Sendable {
    var x: Int32
    var y: Int32
    var screenWidth: UInt16
    var screenHeight: UInt16
}

/// A message from the client to the device on the control socket. Only those Yardlet sends; scrcpy has more.
enum ScrcpyControlMessage: Equatable, Sendable {
    /// A finger: the server injects any pointer other than the mouse's as a touchscreen finger.
    case touch(ScrcpyTouchAction, pointer: UInt64, at: ScrcpyPosition, pressure: Float)
    /// A scroll of -16 to 16 steps each way.
    case scroll(at: ScrcpyPosition, horizontal: Float, vertical: Float)
    /// An Android key code (`KEYCODE_HOME` is 3, `KEYCODE_BACK` 4) with its meta state.
    case key(ScrcpyKeyAction, keycode: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0)
    /// Text typed as key events, at most 300 bytes of UTF-8; what does not fit is cut at a character.
    case text(String)
    /// Sets the device's clipboard, and pastes it when `paste`; the device acknowledges `sequence`.
    case setClipboard(String, sequence: UInt64, paste: Bool)
    /// Asks for the device's clipboard, which comes back as `ScrcpyDeviceMessage.clipboard`.
    case getClipboard
    /// Back, or turning the screen on when it is off.
    case backOrScreenOn(ScrcpyKeyAction)
    case expandNotificationPanel
    case collapsePanels
    case rotateDevice
    /// Asks the server for a new key frame.
    case resetVideo

    /// The pointer ID scrcpy gives a finger that is neither its mouse nor its second, virtual finger.
    static let fingerPointer = UInt64(bitPattern: -2)
    static let textLimit = 300
    static let clipboardLimit = (1 << 18) - 14

    var encoded: Data {
        var data = Data()
        switch self {
        case let .touch(action, pointer, position, pressure):
            data.append(2)
            data.append(action.rawValue)
            data.appendBigEndian(pointer)
            data.append(position)
            data.appendBigEndian(Self.unsignedFixedPoint(pressure))
            data.appendBigEndian(UInt32(0)) // action button: none for a finger
            data.appendBigEndian(UInt32(0)) // buttons: none for a finger
        case let .scroll(position, horizontal, vertical):
            data.append(3)
            data.append(position)
            data.appendBigEndian(UInt16(bitPattern: Self.signedFixedPoint(horizontal / 16)))
            data.appendBigEndian(UInt16(bitPattern: Self.signedFixedPoint(vertical / 16)))
            data.appendBigEndian(UInt32(0))
        case let .key(action, keycode, repeatCount, metaState):
            data.append(0)
            data.append(action.rawValue)
            data.appendBigEndian(keycode)
            data.appendBigEndian(repeatCount)
            data.appendBigEndian(metaState)
        case let .text(text):
            data.append(1)
            data.appendString(text, limit: Self.textLimit)
        case let .setClipboard(text, sequence, paste):
            data.append(9)
            data.appendBigEndian(sequence)
            data.append(paste ? 1 : 0)
            data.appendString(text, limit: Self.clipboardLimit)
        case .getClipboard:
            data.append(contentsOf: [8, 0])
        case let .backOrScreenOn(action):
            data.append(contentsOf: [4, action.rawValue])
        case .expandNotificationPanel:
            data.append(5)
        case .collapsePanels:
            data.append(7)
        case .rotateDevice:
            data.append(11)
        case .resetVideo:
            data.append(17)
        }
        return data
    }

    /// 0…1 in 16 bits, 1 as 0xffff.
    static func unsignedFixedPoint(_ value: Float) -> UInt16 {
        let scaled = UInt32(min(max(value, 0), 1) * 65_536)
        return UInt16(min(scaled, 0xFFFF))
    }

    /// -1…1 in 16 bits, 1 as 0x7fff.
    static func signedFixedPoint(_ value: Float) -> Int16 {
        let scaled = Int32(min(max(value, -1), 1) * 32_768)
        return Int16(min(scaled, 0x7FFF))
    }
}

/// A message from the device on the control socket.
enum ScrcpyDeviceMessage: Equatable, Sendable {
    case clipboard(String)
    case clipboardSet(sequence: UInt64)
    /// A HID device's output, which Yardlet does not use.
    case hidOutput(id: UInt16, Data)

    /// The first whole message at the start of `buffer` and its length; nil while it is incomplete.
    static func parse(_ buffer: Data) throws -> (ScrcpyDeviceMessage, Int)? {
        let bytes = [UInt8](buffer.prefix(5))
        guard let type = bytes.first else { return nil }
        switch type {
        case 0:
            guard buffer.count >= 5 else { return nil }
            let length = Int(buffer.bigEndian(UInt32.self, at: 1))
            guard length <= buffer.count - 5 else { return nil }
            let text = String(decoding: buffer.dropFirst(5).prefix(length), as: UTF8.self)
            return (.clipboard(text), 5 + length)
        case 1:
            guard buffer.count >= 9 else { return nil }
            return (.clipboardSet(sequence: buffer.bigEndian(UInt64.self, at: 1)), 9)
        case 2:
            guard buffer.count >= 5 else { return nil }
            let size = Int(buffer.bigEndian(UInt16.self, at: 3))
            guard size <= buffer.count - 5 else { return nil }
            return (.hidOutput(id: buffer.bigEndian(UInt16.self, at: 1), Data(buffer.dropFirst(5).prefix(size))), 5 + size)
        default:
            throw ScrcpyProtocolError("Unknown device message \(type)")
        }
    }
}

/// What the video socket carries, after the codec: a session for each capture (a new one when the device rotates),
/// then H.264 packets. A config packet (SPS and PPS) carries no picture: a decoder takes it with the next packet.
enum ScrcpyVideoEvent: Equatable, Sendable {
    case session(width: Int, height: Int)
    case packet(Data, presentationMicroseconds: UInt64?, isKeyFrame: Bool)
}

/// Reads the video socket's bytes as they come, in pieces of any size: the codec ID, then 12-byte headers, each a
/// session (its first bit set) or a media packet's flags, presentation time and length, followed by the packet.
struct ScrcpyVideoStreamReader: Sendable {
    static let h264 = UInt32(0x6832_3634)
    /// Larger than any frame a 1,280-pixel H.264 stream makes; a longer length is a broken stream.
    static let packetLimit = 16 << 20

    private var buffer = Data()
    private(set) var codec: UInt32?

    mutating func read(_ bytes: Data) throws -> [ScrcpyVideoEvent] {
        buffer.append(bytes)
        var events: [ScrcpyVideoEvent] = []
        if codec == nil {
            guard buffer.count >= 4 else { return events }
            let id = buffer.bigEndian(UInt32.self, at: 0)
            buffer.removeFirst(4)
            // 0 and 1 are not codecs: the device turned the stream off, or failed to configure it.
            guard id == Self.h264 else {
                throw ScrcpyProtocolError(id <= 1 ? "The device could not start the video stream" : "Unexpected video codec")
            }
            codec = id
        }
        while buffer.count >= 12 {
            let first = buffer.bigEndian(UInt64.self, at: 0)
            if first & (1 << 63) != 0 {
                let width = Int(buffer.bigEndian(UInt32.self, at: 4))
                let height = Int(buffer.bigEndian(UInt32.self, at: 8))
                buffer.removeFirst(12)
                guard width > 0, height > 0 else { throw ScrcpyProtocolError("Empty video size") }
                events.append(.session(width: width, height: height))
                continue
            }
            let length = Int(buffer.bigEndian(UInt32.self, at: 8))
            guard length > 0, length <= Self.packetLimit else { throw ScrcpyProtocolError("Bad video packet length") }
            guard buffer.count >= 12 + length else { break }
            let isConfig = first & (1 << 62) != 0
            let packet = Data(buffer[buffer.startIndex + 12 ..< buffer.startIndex + 12 + length])
            buffer.removeFirst(12 + length)
            events.append(.packet(packet, presentationMicroseconds: isConfig ? nil : first & ((1 << 61) - 1),
                                  isKeyFrame: first & (1 << 61) != 0))
        }
        // Keeps what is left contiguous from index 0 for the next read.
        buffer = Data(buffer)
        return events
    }
}

struct ScrcpyProtocolError: Error, Equatable, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(_ position: ScrcpyPosition) {
        appendBigEndian(position.x)
        appendBigEndian(position.y)
        appendBigEndian(position.screenWidth)
        appendBigEndian(position.screenHeight)
    }

    /// A 4-byte length and UTF-8 cut at a character within `limit` bytes.
    mutating func appendString(_ text: String, limit: Int) {
        var utf8 = Data(text.utf8)
        if utf8.count > limit {
            var end = limit
            // A continuation byte (10xxxxxx) is never where a character starts.
            while end > 0, utf8[utf8.startIndex + end] & 0xC0 == 0x80 { end -= 1 }
            utf8 = utf8.prefix(end)
        }
        appendBigEndian(UInt32(utf8.count))
        append(utf8)
    }
}

private extension Data {
    /// The big-endian integer at `offset` from the start.
    func bigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for byte in self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)] {
            value = value << 8 | T(byte)
        }
        return value
    }
}
