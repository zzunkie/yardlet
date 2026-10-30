import AppKit
import SwiftUI
import XCTest

/// The rendering tests' one way to draw the app's real SwiftUI views without showing anything:
/// no app launch, no visible window, no screen capture and no provider.
///
/// - `image(_:)` and `bitmap(_:)` draw plain SwiftUI content through `ImageRenderer`, at scale 2
///   unless asked otherwise.
/// - `Host` mounts a view in a borderless window that is never ordered on screen. Content that
///   AppKit draws (scroll views, text fields, menus, switches, spinners) needs it, because
///   `ImageRenderer` leaves such content as placeholders. Never order it front or open a menu or
///   popover from it (posted clicks, `performClick`, `popUp`): those come onto the real screen, and
///   a menu's tracking loop holds the person's keyboard and mouse until the test process ends.
/// - `accessibilityElements(in:)` lists what the accessibility tree exposes (role, label and
///   value, in reading order) so two renderers of the same conversation can be compared.
/// - `withAccessibilityTree(_:)` builds that tree for a search of a test's own, and
///   `NSView.pressAccessibilityElement(labelled:)` presses an element in it as an assistive app
///   would.
///
/// Review images go to `<repository>/.build/<folder>/` (`directory(_:)`). Images drawn in both
/// appearances are named `<name>-light.png` and `<name>-dark.png`.
@MainActor
enum WindowlessRender {
    /// The two appearances review images are drawn in, in the order tests draw them.
    enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        init(_ colorScheme: ColorScheme) {
            self = colorScheme == .dark ? .dark : .light
        }

        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
        var appKitName: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
        /// `light` or `dark`, the end of an image's file name.
        var suffix: String { rawValue }
    }

    /// A bitmap drawn in an unshown window, with that window's backing scale, which sets the
    /// bitmap's pixel size.
    struct Capture {
        let bitmap: NSBitmapImageRep
        let backingScaleFactor: CGFloat
    }

    /// The checkout this file belongs to (`Tests/NativeHarnessClientTests/Support/` is three
    /// folders down).
    nonisolated static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// `<repository>/.build/<folder>`, created if needed.
    static func directory(_ folder: String) throws -> URL {
        let directory = repositoryRoot.appending(path: ".build/\(folder)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - ImageRenderer

    /// `content` drawn by `ImageRenderer` at `scale`.
    static func image<Content: View>(
        _ content: Content, scale: CGFloat = 2, file: StaticString = #filePath, line: UInt = #line
    ) throws -> CGImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer drew nothing", file: file, line: line)
    }

    /// `content` drawn by `ImageRenderer` at `scale`, as a bitmap whose pixels can be read.
    static func bitmap<Content: View>(
        _ content: Content, scale: CGFloat = 2, file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: try image(content, scale: scale, file: file, line: line))
    }

    // MARK: - Unshown window

    /// A view mounted in a borderless window that is never ordered on screen. The window keeps
    /// the hosting view alive until `close()`.
    @MainActor
    final class Host<Content: View> {
        let hosting: NSHostingView<Content>
        let window: NSWindow

        /// - Parameter appearance: the window's AppKit appearance. Leave it out to keep the
        ///   window's default and rely on the content's own `colorScheme` environment.
        init(_ content: Content, size: NSSize, appearance: Appearance? = nil) {
            _ = NSApplication.shared
            hosting = NSHostingView(rootView: content)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if let appearance { window.appearance = NSAppearance(named: appearance.appKitName) }
            window.contentView = hosting
        }

        var backingScaleFactor: CGFloat { window.backingScaleFactor }

        /// Lays the view out and turns the main run loop for `interval`, `passes` times, so state
        /// changes, tasks and AppKit-backed content settle before the view is drawn.
        func settle(passes: Int = 8, interval: TimeInterval = 0.03) {
            for _ in 0..<passes {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(interval))
            }
        }

        /// Settles the view until `isDone`, giving the main actor back between passes. An `async`
        /// test holds the main actor while `settle()` turns the run loop, so a view's `.task` can
        /// start but cannot resume there to set its state; awaiting lets it. Fails after `timeout`.
        func settle(
            until isDone: () -> Bool, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
        ) async {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                settle(passes: 1)
                if isDone() { return }
                guard Date() < deadline else {
                    return XCTFail("The view did not settle in \(timeout) seconds", file: file, line: line)
                }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// The view as it is now drawn, after any pending layout.
        func capture(file: StaticString = #filePath, line: UInt = #line) throws -> Capture {
            Capture(bitmap: try WindowlessRender.capture(hosting, file: file, line: line),
                    backingScaleFactor: backingScaleFactor)
        }

        /// What the accessibility tree under the hosting view exposes now.
        ///
        /// - Parameter visibleOnly: list only elements whose frame lies at least partly inside the
        ///   window, leaving out what a scroll view keeps laid out above or below its viewport. A lazy
        ///   stack lays out a margin of rows around the viewport that depends on how it groups them.
        func accessibilityElements(visibleOnly: Bool = false) -> [AccessibilityElement] {
            hosting.layoutSubtreeIfNeeded()
            return WindowlessRender.accessibilityElements(in: hosting, within: visibleOnly ? window.frame : nil)
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// `content` mounted in an unshown window of `size`, settled for `passes` turns of the run
    /// loop, and drawn.
    static func hosted<Content: View>(
        _ content: Content, size: NSSize, appearance: Appearance? = nil, passes: Int = 8,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Capture {
        let host = Host(content, size: size, appearance: appearance)
        defer { host.close() }
        host.settle(passes: passes)
        return try host.capture(file: file, line: line)
    }

    /// Draws `content(appearance)` in an unshown window once per appearance, light first, and
    /// writes `<name>-light.png` and `<name>-dark.png` into `directory`. The window takes the
    /// same appearance; `content` sets its own `colorScheme`.
    @discardableResult
    static func hostedInBothAppearances<Content: View>(
        _ name: String, in directory: URL, size: NSSize, passes: Int = 8,
        file: StaticString = #filePath, line: UInt = #line,
        content: (Appearance) -> Content
    ) throws -> [Capture] {
        try Appearance.allCases.map { appearance in
            let capture = try hosted(content(appearance), size: size, appearance: appearance, passes: passes,
                                     file: file, line: line)
            try writePNG(capture.bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"),
                         file: file, line: line)
            return capture
        }
    }

    /// `view` as it is now drawn, after any pending layout.
    static func capture(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) throws
        -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                   "The view has no area to draw", file: file, line: line)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    // MARK: - PNG

    static func pngData(_ bitmap: NSBitmapImageRep, file: StaticString = #filePath, line: UInt = #line) throws
        -> Data {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
    }

    static func writePNG(
        _ bitmap: NSBitmapImageRep, to url: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try pngData(bitmap, file: file, line: line).write(to: url)
    }

    static func writePNG(_ image: CGImage, to url: URL, file: StaticString = #filePath, line: UInt = #line)
        throws {
        try writePNG(NSBitmapImageRep(cgImage: image), to: url, file: file, line: line)
    }

    /// Whether any pixel sampled every `step` pixels from (`start`, `start`) differs from the
    /// pixel at `background`: the view drew something besides its background.
    static func drawsContent(
        _ bitmap: NSBitmapImageRep, step: Int, from start: Int = 0, background: (x: Int, y: Int) = (0, 0)
    ) -> Bool {
        let backgroundColor = bitmap.colorAt(x: background.x, y: background.y)
        return stride(from: start, to: bitmap.pixelsHigh, by: step).contains { y in
            stride(from: start, to: bitmap.pixelsWide, by: step).contains { bitmap.colorAt(x: $0, y: y) != backgroundColor }
        }
    }

    // MARK: - Accessibility

    /// One element of the accessibility tree: its role (`AXButton`, `AXStaticText`, …), its
    /// label (or title) and its value, each empty when the element has none.
    struct AccessibilityElement: Equatable, Sendable, CustomStringConvertible {
        let role: String
        let label: String
        let value: String

        var description: String {
            [role, label.isEmpty ? nil : "“\(label)”", value.isEmpty ? nil : "= “\(value)”"]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Roles that only arrange other elements. Without a label or value they are passed
    /// through: their children are listed, they are not.
    private static let containerRoles: Set<NSAccessibility.Role> = [
        .group, .scrollArea, .splitGroup, .layoutArea, NSAccessibility.Role(rawValue: "AXOpaqueProviderGroup")
    ]

    /// The accessibility elements under `root` (not `root` itself), depth first in the order
    /// the tree gives them, which is reading order.
    ///
    /// - Rows a lazy stack has not laid out are not in the tree.
    /// - Scroll bars are left out; their values follow the scroll position, not the content.
    /// - Unlabelled containers are passed through (`containerRoles`).
    /// - Text drawn by an AppKit text view repeats itself as a SwiftUI child; the repeat is
    ///   left out.
    /// - With `visibleFrame` (screen coordinates), elements whose frame lies outside it are left
    ///   out; their children are still visited.
    ///
    /// The list reads with the tree built (`withAccessibilityTree(_:)`).
    static func accessibilityElements(in root: NSView, within visibleFrame: NSRect? = nil) -> [AccessibilityElement] {
        withAccessibilityTree { listedElements(in: root, within: visibleFrame) }
    }

    /// Runs `body` with the application's accessibility tree built, then puts the previous setting
    /// back, also when `body` throws. SwiftUI builds the tree only after an assistive app announces
    /// itself by setting `AXEnhancedUserInterface` on the application, as VoiceOver does. An
    /// application no assistive app has touched reads it as off, which is what comes back.
    static func withAccessibilityTree<T>(_ body: () throws -> T) rethrows -> T {
        let wasEnhanced = enhancedUserInterface
        enhancedUserInterface = true
        defer { enhancedUserInterface = wasEnhanced }
        return try body()
    }

    private static func listedElements(in root: NSView, within visibleFrame: NSRect?) -> [AccessibilityElement] {
        var elements: [AccessibilityElement] = []
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        // `clip` is the visible frame narrowed by every scroll area above the node.
        func visit(_ node: AnyObject, listedParent: AccessibilityElement?, clip: NSRect?) {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                guard let role = child.accessibilityRole?() ?? nil else {
                    visit(child, listedParent: listedParent, clip: clip)
                    continue
                }
                if role == .scrollBar { continue }
                let value: Any? = (child.accessibilityValue?() as Any??) ?? nil
                let element = AccessibilityElement(
                    role: role.rawValue,
                    label: text(attribute("accessibilityLabel", of: child) ?? attribute("accessibilityTitle", of: child)),
                    value: text(value)
                )
                let frame = child.accessibilityFrame?() ?? .zero
                let isVisible = clip.map { frame.height > 0 && frame.intersects($0) } ?? true
                let isListed = (child.isAccessibilityElement?() ?? false)
                    && !(containerRoles.contains(role) && element.label.isEmpty && element.value.isEmpty)
                    && element != listedParent && isVisible
                if isListed { elements.append(element) }
                let childClip = clip.map { role == .scrollArea ? $0.intersection(frame) : $0 }
                visit(child, listedParent: isListed ? element : listedParent, clip: childClip)
            }
        }
        visit(root, listedParent: nil, clip: visibleFrame)
        return elements
    }

    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as NSString

    /// The application's `AXEnhancedUserInterface`, reached by selector because the attribute
    /// API that names it is deprecated in favour of methods that do not cover it.
    private static var enhancedUserInterface: Bool {
        get {
            let value = NSApplication.shared.perform(
                NSSelectorFromString("accessibilityAttributeValue:"), with: enhancedUserInterfaceAttribute
            )?.takeUnretainedValue()
            return (value as? NSNumber)?.boolValue ?? false
        }
        set {
            _ = NSApplication.shared.perform(
                NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                with: NSNumber(value: newValue), with: enhancedUserInterfaceAttribute
            )
        }
    }

    /// An accessibility string as the object AppKit hands back. A menu button whose label has a font
    /// of its own gives an attributed title where the Swift method promises a `String`, and reading it
    /// through that method crashes.
    private static func attribute(_ name: String, of element: AnyObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: string
        case let attributed as NSAttributedString: attributed.string
        case let number as NSNumber: number.stringValue
        case let url as URL: url.absoluteString
        case nil: ""
        case let other?: String(describing: other)
        }
    }
}

extension NSView {
    /// Presses the first element under the view labelled `label`, as an assistive app would: through
    /// the accessibility tree, with no event on the screen.
    func pressAccessibilityElement(labelled label: String) -> Bool {
        pressAccessibilityElement { $0 == label }
    }

    /// The same for the first element whose label `matches`, for a label that reads on as it runs.
    /// `pressButton(labeled:)` presses only a button, where a container carries its button's label.
    func pressAccessibilityElement(where matches: (String) -> Bool) -> Bool {
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if let label = child.accessibilityLabel?() ?? nil, matches(label) { return child }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(self)?.accessibilityPerformPress?() ?? false
        }
    }
}
