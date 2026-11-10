import Foundation

/// Text shaped like a key or token a service issues, wherever an agent reads it through Yardlet: a field that is not a
/// password field (a read-only box showing a bot token), a page's text, an address, a script's result, a terminal, or
/// another task's title, conversation or answer. Its secret part becomes `[hidden credential]`, and the prefix that
/// names its kind stays, as `VaultSetupText` keeps a setup address. The shapes are the prefixes services give their keys
/// so that secret scanning finds them, with lengths ordinary words do not reach, a bearer token, a JSON Web Token, and
/// a value of letters and digits given to a name that ends in key, token, secret or password; a secret with none of
/// these around it (a signing secret in hex on its own, a password of letters alone) is not found, and neither is a
/// UUID. On unless the person turned it off in Settings (`VaultCenter.hidesCredentials`).
enum CredentialText {
    static let marker = "[hidden credential]"

    private struct Shape {
        /// Text every match holds, looked for before the expression runs.
        var anchors: [String]
        var pattern: NSRegularExpression
        var template = "$1" + CredentialText.marker

        init(_ anchors: [String], _ pattern: String, template: String? = nil) {
            self.anchors = anchors
            self.pattern = try! NSRegularExpression(pattern: pattern)
            if let template { self.template = template }
        }
    }

    private static let shapes: [Shape] = [
        // Slack bot, user, legacy, refresh and rotating tokens, and app-level tokens.
        Shape(["xox"], #"\b(xox[abposre](?:\.xox[abposr])?-)(?=[A-Za-z0-9-]*[0-9])[A-Za-z0-9-]{10,}"#),
        Shape(["xapp-"], #"\b(xapp-)[A-Za-z0-9-]{10,}"#),
        // Slack webhook and workflow addresses, also percent-encoded inside another address.
        Shape(["hooks.slack.com"], #"(hooks\.slack\.com(?:/|%2[Ff])(?:services|workflows|triggers)(?:/|%2[Ff]))"#
            + #"[A-Za-z0-9]+(?:(?:/|%2[Ff])[A-Za-z0-9]+)*"#),
        // GitHub personal, OAuth, user-to-server, server-to-server and refresh tokens, and fine-grained tokens.
        Shape(["gh"], #"\b(gh[pousr]_)[A-Za-z0-9]{30,}"#),
        Shape(["github_pat_"], #"\b(github_pat_)[A-Za-z0-9_]{30,}"#),
        // OpenAI (`sk-`, `sk-proj-`, `sk-svcacct-`) and Anthropic (`sk-ant-api03-`, `sk-ant-oat01-`) keys.
        Shape(["sk-"], #"\b(sk-(?:ant-[a-z]+[0-9]*-|proj-|svcacct-|admin-)?)(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{32,}"#),
        // Stripe secret and restricted keys, and webhook signing secrets.
        Shape(["k_live_", "k_test_"], #"\b([sr]k_(?:live|test)_)[A-Za-z0-9]{16,}"#),
        Shape(["whsec_"], #"\b(whsec_)[A-Za-z0-9+/=]{16,}"#),
        // AWS access key IDs, long-term and temporary.
        Shape(["AKIA", "ASIA"], #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        // Google API keys.
        Shape(["AIza"], #"\b(AIza)[0-9A-Za-z_-]{35}"#),
        // PEM and OpenSSH private keys and PGP private key blocks; one a cut left without its end, to the end of its body.
        Shape(["PRIVATE KEY"], #"(-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----)"#
            + #"(?:[\s\S]*?(-----END \2-----)|[A-Za-z0-9+/=\s\\]*)"#, template: "$1" + marker + "$3"),
        // JSON Web Tokens: a header and a payload that are JSON objects in base64url, and a signature.
        Shape(["eyJ"], #"\b(eyJ)[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{16,}"#),
        // A bearer token, as an `Authorization` header gives it.
        Shape(["earer"], #"\b([Bb]earer\s+)(?=[A-Za-z0-9._~+/-]*[0-9])[A-Za-z0-9._~+/-]{19,}[A-Za-z0-9_~+/-]=*"#),
        // A value of 16 characters or more, with letters and digits, given to a name that ends in key, token, secret or
        // password (`OPENAI_API_KEY=…`, `"apiKey": "…"`, `password: …`), also inside JSON's escaped quotes; a UUID is
        // an identifier, not a secret. The name is read 40 characters back at most, so a long run of joined words is not
        // searched again from each of its words. Last, after the shapes that name a key's kind.
        Shape(secretNames, #"\b([A-Za-z0-9_.-]{0,40}(?:"# + secretNames.joined(separator: "|")
                + #")(?:\\?["'])?\s*[:=]\s*(?:\\?["'])?)"#
                + #"(?![0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?!"#
                + "\(valueCharacter)*\(valueEnd)))"
                + "(?=\(valueCharacter)*[0-9])(?=\(valueCharacter)*[A-Za-z])\(valueCharacter){15,}\(valueEnd)"),
    ]

    /// The words a secret's name ends in, in capitals, with a capital first and in small letters.
    private static let secretNames = ["key", "token", "secret", "password", "passwd"].flatMap {
        [$0.uppercased(), $0.prefix(1).uppercased() + $0.dropFirst(), $0]
    }
    /// A character of a value given to a secret's name: it ends at a space, a quote, a backslash (JSON's escaped quote
    /// or line break), a bracket, so that a key an earlier shape hid is not hidden again, or what separates values.
    private static let valueCharacter = #"[^\s"'`\\<>,;&()|\[\]]"#
    /// The last character of such a value, which is not the period that ends a sentence.
    private static let valueEnd = #"[^\s"'`\\<>,;&()|\[\].]"#

    static func scrub(_ text: String) -> String {
        var text = text
        for shape in shapes where shape.anchors.contains(where: { text.contains($0) }) {
            text = shape.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                          withTemplate: shape.template)
        }
        return text
    }
}

// MARK: Captures

extension CredentialText {
    /// The shapes for a page script, as a JavaScript array of `[anchors, expression]` for `new RegExp(expression)`.
    /// JavaScript reads the expressions above as ICU does, except that its `\b` sits beside any letter outside ASCII too,
    /// so a page finds at least what a result hides.
    static let pageShapes: String = {
        let list = JSONValue.array(shapes.map { .array([.array($0.anchors.map(JSONValue.string)), .string($0.pattern.pattern)]) })
        return (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }()

    /// Runs `capture` with the keys and tokens the tab's frames show made transparent (`coverScript`) when `hides`, and
    /// puts them back after it, as a picture would otherwise carry what every result hides. The script runs in Yardlet's
    /// isolated world of each frame (`BrowserAgentTools.vaultWorldName`), which the page's own scripts cannot see or
    /// patch, and a frame puts its styles back by itself after `wait` should the release not come. A frame that does not
    /// answer is left as it is.
    @MainActor
    static func covering<T>(_ cdp: any BrowserAgentCDP, when hides: Bool, wait: Duration,
                            _ capture: () async throws -> T) async throws -> T {
        guard hides else { return try await capture() }
        let covered = await cover(cdp, wait: wait)
        let result: Result<T, any Error>
        do { result = .success(try await capture()) } catch { result = .failure(error) }
        for frame in covered {
            _ = try? await cdp.send("Runtime.evaluate", [
                "expression": .string("window.__yardletKeyCover?.release()"), "contextId": .integer(frame.context)
            ], session: frame.session, timeout: frameTimeout)
        }
        return try result.get()
    }

    private static let frameTimeout: Duration = .seconds(5)

    /// Covers the keys in each frame: the frames of the tab's process, and each frame from another site on its own
    /// session with the frames of its process. Gives the frames that covered any, by session and context.
    @MainActor
    private static func cover(_ cdp: any BrowserAgentCDP, wait: Duration) async -> [(session: String?, context: Int64)] {
        let expression = "(\(coverScript))(\(pageShapes), \(wait.components.seconds * 1000))"
        let remote = Set(cdp.frameSessions.map(\.frameID))
        var covered: [(session: String?, context: Int64)] = []
        for session in [nil] + cdp.frameSessions.map({ Optional($0.id) }) {
            guard let top = try? await cdp.send("Page.getFrameTree", [:], session: session, timeout: frameTimeout)["frameTree"]
            else { continue }
            var frames = [top]
            while let frame = frames.popLast() {
                frames += (frame["childFrames"]?.arrayValue ?? []).filter { !remote.contains($0["frame"]?["id"]?.stringValue ?? "") }
                guard let id = frame["frame"]?["id"]?.stringValue,
                      let context = try? await cdp.send("Page.createIsolatedWorld", [
                          "frameId": .string(id), "worldName": .string(BrowserAgentTools.vaultWorldName)
                      ], session: session, timeout: frameTimeout)["executionContextId"]?.integerValue,
                      let count = try? await cdp.send("Runtime.evaluate", [
                          "expression": .string(expression), "contextId": .integer(context), "returnByValue": .bool(true)
                      ], session: session, timeout: frameTimeout)["result"]?["value"]?.integerValue,
                      count > 0 else { continue }
                covered.append((session, context))
            }
        }
        return covered
    }

    /// Runs with the shapes and how long to wait, in milliseconds: makes transparent the fields whose value holds a key
    /// and the innermost elements whose text holds one (also when the key is split over the elements of a highlighted
    /// code), in the document and its open shadow roots, keeping their own styles for `release()`, which leaves no empty
    /// `style` attribute where there was none. Elements the page does not draw (scripts, styles) are passed over. A
    /// capture that comes meanwhile adds to the same cover, which goes when the last one releases it, or after the wait.
    /// Returns how many elements it covers.
    static let coverScript = """
        (shapes, wait) => {
          const patterns = shapes.map(([anchors, source]) => [anchors, new RegExp(source)]);
          const holds = text => !!text && patterns.some(([anchors, pattern]) =>
            anchors.some(anchor => text.includes(anchor)) && pattern.test(text));
          const cover = window.__yardletKeyCover ||= {
            count: 0, saved: new Map(),
            end() {
              clearTimeout(this.timer);
              this.saved.forEach(([had, styles], element) => {
                for (const [name, value, priority] of styles) {
                  value ? element.style.setProperty(name, value, priority) : element.style.removeProperty(name);
                }
                // Chromium writes the inline style into the attribute when it is read, which removing it does not do.
                if (!had && !element.style.length && element.hasAttribute('style')) element.removeAttribute('style');
              });
              delete window.__yardletKeyCover;
            },
            release() { if (--this.count <= 0) this.end(); }
          };
          // No transition lets the text fade out during the capture.
          const styles = [['color', 'transparent'], ['-webkit-text-fill-color', 'transparent'], ['text-shadow', 'none'],
            ['transition-property', 'none']];
          const hide = element => {
            if (!element.style || cover.saved.has(element)) return;
            cover.saved.set(element, [element.hasAttribute('style'), styles.map(([name]) =>
              [name, element.style.getPropertyValue(name), element.style.getPropertyPriority(name)])]);
            for (const [name, value] of styles) element.style.setProperty(name, value, 'important');
          };
          const undrawn = new Set(['script', 'style', 'noscript', 'template']);
          const own = node => Array.from(node.childNodes, child => child.nodeType === Node.TEXT_NODE ? child.data : '').join('');
          const drawn = node => Array.from(node.childNodes, child => child.nodeType === Node.TEXT_NODE ? child.data
            : child.nodeType === Node.ELEMENT_NODE && !undrawn.has(child.localName) ? child.textContent : '').join('');
          const search = root => {
            for (const field of root.querySelectorAll('input:not([type=hidden]), textarea')) {
              if (holds(field.value)) hide(field);
            }
            let level = holds(root.textContent) ? [root] : [];
            while (level.length) {
              const next = [];
              for (const node of level) {
                const inner = Array.from(node.children).filter(child => !undrawn.has(child.localName) && holds(child.textContent));
                if (inner.length ? holds(own(node)) : holds(drawn(node))) hide(node instanceof ShadowRoot ? node.host : node);
                next.push(...inner);
              }
              level = next;
            }
            for (const element of root.querySelectorAll('*')) if (element.shadowRoot) search(element.shadowRoot);
          };
          if (document.body) search(document.body);
          if (!cover.saved.size) { cover.end(); return 0; }
          cover.count += 1;
          clearTimeout(cover.timer);
          cover.timer = setTimeout(() => cover.end(), wait);
          return cover.saved.size;
        }
        """
}
