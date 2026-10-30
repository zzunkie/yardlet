#if DEBUG
import AppKit
import Foundation

/// QA for the address field's suggestions (docs/BROWSER_HOST.md, section 3, "Address suggestions") in the real panel,
/// run by `run-check.sh … --ui-fixture-browser-check-only=address-suggest`. Google's suggest service is a fake here
/// (`FakeGoogleSuggest`), so no request leaves the Mac. The person types the QA host twice and another page once, then
/// types into the field's editor as the keyboard does: the first row completes the host inline, ↓ and Escape move and
/// come back, ⇧fn⌫ removes a row from the history, the dropdown lies over the page and takes the click, Return opens
/// the first row, and turned off nothing is asked of Google. Captures `address-suggest-*-{light,dark}.png`.
@MainActor
final class BrowserHostAddressSuggestQA {
    private let output: URL
    private let base: String
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    init(output: URL, base: String) {
        self.output = output
        self.base = base
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGoogleSuggest.self]
        MacBrowserHost.shared.searchSuggest = BrowserSearchSuggestService(session: URLSession(configuration: configuration))
        guard let controller = await openPanel(), let view = controller.view, let window = view.window,
              let field = addressField(in: window) else { return await finish() }
        var frame = window.frame
        frame.size = NSSize(width: 1400, height: 900)
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .seconds(1))

        // The person's history: the responsive page typed once, the QA host typed twice, the second page by a link.
        for page in [base + "responsive", base, base + "second", base] {
            if page.hasSuffix("second"), let tab = controller.tab {
                tab.send(.navigate(tab: tab.id, url: page))
            } else {
                await type(page, into: field, controller)
                press(window, "\r", keyCode: 0x24)
            }
            _ = await waitUntil(.seconds(10)) { controller.tab?.currentURL == page && !controller.isLoading }
        }
        let history = MacBrowserHost.shared.addressHistory
        let host = BrowserAddressRanking.shownAddress(base)
        check("history: typed pages count as typed, a link's page as visited",
              history.pages[base]?.typedCount == 2 && history.pages[base + "responsive"]?.typedCount == 1
                && history.pages[base + "second"].map { $0.typedCount == 0 && $0.visitCount == 1 } == true,
              history.pages.values.map { "\($0.url) \($0.visitCount)/\($0.typedCount) \($0.title)" }.sorted().joined(separator: "; "))

        // Typing the host's start: the first row completes it inline, selected after the caret, from the first
        // character typed over the page's address.
        await type("1", into: field, controller)
        let first = (field.currentEditor() as? NSTextView).map { ($0.string, $0.selectedRange()) }
        check("typing: the first character over the page's address completes the host",
              first?.0 == host && first?.1 == NSRange(location: 1, length: (host as NSString).length - 1),
              "field \(first?.0 ?? "nil") selection \(first.map { NSStringFromRange($0.1) } ?? "nil")")
        await type("2", into: field, controller, appending: true)
        _ = await waitUntil(.seconds(3)) { controller.autocomplete.rows.contains { $0.fill.hasPrefix("12 fake") } }
        let editor = field.currentEditor() as? NSTextView
        let completion = String(host.dropFirst(2))
        check("typing: the typed host completes inline, selected after the caret",
              controller.autocomplete.rows.first?.destination == base && editor?.string == host
                && editor?.selectedRange() == NSRange(location: 2, length: (completion as NSString).length),
              "field \(editor?.string ?? "nil") selection \(editor.map { NSStringFromRange($0.selectedRange()) } ?? "nil"); "
                + rows(controller))
        check("typing: what was typed searches Google, and Google's suggestions come after it, before pages",
              kinds(controller).hasPrefix("page search search") && controller.autocomplete.rows.contains { $0.isVerbatim && $0.fill == "12" },
              rows(controller))
        let rowPoint = NSPoint(x: field.convert(field.bounds, to: nil).midX, y: field.convert(field.bounds, to: nil).minY - 4 - 4 - 15)
        let hit = window.contentView?.superview?.hitTest(rowPoint)
        check("dropdown: it lies over the page, which does not take its clicks",
              hit.map { !($0 === view || $0.isDescendant(of: view)) } ?? false, "hit \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
        await capture(window, "inline")

        // ↓ moves and the field shows the row; Escape comes back to the first row and its completion.
        press(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 0x7D)
        press(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 0x7D)
        let moved = controller.autocomplete.selected
        check("keys: ↓ selects the next rows and puts the row's text in the field",
              controller.autocomplete.selection == 2 && editor?.string == moved?.fill, "field \(editor?.string ?? "nil"); " + rows(controller))
        await capture(window, "selected")
        press(window, "\u{1B}", keyCode: 0x35)
        check("keys: Escape goes back to the first row and its completion",
              controller.autocomplete.selection == 0 && editor?.string == host
                && editor?.selectedRange() == NSRange(location: 2, length: (completion as NSString).length),
              "field \(editor?.string ?? "nil") selection \(editor.map { NSStringFromRange($0.selectedRange()) } ?? "nil")")

        // ⇧fn⌫ on the responsive page's row removes it from the history.
        await type("res", into: field, controller)
        _ = await waitUntil(.seconds(3)) {
            controller.autocomplete.rows.contains { $0.destination == self.base + "responsive" }
                && controller.autocomplete.rows.contains { $0.fill == "res fake one" }
        }
        if let index = controller.autocomplete.rows.firstIndex(where: { $0.destination == base + "responsive" }) {
            for _ in 0..<index { press(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 0x7D) }
        }
        press(window, String(UnicodeScalar(NSDeleteFunctionKey)!), keyCode: 0x75, modifiers: [.shift, .function])
        check("keys: Shift-Delete removes a page from the history and its row",
              history.pages[base + "responsive"] == nil && !controller.autocomplete.rows.contains { $0.destination == base + "responsive" },
              rows(controller))

        // Return opens the first row, as typed: the page the tab shows, typed again.
        await type("12", into: field, controller)
        press(window, "\r", keyCode: 0x24)
        _ = await waitUntil(.seconds(10)) { history.pages[self.base]?.typedCount == 3 && !controller.isLoading }
        check("keys: Return opens the completed host and counts it as typed",
              controller.tab?.currentURL == base && history.pages[base]?.typedCount == 3 && !controller.autocomplete.isOpen,
              "page \(controller.tab?.currentURL ?? "nil"), typed \(history.pages[base]?.typedCount ?? -1)")

        // A row opens when pressed. The QA app never becomes active, so its window is no key window and takes no
        // first click; the row is pressed through accessibility there, and the hit test above shows a click lands on
        // the dropdown.
        await type("sec", into: field, controller)
        _ = await waitUntil(.seconds(3)) {
            controller.autocomplete.rows.contains { $0.destination == self.base + "second" }
                && controller.autocomplete.rows.contains { $0.fill == "sec fake one" }
        }
        var how = "click"
        if let index = controller.autocomplete.rows.firstIndex(where: { $0.destination == base + "second" }) {
            let box = field.convert(field.bounds, to: nil)
            await click(window, at: NSPoint(x: box.midX, y: box.minY - 4 - 4 - 30 * CGFloat(index) - 15))
            if controller.autocomplete.isOpen, !window.isKeyWindow {
                how = "accessibility press (window not key: app active \(NSApp.isActive))"
                let pressed = pressButton(in: window.contentView, labelContaining: BrowserAddressRanking.shownAddress(base + "second"))
                how += pressed ? "" : ", no such button"
            }
        }
        let windowState = how
        _ = await waitUntil(.seconds(10)) { controller.tab?.currentURL == self.base + "second" && !controller.isLoading }
        check("mouse: a row opens its page when pressed (a click where the window is key, else its accessibility press)",
              controller.tab?.currentURL == base + "second" && !controller.autocomplete.isOpen,
              "page \(controller.tab?.currentURL ?? "nil"); \(windowState); " + rows(controller))

        // Turned off, nothing is asked of Google and the history still suggests.
        UserDefaults.yardlet.set(false, forKey: SearchSuggestionPreference.key)
        let asked = FakeGoogleSuggest.queries
        await type("12", into: field, controller)
        try? await Task.sleep(for: .milliseconds(600))
        check("setting: turned off, what is typed stays on the Mac and the history still suggests",
              FakeGoogleSuggest.queries == asked && controller.autocomplete.rows.first?.destination == base
                && !controller.autocomplete.rows.contains { $0.fill.contains("fake") },
              "asked \(FakeGoogleSuggest.queries.dropFirst(asked.count)); " + rows(controller))
        UserDefaults.yardlet.removeObject(forKey: SearchSuggestionPreference.key)
        record["googleQueries"] = .array(FakeGoogleSuggest.queries.map(JSONValue.string))
        press(window, "\u{1B}", keyCode: 0x35)
        press(window, "\u{1B}", keyCode: 0x35)
        await finish()
    }

    // MARK: Typing

    /// Text the keyboard types into the address field's editor, after the person clicks into it (all selected).
    private func type(_ text: String, into field: NSTextField, _ controller: BrowserHostPaneController, appending: Bool = false) async {
        if field.currentEditor() == nil || !controller.isEditingAddress {
            field.window?.makeFirstResponder(field)
            _ = await waitUntil(.seconds(2)) { controller.isEditingAddress }
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        if !appending { editor.selectAll(nil) }
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// A key as the keyboard sends it to the window, which passes it to the field's editor.
    private func press(_ window: NSWindow, _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    /// A click as the mouse sends it to the window, which is the app's key window as while the person types in it
    /// (the QA app itself stays inactive).
    private func click(_ window: NSWindow, at point: NSPoint) async {
        if !window.isKeyWindow { window.makeKey() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            window.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Presses the first button under `root` whose accessibility label holds `text`, with the app's accessibility on
    /// (`AXEnhancedUserInterface`, which SwiftUI builds its elements for), as VoiceOver would.
    private func pressButton(in root: NSView?, labelContaining text: String) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: attribute)
        defer { _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: false), with: attribute) }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if let label = child.accessibilityLabel?() ?? nil, label.contains(text),
                   (child.accessibilityRole?() ?? nil) == NSAccessibility.Role.button { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return root.flatMap(visit)?.accessibilityPerformPress?() ?? false
    }

    private func addressField(in window: NSWindow) -> NSTextField? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(window.contentView ?? NSView()).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == L10n.string("Search Google or type a URL") }
    }

    private func rows(_ controller: BrowserHostPaneController) -> String {
        controller.autocomplete.rows.enumerated().map { index, row in
            "\(index == controller.autocomplete.selection ? ">" : "")\(row.kind) \(row.fill)\(row.inlineCompletion.isEmpty ? "" : "[\(row.inlineCompletion)]") \(row.relevance)"
        }.joined(separator: " | ")
    }

    private func kinds(_ controller: BrowserHostPaneController) -> String {
        controller.autocomplete.rows.map { $0.kind == .page ? "page" : "search" }.joined(separator: " ")
    }

    // MARK: Panel and record

    private func openPanel() async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            check("panel: the task's browser panel opens", false, "no panel")
            return nil
        }
        _ = await waitUntil(.seconds(10)) { controller.hasTab && controller.view?.viewSurface != nil }
        return controller
    }

    /// The window in light and dark, as AppKit draws it (the QA app's own appearance; the window's follows Yardlet's
    /// appearance setting).
    private func capture(_ window: NSWindow, _ name: String) async {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(1))
            guard let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: output.appending(path: "address-suggest-\(name)-\(suffix).png"))
        }
        NSApp.appearance = nil
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string("address-suggest: " + name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        endBrowserQA(checks: checks)
    }
}

/// Google's suggest service for the QA: two suggestions for whatever was asked, and the questions it got.
final class FakeGoogleSuggest: URLProtocol {
    nonisolated(unsafe) static var queries: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.google.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "q" }?.value ?? ""
        Self.queries.append(query)
        let answer: [Any] = [query, [query + " fake one", query + " fake two"], ["", ""], [],
                             ["google:suggesttype": ["QUERY", "QUERY"], "google:suggestrelevance": [700, 650]]]
        let body = Data(")]}'\n".utf8) + ((try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/javascript; charset=UTF-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
