import Foundation
import YardletRemote

/// What a watched tab's page copies because of a remote device's input, for that device's clipboard
/// (docs/REMOTE_PROTOCOL.md §15.25, `tabCopied`): the device's ⌘C and ⌘X on the page, and the page's own copy right after
/// the device's click or key (a Copy button: `navigator.clipboard.writeText` or `write`, or `document.execCommand`).
///
/// Chromium writes a page's copy to this Mac's clipboard and tells no one, so while a device watches the tab a script in
/// the page's own world takes the page's copies first and offers each to this Mac (`Runtime.addBinding`). A copy that
/// follows the watching device's own input, with nothing done to the page here or by the agent since, in the document
/// that took that input while it still has the user activation the input gave (read with Chromium's own getter, kept
/// before the page's scripts run), goes to that device and nowhere else: this Mac's clipboard is not the device's, as a
/// remote click's downloads are refused here. A page the input led to that copies as it loads has no activation, so it
/// cannot put text on the device's clipboard unasked. Any other copy (the person here, the agent) goes on to this Mac's
/// clipboard as the page asked. The device's ⌘C and ⌘X run the page's copy in Yardlet's own world, which the page
/// cannot change, from the focused frame's selection, as Chromium copies.
///
/// Never copied out: a password field or a field drawn as dots (Chromium does not copy those either), and text that
/// carries a value the password manager filled. The script leaves the page once no device watches the tab.
@MainActor
final class RemoteTabCopies {
    /// The binding the page's script offers copies through, and the object it answers on: one name for this Mac's run.
    let binding = "__yardletCopy" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    var control: String { binding + "Answer" }
    /// Whether the tab is watched by a device now, as the bridge holds it.
    var isWatched: (BrowserTab) -> Bool = { _ in false }
    /// Sends the copy to the connection whose watch `permit` is.
    var deliver: (BrowserTab, String, RemoteTabPermit) -> Void = { _, _, _ in }
    /// Whether text carries a value the password manager filled lately.
    var carriesFilledValue: (String) -> Bool = { _ in true }
    /// Whether a device may see the tab's page now, its frames included (not a `file:` page outside the task's files).
    var showsPage: (BrowserTab) async -> Bool = { _ in false }

    private struct Hook {
        var tab: BrowserTab
        var observer: UUID
        /// The script for each new document (`Page.addScriptToEvaluateOnNewDocument`), once added.
        var script: String?
        var installing: Task<Void, Never>?
    }

    private var hooks: [BrowserTabID: Hook] = [:]
    /// The page's contexts the script runs in, as each says (`hello`): let go of when the watch ends, and taken again
    /// when another begins, while the tab stays open.
    private var contexts: [BrowserTabID: Set<Int64>] = [:]
    /// The last click or key of a device on each tab, and when: the page's copy within `tabCopyWindow` of it is that
    /// device's, while the device's input is still the last.
    private var inputs: [BrowserTabID: (permit: RemoteTabPermit, at: ContinuousClock.Instant)] = [:]

    // MARK: - Watching

    /// The page's copies are taken while a device watches the tab, and the script lets them go once none does.
    func setWatched(_ watched: Bool, tab: BrowserTab) {
        if watched {
            guard hooks[tab.id] == nil, !tab.isClosed else { return }
            let observer = tab.devTools.observeEvents { [weak self, weak tab] method, params in
                guard method == "Runtime.bindingCalled", let self, let tab,
                      params["name"]?.stringValue == self.binding else { return }
                self.pageSaid(params["payload"]?.stringValue ?? "", context: params["executionContextId"]?.integerValue, on: tab)
            }
            hooks[tab.id] = Hook(tab: tab, observer: observer)
            hooks[tab.id]?.installing = Task { [weak self] in await self?.install(on: tab, hook: observer) }
        } else if let hook = hooks.removeValue(forKey: tab.id) {
            inputs[tab.id] = nil
            guard !tab.isClosed else {
                hook.installing?.cancel()
                contexts[tab.id] = nil
                return tab.devTools.stopObservingEvents(hook.observer)
            }
            Task { [weak self] in await self?.uninstall(hook) }
        }
    }

    /// The tab closed or is no longer the session's: nothing more to let go of in it.
    func forget(_ tab: BrowserTab) {
        contexts[tab.id] = nil
        inputs[tab.id] = nil
        guard let hook = hooks.removeValue(forKey: tab.id) else { return }
        hook.installing?.cancel()
        tab.devTools.stopObservingEvents(hook.observer)
    }

    /// Puts the script in for the watch whose observer is `hook`.
    private func install(on tab: BrowserTab, hook: UUID) async {
        let devTools = tab.devTools
        let timeout = RemoteTabBridge.inputTimeout
        _ = try? await devTools.send("Page.enable", timeout: timeout)
        _ = try? await devTools.send("Runtime.addBinding", ["name": .string(binding)], timeout: timeout)
        let source = Self.hookScript(binding: binding, control: control)
        let added = try? await devTools.send("Page.addScriptToEvaluateOnNewDocument", ["source": .string(source)], timeout: timeout)
        let script = added?["identifier"]?.stringValue
        guard !Task.isCancelled, hooks[tab.id]?.observer == hook else {
            // The watch ended while the script went in: it comes out again.
            if let script {
                _ = try? await devTools.send("Page.removeScriptToEvaluateOnNewDocument", ["identifier": .string(script)], timeout: timeout)
            }
            return
        }
        hooks[tab.id]?.script = script
        // The page shown now, and the documents an earlier watch let go of, take copies again.
        _ = try? await devTools.send("Runtime.evaluate", ["expression": .string(source)], timeout: timeout)
        await call("on()", in: contexts[tab.id] ?? [], of: tab)
    }

    /// The watched tab's page finished loading: one that began before the script went in takes it now (a document that
    /// has it only says `hello` again).
    func pageLoaded(_ tab: BrowserTab) {
        guard let hook = hooks[tab.id], hook.script != nil else { return }
        let source = Self.hookScript(binding: binding, control: control)
        Task {
            _ = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(source)], timeout: RemoteTabBridge.inputTimeout)
        }
    }

    /// Lets the page's copies go as the page asks in every document that took them, and takes the script out; a watch
    /// that began again meanwhile keeps them.
    private func uninstall(_ hook: Hook) async {
        let tab = hook.tab
        // A copy offered meanwhile is not the device's: it goes on as the page asked, without waiting; a document that
        // took the script meanwhile lets copies go at once.
        let observer = tab.devTools.observeEvents { [weak self, weak tab] method, params in
            guard method == "Runtime.bindingCalled", let self, let tab, self.hooks[tab.id] == nil,
                  params["name"]?.stringValue == self.binding,
                  let context = params["executionContextId"]?.integerValue else { return }
            let payload = params["payload"]?.stringValue ?? ""
            if payload == Self.hello {
                Task { await self.call("off()", in: [context], of: tab) }
            } else if let id = Self.offer(payload)?.id {
                self.answer(id, taken: false, context: context, on: tab)
            }
        }
        tab.devTools.stopObservingEvents(hook.observer)
        defer { tab.devTools.stopObservingEvents(observer) }
        await hook.installing?.value
        let timeout = RemoteTabBridge.inputTimeout
        if let script = hook.script {
            _ = try? await tab.devTools.send("Page.removeScriptToEvaluateOnNewDocument", ["identifier": .string(script)],
                                             timeout: timeout)
        }
        guard hooks[tab.id] == nil, !tab.isClosed else { return }
        _ = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(release)], timeout: timeout)
        await call("off()", in: contexts[tab.id] ?? [], of: tab)
        if hooks[tab.id] == nil {
            _ = try? await tab.devTools.send("Runtime.removeBinding", ["name": .string(binding)], timeout: timeout)
        }
    }

    private var release: String { "globalThis[\(Self.literal(control))]?.off()" }

    /// Calls the script's `on()` or `off()` in each context, forgetting the ones that are gone (their page moved on).
    private func call(_ method: String, in known: Set<Int64>, of tab: BrowserTab) async {
        for context in known {
            let answered = try? await tab.devTools.send("Runtime.evaluate", [
                "expression": .string("globalThis[\(Self.literal(control))]?.\(method)"), "contextId": .integer(context)
            ], timeout: RemoteTabBridge.inputTimeout)
            if answered == nil { contexts[tab.id]?.remove(context) }
        }
    }

    // MARK: - Input

    /// A device's click, press or key reached the page: what the page copies within `tabCopyWindow` is that device's.
    func noteInput(on tab: BrowserTab, permit: RemoteTabPermit) {
        inputs[tab.id] = (permit, .now)
    }

    /// The device's ⌘C or ⌘X: the page's copy (or cut) of the focused frame's selection, run in Yardlet's own world,
    /// and what it copied for the device. Nothing from a password field or a field drawn as dots.
    func copy(on tab: BrowserTab, cut: Bool, permit: RemoteTabPermit) async throws {
        noteInput(on: tab, permit: permit)
        guard !tab.isPasswordFieldFocused else { return }
        let devTools = tab.devTools
        let timeout = RemoteTabBridge.inputTimeout
        let tree = try await devTools.send("Page.getFrameTree", [:], timeout: timeout)
        guard let frame = tree["frameTree"]?["frame"]?["id"]?.stringValue else { return }
        let world = try await devTools.send("Page.createIsolatedWorld", [
            "frameId": .string(frame), "worldName": .string(Self.worldName)
        ], timeout: timeout)
        guard let context = world["executionContextId"]?.integerValue else { return }
        let copied = try await devTools.send("Runtime.callFunctionOn", [
            "functionDeclaration": .string(Self.copyFunction), "executionContextId": .integer(context),
            "arguments": .array([.object(["value": .bool(cut)]), .object(["value": .bool(true)])]),
            "returnByValue": .bool(true), "userGesture": .bool(true)
        ], timeout: timeout)
        guard let text = copied["result"]?["value"]?["text"]?.stringValue else { return }
        send(text, from: tab, permit: permit)
    }

    // MARK: - The page's copies

    private static func offer(_ payload: String) -> (id: Int64, text: String, active: Bool)? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
              let id = value["id"]?.integerValue, let text = value["text"]?.stringValue else { return nil }
        return (id, text, value["active"] == .bool(true))
    }

    /// What the page's script said: a document took the script (`hello`), or the page copies text, which goes to the
    /// device whose input it follows, or, when it follows none, on to this Mac's clipboard as the page asked.
    private func pageSaid(_ payload: String, context: Int64?, on tab: BrowserTab) {
        guard let context, hooks[tab.id] != nil else { return }
        if payload == Self.hello {
            contexts[tab.id, default: []].insert(context)
            return
        }
        guard let offer = Self.offer(payload) else { return }
        guard offer.active, let permit = devicesCopy(on: tab) else {
            return answer(offer.id, taken: false, context: context, on: tab)
        }
        // The device's copy, whether or not it may have it: never this Mac's clipboard.
        answer(offer.id, taken: true, context: context, on: tab)
        Task { [weak self] in
            guard let self, await self.showsPage(tab) else { return }
            self.send(offer.text, from: tab, permit: permit)
        }
    }

    /// The device whose input the page's copy follows now: its click or key was the last input to the page, within
    /// Chromium's user activation, and it still watches the tab. The page says whether the copying document has that
    /// activation (`offer`'s `active`).
    private func devicesCopy(on tab: BrowserTab) -> RemoteTabPermit? {
        guard let input = inputs[tab.id], input.permit.isValid, isWatched(tab), tab.remoteInputIsLast,
              ContinuousClock.now - input.at <= .seconds(RemoteProtocol.tabCopyWindow) else { return nil }
        return input.permit
    }

    private func answer(_ id: Int64, taken: Bool, context: Int64, on tab: BrowserTab) {
        let expression = "globalThis[\(Self.literal(control))]?.answer(\(id), \(taken))"
        Task {
            _ = try? await tab.devTools.send("Runtime.evaluate", [
                "expression": .string(expression), "contextId": .integer(context)
            ], timeout: RemoteTabBridge.inputTimeout)
        }
    }

    /// The device's copy goes to it, unless it is too long or carries a filled value: then it goes nowhere, and not to
    /// this Mac's clipboard either.
    private func send(_ text: String, from tab: BrowserTab, permit: RemoteTabPermit) {
        guard !text.isEmpty, text.utf8.count <= RemoteProtocol.maxTabCopyBytes, !carriesFilledValue(text),
              permit.isValid, isWatched(tab) else { return }
        deliver(tab, text, permit)
    }

    private static func literal(_ text: String) -> String {
        let encoded = (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) }
        return encoded ?? "\"\""
    }

    // MARK: - Scripts

    static let worldName = "yardlet-remote-copy"
    static let hello = #"{"hello":1}"#

    /// The page's copy of its selection, as Chromium's copy and cut commands make it: a `copy` (or `cut`) event at the
    /// selection or the focused field, the page's own data when it takes the event over, else the selected text; a cut
    /// then deletes the selection in a field or editable text. `deep` starts from the focused frame (same-site frames and
    /// open shadow roots), as ⌘C does. Nothing from a password field or a field drawn as dots. `{text}`, or null.
    static let copyFunction = """
        function (cut, deep) {
          let doc = document, active = doc.activeElement;
          while (deep && active) {
            if (active.shadowRoot && active.shadowRoot.activeElement) { active = active.shadowRoot.activeElement; continue; }
            let inner = null;
            if (active.tagName === 'IFRAME' || active.tagName === 'FRAME') { try { inner = active.contentDocument; } catch (e) {} }
            if (!inner) break;
            doc = inner;
            active = inner.activeElement;
          }
          const view = doc.defaultView || window;
          const secret = element => {
            if (!element || element.nodeType !== 1) return false;
            if (element.tagName === 'INPUT' && String(element.type).toLowerCase() === 'password') return true;
            try {
              const style = view.getComputedStyle(element);
              return (style.getPropertyValue('-webkit-text-security') || 'none') !== 'none';
            } catch (e) { return false; }
          };
          if (secret(active)) return null;
          const field = active && (active.tagName === 'TEXTAREA'
            || (active.tagName === 'INPUT' && typeof active.selectionStart === 'number')) ? active : null;
          const selection = doc.getSelection();
          const node = selection && selection.anchorNode;
          const anchor = node ? (node.nodeType === 1 ? node : node.parentElement) : null;
          if (!field && secret(anchor)) return null;
          let selected = '';
          if (field) { try { selected = field.value.slice(field.selectionStart, field.selectionEnd); } catch (e) {} }
          else if (selection) { selected = String(selection); }
          const editable = field ? !field.readOnly && !field.disabled
            : Boolean((active && active.isContentEditable) || (anchor && anchor.isContentEditable));
          const target = field || (active && active.isContentEditable ? active : null) || anchor || doc.body || doc.documentElement;
          if (!target) return null;
          const data = new view.DataTransfer();
          const event = new view.ClipboardEvent(cut ? 'cut' : 'copy',
            { bubbles: true, cancelable: true, composed: true, clipboardData: data });
          let text = selected;
          if (!target.dispatchEvent(event)) text = data.getData('text/plain');
          else if (cut && selected && editable) doc.execCommand('delete');
          return text ? { text } : null;
        }
        """

    /// The script in the page's own world of a watched tab: `navigator.clipboard.writeText` and `write` (its text) and
    /// `document.execCommand('copy')` and `('cut')` offer what they copy through `binding`, with whether the document has
    /// user activation as the call is made, and wait for the answer on `control`: taken, the copy is the device's and goes no further; not taken, or no answer within a second, the
    /// page's own call goes on (an `execCommand` copy then as `writeText`, since its selection is gone by then). `off()`
    /// lets every copy go as the page asks, `on()` takes them again; each document says `hello` as it takes them.
    static func hookScript(binding: String, control: String) -> String {
        """
        (() => {
          const existing = globalThis[\(literal(control))];
          if (existing) { existing.on(); return; }
          const send = globalThis[\(literal(binding))];
          if (typeof send !== 'function') return;
          const copyHere = \(copyFunction);
          const writeText = globalThis.Clipboard && Clipboard.prototype.writeText;
          const write = globalThis.Clipboard && Clipboard.prototype.write;
          const execCommand = Document.prototype.execCommand;
          const activation = globalThis.UserActivation
            && Object.getOwnPropertyDescriptor(UserActivation.prototype, 'isActive');
          const userActivation = navigator.userActivation;
          const active = () => { try { return activation.get.call(userActivation) === true; } catch (e) { return false; } };
          const waiting = new Map();
          let armed = false, next = 0, copying = false;
          const offer = (text, activated = active()) => new Promise(resolve => {
            if (!armed || typeof text !== 'string' || !text) return resolve(false);
            const id = ++next;
            waiting.set(id, resolve);
            setTimeout(() => { if (waiting.delete(id)) resolve(false); }, 1000);
            try { send(JSON.stringify({ id, text, active: activated })); } catch (e) { waiting.delete(id); resolve(false); }
          });
          Object.defineProperty(globalThis, \(literal(control)), { configurable: true, value: {
            answer(id, taken) { const resolve = waiting.get(id); if (resolve) { waiting.delete(id); resolve(taken === true); } },
            on() { armed = true; try { send(\(literal(hello))); } catch (e) {} },
            off() { armed = false; for (const resolve of waiting.values()) resolve(false); waiting.clear(); }
          } });
          if (writeText) Clipboard.prototype.writeText = { writeText(data) {
            if (!armed || arguments.length < 1) return writeText.apply(this, arguments);
            const self = this, args = arguments;
            return offer(String(data)).then(taken => taken ? undefined : writeText.apply(self, args));
          } }.writeText;
          if (write) Clipboard.prototype.write = { write(items) {
            if (!armed || arguments.length < 1) return write.apply(this, arguments);
            const self = this, args = arguments, activated = active();
            return (async () => {
              let text = null;
              try {
                for (const item of items) {
                  if (item.types.includes('text/plain')) { text = await (await item.getType('text/plain')).text(); break; }
                }
              } catch (e) {}
              if (text !== null && await offer(text, activated)) return undefined;
              return write.apply(self, args);
            })();
          } }.write;
          Document.prototype.execCommand = { execCommand(command) {
            const kind = String(command).toLowerCase();
            if (!armed || copying || this !== document || (kind !== 'copy' && kind !== 'cut')) return execCommand.apply(this, arguments);
            copying = true;
            let copied = null;
            try { copied = copyHere(kind === 'cut', false); } catch (e) {} finally { copying = false; }
            if (!copied) return false;
            offer(copied.text).then(taken => {
              if (!taken && writeText) writeText.call(navigator.clipboard, copied.text).catch(() => {});
            });
            return true;
          } }.execCommand;
          globalThis[\(literal(control))].on();
        })()
        """
    }
}
