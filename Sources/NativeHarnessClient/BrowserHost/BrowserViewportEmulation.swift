import Foundation

/// A screen size a tab's page is shown at instead of its panel's own, as the Claude app's Browser pane
/// emulates one: the person picks it in the panel's Viewport menu, the agent with
/// `browser_resize`. It holds for the tab across reloads and navigations; the tab is drawn at this size
/// and the panel shows it scaled down when it is larger than the panel.
struct BrowserViewportEmulation: Equatable, Sendable {
    enum Owner: Equatable, Sendable {
        /// The panel's Viewport menu: it stays until the person or the agent changes it.
        case person
        /// `browser_resize`: it goes when the agent's turn ends, as the Claude app's does.
        case agent
    }

    /// One of the menu's and the tool's sizes.
    struct Preset: Equatable, Sendable {
        let id: String
        let width: Int
        let height: Int
    }

    static let mobile = Preset(id: "mobile", width: 375, height: 812)
    static let tablet = Preset(id: "tablet", width: 768, height: 1024)
    /// The menu's desktop sizes, as the Claude app lists them.
    static let laptop = Preset(id: "1280x800", width: 1280, height: 800)
    static let computer = Preset(id: "1024x768", width: 1024, height: 768)
    /// The largest side a size may have (the Claude app's limit).
    static let maximumSide = 9999

    var width: Int
    var height: Int
    /// A phone: a mobile viewport, touch, and Android Chrome's user agent. Narrower than 768 is a phone
    /// (the Claude app's rule); the tablet preset is only a size.
    var mobile: Bool
    var owner: Owner

    init(width: Int, height: Int, owner: Owner) {
        self.width = width
        self.height = height
        mobile = width < 768
        self.owner = owner
    }

    init(_ preset: Preset, owner: Owner) {
        self.init(width: preset.width, height: preset.height, owner: owner)
    }

    /// The preset of this size, if any.
    var preset: Preset? {
        [Self.mobile, Self.tablet, Self.laptop, Self.computer].first { $0.width == width && $0.height == height }
    }

    /// `Emulation.setDeviceMetricsOverride`: the page lays out at this size; a phone gets a mobile viewport and
    /// two device pixels per CSS pixel, any other size the display's own (0), as in the Claude app. The panel
    /// draws a larger size scaled down itself, so the page's coordinates stay the agent's.
    var deviceMetrics: [String: JSONValue] {
        ["width": .integer(Int64(width)), "height": .integer(Int64(height)),
         "deviceScaleFactor": .integer(mobile ? 2 : 0), "mobile": .bool(mobile)]
    }

    /// Android Chrome's user agent on a Pixel 8 for this Chromium's major version, the Claude app's phone.
    static func phoneUserAgent(chromeMajor: String) -> String {
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeMajor).0.0.0 Mobile Safari/537.36"
    }

    /// The client hints that go with it (`navigator.userAgentData`, `Sec-CH-UA-*`), with the browser's own brands.
    static func phoneUserAgentMetadata(brands: [JSONValue]) -> JSONValue {
        .object(["brands": .array(brands), "platform": .string("Android"), "platformVersion": .string("14.0.0"),
                 "architecture": .string(""), "model": .string("Pixel 8"), "mobile": .bool(true)])
    }

    /// The Chromium major version in a user agent ("Chrome/154.0.0.0").
    static func chromeMajor(in userAgent: String) -> String? {
        guard let range = userAgent.range(of: #"Chrome/\d+"#, options: .regularExpression) else { return nil }
        return String(userAgent[range].dropFirst("Chrome/".count))
    }

    /// Where the panel draws a page of `size` in a view of `bounds`: scaled down to fit when larger, never
    /// up, across the middle and from the top, as the Claude app places its emulated view.
    static func pageFrame(for size: CGSize, in bounds: CGSize) -> (origin: CGPoint, scale: CGFloat) {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return (CGPoint(x: 0, y: 0), 1) }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        return (CGPoint(x: ((bounds.width - size.width * scale) / 2).rounded(), y: 0), scale)
    }
}
