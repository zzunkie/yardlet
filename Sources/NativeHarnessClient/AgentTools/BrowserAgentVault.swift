import Foundation
import YardletAgentTools

/// Values the vault filled into pages lately, kept in memory for 30 minutes so that no tool result
/// carries one back to the model (design §5.3, the way CI logs mask their secrets), in the spellings a
/// page or a result most often turns them into. Short values are left alone: they would blank out
/// ordinary text.
struct VaultScrubList {
    private var entries: [(value: [UInt8], until: Date)] = []
    static let keep: TimeInterval = 30 * 60
    static let shortest = 4

    mutating func add(_ value: String?, now: Date = Date()) {
        guard let value, value.count >= Self.shortest else { return }
        let until = now.addingTimeInterval(Self.keep)
        for spelling in Set(Self.spellings(of: value)) {
            let bytes = Array(spelling.utf8)
            entries.removeAll { $0.until < now || $0.value == bytes }
            entries.append((bytes, until))
        }
    }

    /// The value as written, escaped in JSON (a script's result), and as base64 (plain, unpadded and
    /// URL-safe) and hex. Each is also found percent-encoded, in either case, once or twice (an address
    /// inside another's query), and with `+` for a space (a form's fields in an address). A page can
    /// still make a spelling this misses; these keep the usual ones from passing for something else.
    static func spellings(of value: String) -> [String] {
        let bytes = Data(value.utf8)
        let base64 = bytes.base64EncodedString()
        let unpadded = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let urlSafe = unpadded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let json = [JSONEncoder.OutputFormatting(), .withoutEscapingSlashes].compactMap { formatting -> String? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) }
        }
        return [value, base64, unpadded, urlSafe, hex, hex.uppercased()] + json
    }

    func scrub(_ text: String, now: Date = Date()) -> String {
        let live = entries.filter { $0.until >= now }.map(\.value).sorted { $0.count > $1.count }
        guard !live.isEmpty else { return text }
        let bytes = Array(text.utf8)
        var scrubbed: [UInt8] = []
        var index = 0
        var changed = false
        while index < bytes.count {
            if let end = live.lazy.compactMap({ Self.end(of: $0, in: bytes, at: index) }).first {
                scrubbed += Array("[saved value]".utf8)
                index = end
                changed = true
            } else {
                scrubbed.append(bytes[index])
                index += 1
            }
        }
        return changed ? String(decoding: scrubbed, as: UTF8.self) : text
    }

    /// Whether the text carries a value in any of its spellings: an address or title not to keep.
    func carries(_ text: String, now: Date = Date()) -> Bool {
        let live = entries.filter { $0.until >= now }.map(\.value)
        guard !live.isEmpty else { return false }
        let bytes = Array(text.utf8)
        return bytes.indices.contains { index in live.contains { Self.end(of: $0, in: bytes, at: index) != nil } }
    }

    func scrub(_ result: AgentToolResult, now: Date = Date()) -> AgentToolResult {
        guard entries.contains(where: { $0.until >= now }) else { return result }
        var result = result
        result.content = result.content.map { content in
            if case .text(let text) = content { return .text(scrub(text, now: now)) }
            return content
        }
        return result
    }

    /// Where `spelling` ends when it starts at `start` in `text`, each byte as itself, as `%XX` or `%25XX`,
    /// and a space also as `+` or `%2B`.
    static func end(of spelling: [UInt8], in text: [UInt8], at start: Int) -> Int? {
        func hex(_ at: Int) -> UInt8? {
            guard at + 1 < text.count, let high = Self.hexDigit(text[at]), let low = Self.hexDigit(text[at + 1]) else { return nil }
            return high << 4 | low
        }
        func matches(_ byte: UInt8, _ wanted: UInt8) -> Bool { byte == wanted || (wanted == 0x20 && byte == 0x2B) }
        func end(_ next: Int, _ at: Int) -> Int? {
            guard next < spelling.count else { return at }
            guard at < text.count else { return nil }
            let wanted = spelling[next]
            if text[at] == 0x25, let byte = hex(at + 1) {
                if matches(byte, wanted), let found = end(next + 1, at + 3) { return found }
                if byte == 0x25, let inner = hex(at + 3), matches(inner, wanted), let found = end(next + 1, at + 5) { return found }
            }
            return matches(text[at], wanted) ? end(next + 1, at + 1) : nil
        }
        return end(0, start)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

/// A password or a code the vault filled into a page: the document (the main frame's `loaderId`) and where the
/// tab's event log stood (a main-frame navigation after it ends the fill).
struct BrowserAgentVaultFill: Equatable {
    var loaderID: String
    var eventMark: Int
}

/// The vault's fills in one tab, the agent's and the person's (the key button, the code bar) alike, so that what an
/// agent may observe there does not depend on who filled it (design §5.3). Each document a secret went into stays
/// closed to the agent's scripts while it is shown, also when going back shows it again.
@MainActor
final class BrowserVaultFills {
    private(set) var fills: [BrowserAgentVaultFill] = []
    /// The documents (main frame `loaderId`) the agent ran its own scripts in, there or in a tab linked by
    /// `window.opener` while they were shown: a fill there asks the person first (`VaultFillRequest.afterAgentScript`).
    private(set) var scriptedDocuments: Set<String> = []

    func noteScript(in loaderID: String) {
        guard !loaderID.isEmpty else { return }
        scriptedDocuments.insert(loaderID)
        if scriptedDocuments.count > 200 { scriptedDocuments.removeFirst() }
    }

    var documents: Set<String> { Set(fills.map(\.loaderID)) }

    /// Records a fill before its values go in: the page can act on them (a dialog, a navigation, a submission)
    /// before the call that fills it answers.
    func record(_ fill: BrowserAgentVaultFill) {
        fills.append(fill)
        if fills.count > 50 { fills.removeFirst() }
    }

    /// Takes back a recorded fill that put nothing in.
    func withdraw(_ fill: BrowserAgentVaultFill) {
        if let index = fills.lastIndex(of: fill) { fills.remove(at: index) }
    }

    /// Whether the tab shows a filled document now: the one filled last, until the main frame opens another by a
    /// navigation or a reload, or one filled earlier that going back brought again.
    func holdShownDocument(in log: [(method: String, params: JSONValue)]) -> Bool {
        guard let last = fills.last else { return false }
        guard log.count > last.eventMark, let shown = log[last.eventMark...].last(where: Self.isMainNavigation) else { return true }
        return shown.params["frame"]?["loaderId"]?.stringValue.map(documents.contains) ?? false
    }

    /// Whether the document the log starts in, which no navigation in it names, was filled.
    func holdsFirstDocument(of log: [(method: String, params: JSONValue)]) -> Bool {
        let first = log.firstIndex(where: Self.isMainNavigation) ?? log.count
        return fills.contains { $0.eventMark <= first }
    }

    static func isMainNavigation(_ event: (method: String, params: JSONValue)) -> Bool {
        event.method == "Page.frameNavigated" && event.params["frame"]?["parentId"] == nil
    }
}

extension Notification.Name {
    /// The vault filled a value into a page for an agent; `userInfo[VaultFillNotice.tabKey]` is its tab.
    static let vaultFilled = Notification.Name("YardletVaultFilled")
}

enum VaultFillNotice {
    static let tabKey = "tab"
}

/// The person's side of the vault in a tab (design §8.3, §14): filling for them from the address field's
/// key button and the code bar, noticing that they signed in, to offer saving it, and noticing a
/// two-factor code field or setup QR code, to offer filling or saving the code.
@MainActor
enum VaultPageScripts {
    /// The binding the watch calls with a JSON object of strings whose `kind` says what it saw:
    /// - `signIn`, with `username` and `password`: the person submitted a sign-in. With `made` set instead of
    ///   `password`, the form held a password the vault made, which Yardlet already has.
    /// - `typedSecret`: someone typed into a password field (trusted input), told once a document.
    /// - `passwordFocus`, with `page`, and `isNew` set for a new-password field still empty; `passwordBlur`:
    ///   a password field took or lost the focus.
    /// - `madeCleared`: the person emptied a field that held a password the vault made (Chrome then drops it).
    /// - `codeField`, with `page`: a one-time code field showed.
    /// - `qr`, with `page`: a graphic the size and shape of a QR code showed; Yardlet reads the screen.
    /// - `setup`, with `page` and `text`: a link to set up a code (`otpauth://`).
    static let offerBinding = "__yardletVaultOffer"

    /// `isCodeField(e)`: whether an input takes a one-time code (design §5.2 step 3), for fills.
    /// `looksLikeCodeField(e)`: the stricter test for offering one, which leaves out other short
    /// numeric fields such as postal codes.
    static let codeFieldTests = """
        const codeTypes = ['text', 'tel', 'number', ''];
        const codeWords = /one.?time|otp|mfa|2fa|two.?factor|verification.?code|auth\\w*.?code|security.?code|passcode/i;
        const namesCode = e => codeWords.test([e.name, e.id, e.placeholder, e.getAttribute('aria-label')].join(' '));
        const isCodeField = e => e instanceof HTMLInputElement && codeTypes.includes(e.type)
          && ((e.autocomplete || '').includes('one-time-code') || (e.maxLength > 0 && e.maxLength <= 10)
            || e.inputMode === 'numeric' || namesCode(e));
        const looksLikeCodeField = e => e instanceof HTMLInputElement && codeTypes.includes(e.type) && !e.disabled && !e.readOnly
          && ((e.autocomplete || '').includes('one-time-code') || namesCode(e)
            || (e.maxLength > 0 && e.maxLength <= 8 && (e.inputMode === 'numeric' || e.type === 'tel' || e.type === 'number')));
        """

    /// `autocompleteOf(e)`, `isCurrentPassword(e)` and `newPasswordFields(e)`: the fields a new password goes
    /// into when `e` is one of them (design §15). The form's fields marked `new-password`; else, past the
    /// current password (marked so, or named so in its name, id, placeholder or label), the form's other one
    /// or two (a change's new password and its confirmation); else both of a form's two (a sign-up's password
    /// and confirmation) or the last two of three; else a lone field named new. A sign-in's field has none.
    /// `madePasswords()` holds the fields that took a password the vault made, until the person types in one.
    static let newPasswordTests = """
        const autocompleteOf = e => (e.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
        const fieldWords = e => [e.name, e.id, e.placeholder, e.getAttribute('aria-label')]
          .concat(Array.from(e.labels || []).map(l => l.textContent)).join(' ');
        const isCurrentPassword = e => autocompleteOf(e).includes('current-password')
          || (!autocompleteOf(e).includes('new-password') && /current|old|existing|기존|현재/i.test(fieldWords(e)));
        const passwordFieldsWith = e => Array.from((e.form || e.closest('form') || document).querySelectorAll('input[type=password]'))
          .filter(f => f === e || (!f.disabled && !f.readOnly && f.getBoundingClientRect().width > 0));
        const newPasswordFields = e => {
          if (!(e instanceof HTMLInputElement) || e.type !== 'password') return [];
          const fields = passwordFieldsWith(e);
          const marked = fields.filter(f => autocompleteOf(f).includes('new-password'));
          if (marked.length) return marked.includes(e) ? marked : [];
          const rest = fields.filter(f => !isCurrentPassword(f));
          if (!rest.includes(e)) return [];
          if (rest.length < fields.length) return rest.length <= 2 ? rest : [];
          if (fields.length === 2) return fields;
          if (fields.length === 3) return fields.indexOf(e) > 0 ? fields.slice(1) : [];
          return fields.length === 1 && /new|신규|새/i.test(fieldWords(e)) ? [e] : [];
        };
        const madePasswords = () => window.__yardletMade || (window.__yardletMade = new WeakSet());
        """

    /// Runs in the vault's isolated world of every document of a panel's tab. It listens for the person
    /// submitting a form whose password field they typed into, or that holds a password the vault made
    /// (not one the vault filled from an item), and tells Yardlet through the binding, once per submission.
    /// It tells when a password field takes or loses the focus, and whether it is an empty new-password
    /// field, for the strong password suggestion. It also looks, at most twice a second while the
    /// page changes, for a one-time code field (told once while it shows) and for a QR code's square on
    /// screen (each element once, ten QR looks a document) and tells Yardlet; no value leaves the page
    /// that way.
    static let watchScript = """
        (() => {
          if (window.__yardletVaultWatch) return;
          window.__yardletVaultWatch = true;
          const send = message => { if (typeof window.__yardletVaultOffer === 'function') window.__yardletVaultOffer(JSON.stringify(message)); };
          \(newPasswordTests)
          const typed = new WeakSet();
          const textTypes = ['text', 'email', 'tel', ''];
          let toldTyped = false;
          addEventListener('input', e => {
            if (!e.isTrusted || !(e.target instanceof HTMLInputElement) || e.target.type !== 'password') return;
            typed.add(e.target);
            if (!toldTyped) { toldTyped = true; send({ kind: 'typedSecret' }); }
            if (madePasswords().delete(e.target) && !e.target.value) send({ kind: 'madeCleared' });
          }, true);
          let last = '';
          const offer = scope => {
            const fields = Array.from((scope || document).querySelectorAll('input'));
            const made = fields.find(e => e.type === 'password' && e.value && madePasswords().has(e));
            const own = fields.filter(e => e.type === 'password' && e.value && typed.has(e) && !(window.__yardletVault || []).includes(e));
            // A change form's new password, not the current one typed above it.
            const pass = made || own.find(e => newPasswordFields(e).length) || own[0];
            if (!pass) return;
            const user = fields.find(e => textTypes.includes(e.type) && (e.autocomplete || '').split(/\\s+/).includes('username') && e.value)
              || fields.slice(0, fields.indexOf(pass)).reverse().find(e => textTypes.includes(e.type) && e.value);
            const message = made ? { kind: 'signIn', username: user ? user.value : '', made: '1' }
              : { kind: 'signIn', username: user ? user.value : '', password: pass.value };
            const payload = JSON.stringify(message);
            if (payload === last) return;
            last = payload;
            send(message);
          };
          addEventListener('submit', e => offer(e.target), true);
          addEventListener('click', e => { const b = e.target instanceof Element && e.target.closest('button, input[type=submit]');
            if (b) offer(b.form || b.closest('form')); }, true);
          addEventListener('keydown', e => { if (e.key === 'Enter' && e.target instanceof HTMLInputElement && e.target.type === 'password')
            offer(e.target.form || e.target.closest('form')); }, true);
          addEventListener('focusin', e => {
            if (!(e.target instanceof HTMLInputElement) || e.target.type !== 'password') return;
            const fresh = newPasswordFields(e.target);
            send({ kind: 'passwordFocus', page: location.href,
                   isNew: fresh.length && fresh.every(f => !f.value && !madePasswords().has(f)) ? '1' : '' });
          }, true);
          addEventListener('focusout', e => {
            if (e.target instanceof HTMLInputElement && e.target.type === 'password') send({ kind: 'passwordBlur', page: location.href });
          }, true);

          \(codeFieldTests)
          const onScreen = r => r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
          const toldFields = new WeakSet(), seenGraphics = new WeakSet(), seenLinks = new Set();
          let codeField = null, qrLooks = 0, pending = 0;
          const look = () => {
            pending = 0;
            // Once while a code field shows; again when a later step shows another.
            if (!codeField || !codeField.isConnected || !onScreen(codeField.getBoundingClientRect())) {
              const field = Array.from(document.querySelectorAll('input'))
                .find(e => !toldFields.has(e) && looksLikeCodeField(e) && onScreen(e.getBoundingClientRect()));
              if (field) { codeField = field; toldFields.add(field); send({ kind: 'codeField', page: location.href }); }
            }
            for (const link of document.querySelectorAll('a[href^="otpauth" i]')) {
              if (seenLinks.has(link.href)) continue;
              seenLinks.add(link.href);
              send({ kind: 'setup', page: location.href, text: link.href });
            }
            if (qrLooks >= 10) return;
            let square = false;
            for (const e of document.querySelectorAll('img, canvas, svg')) {
              if (seenGraphics.has(e) || (e.parentElement && e.parentElement.closest('svg'))) continue;
              if (e instanceof HTMLImageElement && !e.complete) { e.addEventListener('load', schedule, { once: true }); continue; }
              const r = e.getBoundingClientRect();
              // Not laid out or not on screen yet: looked at again when it is.
              if (!onScreen(r)) continue;
              seenGraphics.add(e);
              if (r.width >= 96 && r.width <= 640 && Math.abs(r.width - r.height) <= r.width * 0.15) square = true;
            }
            if (square) { qrLooks += 1; send({ kind: 'qr', page: location.href }); }
          };
          const schedule = () => { if (!pending) pending = setTimeout(look, 500); };
          new MutationObserver(schedule).observe(document, { subtree: true, childList: true, attributes: true,
            attributeFilter: ['src', 'class', 'style', 'hidden', 'open'] });
          addEventListener('scroll', schedule, true);
          addEventListener('resize', schedule);
          addEventListener('load', schedule);
          schedule();
        })();
        """

    /// The field the person's fill goes to: the focused field, else the page's first password field,
    /// else its first username field, else its first one-time code field. For the code bar
    /// (`codeOnly`), the focused code field, else the first code field.
    static func personTarget(codeOnly: Bool) -> String {
        """
        (() => {
          \(codeFieldTests)
          const visible = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
          const focused = document.activeElement;
          const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
          if (\(codeOnly)) {
            return isCodeField(focused) ? focused : inputs.find(looksLikeCodeField) || inputs.find(isCodeField) || null;
          }
          if (focused instanceof HTMLInputElement) return focused;
          return inputs.find(e => e.type === 'password') || inputs.find(e => (e.autocomplete || '').includes('username'))
            || inputs.find(looksLikeCodeField) || null;
        })()
        """
    }

    /// The person's fill with the target field as `this`: the code into a code field when the item has
    /// one, else the sign-in into the field's form.
    static let personFillFunction = """
        function(username, password, code, origin) {
          \(codeFieldTests)
          const kind = typeof code === 'string' && (looksLikeCodeField(this) || (isCodeField(this) && typeof password !== 'string'))
            ? 'one_time_code' : 'login';
          return (\(BrowserAgentTools.fillFunction)).call(this, kind, username, password, code, origin);
        }
        """

    /// The value the person typed in the page's username field, for "Add to Password Manager…".
    static let typedUsername = """
        (() => {
          const textTypes = ['text', 'email', 'tel', ''];
          const fields = Array.from(document.querySelectorAll('input'));
          const pass = fields.find(e => e.type === 'password');
          const user = fields.find(e => textTypes.includes(e.type) && (e.autocomplete || '').includes('username') && e.value)
            || (pass ? fields.slice(0, fields.indexOf(pass)).reverse().find(e => textTypes.includes(e.type) && e.value) : null);
          return user ? user.value : '';
        })()
        """

    /// The field the person's strong password goes to: the focused password field, else the page's first
    /// new-password field.
    static let newPasswordTarget = """
        (() => {
          \(newPasswordTests)
          const focused = document.activeElement;
          if (focused instanceof HTMLInputElement && focused.type === 'password') return focused;
          return Array.from(document.querySelectorAll('input[type=password]'))
            .find(e => newPasswordFields(e).length && e.getBoundingClientRect().width > 0) || null;
        })()
        """

    /// With a password field as `this`: what a password made for it must meet (the site's `passwordrules`,
    /// the field's `minlength` and `maxlength`) and the username in its form, which the saved item takes.
    static let newPasswordContext = """
        function() {
          \(newPasswordTests)
          const target = this;
          if (!(target instanceof HTMLInputElement) || target.type !== 'password') return { isPassword: false };
          const textTypes = ['text', 'email', 'tel', ''];
          const inputs = Array.from((target.form || target.closest('form') || document).querySelectorAll('input'));
          const first = newPasswordFields(target)[0] || target;
          const user = inputs.find(e => textTypes.includes(e.type) && autocompleteOf(e).includes('username') && e.value)
            || inputs.slice(0, inputs.indexOf(first)).reverse().find(e => textTypes.includes(e.type) && e.value);
          return { isPassword: true, rules: target.getAttribute('passwordrules') || '', minLength: target.minLength,
                   maxLength: target.maxLength, username: user ? user.value.trim() : '' };
        }
        """

    /// The person's field for a strong password, in the vault's world of the main frame: the field's object, bound
    /// to the document it is in, that document as the browser reports it, what the password must meet and the form's
    /// username; nil when the page has no password field.
    static func newPasswordField(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async
        -> (objectID: String, frame: (id: String, loaderID: String, origin: String), context: JSONValue)? {
        guard let frame = try? await mainFrame(cdp, timeout: timeout),
              let world = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let target = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string(newPasswordTarget), "contextId": .integer(world)
              ], timeout: timeout),
              let objectID = target["result"]?["objectId"]?.stringValue,
              let context = try? await cdp.send("Runtime.callFunctionOn", [
                  "functionDeclaration": .string(newPasswordContext), "objectId": .string(objectID), "returnByValue": .bool(true)
              ], timeout: timeout),
              context["result"]?["value"]?["isPassword"]?.boolValue == true else { return nil }
        return (objectID, frame, context["result"]?["value"] ?? .null)
    }

    /// Puts a password the vault made into the field and its confirmation, as `fillForPerson` puts a saved one: only
    /// into the document of `frame`, recorded on the tab before it goes in; false when the page took nothing.
    static func fillNewPassword(_ cdp: any BrowserAgentCDP, frame: (id: String, loaderID: String, origin: String),
                                fills: BrowserVaultFills, into objectID: String, password: String,
                                timeout: Duration = .seconds(10)) async -> Bool {
        guard (try? await mainFrame(cdp, timeout: timeout))?.loaderID == frame.loaderID else { return false }
        let record = BrowserAgentVaultFill(loaderID: frame.loaderID, eventMark: cdp.eventLog.count)
        fills.record(record)
        let filled = try? await cdp.send("Runtime.callFunctionOn", [
            "functionDeclaration": .string(BrowserAgentTools.fillFunction), "objectId": .string(objectID),
            "arguments": .array([.string(VaultFillKind.newPassword.rawValue), .null, .string(password), .null,
                                 .string(frame.origin)].map { .object(["value": $0]) }),
            "returnByValue": .bool(true)
        ], timeout: timeout)
        guard filled?["result"]?["value"]?["kinds"] != nil else {
            fills.withdraw(record)
            return false
        }
        if let now = try? await mainFrame(cdp, timeout: timeout), now.loaderID != frame.loaderID {
            // The page went on to another document of its own as the fill went in; it may hold the value too.
            fills.record(BrowserAgentVaultFill(loaderID: now.loaderID, eventMark: record.eventMark))
        }
        return true
    }

    /// The tab's main frame: its ID, the document it shows and its origin, as the browser reports them.
    static func mainFrame(_ cdp: any BrowserAgentCDP, timeout: Duration) async throws
        -> (id: String, loaderID: String, origin: String) {
        let tree = try await cdp.send("Page.getFrameTree", [:], timeout: timeout)
        let frame = tree["frameTree"]?["frame"]
        let origin = frame?["securityOrigin"]?.stringValue.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            ?? frame?["url"]?.stringValue.flatMap(VaultSite.origin(of:)) ?? ""
        return (frame?["id"]?.stringValue ?? "", frame?["loaderId"]?.stringValue ?? "", origin)
    }

    /// A context in the vault's isolated world of the tab's main frame.
    static func vaultWorld(_ cdp: any BrowserAgentCDP, frame: String, timeout: Duration) async throws -> Int64 {
        let world = try await cdp.send("Page.createIsolatedWorld", [
            "frameId": .string(frame), "worldName": .string(BrowserAgentTools.vaultWorldName)
        ], timeout: timeout)
        guard let context = world["executionContextId"]?.integerValue else { throw BrowserAgentToolError("no context") }
        return context
    }

    /// Starts the watch in a panel's tab: in every new document and in the one shown now.
    static func installWatch(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async {
        _ = try? await cdp.send("Runtime.enable", [:], timeout: timeout)
        _ = try? await cdp.send("Page.enable", [:], timeout: timeout)
        _ = try? await cdp.send("Runtime.addBinding", [
            "name": .string(offerBinding), "executionContextName": .string(BrowserAgentTools.vaultWorldName)
        ], timeout: timeout)
        _ = try? await cdp.send("Page.addScriptToEvaluateOnNewDocument", [
            "source": .string(watchScript), "worldName": .string(BrowserAgentTools.vaultWorldName)
        ], timeout: timeout)
        if let frame = try? await mainFrame(cdp, timeout: timeout), !frame.id.isEmpty,
           let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout) {
            _ = try? await cdp.send("Runtime.evaluate", ["expression": .string(watchScript), "contextId": .integer(context)],
                                    timeout: timeout)
        }
    }

    /// The person's fill from the key button (the focused field's form, the page's sign-in form, or its
    /// code field) or from the code bar (`codeOnly`: the code alone, into the page's code field), into the document
    /// the values were given for (`frame`): a page that moved on since takes nothing. It is recorded in the tab's
    /// `fills` before the values go in, as an agent's fill is, so the agent's tools treat the page alike.
    @discardableResult
    static func fillForPerson(_ cdp: any BrowserAgentCDP, frame: (id: String, loaderID: String, origin: String),
                              fills: BrowserVaultFills, username: String?, password: String?, code: String?,
                              codeOnly: Bool = false, timeout: Duration = .seconds(10)) async -> Bool {
        guard let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let target = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string(personTarget(codeOnly: codeOnly)), "contextId": .integer(context)
              ], timeout: timeout),
              let objectID = target["result"]?["objectId"]?.stringValue,
              (try? await mainFrame(cdp, timeout: timeout))?.loaderID == frame.loaderID else { return false }
        let values: [String?] = codeOnly ? [nil, nil, code] : [username, password, code]
        let secret = values[1] != nil || values[2] != nil
        let record = BrowserAgentVaultFill(loaderID: frame.loaderID, eventMark: cdp.eventLog.count)
        if secret { fills.record(record) }
        let filled = try? await cdp.send("Runtime.callFunctionOn", [
            "functionDeclaration": .string(personFillFunction), "objectId": .string(objectID),
            "arguments": .array((values + [frame.origin]).map { .object(["value": $0.map(JSONValue.string) ?? .null]) }),
            "returnByValue": .bool(true)
        ], timeout: timeout)
        let kinds = filled?["result"]?["value"]?["kinds"]?.arrayValue?.compactMap(\.stringValue)
        guard secret else { return kinds != nil }
        if let kinds, !kinds.contains("password"), !kinds.contains("one_time_code") {
            fills.withdraw(record)
        } else if let now = try? await mainFrame(cdp, timeout: timeout), now.loaderID != frame.loaderID {
            // The page went on to another document of its own as the fill went in; it may hold the values too.
            fills.record(BrowserAgentVaultFill(loaderID: now.loaderID, eventMark: record.eventMark))
        }
        return kinds != nil
    }

    /// How a two-factor setup key reads on a page: base32 in capitals or small letters, whole or in groups of four.
    static func spellings(ofSetupKey key: Data) -> [String] {
        let whole = Base32.encode(key)
        guard whole.count >= VaultScrubList.shortest else { return [] }
        let grouped = stride(from: 0, to: whole.count, by: 4).map { start in
            String(whole.dropFirst(start).prefix(4))
        }.joined(separator: " ")
        return [whole, whole.lowercased(), grouped, grouped.lowercased()]
    }

    /// The page shows secrets the vault keeps (a two-factor setup's key, which makes the codes for good): the agent's
    /// tools treat its document as one the vault filled, and a snapshot leaves out what shows them. The caller keeps
    /// them out of results (`VaultScrubList`).
    static func noteSecretsShown(_ secrets: [String], on cdp: any BrowserAgentCDP, fills: BrowserVaultFills,
                                 timeout: Duration = .seconds(10)) async {
        guard let frame = try? await mainFrame(cdp, timeout: timeout) else { return }
        fills.record(BrowserAgentVaultFill(loaderID: frame.loaderID, eventMark: cdp.eventLog.count))
        guard !secrets.isEmpty, let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout) else { return }
        _ = try? await cdp.send("Runtime.callFunctionOn", [
            "functionDeclaration": .string("function(values) { window.__yardletVaultSecrets = (window.__yardletVaultSecrets || []).concat(values); }"),
            "executionContextId": .integer(context),
            "arguments": .array([.object(["value": .array(secrets.map(JSONValue.string))])])
        ], timeout: timeout)
    }

    /// Whether the page shows a field for a one-time code, read in the vault's world.
    static func hasCodeField(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async -> Bool {
        guard let frame = try? await mainFrame(cdp, timeout: timeout),
              let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let found = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string("(() => { \(codeFieldTests) return Array.from(document.querySelectorAll('input'))"
                      + ".some(e => looksLikeCodeField(e) && e.getBoundingClientRect().width > 0); })()"),
                  "contextId": .integer(context), "returnByValue": .bool(true)
              ], timeout: timeout) else { return false }
        return found["result"]?["value"]?.boolValue == true
    }

    /// The value in the page's username field, read in the vault's world.
    static func typedUsername(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async -> String {
        guard let frame = try? await mainFrame(cdp, timeout: timeout),
              let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let value = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string(typedUsername), "contextId": .integer(context), "returnByValue": .bool(true)
              ], timeout: timeout) else { return "" }
        return value["result"]?["value"]?.stringValue ?? ""
    }
}

/// The secret of a two-factor setup address in text (`otpauth://totp/…?secret=…`, an export's
/// `otpauth-migration://offline?data=…`, also percent-encoded inside another address, as QR code images are
/// often made), which makes the account's codes for good. No result carries it, whoever's it is.
enum VaultSetupText {
    private static let address = try! NSRegularExpression(pattern:
        "(otpauth(?:-migration)?(?::|%3A)(?://|%2F%2F)[^\\s\"'<>]*?(?:[?&]|%3F|%26)(?:secret|data)(?:=|%3D))"
        + "((?:[^&\\s\"'<>%]|%(?!26)[0-9A-Fa-f]{2})+)", options: [.caseInsensitive])

    static func scrub(_ text: String) -> String {
        guard text.range(of: "otpauth", options: .caseInsensitive) != nil else { return text }
        return address.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                withTemplate: "$1[saved value]")
    }

    static func scrub(_ result: AgentToolResult) -> AgentToolResult {
        var result = result
        result.content = result.content.map { content in
            if case .text(let text) = content { return .text(scrub(text)) }
            return content
        }
        return result
    }
}

extension BrowserAgentTools {
    /// The world Yardlet's vault code runs in: the page's own scripts cannot see or patch it.
    static let vaultWorldName = "yardlet-vault"

    /// `browser_fill_credential` (design §5.2).
    func fillCredential(_ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID?) async throws -> AgentToolResult {
        guard let vault, let sessionID else {
            throw BrowserAgentToolError("Yardlet's password manager is not available in this build.")
        }
        guard let kind = VaultFillKind(rawValue: arguments["kind"]?.stringValue ?? VaultFillKind.login.rawValue) else {
            throw BrowserAgentToolError("kind must be login, one_time_code or passkey.")
        }
        let itemName = arguments["item"]?.stringValue
        if kind == .passkey {
            return try await armPasskey(itemName: itemName, on: page, sessionID: sessionID)
        }
        guard let ref = arguments["ref"]?.stringValue else {
            throw BrowserAgentToolError("browser_fill_credential needs the ref of a field in the sign-in form.")
        }
        let element = try element(ref, on: page)
        // The vault fills only the page's own fields: not a frame from another site (docs/BROWSER_VAULT_DESIGN.md, "How filling works"), as not a frame of
        // the page's own process (`ownerDocument` below).
        guard element.session == nil else {
            throw BrowserAgentToolError("\(ref) is inside a frame in the page; Yardlet fills only the page's own fields.")
        }
        let node = element.node
        let frame = try await mainFrame(of: page)
        let world = try await send(page, "Page.createIsolatedWorld", [
            "frameId": .string(frame.id), "worldName": .string(Self.vaultWorldName)
        ])
        guard let contextID = world["executionContextId"]?.integerValue else {
            throw BrowserAgentToolError("The browser did not open a context to fill the page in.")
        }
        let resolved = try await send(page, "DOM.resolveNode", [
            "backendNodeId": .integer(Int64(node)), "executionContextId": .integer(contextID)
        ], ref: ref)
        guard let objectID = resolved["object"]?["objectId"]?.stringValue else {
            throw BrowserAgentToolError("\(ref) could not be found on the page. Call browser_snapshot again.")
        }
        let onPage = try await callInVaultWorld(page, objectID,
            "function() { return this instanceof HTMLElement && this.ownerDocument === document; }")
        guard onPage.boolValue == true else {
            throw BrowserAgentToolError("\(ref) is inside a frame in the page; Yardlet fills only the page's own fields.")
        }
        if kind == .newPassword {
            return try await fillNewPassword(vault, itemName: itemName, ref: ref, objectID: objectID, frame: frame,
                                             submit: arguments["submit"]?.boolValue, on: page, sessionID: sessionID)
        }

        var request = VaultFillRequest(sessionID: sessionID, itemName: itemName, kind: kind, origin: frame.origin)
        request.afterAgentScript = page.vaultFills.scriptedDocuments.contains(frame.loaderID)
        let grant: VaultFillGrant
        switch await vault.authorize(request) {
        case .success(let allowed): grant = allowed
        case .failure(let refusal): throw BrowserAgentToolError(refusal.message)
        }
        // The page may have moved on while the person was asked.
        guard (try? await mainFrame(of: page))?.loaderID == frame.loaderID else {
            vault.record(grant, for: request, filled: [], failure: "The page navigated before the fill.")
            throw BrowserAgentToolError("The page navigated before Yardlet could fill it; nothing was filled.")
        }
        // A secret goes only into a form that sends it to the item's own sites over https.
        let submission = try await callInVaultWorld(page, objectID, Self.submissionFunction)
        let targets = (submission["targets"]?.arrayValue ?? []).compactMap { target -> FormTarget? in
            guard let action = target["action"]?.stringValue, let method = target["method"]?.stringValue else { return nil }
            return FormTarget(action: action, method: method)
        }
        if grant.password != nil || grant.code != nil,
           let elsewhere = targets.first(where: { !Self.isItemDestination($0.action, of: grant.item) }) {
            let message = "Yardlet did not fill “\(grant.item.name)”: the form sends its fields to "
                + "\(VaultSite.origin(of: elsewhere.action) ?? "another address"), which is not one of the item's sites over https."
            vault.record(grant, for: request, filled: [], failure: message)
            throw BrowserAgentToolError(message)
        }
        // Before the values go in: the page can open a dialog, navigate or submit as they do, and the call that fills
        // may then fail without saying what went in; its address must not carry them either. A fill that put nothing in
        // takes its record back.
        vaultScrub.add(grant.password)
        vaultScrub.add(grant.code)
        let record = grant.password != nil || grant.code != nil
            ? BrowserAgentVaultFill(loaderID: frame.loaderID, eventMark: page.cdp.eventLog.count) : nil
        if let record { page.vaultFills.record(record) }
        if let password = grant.password, password.count >= VaultScrubList.shortest {
            page.guardFilledValues(VaultScrubList.spellings(of: password))
        }
        let filled = try await callInVaultWorld(page, objectID, Self.fillFunction, arguments: [
            .string(kind.rawValue),
            grant.username.map(JSONValue.string) ?? .null,
            grant.password.map(JSONValue.string) ?? .null,
            grant.code.map(JSONValue.string) ?? .null,
            .string(frame.origin)
        ])
        let kinds = filled["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let record, filled["error"] != nil || !(kinds.contains("password") || kinds.contains("one_time_code")) {
            page.vaultFills.withdraw(record)
        }
        if let failure = filled["error"]?.stringValue {
            let message = Self.fillFailure(failure, ref: ref)
            vault.record(grant, for: request, filled: [], failure: message)
            throw BrowserAgentToolError(message)
        }
        vault.record(grant, for: request, filled: kinds)
        NotificationCenter.default.post(name: .vaultFilled, object: nil, userInfo: [VaultFillNotice.tabKey: page.tabID])

        // A safe form is submitted unless the agent says not to, so the values stay on the page as briefly as they can;
        // another is left unsent whatever the agent asked. A field in no form is submitted with Enter only when asked.
        let asked = arguments["submit"]?.boolValue
        var submitted = false
        let secret = kinds.contains("password") || kinds.contains("one_time_code")
        var unsent = submission["form"]?.boolValue == true && secret
            ? Self.submissionRisk(targets, pageOrigin: frame.origin, password: kinds.contains("password")) : nil
        if asked != false, unsent == nil {
            switch try await callInVaultWorld(page, objectID, Self.submitFunction).stringValue {
            case "submitted":
                submitted = true
            case "address":
                unsent = Self.addressRisk
            default:
                if asked == true, let enter = BrowserAgentKeyPress.parse("Enter") {
                    try await dispatch(enter, on: page)
                    submitted = true
                }
            }
        }
        let what: String
        switch (kinds.contains("username"), kinds.contains("password"), kinds.contains("one_time_code")) {
        case (true, true, _): what = "the username and password"
        case (false, true, _): what = "the password"
        case (true, false, _): what = "the username"
        default: what = "the one-time code"
        }
        let host = VaultSite.host(of: frame.origin)
        if let unsent, asked != false {
            return .text("Filled \(what) of “\(grant.item.name)” into the form on \(host) but did not submit it: \(unsent) "
                + "Click the page's sign-in button: the page's own script usually sends the form another way. If the page "
                + "would put the password in an address or send it to another site, Yardlet stops it and says so. "
                + "The values are not shown to you.")
        }
        return .text("Filled \(what) of “\(grant.item.name)” into the form on \(host)"
            + (submitted ? " and submitted it." : ".") + " The values are not shown to you.")
    }

    /// `browser_fill_credential` with `kind: new_password` (design §15), on the path a saved password's fill takes:
    /// Yardlet makes the password within what the field asks, saves it as a new item for the site before the page
    /// takes it (so a page that fails or submits on its own loses nothing), and fills the field and its confirmation
    /// only when the form sends them to that site.
    private func fillNewPassword(_ vault: VaultCenter, itemName: String?, ref: String, objectID: String,
                                 frame: (id: String, loaderID: String, origin: String), submit asked: Bool?,
                                 on page: BrowserAgentPage, sessionID: UUID) async throws -> AgentToolResult {
        let context = try await callInVaultWorld(page, objectID, VaultPageScripts.newPasswordContext)
        guard context["isPassword"]?.boolValue == true else {
            throw BrowserAgentToolError("\(ref) is not a password field. Give the ref of the new password field.")
        }
        let username = context["username"]?.stringValue ?? ""
        var request = VaultFillRequest(sessionID: sessionID, itemName: itemName, kind: .newPassword, origin: frame.origin)
        request.afterAgentScript = page.vaultFills.scriptedDocuments.contains(frame.loaderID)
        let confirmation: VaultUse.Confirmation
        switch await vault.authorizeNewPassword(request, username: username) {
        case .success(let confirmed): confirmation = confirmed
        case .failure(let refusal): throw BrowserAgentToolError(refusal.message)
        }
        // The page may have moved on while the person was asked.
        guard (try? await mainFrame(of: page))?.loaderID == frame.loaderID,
              let site = VaultSite.suggestion(for: frame.origin, suffixes: vault.suffixes) else {
            throw BrowserAgentToolError("The page navigated before Yardlet could fill it; nothing was filled or saved.")
        }
        // The password goes only into a form that sends it to the new item's site over https.
        let submission = try await callInVaultWorld(page, objectID, Self.submissionFunction)
        let targets = (submission["targets"]?.arrayValue ?? []).compactMap { target -> FormTarget? in
            guard let action = target["action"]?.stringValue, let method = target["method"]?.stringValue else { return nil }
            return FormTarget(action: action, method: method)
        }
        let destination = VaultItem(name: "", sites: [site], username: "")
        if let elsewhere = targets.first(where: { !Self.isItemDestination($0.action, of: destination) }) {
            let message = "Yardlet made no password: the form sends its fields to "
                + "\(VaultSite.origin(of: elsewhere.action) ?? "another address"), which is not \(site) over https."
            vault.recordRefusal(request, message)
            throw BrowserAgentToolError(message)
        }
        guard let password = vault.makePassword(rules: context["rules"]?.stringValue,
                                                minLength: Int(context["minLength"]?.integerValue ?? 0),
                                                maxLength: Int(context["maxLength"]?.integerValue ?? 0)) else {
            throw BrowserAgentToolError("The system's random source failed, so Yardlet made no password.")
        }
        let item: VaultItem
        do {
            item = try vault.presaveMadePassword(password, origin: frame.origin, username: username, name: itemName)
        } catch {
            throw BrowserAgentToolError("Yardlet could not save a new password, so it filled none.")
        }
        let grant = VaultFillGrant(item: item, password: password, confirmedBy: confirmation)
        // Before the value goes in, as for a saved password (`fillCredential`).
        vaultScrub.add(password)
        let record = BrowserAgentVaultFill(loaderID: frame.loaderID, eventMark: page.cdp.eventLog.count)
        page.vaultFills.record(record)
        if password.count >= VaultScrubList.shortest {
            page.guardFilledValues(VaultScrubList.spellings(of: password))
        }
        let filled = try await callInVaultWorld(page, objectID, Self.fillFunction, arguments: [
            .string(VaultFillKind.newPassword.rawValue), .null, .string(password), .null, .string(frame.origin)
        ])
        let kinds = filled["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let failure = filled["error"]?.stringValue {
            page.vaultFills.withdraw(record)
            try? vault.delete(item.id)
            let message = Self.fillFailure(failure, ref: ref)
            vault.record(grant, for: request, filled: [], failure: message)
            throw BrowserAgentToolError(message)
        }
        vault.record(grant, for: request, filled: kinds)
        NotificationCenter.default.post(name: .vaultFilled, object: nil, userInfo: [VaultFillNotice.tabKey: page.tabID])

        // Submitted as a saved password's form is: a safe form unless the agent says not to, another never.
        var submitted = false
        var unsent = submission["form"]?.boolValue == true
            ? Self.submissionRisk(targets, pageOrigin: frame.origin, password: true) : nil
        if asked != false, unsent == nil {
            switch try await callInVaultWorld(page, objectID, Self.submitFunction).stringValue {
            case "submitted":
                submitted = true
            case "address":
                unsent = Self.addressRisk
            default:
                if asked == true, let enter = BrowserAgentKeyPress.parse("Enter") {
                    try await dispatch(enter, on: page)
                    submitted = true
                }
            }
        }
        let fields = kinds.contains("new_password_and_confirmation") ? "the new password and its confirmation"
            : "the new password field"
        let saved = "saved it as “\(item.name)”" + (item.username.isEmpty ? "" : " for \(item.username)")
        let host = VaultSite.host(of: frame.origin)
        if let unsent, asked != false {
            return .text("Made a new password, filled \(fields) on \(host) and \(saved), but did not submit the form: "
                + "\(unsent) Click the page's button to create the account. The value is not shown to you.")
        }
        return .text("Made a new password, filled \(fields) on \(host) and \(saved)"
            + (submitted ? ", then submitted the form." : ".") + " The value is not shown to you; sign in later with this item.")
    }

    /// Whether the vault filled a password or a code into the document the page shows now (design §5.3):
    /// the one it filled last, until the main frame opens another by a navigation or a reload, or one it
    /// filled earlier that going back brought again. A page can copy what it was given, so an emptied field
    /// does not end it. While it holds, the page's scripts are not run for the agent.
    func vaultFilledDocument(_ page: BrowserAgentPage) -> Bool {
        page.vaultFills.holdShownDocument(in: page.cdp.eventLog)
    }

    /// Why the agent may not run `what` on the page now, or nil: the page is a document the vault filled, or a tab
    /// linked to it by `window.opener` shows one, whose document scripts here could read.
    func vaultObservationRefusal(_ page: BrowserAgentPage, _ what: String, linked: Bool = true) -> String? {
        if vaultFilledDocument(page) {
            return "This page holds a password or code (one Yardlet's password manager filled, one the person typed, or a "
                + "two-factor setup key), so \(what) does not run on it. Reload it (browser_navigate to its address) or go to "
                + "another page to use \(what) again; browser_snapshot, clicks and typing work as before."
        }
        if linked, let linked = page.linkedVaultFill() {
            return "Tab \(linked) shows a page that holds a password or code, and this tab is linked to it (one of them "
                + "opened the other), so \(what) does not run here until that tab goes to another page or closes. "
                + "browser_snapshot, clicks and typing work as before."
        }
        return nil
    }

    /// The elements on a filled page that hold or show a filled value, for a snapshot to leave out: the filled
    /// fields, and the innermost elements whose text has a filled value (a code drawn in boxes of the page's own, a
    /// password the page shows elsewhere). Empty when the page is no filled document; nil when they cannot be found,
    /// so that nothing is shown of the page.
    func vaultSecretNodes(on page: BrowserAgentPage) async -> Set<BrowserAgentSnapshot.Ref>? {
        guard vaultFilledDocument(page) else { return [] }
        let group = "yardlet-vault-secrets"
        defer { Task { _ = try? await self.send(page, "Runtime.releaseObjectGroup", ["objectGroup": .string(group)]) } }
        guard let frame = try? await mainFrame(of: page),
              let context = try? await send(page, "Page.createIsolatedWorld", [
                  "frameId": .string(frame.id), "worldName": .string(Self.vaultWorldName)
              ])["executionContextId"]?.integerValue,
              let list = try? await send(page, "Runtime.evaluate", [
                  "expression": .string(Self.secretElements), "contextId": .integer(context), "objectGroup": .string(group)
              ])["result"]?["objectId"]?.stringValue,
              let items = try? await send(page, "Runtime.getProperties", [
                  "objectId": .string(list), "ownProperties": .bool(true)
              ])["result"]?.arrayValue else { return nil }
        var nodes: Set<BrowserAgentSnapshot.Ref> = []
        for item in items where Int(item["name"]?.stringValue ?? "") != nil {
            guard let object = item["value"]?["objectId"]?.stringValue,
                  let node = try? await send(page, "DOM.describeNode", ["objectId": .string(object)])["node"]?["backendNodeId"]?
                    .integerValue else { return nil }
            nodes.insert(BrowserAgentSnapshot.Ref(node: Int(node), session: nil))
        }
        return nodes
    }

    /// In the vault's world of a filled document: the filled fields still on it and the innermost elements whose
    /// text holds a filled secret, spaces and dashes aside (`window.__yardletVaultSecrets`, which the fill keeps there).
    static let secretElements = """
        (() => {
          const plain = s => (s || '').replace(/[\\s\\-\\u2013\\u00b7\\u2022]/g, '');
          const found = new Set((window.__yardletVault || []).filter(e => e.isConnected));
          for (const value of new Set((window.__yardletVaultSecrets || []).map(plain).filter(v => v.length >= 4))) {
            if (!document.body || !plain(document.body.textContent).includes(value)) continue;
            let level = [document.body];
            while (level.length) {
              const next = [];
              for (const e of level) {
                const inner = Array.from(e.children).filter(c => plain(c.textContent).includes(value));
                if (inner.length) next.push(...inner); else found.add(e);
              }
              level = next;
            }
          }
          return Array.from(found).slice(0, 64);
        })()
        """

    // MARK: Pieces

    /// The page's main frame as the browser reports it: its ID, the document it shows, and its origin.
    private func mainFrame(of page: BrowserAgentPage) async throws -> (id: String, loaderID: String, origin: String) {
        let tree = try await send(page, "Page.getFrameTree")
        let frame = tree["frameTree"]?["frame"]
        guard let id = frame?["id"]?.stringValue else { throw BrowserAgentToolError("The browser did not describe the page.") }
        let origin = frame?["securityOrigin"]?.stringValue.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            ?? frame?["url"]?.stringValue.flatMap(VaultSite.origin(of:)) ?? ""
        return (id, frame?["loaderId"]?.stringValue ?? "", origin)
    }

    private func callInVaultWorld(_ page: BrowserAgentPage, _ objectID: String, _ function: String,
                                  arguments: [JSONValue] = []) async throws -> JSONValue {
        let result = try await send(page, "Runtime.callFunctionOn", [
            "functionDeclaration": .string(function), "objectId": .string(objectID),
            "arguments": .array(arguments.map { .object(["value": $0]) }), "returnByValue": .bool(true)
        ])
        if result["exceptionDetails"] != nil {
            throw BrowserAgentToolError("The fill did not run on this page.")
        }
        return result["result"]?["value"] ?? .null
    }

    private static func fillFailure(_ code: String, ref: String) -> String {
        switch code {
        case "no sign-in field": "\(ref) is not in a form with a username or password field."
        case "nothing to fill": "The item has no value for the fields of this form."
        case "not a code field": "\(ref) is not a one-time code field."
        case "not enough code boxes": "The code boxes after \(ref) are fewer than the code's digits."
        case "moved": "The page went to another site before Yardlet could fill it; nothing was filled."
        case "not a password field": "\(ref) is not a password field."
        default: "The fill did not run on this page."
        }
    }

    /// Runs in the vault's isolated world with the field as `this`. A password goes only into a
    /// password field, a username into a text field of the same form, a code into a code field
    /// (design §5.2 step 3), and a password the vault made into a password field and its confirmation (§15);
    /// nothing goes into a document of another origin than the one the values were given for (the page may have
    /// moved on since). The fields that took a secret (a password, a code; not the username) and the secrets
    /// themselves are kept in this world, which the page's scripts cannot reach, for `secretElements`.
    static let fillFunction = """
        function(kind, username, password, code, origin) {
          const target = this;
          if (typeof origin === 'string' && location.origin !== origin) return { error: 'moved' };
          const visible = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
          const textTypes = ['text', 'email', 'tel', 'url', ''];
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          const put = (e, v) => {
            e.focus();
            setter.call(e, v);
            e.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const isInput = e => e instanceof HTMLInputElement;
          const secret = [], values = [], kinds = [];
          if (kind === 'login') {
            const scope = (isInput(target) && target.form) || target.closest('form') || document;
            const inputs = Array.from(scope.querySelectorAll('input')).filter(e => !e.disabled && !e.readOnly && visible(e));
            const passwordField = isInput(target) && target.type === 'password' ? target : inputs.find(e => e.type === 'password');
            let userField = null;
            if (isInput(target) && target.type !== 'password' && textTypes.includes(target.type)) {
              userField = target;
            } else {
              userField = inputs.find(e => textTypes.includes(e.type) && (e.autocomplete || '').split(/\\s+/).includes('username'))
                || (passwordField ? inputs.slice(0, inputs.indexOf(passwordField)).reverse().find(e => textTypes.includes(e.type)) : null);
            }
            if (!passwordField && !userField) return { error: 'no sign-in field' };
            if (typeof password === 'string' && passwordField) { put(passwordField, password); secret.push(passwordField); values.push(password); kinds.push('password'); }
            if (typeof username === 'string' && userField) { put(userField, username); kinds.push('username'); }
            if (!kinds.length) return { error: 'nothing to fill' };
          } else if (kind === 'one_time_code') {
            \(VaultPageScripts.codeFieldTests)
            if (!isCodeField(target) || typeof code !== 'string') return { error: 'not a code field' };
            if (target.maxLength === 1) {
              const scope = target.form || target.closest('form') || document;
              const boxes = Array.from(scope.querySelectorAll('input')).filter(e => e.maxLength === 1 && visible(e));
              const run = boxes.slice(boxes.indexOf(target), boxes.indexOf(target) + code.length);
              if (run.length < code.length) return { error: 'not enough code boxes' };
              run.forEach((e, i) => { put(e, code[i]); secret.push(e); });
            } else {
              put(target, code); secret.push(target);
            }
            values.push(code);
            kinds.push('one_time_code');
          } else if (kind === 'new_password') {
            \(VaultPageScripts.newPasswordTests)
            if (!isInput(target) || target.type !== 'password' || typeof password !== 'string') return { error: 'not a password field' };
            const fields = newPasswordFields(target);
            for (const e of fields.length ? fields : [target]) { put(e, password); secret.push(e); madePasswords().add(e); }
            values.push(password);
            kinds.push(fields.length > 1 ? 'new_password_and_confirmation' : 'new_password');
          }
          window.__yardletVault = (window.__yardletVault || []).concat(secret);
          window.__yardletVaultSecrets = (window.__yardletVaultSecrets || []).concat(values);
          return { kinds };
        }
        """

    /// Where a form sends its fields, and how (`get`, `post`).
    struct FormTarget: Equatable {
        var action: String
        var method: String
    }

    /// Where the field's form sends its fields: `form` (whether the field is in one), and `targets`, the form's
    /// action and each submit button's own (`formaction`, `formmethod`) as absolute addresses, leaving out a
    /// `method="dialog"` that sends nothing. A field in no form has none: the page's script sends what it sends. The
    /// prototype's getters keep a field named `action` from answering.
    static let submissionFunction = """
        function() {
          const form = (this instanceof HTMLInputElement && this.form) || this.closest('form');
          if (!form) return { form: false, targets: [] };
          const get = (type, name, e) => Object.getOwnPropertyDescriptor(type.prototype, name).get.call(e);
          const formAction = get(HTMLFormElement, 'action', form), formMethod = get(HTMLFormElement, 'method', form);
          const targets = [{ action: formAction, method: formMethod }];
          for (const e of get(HTMLFormElement, 'elements', form)) {
            const type = e instanceof HTMLButtonElement ? HTMLButtonElement : e instanceof HTMLInputElement ? HTMLInputElement : null;
            if (!type || !['submit', 'image'].includes(get(type, 'type', e))) continue;
            targets.push({ action: e.hasAttribute('formaction') ? get(type, 'formAction', e) : formAction,
                           method: e.hasAttribute('formmethod') ? get(type, 'formMethod', e) : formMethod });
          }
          return { form: true, targets: targets.filter(t => t.method !== 'dialog') };
        }
        """

    /// Whether a form may send the item's secrets to `destination`: one of the item's sites over https (or the
    /// exact local origin a development item names), or a `javascript:` action, which sends nothing.
    static func isItemDestination(_ destination: String, of item: VaultItem) -> Bool {
        if destination.lowercased().hasPrefix("javascript:") { return true }
        guard let origin = VaultSite.origin(of: destination) else { return false }
        return item.sites.contains { VaultSite.matches($0, origin: origin) }
    }

    static let addressRisk = "the form sends its fields in the page's address (it has no method=\"post\"), which would "
        + "put the password there."

    /// Why Yardlet does not submit a form that holds a secret itself, or nil for a safe one: every way it sends goes
    /// to the page's own origin over https (or to the local development server the page is on), and by POST when it
    /// holds a password, which GET would put in the address. A one-time code may go by GET: it is spent once sent. An
    /// action of `javascript:` leaves sending to the page's script.
    static func submissionRisk(_ targets: [FormTarget], pageOrigin: String, password: Bool) -> String? {
        if password, targets.contains(where: { $0.method.lowercased() != "post" }) { return addressRisk }
        for target in targets where !target.action.lowercased().hasPrefix("javascript:") {
            guard let origin = VaultSite.origin(of: target.action), origin == VaultSite.origin(of: pageOrigin) else {
                return "the form sends its fields to \(VaultSite.origin(of: target.action) ?? "another address"), not to "
                    + "this page's own address."
            }
            if origin.hasPrefix("http://"), VaultSite.normalize(origin) != origin {
                return "the form sends its fields over plain http."
            }
        }
        return nil
    }

    /// Submits the field's form as a click on its submit button would (handlers that listen for the
    /// click still run): `submitted`, or `no form` when the field is in none. A form that holds a password
    /// and is sent by GET, as one without `method="post"` is, would put the password in the address: it is
    /// left unsent (`address`).
    static let submitFunction = """
        function() {
          const form = (this instanceof HTMLInputElement && this.form) || this.closest('form');
          if (!form) return 'no form';
          const button = Array.from(form.querySelectorAll('button, input[type=submit], input[type=image]'))
            .find(b => (b.type || 'submit') === 'submit' && !b.disabled);
          const get = (type, name, e) => Object.getOwnPropertyDescriptor(type.prototype, name).get.call(e);
          const method = button && button.hasAttribute('formmethod') ? button.formMethod : get(HTMLFormElement, 'method', form);
          const password = Array.from(get(HTMLFormElement, 'elements', form))
            .some(e => e instanceof HTMLInputElement && e.type === 'password' && e.value);
          if (method === 'get' && password) return 'address';
          if (button) button.click(); else if (form.requestSubmit) form.requestSubmit(); else form.submit();
          return 'submitted';
        }
        """
}
