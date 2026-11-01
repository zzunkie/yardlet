import Foundation

// Platform-neutral contract between Yardlet's browser panel (and the agent's CDP tools) and a
// browser engine host: CEF in a separate process on macOS, WebView2 on Windows. The panel sends
// commands and receives events; how they travel (a pipe, a named pipe, an in-process call) and
// how painted frames are shared (IOSurface, a DXGI handle) belong to the platform layer.
//
// Wire format, for transports that cross a process boundary: one JSON object per message, whose
// single key names the case and whose value holds the labelled fields — Swift's synthesized
// Codable form, e.g. `{"close":{"tab":3}}` or `{"shutdown":{}}`. `BrowserHostFraming` prefixes
// each message with its UTF-8 byte count. Coordinates are view points (DIP) with a top-left
// origin; text ranges count UTF-16 code units.

typealias BrowserTabID = Int

struct BrowserViewport: Codable, Equatable, Sendable {
    /// View size in points.
    var width: Double
    var height: Double
    /// Device pixels per point (2 on Retina displays).
    var scale: Double
    /// The view's position on screen in points, for popups and IME candidate windows.
    var screenX: Double = 0
    var screenY: Double = 0
    /// The refresh rate of the display the view is on, so the engine paints one frame per refresh
    /// (120 on ProMotion displays). Nil leaves the engine's default (60).
    var framesPerSecond: Int?

    /// Size for a tab the agent opens while no panel shows it; a panel resizes it on attach.
    static let offscreenDefault = BrowserViewport(width: 1280, height: 800, scale: 2)
}

/// Where Yardlet shows one of Chromium's own windows (`presentChromiumWindows`): over `frame`, a panel's page in
/// screen coordinates (AppKit's, from the bottom left), just above window `above` (that panel's window). Without a
/// frame the window stays where it is, over the windows in front.
struct BrowserChromiumWindowPlacement: Codable, Equatable, Sendable {
    var window: Int
    var frame: BrowserRect?
    var above: Int?
}

struct BrowserRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct BrowserModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    static let capsLock = BrowserModifiers(rawValue: 1 << 0)
    static let shift = BrowserModifiers(rawValue: 1 << 1)
    static let control = BrowserModifiers(rawValue: 1 << 2)
    static let option = BrowserModifiers(rawValue: 1 << 3)
    static let leftButton = BrowserModifiers(rawValue: 1 << 4)
    static let middleButton = BrowserModifiers(rawValue: 1 << 5)
    static let rightButton = BrowserModifiers(rawValue: 1 << 6)
    static let command = BrowserModifiers(rawValue: 1 << 7)
    static let numLock = BrowserModifiers(rawValue: 1 << 8)
    static let keypad = BrowserModifiers(rawValue: 1 << 9)
    /// For modifier key presses: which of the pair was pressed.
    static let isLeft = BrowserModifiers(rawValue: 1 << 10)
    static let isRight = BrowserModifiers(rawValue: 1 << 11)
    static let isRepeat = BrowserModifiers(rawValue: 1 << 13)
    static let preciseScrolling = BrowserModifiers(rawValue: 1 << 14)
}

enum BrowserMouseButton: String, Codable, Equatable, Sendable {
    case left, middle, right
}

struct BrowserMouseInput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case move, down, up, leave }
    var kind: Kind
    var x: Double
    var y: Double
    var button: BrowserMouseButton?
    var clickCount: Int = 1
    var modifiers: BrowserModifiers = []
}

struct BrowserWheelInput: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    /// Scroll distance in points; positive values scroll content toward the top-left.
    var deltaX: Double
    var deltaY: Double
    var modifiers: BrowserModifiers = []
}

struct BrowserKeyInput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A physical key press before any text it produces.
        case rawDown
        case up
        /// Text produced by a key press without an input method.
        case character
    }
    var kind: Kind
    /// Windows virtual-key code, which engines use for DOM `keyCode`. 229 marks a key an input
    /// method consumed.
    var windowsKeyCode: Int
    /// The platform's own key code (macOS virtual key code).
    var nativeKeyCode: Int
    var character: UInt16 = 0
    var unmodifiedCharacter: UInt16 = 0
    var modifiers: BrowserModifiers = []
    var isSystemKey = false
}

struct BrowserTextRange: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
}

struct BrowserCompositionUnderline: Codable, Equatable, Sendable {
    var range: BrowserTextRange
    var isThick: Bool
}

enum BrowserComposition: Codable, Equatable, Sendable {
    /// Replaces the marked (uncommitted) text.
    case set(text: String, underlines: [BrowserCompositionUnderline], selection: BrowserTextRange,
             replacement: BrowserTextRange?)
    /// Inserts committed text, ending any composition.
    case commit(text: String, replacement: BrowserTextRange?, relativeCursor: Int)
    /// Keeps the marked text as committed text.
    case finish(keepSelection: Bool)
    case cancel
}

enum BrowserNavigationAction: String, Codable, Equatable, Sendable {
    case back, forward, reload, stop
}

/// Editing commands the platform's Edit menu and shortcuts send to the focused page.
enum BrowserEditAction: String, Codable, Equatable, Sendable {
    case undo, redo, cut, copy, paste, delete, selectAll
}

enum BrowserZoomAction: String, Codable, Equatable, Sendable {
    case zoomIn, zoomOut, reset
}

/// Files dragged over the page from the platform (a Finder drag).
struct BrowserDragInput: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case enter, over, leave, drop }
    var phase: Phase
    var x: Double
    var y: Double
    /// Absolute file paths; only sent with `enter`.
    var files: [String] = []
    /// Allowed operations as `BrowserDragOperations` raw bits.
    var operations: Int = BrowserDragOperations.copy.rawValue
    var modifiers: BrowserModifiers = []
}

/// Drag operation bits, the same values as Chromium's drag operation mask.
struct BrowserDragOperations: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int
    static let copy = BrowserDragOperations(rawValue: 1)
    static let link = BrowserDragOperations(rawValue: 2)
    static let generic = BrowserDragOperations(rawValue: 4)
    static let move = BrowserDragOperations(rawValue: 16)
}

struct BrowserJavaScriptDialog: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case alert, confirm, prompt, beforeUnload }
    var id: Int
    var kind: Kind
    var message: String
    var defaultPrompt: String
    /// The page origin that asked, shown so a page cannot pose as Yardlet.
    var origin: String
    var isReload: Bool
}

struct BrowserFileDialog: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case open, openMultiple, openFolder, save }
    var id: Int
    var mode: Mode
    var title: String
    var defaultPath: String
    /// File name extensions without the dot; empty means any file.
    var extensions: [String]
}

/// A page asks for permissions Chrome asks the person about in its permission bubble.
struct BrowserPermissionPrompt: Codable, Equatable, Sendable {
    var id: Int
    var origin: String
    /// Chromium's names for them: notifications, geolocation, clipboard, multipleDownloads, storageAccess …
    var permissions: [String]
}

/// The person's answer to a permission prompt; Chromium keeps an allow or a block for the site.
enum BrowserPermissionResult: String, Codable, Equatable, Sendable {
    case allow, block, dismiss
}

/// A page asks to open an address Chromium leaves to another app: mailto:, tel:, zoommtg:, slack: …
struct BrowserExternalAppRequest: Codable, Equatable, Sendable {
    var url: String
    /// The origin of the document that asked (`https://zoom.us`); empty when it has none to name.
    var origin: String
    var userGesture: Bool
    /// The person told Chrome to always allow this origin's links of this kind (the tab's profile).
    var remembered: Bool
}

/// What came of a page's request to open another app (`BrowserHostClient`, Chrome's rules).
enum BrowserExternalAppOutcome: String, Codable, Equatable, Sendable {
    /// It opened without asking: a mail link, or a site the person always allowed for that kind of link.
    case opened
    /// The person is asked in the tab's panel (the bar's Open or Cancel).
    case asked
    /// No app on this Mac opens it.
    case noApp
    /// The page asked again before another click or key press, which Chrome does not let through.
    case ignored
}

struct BrowserDownload: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case started, inProgress, completed, cancelled, interrupted }
    var id: Int
    var state: State
    var fileName: String
    var path: String
    var receivedBytes: Int64
    /// -1 when the server did not say.
    var totalBytes: Int64
}

struct BrowserFindResult: Codable, Equatable, Sendable {
    var matches: Int
    var activeMatch: Int
    var isFinal: Bool
}

enum BrowserFrameLayer: String, Codable, Equatable, Sendable {
    /// The page.
    case view
    /// A widget drawn over the page, such as an open `<select>` list.
    case popup
}

struct BrowserFrame: Codable, Equatable, Sendable {
    var layer: BrowserFrameLayer
    /// Platform token for the shared pixel buffer (an IOSurface ID on macOS).
    var surface: UInt64
    var pixelWidth: Int
    var pixelHeight: Int
    var sequence: UInt64
    /// Host's monotonic clock at paint time, in nanoseconds (`DispatchTime.uptimeNanoseconds`).
    var paintedAt: UInt64
    /// `accelerated` when the engine handed over a GPU texture, `software` for a CPU buffer.
    var source: String
}

enum BrowserCursor: String, Codable, Equatable, Sendable {
    case pointer, crosshair, hand, text, wait, progress, help, move, notAllowed, none
    case resizeEast, resizeWest, resizeNorth, resizeSouth, resizeEastWest, resizeNorthSouth
    case resizeColumn, resizeRow, grab, grabbing, zoomIn, zoomOut, contextMenu, copy, alias
}

struct BrowserContextMenuItem: Codable, Equatable, Sendable {
    /// Nil for a separator.
    var commandID: Int?
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
}

struct BrowserContextMenu: Codable, Equatable, Sendable {
    var id: Int
    var x: Double
    var y: Double
    var items: [BrowserContextMenuItem]
}

// MARK: Accessibility (windowless engines report the page's tree; see BrowserAccessibilityTree)

/// One node of a page's accessibility tree, as the host trims it from the engine's (CEF:
/// `CEFAccessibilityReducer`). Every update carries the node's whole data. `bounds` are in the
/// engine's page pixels relative to the `container` node (the tree's root when nil), before that
/// container's scroll offset is taken off.
struct BrowserAccessibilityNode: Codable, Equatable, Sendable {
    var id: Int
    /// Chromium's role name: `button`, `link`, `textField`, `heading`, `staticText`, …
    var role: String
    var name: String?
    var value: String?
    var description: String?
    var placeholder: String?
    var roleDescription: String?
    var url: String?
    var inputType: String?
    var keyShortcuts: String?
    /// Chromium state names kept by the host: `focusable`, `editable`, `expanded`, `collapsed`,
    /// `invisible`, `ignored`, `multiline`, `protected`, `required`, `richlyEditable`, …
    var states: [String]?
    /// `true`, `false` or `mixed` for check boxes, radio buttons, switches and toggle buttons.
    var checked: String?
    var selected: Bool?
    /// `disabled` or `readOnly`.
    var restriction: String?
    var hasPopup: String?
    var invalid: Bool?
    /// Heading level.
    var level: Int?
    var rowCount: Int?
    var columnCount: Int?
    var rowIndex: Int?
    var columnIndex: Int?
    var rowSpan: Int?
    var columnSpan: Int?
    var positionInSet: Int?
    var setSize: Int?
    var rangeValue: Double?
    var rangeMinimum: Double?
    var rangeMaximum: Double?
    var selectionStart: Int?
    var selectionEnd: Int?
    var activeDescendant: Int?
    /// A frame's tree hosted by this node (an iframe).
    var childTree: String?
    var children: [Int]?
    var bounds: BrowserRect?
    var container: Int?
    var scrollX: Double?
    var scrollY: Double?

    func has(_ state: String) -> Bool { states?.contains(state) ?? false }
}

struct BrowserAccessibilityTreeData: Codable, Equatable, Sendable {
    /// Set for a frame's tree inside another tree; nil for the main frame.
    var parent: String?
    var focus: Int?
    var focusedTree: String?
    var title: String?
    var url: String?
    var loaded: Bool?
}

/// Chromium's tree update: first `clear` removes that node's descendants, then `nodes` replace or
/// add nodes; nodes no longer reachable from `root` are gone.
struct BrowserAccessibilityUpdate: Codable, Equatable, Sendable {
    var root: Int?
    var clear: Int?
    var treeData: BrowserAccessibilityTreeData?
    var nodes: [BrowserAccessibilityNode]
}

struct BrowserAccessibilityEvent: Codable, Equatable, Sendable {
    /// Chromium's event name: `focus`, `loadComplete`, `valueChanged`, …
    var type: String
    var id: Int?
}

struct BrowserAccessibilityTreeChange: Codable, Equatable, Sendable {
    /// The frame tree this change belongs to (one per frame document).
    var tree: String
    var updates: [BrowserAccessibilityUpdate]
    var events: [BrowserAccessibilityEvent]?
}

struct BrowserAccessibilityLocation: Codable, Equatable, Sendable {
    var tree: String
    var id: Int
    var container: Int?
    var bounds: BrowserRect
}

enum BrowserUnresponsiveAction: String, Codable, Equatable, Sendable {
    case wait, terminate
}

/// A task's own browser profile (docs/BROWSER_SESSION_ISOLATION.md): its folder key (`Task-<key>` beside the
/// default profile), and the profile a new folder copies its cookies from (another key; nil for the default
/// profile). Before the tab's page the profile also takes, from the default profile, the person's sign-ins it
/// follows and has not yet (`follow`, sites whose cookies it replaces) and, for a task that predates following,
/// the sites it has no cookie of (`fill`) (section 11).
struct BrowserTabProfile: Codable, Equatable, Sendable {
    var key: String
    var seedFrom: String?
    var follow: [String]? = nil
    var fill: Bool? = nil
}

/// A cookie another browser keeps (`BrowserLoginImport`), as Chromium stores it: `domain` with a leading dot for a
/// domain cookie and the host alone for a host-only one; CEF's SameSite (0 unspecified, 1 none, 2 lax, 3 strict)
/// and priority (-1 low, 0 medium, 1 high); `expires` in Chromium's microseconds since 1601, nil for a session
/// cookie.
struct BrowserImportedCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var sameSite: Int
    var priority: Int
    var expires: Int64?
}

enum BrowserHostCommand: Codable, Equatable, Sendable {
    /// Opens a tab; with a profile it shares that task profile's cookies and storage, else the default's.
    case open(tab: BrowserTabID, url: String, viewport: BrowserViewport, profile: BrowserTabProfile? = nil)
    /// Copies the cookies of `domain` and its subdomains from one profile to another (a key; nil for the
    /// default profile), with `replace` in place of the target's cookies of `domain`, answered with `cookiesCopied`
    /// once the target has them: a person's sign-in in a task's tab goes to the default profile and the tasks that
    /// follow it.
    case copyCookies(request: Int, from: String?, to: String?, domain: String, replace: Bool)
    /// Sums a hash of each cookie of `site` and its subdomains in a profile (a key; nil for the default profile),
    /// answered with `cookieDigest`: whether a sign-in changed them, without their values leaving the host.
    case cookieDigest(request: Int, profile: String?, site: String)
    /// Replaces the cookies of `sites` (each a domain with its subdomains) in one profile (a key; nil for the default
    /// profile) with another browser's, which the person chose to bring over; answered with `cookiesImported`. A task
    /// profile that has no folder yet is left as it is: it starts from the default profile's cookies.
    case importCookies(request: Int, to: String?, sites: [String], cookies: [BrowserImportedCookie])
    case resize(tab: BrowserTabID, viewport: BrowserViewport)
    case navigate(tab: BrowserTabID, url: String)
    case navigation(tab: BrowserTabID, action: BrowserNavigationAction)
    case mouse(tab: BrowserTabID, input: BrowserMouseInput)
    case wheel(tab: BrowserTabID, input: BrowserWheelInput)
    case key(tab: BrowserTabID, input: BrowserKeyInput)
    case composition(tab: BrowserTabID, composition: BrowserComposition)
    case edit(tab: BrowserTabID, action: BrowserEditAction)
    case zoom(tab: BrowserTabID, action: BrowserZoomAction)
    /// Finds text in the page; `findNext` continues the current search.
    case find(tab: BrowserTabID, text: String, forward: Bool, matchCase: Bool, findNext: Bool)
    case stopFinding(tab: BrowserTabID, clearSelection: Bool)
    case drag(tab: BrowserTabID, input: BrowserDragInput)
    case focus(tab: BrowserTabID, isFocused: Bool)
    case visibility(tab: BrowserTabID, isHidden: Bool)
    /// Answers a `contextMenu` event; nil command dismisses the menu.
    case contextMenuResult(tab: BrowserTabID, menu: Int, commandID: Int?)
    /// Answers a `javaScriptDialog` event. `text` is the prompt's input.
    case javaScriptDialogResult(tab: BrowserTabID, dialog: Int, accepted: Bool, text: String?)
    /// Answers a `fileDialog` event; nil paths cancel it.
    case fileDialogResult(tab: BrowserTabID, dialog: Int, paths: [String]?)
    case cancelDownload(tab: BrowserTabID, download: Int)
    /// Answers a `permissionPrompt` event.
    case permissionResult(tab: BrowserTabID, prompt: Int, result: BrowserPermissionResult)
    /// Turns the page's accessibility tree on or off. While on, the host sends the whole tree and
    /// then its changes (`accessibilityTree`, `accessibilityLocations`); while off the engine does
    /// no accessibility work.
    case accessibility(tab: BrowserTabID, isEnabled: Bool)
    /// A raw Chrome DevTools Protocol message.
    case devTools(tab: BrowserTabID, message: String)
    /// Answers Chromium's hang monitor for a tab it found unresponsive (`responsiveness`): wait another
    /// 15 seconds, or end the renderer (the page then reports `pageCrashed`).
    case unresponsive(tab: BrowserTabID, action: BrowserUnresponsiveAction)
    /// The memory saver: discards a hidden tab as Chrome's Memory Saver does, unless its page is one Chrome keeps
    /// (docs/BROWSER_HOST.md §3 "Memory saver"). The page's renderer ends and the tab keeps its address, title and
    /// history; `discarded` follows, or `discardRefused`. A reload (`navigation`) loads the page again. `urgent`: the
    /// Mac is short of memory, when Chrome does not keep a page for its notification permission.
    case discard(tab: BrowserTabID, urgent: Bool)
    case close(tab: BrowserTabID)
    /// Closes a tab as a person closes it: a page that asks before it is left (beforeunload) asks first, as a
    /// `javaScriptDialog`, and Stay keeps the tab open. Otherwise `closed` follows, as for `close`.
    case requestClose(tab: BrowserTabID)
    /// Keeps the person's "Always allow" for `origin` to open `scheme` addresses in their app (Chrome's profile
    /// setting), so the next such link from that site opens without asking.
    case allowExternalApp(tab: BrowserTabID, origin: String, scheme: String)
    /// A password the vault fills into the tab's page, in `values`' spellings: until the main frame starts another
    /// document, the host refuses every navigation of the tab (any frame, a redirect, a new window) whose address
    /// carries one, also percent-encoded or with `+` for a space, and says so with `filledValueBlocked`. Sent before
    /// the fill, so a page that submits on its own as the value goes in is held too.
    case guardFilledValues(tab: BrowserTabID, values: [String])
    /// Shows Chromium's own windows (the passkey dialog) where the person sees their tab, without activating the
    /// host: each placed window over the panel that shows its tab, just above that panel's window, as Chrome draws a
    /// tab's dialog over the tab (a window whose tab is not known where it is). A window not placed waits past the
    /// screens until a panel shows its tab.
    case presentChromiumWindows(placements: [BrowserChromiumWindowPlacement])
    /// Closes Chromium's own windows over these tabs (every window for nil) as a person pressing Escape would: the
    /// page's passkey request ends with NotAllowedError.
    case closeChromiumWindows(tabs: [BrowserTabID]?)
    /// Closes every tab and ends the host.
    case shutdown
}

enum BrowserHostEvent: Codable, Equatable, Sendable {
    case ready(processID: Int, engine: String, acceleratedPaint: Bool)
    /// An `importCookies` is done: the cookies it set (0 for a task profile it left as it is), or -1 when it could not run.
    case cookiesImported(request: Int, count: Int)
    /// A `copyCookies` is done: the cookies it set, or -1 when it could not run.
    case cookiesCopied(request: Int, count: Int)
    /// A `cookieDigest`'s sum, 16 hexadecimal digits; empty when it could not run.
    case cookieDigest(request: Int, digest: String)
    /// Chromium opened (true) or closed its last window of its own in the host, such as the passkey
    /// dialog, or the windows shown changed. While one is shown the host may be activated, so the window takes
    /// the keyboard. `kinds` (one per title): passkey, signIn (HTTP authentication), print, other; nil from a
    /// host before 2026-10-25, whose windows were passkey dialogs. `ids` are the windows' numbers and `tabs` the tab
    /// each is over (-1 when not known, as for the print dialog); nil from a host before 2026-10-27.
    case chromiumWindow(isShown: Bool, titles: [String]?, kinds: [String]? = nil, ids: [Int]? = nil, tabs: [BrowserTabID]? = nil)
    case opened(tab: BrowserTabID)
    case frame(tab: BrowserTabID, frame: BrowserFrame)
    /// Where the popup layer sits in view points; nil hides it.
    case popup(tab: BrowserTabID, rect: BrowserRect?)
    case cursor(tab: BrowserTabID, cursor: BrowserCursor)
    case contextMenu(tab: BrowserTabID, menu: BrowserContextMenu)
    /// Character bounds of the current composition in view points, for IME candidate windows.
    case compositionBounds(tab: BrowserTabID, rects: [BrowserRect])
    case address(tab: BrowserTabID, url: String)
    case title(tab: BrowserTabID, title: String)
    /// The page's icon, downloaded through the tab's own profile (`url` is where it came from); PNG,
    /// or empty when the page has none that loads.
    case favicon(tab: BrowserTabID, url: String, png: Data)
    case loading(tab: BrowserTabID, isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    case loadEnd(tab: BrowserTabID, url: String, status: Int)
    case loadError(tab: BrowserTabID, url: String, code: Int, message: String)
    case console(tab: BrowserTabID, level: Int, message: String, source: String, line: Int)
    /// The page asked for a new window (`window.open`, `target=_blank`, a modified click) and the host
    /// made none for it (no user gesture, or no room); the client opens `url` as another tab of the task,
    /// behind when `background`.
    case newWindow(tab: BrowserTabID, url: String, background: Bool, userGesture: Bool)
    /// The host made the page's new window as tab `tab`, which keeps `window.opener` (Chrome's
    /// pop-up); the client shows it as another tab of the opener's task, behind when `background`,
    /// or closes it.
    case popupOpened(tab: BrowserTabID, opener: BrowserTabID, url: String, background: Bool)
    /// Produced by the client, never sent by a host: the tab's page opened `newTab` (a new window
    /// request), or nil when the task had no room for another tab and the page went there itself.
    case openedTab(tab: BrowserTabID, newTab: BrowserTabID?, url: String)
    /// The page asked to open another app's address, which the host does not load; the client asks the person or
    /// opens it.
    case externalApp(tab: BrowserTabID, request: BrowserExternalAppRequest)
    /// Produced by the client, never sent by a host: what came of the page's request to open `url` in `app`
    /// (nil when no app opens it).
    case externalAppHandled(tab: BrowserTabID, url: String, app: String?, outcome: BrowserExternalAppOutcome)
    /// The main frame committed a new document (never for a same-document move): what was asked or blocked for
    /// the page before (a question to open an app, blocked pop-ups) goes.
    case newDocument(tab: BrowserTabID, url: String)
    /// A navigation the URL policy refused (`BrowserURLPolicy`).
    case navigationBlocked(tab: BrowserTabID, url: String)
    /// A navigation whose address carried a password the vault filled into the page (`guardFilledValues`), which
    /// the host refused before it was sent. The address is not given: it holds the password.
    case filledValueBlocked(tab: BrowserTabID)
    case tooltip(tab: BrowserTabID, text: String?)
    case javaScriptDialog(tab: BrowserTabID, dialog: BrowserJavaScriptDialog)
    /// The page went away while a dialog was open; any sheet for it should close.
    case javaScriptDialogReset(tab: BrowserTabID)
    case fileDialog(tab: BrowserTabID, dialog: BrowserFileDialog)
    /// Produced by the client, never sent by a host: the page's JavaScript dialog or file chooser `dialog` no longer
    /// waits (the panel or the agent answered it, or it went with its page).
    case dialogClosed(tab: BrowserTabID, dialog: Int)
    /// The page asks for permissions; answer with `permissionResult`.
    case permissionPrompt(tab: BrowserTabID, prompt: BrowserPermissionPrompt)
    /// The prompt went away: answered, or the page moved on or closed first.
    case permissionPromptDismissed(tab: BrowserTabID, prompt: Int)
    case download(tab: BrowserTabID, download: BrowserDownload)
    case findResult(tab: BrowserTabID, result: BrowserFindResult)
    /// The operation the page accepts for the current drag.
    case dragOperation(tab: BrowserTabID, operations: Int)
    /// Whether the page's focused field is a password field (an `<input type=password>` in any frame), sent
    /// when that changes; the panel turns on secure keyboard entry while it has the keyboard there.
    case passwordField(tab: BrowserTabID, isFocused: Bool)
    /// The tab's renderer process ended; the page must be reloaded.
    /// The tab's renderer ended: `status` is CEF's termination status ("crashed", "oom", "killed",
    /// "abnormal" …) and `code` its exit code (a signal number when it crashed).
    case pageCrashed(tab: BrowserTabID, reason: String, status: String? = nil, code: Int? = nil)
    /// Chromium's hang monitor: the tab's renderer has not handled input for 15 seconds (false), or
    /// answers again (true).
    case responsiveness(tab: BrowserTabID, isResponsive: Bool)
    /// The tab was discarded (`discard`): its page is gone until a reload.
    case discarded(tab: BrowserTabID)
    /// The host kept the tab `discard` named: its page is one Chrome would keep (`reason`: loading, capturing,
    /// audible, post, pdf, notifications, media, form, shared, unread, unanswered, shown, gone …).
    case discardRefused(tab: BrowserTabID, reason: String)
    /// Part of the page's accessibility tree changed (the whole tree first, after `accessibility`
    /// turned it on or a new document loaded).
    case accessibilityTree(tab: BrowserTabID, change: BrowserAccessibilityTreeChange)
    /// Nodes moved without other changes.
    case accessibilityLocations(tab: BrowserTabID, changes: [BrowserAccessibilityLocation])
    /// The page (main frame) scrolled; the offset is in view points. Chromium's accessibility
    /// updates do not carry plain scrolling, so the accessibility tree takes it from here.
    case scrollOffset(tab: BrowserTabID, x: Double, y: Double)
    /// A raw Chrome DevTools Protocol reply or event.
    case devTools(tab: BrowserTabID, message: String)
    /// The engine stopped painting the tab (after `visibility` hid it) and released the frame
    /// surfaces it had handed over; every frame event written before this one has been delivered,
    /// so the receiver may release its copies of those surfaces too.
    case hidden(tab: BrowserTabID)
    case closed(tab: BrowserTabID)
    /// Something the host could not do: for one tab (it could not open the tab: no browser was made), or
    /// for the whole host when `tab` is nil. `limit`: the most tabs the host holds, when that many were open.
    case failed(message: String, tab: BrowserTabID? = nil, limit: Int? = nil)
    /// Produced by the transport, never sent by a host: the host is gone.
    case terminated(reason: String)

    /// The tab an event belongs to; nil for host-wide events.
    var tab: BrowserTabID? {
        switch self {
        case .ready, .chromiumWindow, .cookiesImported, .cookiesCopied, .cookieDigest, .failed, .terminated: nil
        case .opened(let tab), .frame(let tab, _), .popup(let tab, _), .cursor(let tab, _),
             .contextMenu(let tab, _), .compositionBounds(let tab, _), .address(let tab, _),
             .title(let tab, _), .favicon(let tab, _, _), .loading(let tab, _, _, _), .loadEnd(let tab, _, _),
             .loadError(let tab, _, _, _), .console(let tab, _, _, _, _), .newWindow(let tab, _, _, _), .popupOpened(let tab, _, _, _),
             .openedTab(let tab, _, _), .externalApp(let tab, _), .externalAppHandled(let tab, _, _, _), .newDocument(let tab, _),
             .navigationBlocked(let tab, _), .filledValueBlocked(let tab), .tooltip(let tab, _), .javaScriptDialog(let tab, _),
             .javaScriptDialogReset(let tab), .fileDialog(let tab, _), .dialogClosed(let tab, _), .permissionPrompt(let tab, _),
             .permissionPromptDismissed(let tab, _), .download(let tab, _),
             .findResult(let tab, _), .dragOperation(let tab, _), .passwordField(let tab, _), .pageCrashed(let tab, _, _, _), .responsiveness(let tab, _),
             .discarded(let tab), .discardRefused(let tab, _),
             .accessibilityTree(let tab, _), .accessibilityLocations(let tab, _), .scrollOffset(let tab, _, _),
             .devTools(let tab, _), .hidden(let tab), .closed(let tab):
            tab
        }
    }
}

/// One live host. Implementations deliver events on the main actor, in order.
@MainActor
protocol BrowserHostConnection: AnyObject {
    var eventHandler: ((BrowserHostEvent) -> Void)? { get set }
    func send(_ command: BrowserHostCommand)
    /// Ends the host without waiting for it to close its tabs.
    func terminate()
    /// Blocks until the host has exited, at most `timeout`; false if it still runs. Application
    /// termination waits on it after `shutdown`, so Yardlet does not exit before Chromium has.
    func waitUntilExit(timeout: Duration) -> Bool
}

extension BrowserHostConnection {
    func waitUntilExit(timeout: Duration) -> Bool { false }
}
