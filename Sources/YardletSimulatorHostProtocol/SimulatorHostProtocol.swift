import Foundation

// The contract between Yardlet and the simulator host (`Yardlet Simulator Host.app`), the helper that shows and
// drives iOS simulators through Xcode's SimulatorKit. Yardlet sends commands on the helper's standard input and
// reads events from its standard output; each message is one JSON object in Swift's synthesized Codable form
// (`{"attach":{"device":"…"}}`), after its UTF-8 byte count (`SimulatorHostFraming`). Frames travel as IOSurfaces
// over a Mach port, as the browser host's do (YardletSurfacePort).
//
// The helper takes only these typed commands; none of them names a class, a selector or a path. A device is a
// UUID, so a malformed one does not decode, and a point is normalized to the screen, so one outside 0...1 does
// not decode either: the helper checks again what Yardlet already checked.

/// A point on a device's screen, from its top left corner, as a fraction of the screen's width and height.
public struct SimulatorPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    /// Nil unless both coordinates are finite and within 0...1.
    public init?(x: Double, y: Double) {
        guard Self.isNormalized(x), Self.isNormalized(y) else { return nil }
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        guard let point = SimulatorPoint(x: x, y: y) else {
            throw DecodingError.dataCorruptedError(forKey: .x, in: container,
                                                   debugDescription: "a point's coordinates are fractions of the screen, 0...1")
        }
        self = point
    }

    private static func isNormalized(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 1 }
}

public enum SimulatorTouchPhase: String, Codable, Equatable, Sendable {
    case down, move, up
}

/// A button or a key: pressed and held, let go, or both in turn.
public enum SimulatorPressPhase: String, Codable, Equatable, Sendable {
    case down, up, press
}

/// The device's hardware buttons. Home and lock go to the legacy button service; the others are HID usages of the
/// device's chrome (volume, power, the action button).
public enum SimulatorButton: String, Codable, Equatable, Sendable, CaseIterable {
    case home, lock, volumeUp, volumeDown, power, action
}

public enum SimulatorImageFormat: String, Codable, Equatable, Sendable {
    case png, jpeg
}

/// A key on the keyboard usage page (0x07): letters through the right GUI key.
public struct SimulatorKeyUsage: Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init?(_ rawValue: UInt32) {
        guard Self.range.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(UInt32.self)
        guard let usage = SimulatorKeyUsage(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a keyboard usage (0x04...0xE7)"))
        }
        self = usage
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let range: ClosedRange<UInt32> = 0x04...0xE7
}

/// Text for the hardware keyboard path: printable ASCII, newlines and tabs, at most `maximumLength` characters.
public struct SimulatorKeyboardText: Codable, Equatable, Sendable {
    public static let maximumLength = 1000
    public let text: String

    public init?(_ text: String) {
        guard text.count <= Self.maximumLength, text.unicodeScalars.allSatisfy({ SimulatorKeyboard.stroke(for: $0) != nil })
        else { return nil }
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let text = SimulatorKeyboardText(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "keyboard text is printable ASCII, newlines and tabs, up to \(Self.maximumLength) characters"))
        }
        self = text
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public enum SimulatorHostCommand: Codable, Equatable, Sendable {
    /// Starts using a booted device: its screen and its input. Answered with `attached` or `deviceFailed`.
    case attach(device: UUID)
    /// Lets go of the device. The helper ends a minute after it lets go of its last device.
    case detach(device: UUID)
    /// Sends the device's frames for one subscriber (a panel), scaled to fit within the pixel size it asks for. With
    /// several subscribers the frames fit the largest of their sizes. Until the first change on screen the helper
    /// sends the screen as it is.
    case startFrames(device: UUID, subscription: Int, pixelWidth: Int, pixelHeight: Int)
    /// Ends a subscription; with none left the helper stops copying frames.
    case stopFrames(device: UUID, subscription: Int)
    /// The screen as an image of the device's size in points. Answered with `screenshot` or `requestFailed`.
    case screenshot(request: Int, device: UUID, format: SimulatorImageFormat)
    /// One finger.
    case touch(device: UUID, phase: SimulatorTouchPhase, point: SimulatorPoint)
    case button(device: UUID, button: SimulatorButton, phase: SimulatorPressPhase)
    case key(device: UUID, usage: SimulatorKeyUsage, phase: SimulatorPressPhase)
    /// Types the text on the hardware keyboard, key by key, as the device's keyboard layout reads the keys.
    case typeText(device: UUID, text: SimulatorKeyboardText)
    /// The accessibility elements of the app in front, as the device's accessibility runtime describes them, their
    /// frames in points. Answered with `accessibilityTree` or `requestFailed`.
    case accessibilityTree(request: Int, device: UUID)
    /// Whether the helper holds screen recording permission, can read the home folder or can open a network
    /// connection (it should do none of these), checked without asking the person or sending anything. Answered with
    /// `diagnosis`.
    case diagnose(request: Int)
}

/// A device's screen: the one shown, for a device with more than one.
public struct SimulatorScreen: Codable, Equatable, Sendable {
    public var screenID: UInt32
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point.
    public var scale: Double

    public init(screenID: UInt32, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.screenID = screenID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public var pointWidth: Int { Int((Double(pixelWidth) / scale).rounded()) }
    public var pointHeight: Int { Int((Double(pixelHeight) / scale).rounded()) }
}

/// A copy of the screen in one of the helper's surfaces.
public struct SimulatorFrame: Codable, Equatable, Sendable {
    public var device: UUID
    /// The IOSurface's ID.
    public var surface: UInt32
    /// The helper sent this surface's Mach port just before this event: the receiver takes it from the port and
    /// replaces any surface it holds under the same ID.
    public var fresh: Bool
    /// Increases when the helper replaces its surfaces (another size); surfaces of an earlier pool are not used again.
    public var pool: UInt64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var sequence: UInt64
    /// The helper's monotonic clock when the device drew the frame, in nanoseconds (`DispatchTime.uptimeNanoseconds`).
    public var drawnAt: UInt64

    public init(device: UUID, surface: UInt32, fresh: Bool, pool: UInt64, pixelWidth: Int, pixelHeight: Int,
                sequence: UInt64, drawnAt: UInt64) {
        self.device = device
        self.surface = surface
        self.fresh = fresh
        self.pool = pool
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sequence = sequence
        self.drawnAt = drawnAt
    }
}

public struct SimulatorScreenshot: Codable, Equatable, Sendable {
    public var device: UUID
    public var format: SimulatorImageFormat
    public var width: Int
    public var height: Int
    public var data: Data

    public init(device: UUID, format: SimulatorImageFormat, width: Int, height: Int, data: Data) {
        self.device = device
        self.format = format
        self.width = width
        self.height = height
        self.data = data
    }
}

/// An element of an app's accessibility tree: what it is, what it says, and where it is on the screen in points from
/// its top left.
public struct SimulatorAccessibilityElement: Codable, Equatable, Sendable {
    /// The macOS accessibility role the element translates to (`AXButton`, `AXTextField`, `AXStaticText`).
    public var role: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var children: [SimulatorAccessibilityElement]

    public init(role: String, label: String? = nil, value: String? = nil, identifier: String? = nil, x: Double,
                y: Double, width: Double, height: Double, children: [SimulatorAccessibilityElement] = []) {
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.children = children
    }
}

public enum SimulatorHostEvent: Codable, Equatable, Sendable {
    /// SimulatorKit loaded from the Xcode named by version (`27.2 (27B52)`), with every part the helper uses.
    /// `capabilities` names the optional ones it found: `digitizerTouch` (touches reach system layers such as
    /// Notification Center; without it touches go the mouse way).
    case ready(xcode: String, capabilities: [String])
    /// This Xcode lacks parts the helper needs (`missing` names them). The helper ends after this event.
    case unsupported(xcode: String, missing: [String])
    case attached(device: UUID, screen: SimulatorScreen)
    /// The shown screen changed: its size, or which screen of a device with two.
    case screenChanged(device: UUID, screen: SimulatorScreen)
    /// The helper let go of the device: Yardlet asked, or the device shut down.
    case detached(device: UUID, reason: String)
    case deviceFailed(device: UUID, message: String)
    case frame(SimulatorFrame)
    case screenshot(request: Int, image: SimulatorScreenshot)
    /// The app in front's elements, in the tree they form; `truncated` when the helper stopped at its limit of elements
    /// or time.
    case accessibilityTree(request: Int, elements: [SimulatorAccessibilityElement], truncated: Bool)
    case requestFailed(request: Int, message: String)
    /// Input the device did not take, or a command for a device the helper has not attached.
    case commandFailed(device: UUID, message: String)
    case diagnosis(request: Int, processID: Int32, screenCaptureAccess: Bool, homeReadable: Bool, networkReachable: Bool)
}

/// Stream framing: a 4-byte big-endian length, then that many bytes of UTF-8 JSON.
public enum SimulatorHostFraming {
    public static let maximumMessageLength = 64 * 1024 * 1024

    public static func frame<T: Encodable>(_ message: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let body = try encoder.encode(message)
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    public struct MessageTooLong: Error, Equatable {
        public let length: Int
    }

    /// Collects bytes from a stream and returns each complete message body.
    public struct Reader: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var messages: [Data] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= SimulatorHostFraming.maximumMessageLength else { throw MessageTooLong(length: length) }
                guard buffer.count >= 4 + length else { break }
                messages.append(Data(buffer[start + 4..<start + 4 + length]))
                buffer.removeSubrange(start..<start + 4 + length)
            }
            return messages
        }
    }
}
