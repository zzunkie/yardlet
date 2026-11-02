import Foundation

/// What picking an element on a page found: the element's context for the task's next message
/// (`BrowserComment`) and its capture as PNG.
struct BrowserPickedElement: Equatable, Sendable {
    var comment: BrowserComment
    var png: Data?
}

/// Picks an element on a tab's page the way Chrome DevTools' "Select an element" does: Chromium's
/// own inspect mode outlines the element under the pointer (`Overlay.setInspectMode`, DevTools'
/// colors, as the Claude app's element selection uses it) and reports the one clicked
/// (`Overlay.inspectNodeRequested`). The element's selector, its HTML without what was typed into its
/// fields, its main computed styles and its capture are read over CDP. Nothing stays on the page:
/// stopping turns the mode and the domains it needed off.
@MainActor
final class BrowserElementPicker {
    private let devTools: BrowserDevToolsClient
    private var observer: UUID?
    /// The element the person clicked, by its backend node; the page's Escape ends the mode too.
    var onPick: ((Int64) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isPicking = false

    init(devTools: BrowserDevToolsClient) {
        self.devTools = devTools
    }

    /// DevTools' highlight: content blue, padding green, border yellow, margin orange, with the
    /// element's name and size beside it.
    static let highlight: JSONValue = .object([
        "showInfo": .bool(true), "showStyles": .bool(false), "showAccessibilityInfo": .bool(false),
        "contentColor": color(111, 168, 220, 0.66), "paddingColor": color(147, 196, 125, 0.55),
        "borderColor": color(255, 229, 153, 0.66), "marginColor": color(246, 178, 107, 0.66)
    ])

    private static func color(_ red: Int64, _ green: Int64, _ blue: Int64, _ alpha: Double) -> JSONValue {
        .object(["r": .integer(red), "g": .integer(green), "b": .integer(blue), "a": .number(alpha)])
    }

    func start() async throws {
        guard !isPicking else { return }
        isPicking = true
        observer = devTools.observeEvents { [weak self] method, params in
            guard let self, self.isPicking else { return }
            switch method {
            case "Overlay.inspectNodeRequested":
                if let node = params["backendNodeId"]?.integerValue { self.onPick?(node) }
            case "Overlay.inspectModeCanceled":
                self.onCancel?()
            default:
                break
            }
        }
        do {
            // Overlay needs the DOM domain.
            _ = try await devTools.send("DOM.enable", timeout: .seconds(10))
            _ = try await devTools.send("Overlay.enable", timeout: .seconds(10))
            _ = try await devTools.send("Overlay.setInspectMode", [
                "mode": .string("searchForNode"), "highlightConfig": Self.highlight
            ], timeout: .seconds(10))
        } catch {
            await stop()
            throw error
        }
    }

    /// Leaves the page as it was: no outline, no inspect mode, no domain left on.
    func stop() async {
        guard isPicking else { return }
        isPicking = false
        if let observer { devTools.stopObservingEvents(observer) }
        observer = nil
        _ = try? await devTools.send("Overlay.setInspectMode", ["mode": .string("none"), "highlightConfig": .object([:])],
                                     timeout: .seconds(5))
        _ = try? await devTools.send("Overlay.disable", timeout: .seconds(5))
        _ = try? await devTools.send("DOM.disable", timeout: .seconds(5))
    }

    /// The clicked element's context and capture. The outline is off by then (`stop`), so the capture
    /// shows the page as the person sees it, with every typed value in it hidden while it is taken.
    /// `scrub` takes out what no tool result carries (values the password manager filled, keys and tokens), and no
    /// attachment either; with `hidesCredentials`, the capture covers the keys and tokens the page shows too.
    static func describe(_ node: Int64, pageURL: String, on devTools: BrowserDevToolsClient,
                         scrub: (String) -> String, hidesCredentials: Bool) async throws -> BrowserPickedElement {
        let resolved = try await devTools.send("DOM.resolveNode", ["backendNodeId": .integer(node)], timeout: .seconds(10))
        guard let object = resolved["object"]?["objectId"]?.stringValue else {
            throw BrowserDevToolsError.notSent("DOM.resolveNode")
        }
        defer { Task { _ = try? await devTools.send("Runtime.releaseObject", ["objectId": .string(object)]) } }
        let described = try await devTools.send("Runtime.callFunctionOn", [
            "functionDeclaration": .string(describeElement), "objectId": .string(object),
            // The page gives more than the message keeps: the cut comes after the vault's values are out,
            // so none is left cut in two.
            "arguments": .array([.object(["value": .integer(Int64(BrowserComment.htmlLimit * 4))])]),
            "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        guard described["exceptionDetails"] == nil, let value = described["result"]?["value"] else {
            throw BrowserDevToolsError.protocolError("Runtime.callFunctionOn", described["exceptionDetails"] ?? .null)
        }
        let metrics = try await devTools.send("Page.getLayoutMetrics", timeout: .seconds(10))["cssVisualViewport"]
        let viewport = (width: metrics?["clientWidth"]?.doubleValue ?? 0, height: metrics?["clientHeight"]?.doubleValue ?? 0)
        let box = try? await bounds(of: node, on: devTools)
        let tag = value["tag"]?.stringValue ?? "element"
        var words = scrub(value["label"]?.stringValue ?? "")
        if words.count > 80 { words = String(words.prefix(79)) + "…" }
        var html = BrowserCommentPrompt.sectionSafeHTML(scrub(value["html"]?.stringValue ?? ""))
        let htmlIsCut = value["cut"]?.boolValue == true || html.count > BrowserComment.htmlLimit
        if html.count > BrowserComment.htmlLimit { html = String(html.prefix(BrowserComment.htmlLimit)) }
        let comment = BrowserComment(
            pageURL: scrub(pageURL), frameURL: value["frameURL"]?.stringValue.map(scrub),
            target: words.isEmpty ? tag : "\(tag) \"\(words)\"",
            selector: scrub(value["selector"]?.stringValue ?? tag),
            html: html, htmlIsCut: htmlIsCut,
            styles: (value["styles"]?.arrayValue ?? []).compactMap { pair in
                guard let pair = pair.arrayValue, pair.count == 2, let name = pair[0].stringValue,
                      let style = pair[1].stringValue else { return nil }
                return BrowserComment.Style(name: name, value: scrub(style))
            },
            x: Int(((box?.x ?? 0) + (box?.width ?? 0) / 2).rounded()),
            y: Int(((box?.y ?? 0) + (box?.height ?? 0) / 2).rounded()),
            viewportWidth: Int(viewport.width.rounded()), viewportHeight: Int(viewport.height.rounded()))
        let png = try? await CredentialText.covering(devTools, when: hidesCredentials, wait: .seconds(30)) {
            try await capture(box, viewport: viewport, metrics: metrics, on: devTools)
        }
        return BrowserPickedElement(comment: comment, png: png)
    }

    /// The element's box in viewport CSS pixels, as `DOM.getContentQuads` gives it for the main frame.
    private static func bounds(of node: Int64, on devTools: BrowserDevToolsClient) async throws
        -> (x: Double, y: Double, width: Double, height: Double) {
        let quads = try await devTools.send("DOM.getContentQuads", ["backendNodeId": .integer(node)], timeout: .seconds(10))
        var found: (x: Double, y: Double, width: Double, height: Double)?
        for quad in quads["quads"]?.arrayValue ?? [] {
            let points = quad.arrayValue?.compactMap(\.doubleValue) ?? []
            guard points.count == 8 else { continue }
            let xs = stride(from: 0, to: 8, by: 2).map { points[$0] }, ys = stride(from: 1, to: 8, by: 2).map { points[$0] }
            let box = (x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            // An inline element wrapping across lines has a quad per line: the capture takes them all.
            if let union = found {
                let left = min(union.x, box.x), top = min(union.y, box.y)
                found = (left, top, max(union.x + union.width, box.x + box.width) - left,
                         max(union.y + union.height, box.y + box.height) - top)
            } else {
                found = box
            }
        }
        guard let found, found.width >= 1, found.height >= 1 else { throw BrowserDevToolsError.notSent("DOM.getContentQuads") }
        return found
    }

    /// The part of the visible page the element covers, with a little of what is around it, at most
    /// `longestSide` pixels on its longer side. Typed values in it are hidden for the capture.
    static let margin = 24.0
    static let longestSide = 1_600.0

    private static func capture(_ box: (x: Double, y: Double, width: Double, height: Double)?,
                                viewport: (width: Double, height: Double), metrics: JSONValue?,
                                on devTools: BrowserDevToolsClient) async throws -> Data? {
        guard let box, viewport.width >= 1, viewport.height >= 1 else { return nil }
        let left = max(0, box.x - margin), top = max(0, box.y - margin)
        let right = min(viewport.width, box.x + box.width + margin), bottom = min(viewport.height, box.y + box.height + margin)
        guard right - left >= 1, bottom - top >= 1 else { return nil }
        let ratio = try await devTools.send("Runtime.evaluate", ["expression": .string("devicePixelRatio"),
                                                                 "returnByValue": .bool(true)])["result"]?["value"]?.doubleValue ?? 1
        let scale = min(1, longestSide / (max(right - left, bottom - top) * max(ratio, 0.1)))
        // A picture whose typed values could not be hidden is not taken.
        guard let hidden = try? await devTools.send("Runtime.evaluate", [
            "expression": .string("(\(hideTypedValues))(\(left), \(top), \(right - left), \(bottom - top))"),
            "returnByValue": .bool(true)
        ]), hidden["exceptionDetails"] == nil, let count = hidden["result"]?["value"]?.integerValue else { return nil }
        let covered = count > 0
        let shot: JSONValue
        do {
            shot = try await devTools.send("Page.captureScreenshot", [
                "format": .string("png"),
                "clip": .object([
                    "x": .number(left + (metrics?["pageX"]?.doubleValue ?? 0)), "y": .number(top + (metrics?["pageY"]?.doubleValue ?? 0)),
                    "width": .number(right - left), "height": .number(bottom - top), "scale": .number(scale)
                ])
            ], timeout: .seconds(15))
        } catch {
            if covered { await showTypedValues(on: devTools) }
            throw error
        }
        if covered { await showTypedValues(on: devTools) }
        return shot["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
    }

    private static func showTypedValues(on devTools: BrowserDevToolsClient) async {
        _ = try? await devTools.send("Runtime.evaluate", ["expression": .string(showTypedValuesScript)])
    }

    // MARK: Page scripts

    /// Runs with the element as `this`: a selector that finds it in its document (an ID, at most two
    /// classes and `:nth-of-type`, as the Codex app writes one, climbing only until it is unique), its
    /// outer HTML from a copy whose fields hold no typed value (no `value` on inputs other than buttons,
    /// no text in text areas, no chosen option), cut at `limit` characters, its words, and its main
    /// computed styles (the Claude app's set, and the Codex app's flex ones for a flex or grid box).
    /// The message's own limits apply after the vault's values are taken out (`describe`).
    static let describeElement = """
        function (limit) {
          const el = this;
          const root = el.getRootNode();
          const scope = root.querySelectorAll ? root : document;
          const unique = (selector) => {
            try { const found = scope.querySelectorAll(selector); return found.length === 1 && found[0] === el; } catch { return false; }
          };
          const parts = [];
          for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
            if (node.id && scope.querySelectorAll('#' + CSS.escape(node.id)).length === 1) { parts.unshift('#' + CSS.escape(node.id)); break; }
            let part = node.localName;
            const classes = [...node.classList].filter(c => !/\\d{4,}/.test(c)).slice(0, 2);
            if (classes.length) part += classes.map(c => '.' + CSS.escape(c)).join('');
            const parent = node.parentElement;
            if (parent) {
              const same = [...parent.children].filter(c => c.localName === node.localName);
              if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
            }
            parts.unshift(part);
            if (unique(parts.join(' > '))) break;
          }
          const copy = el.cloneNode(true);
          const buttons = new Set(['button', 'submit', 'reset', 'image']);
          for (const field of [copy, ...copy.querySelectorAll('input, textarea, option')]) {
            if (field.localName === 'input' && !buttons.has((field.getAttribute('type') || '').toLowerCase())) field.removeAttribute('value');
            else if (field.localName === 'textarea') field.textContent = '';
            else if (field.localName === 'option') field.removeAttribute('selected');
          }
          let html = copy.outerHTML;
          const cut = html.length > limit;
          if (cut) html = html.slice(0, limit);
          const words = (el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title')
            || (copy.textContent || '')).replace(/\\s+/g, ' ').trim().slice(0, 400);
          const style = getComputedStyle(el);
          const names = ['display', 'position', 'width', 'height', 'margin', 'padding', 'color', 'background-color',
            'font-family', 'font-size', 'font-weight', 'line-height', 'border-width', 'border-style', 'border-color',
            'border-radius', 'opacity'];
          if (/flex|grid/.test(style.display)) names.push('flex-direction', 'justify-content', 'align-items', 'gap');
          return {
            tag: el.localName, selector: parts.join(' > '), html, cut,
            label: words,
            styles: names.map(n => [n, style.getPropertyValue(n)]).filter(([, v]) => v !== ''),
            frameURL: window.top === window ? null : location.href
          };
        }
        """

    /// Makes the typed text of every field in the capture's area transparent until `showTypedValues`.
    static let hideTypedValues = """
        (x, y, width, height) => {
          const kept = new Set(['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'range', 'color', 'file']);
          const hidden = [];
          for (const field of document.querySelectorAll('input, textarea')) {
            if (field.value === '' || kept.has(field.type)) continue;
            const r = field.getBoundingClientRect();
            if (r.right < x || r.left > x + width || r.bottom < y || r.top > y + height) continue;
            hidden.push([field, ['color', '-webkit-text-fill-color'].map(p => [p, field.style.getPropertyValue(p), field.style.getPropertyPriority(p)])]);
            field.style.setProperty('color', 'transparent', 'important');
            field.style.setProperty('-webkit-text-fill-color', 'transparent', 'important');
          }
          window.__yardletPickHidden = hidden;
          return hidden.length;
        }
        """

    static let showTypedValuesScript = """
        (window.__yardletPickHidden || []).forEach(([field, styles]) => styles.forEach(([p, v, priority]) =>
          v ? field.style.setProperty(p, v, priority) : field.style.removeProperty(p)));
        delete window.__yardletPickHidden;
        """
}
