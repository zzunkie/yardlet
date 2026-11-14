import Foundation

// A task's browser tabs on the remote (docs/REMOTE_PROTOCOL.md §15.25): the tabs the task's side panel lists, the
// watched tab's frames, and the person's clicks, scrolling and typing sent back to it.

extension RemoteProtocol {
    /// The largest frame a client may ask for, a side in image pixels, and the size asked for when it names none.
    public static let maxTabFrameSide = 2_560
    public static let defaultTabFrameWidth = 1_280
    public static let defaultTabFrameHeight = 1_600
    /// A frame larger than this is not sent (a JPEG of the largest side is a fraction of it).
    public static let maxTabFrameBytes = 4 * 1024 * 1024
    /// The longest text one `tabInput` types, in characters and in UTF-8 bytes (a character can be many).
    public static let maxTabInputCharacters = 4_000
    public static let maxTabInputBytes = 16_000
    /// The longest key name one `tabInput` presses, in UTF-8 bytes: a character with marks combined onto it is still
    /// one character however many bytes it takes.
    public static let maxTabKeyBytes = 64
    /// What a client's own screen may ask a tab to be drawn at, in CSS pixels (`RemoteTabViewport`).
    public static let tabViewportWidths = 200...1_920
    public static let tabViewportHeights = 200...2_560
    /// A frame not acknowledged within this long no longer holds back the next (a client that lost it).
    public static let tabFrameAckTimeout: TimeInterval = 10
    /// A connection's input that waits for the input before it: more is refused (`rateLimited`).
    public static let maxPendingTabInputs = 32
    /// The longest text a page's copy brings to the client (`tabCopied`), in UTF-8 bytes: a quarter of the largest
    /// frame, far past a key or a page of code, and a longer copy does not come at all rather than come cut.
    public static let maxTabCopyBytes = 1_048_576
    /// How long after a connection's click or key a page's own copy still counts as that input's, as Chromium's
    /// transient user activation lasts.
    public static let tabCopyWindow: TimeInterval = 5
}

/// The size a client asks a watched tab to be drawn at while it watches (a phone's screen, another computer's panel), in
/// CSS pixels; `mobile` draws it as a phone (touch, a phone's user agent), as the agent's `browser_resize` does.
public struct RemoteTabViewport: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var mobile: Bool?

    public init(width: Int, height: Int, mobile: Bool? = nil) {
        self.width = width
        self.height = height
        self.mobile = mobile
    }

    /// Inside the sizes a client may ask for.
    public var isAllowed: Bool {
        RemoteProtocol.tabViewportWidths.contains(width) && RemoteProtocol.tabViewportHeights.contains(height)
    }
}

/// Whether a connection's input to a tab may still go on: the server ends it when the watch ends, the connection
/// closes, the device is removed or the remote turns off, and the bridge checks it before each step it sends.
public final class RemoteTabPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    /// Names the watch's connection to the bridge: a page's copy goes to the connection whose input it follows.
    public let id = UUID()

    public init() {}

    public var isValid: Bool { lock.withLock { valid } }

    public func revoke() {
        lock.withLock { valid = false }
    }
}

/// A browser tab of a task, as the task's side panel lists it.
public struct RemoteBrowserTab: Codable, Equatable, Sendable {
    /// The side-panel tab: it stays the same when the tab's page is opened again in its place.
    public var tabId: String
    public var title: String?
    /// The page's address; only its origin while the address carries a value the password manager filled.
    public var url: String?
    /// The tab the task's panel shows in front.
    public var active: Bool?
    public var loading: Bool?
    public var canGoBack: Bool?
    public var canGoForward: Bool?
    /// What the tab waits on from the person (`handoff`, `passkey`, `signIn`, `permission`, `externalApp`,
    /// `javaScriptDialog`, `fileChooser`), the most pressing one.
    public var waiting: String?
    /// The agent handed this tab to the person: the request `answerHandoff` names (§15.18).
    public var requestId: String?
    /// The handoff's reason, in the agent's words.
    public var reason: String?
    /// The page's focused field is a password field: a client masks what it types into it.
    public var passwordField: Bool?
    /// The site's permission prompt up on the tab, also while `waiting` names a more pressing wait.
    public var permission: RemoteTabPermission?

    public init(tabId: String, title: String? = nil, url: String? = nil, active: Bool? = nil, loading: Bool? = nil,
                canGoBack: Bool? = nil, canGoForward: Bool? = nil, waiting: String? = nil, requestId: String? = nil,
                reason: String? = nil, passwordField: Bool? = nil, permission: RemoteTabPermission? = nil) {
        self.tabId = tabId
        self.title = title
        self.url = url
        self.active = active
        self.loading = loading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.waiting = waiting
        self.requestId = requestId
        self.reason = reason
        self.passwordField = passwordField
        self.permission = permission
    }
}

/// A site's permission prompt in a task's tab, as the Mac's browser panel shows it in its permission bar: the page's
/// origin and what it asks for, in Chromium's names (`camera`, `microphone`, `geolocation`, `notifications` …).
public struct RemoteTabPermission: Codable, Equatable, Sendable {
    /// The prompt, which `answerTabPermission` names: a newer prompt on the same tab has another. Chromium's 64-bit
    /// number, which can be past 2^53.
    public var prompt: Int
    public var origin: String
    public var permissions: [String]

    public init(prompt: Int, origin: String, permissions: [String]) {
        self.prompt = prompt
        self.origin = origin
        self.permissions = permissions
    }
}

/// The person's answer to a site's permission prompt, as the panel's Allow, Block and Close give it: Chromium keeps an
/// allow or a block for the site.
public enum RemoteTabPermissionAnswer: String, Codable, Sendable, CaseIterable {
    case allow, block, dismiss
}

/// One picture of a tab's visible page, and the page's size it shows.
public struct RemoteTabFrame: Equatable, Sendable {
    /// JPEG (the Mac's) or PNG bytes.
    public var image: Data
    public var mediaType: String
    /// The picture's size in pixels.
    public var width: Int
    public var height: Int
    /// The visible page's size in CSS pixels: what `tabInput` coordinates count in.
    public var viewportWidth: Double
    public var viewportHeight: Double

    public init(image: Data, mediaType: String = "image/jpeg", width: Int, height: Int, viewportWidth: Double,
                viewportHeight: Double) {
        self.image = image
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}

/// What the person does to the watched tab. Coordinates are CSS pixels from the visible page's top left, the
/// frame's `viewportWidth` by `viewportHeight`.
public struct RemoteTabInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A press and release at one point: a tap, or a click (`clickCount` 2 for a double click).
        case click
        /// A press, a move or a release (`action`), for a drag or a hover.
        case mouse
        /// A wheel at a point, `deltaX` and `deltaY` in CSS pixels; positive scrolls the page right and down.
        case scroll
        /// Text typed where the page's focus is, as the keyboard's input method committed it.
        case text
        /// A key with its modifiers (`Enter`, `Backspace`, `Shift+Tab`, `Meta+a`).
        case key
        /// The panel's Back, Forward and Reload (`action`).
        case navigate
    }

    public var kind: Kind
    public var x: Double?
    public var y: Double?
    /// `left` (when absent), `middle` or `right`.
    public var button: String?
    public var clickCount: Int?
    /// `mouse`: `down`, `move` or `up`. `navigate`: `back`, `forward` or `reload`.
    public var action: String?
    public var deltaX: Double?
    public var deltaY: Double?
    public var text: String?
    public var key: String?
    /// Held with a click, a press or a wheel: `shift`, `control`, `alt`, `meta`.
    public var modifiers: [String]?

    public init(kind: Kind, x: Double? = nil, y: Double? = nil, button: String? = nil, clickCount: Int? = nil,
                action: String? = nil, deltaX: Double? = nil, deltaY: Double? = nil, text: String? = nil, key: String? = nil,
                modifiers: [String]? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.action = action
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.text = text
        self.key = key
        self.modifiers = modifiers
    }

    public static func click(x: Double, y: Double, button: String? = nil, clickCount: Int? = nil,
                             modifiers: [String]? = nil) -> RemoteTabInput {
        RemoteTabInput(kind: .click, x: x, y: y, button: button, clickCount: clickCount, modifiers: modifiers)
    }

    public static func text(_ text: String) -> RemoteTabInput {
        RemoteTabInput(kind: .text, text: text)
    }

    public static func key(_ key: String) -> RemoteTabInput {
        RemoteTabInput(kind: .key, key: key)
    }

    public static let buttons: Set<String> = ["left", "middle", "right"]
    public static let mouseActions: Set<String> = ["down", "move", "up"]
    public static let navigateActions: Set<String> = ["back", "forward", "reload"]
    public static let modifierNames: Set<String> = ["shift", "control", "alt", "meta"]

    /// The fields each kind takes; a field of another kind's is refused, so nothing rides along unchecked.
    private static let fields: [Kind: Set<String>] = [
        .click: ["x", "y", "button", "clickCount", "modifiers"],
        .mouse: ["x", "y", "button", "clickCount", "action", "modifiers"],
        .scroll: ["x", "y", "deltaX", "deltaY", "modifiers"],
        .text: ["text"],
        .key: ["key"],
        .navigate: ["action"]
    ]

    private var present: [String] {
        [("x", x != nil), ("y", y != nil), ("button", button != nil), ("clickCount", clickCount != nil),
         ("action", action != nil), ("deltaX", deltaX != nil), ("deltaY", deltaY != nil), ("text", text != nil),
         ("key", key != nil), ("modifiers", modifiers != nil)].filter(\.1).map(\.0)
    }

    /// Why the Mac would not send it, or nil: a point, delta, button, action, key or text it lacks or that does not
    /// fit, or a field its kind does not take. Text over `maxTabInputCharacters` is `tooLarge`; a key name over
    /// `maxTabKeyBytes` is `badRequest`.
    public var problem: RemoteError? {
        func bad(_ message: String) -> RemoteError { RemoteError(.badRequest, message) }
        if let stray = present.first(where: { !(Self.fields[kind] ?? []).contains($0) }) {
            return bad("\(stray) does not go with \(kind.rawValue)")
        }
        func point() -> RemoteError? {
            guard let x, let y, x.isFinite, y.isFinite, (-1...100_000).contains(x), (-1...100_000).contains(y) else {
                return bad("\(kind.rawValue) needs x and y inside the page")
            }
            return nil
        }
        if let button, !Self.buttons.contains(button) { return bad("button must be left, middle or right") }
        if let modifiers, modifiers.count > 4 || !modifiers.allSatisfy(Self.modifierNames.contains) {
            return bad("modifiers are shift, control, alt and meta")
        }
        switch kind {
        case .click:
            if let clickCount, !(1...3).contains(clickCount) { return bad("clickCount is 1, 2 or 3") }
            return point()
        case .mouse:
            guard let action, Self.mouseActions.contains(action) else { return bad("mouse needs action down, move or up") }
            return point()
        case .scroll:
            let deltas = [deltaX ?? 0, deltaY ?? 0]
            guard deltas.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }), deltas.contains(where: { $0 != 0 }) else {
                return bad("scroll needs deltaX or deltaY")
            }
            return point()
        case .text:
            guard let text, !text.isEmpty else { return bad("text needs text") }
            return text.count > RemoteProtocol.maxTabInputCharacters || text.utf8.count > RemoteProtocol.maxTabInputBytes
                ? RemoteError(.tooLarge) : nil
        case .key:
            guard let key, !key.isEmpty, key.utf8.count <= RemoteProtocol.maxTabKeyBytes else {
                return bad("key needs a key name of at most \(RemoteProtocol.maxTabKeyBytes) bytes")
            }
            return nil
        case .navigate:
            guard let action, Self.navigateActions.contains(action) else {
                return bad("navigate needs action back, forward or reload")
            }
            return nil
        }
    }
}

/// The tabs a connection watches, by task: the tab whose frames it takes, or none while it only follows the list, and
/// the size it asks the tab to be drawn at.
public struct RemoteTabWatch: Hashable, Sendable {
    public var taskID: String
    public var tabID: String?
    public var viewport: RemoteTabViewport?

    public init(taskID: String, tabID: String?, viewport: RemoteTabViewport? = nil) {
        self.taskID = taskID
        self.tabID = tabID
        self.viewport = viewport
    }
}
