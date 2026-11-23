import Foundation
import Observation
import UIKit
import YardletRemote

/// A task's browser tabs on the connection (docs/REMOTE_PROTOCOL.md §15.25), as the Mac's own remote window keeps them:
/// the tab screen shows one task's tabs and watches one of them while it is on screen; while none shows, the
/// conversation on screen follows its task's list alone where the Mac offers that (`tabLists`), so it knows whether the
/// task has tabs. One watch per connection: each request goes out in the order these calls make them, and the next
/// watch replaces the last. Every frame is acknowledged once decoded, on the connection it came on, also one of a tab no
/// longer watched; only the latest picture is kept, in memory.
@MainActor
@Observable
final class TaskBrowser {
    /// The watched tab's latest picture, decoded.
    struct Picture {
        let image: UIImage
        let tabID: String
        /// The visible page in CSS pixels: what input counts in.
        let viewportWidth: Double
        let viewportHeight: Double
    }

    /// The size the tab screen asks the tab to be drawn at: its page area in points, which the page takes as CSS pixels
    /// as Safari on the phone does, and the largest picture it wants, the same area in pixels.
    struct Size: Equatable {
        var viewport: RemoteTabViewport
        var maxWidth: Int
        var maxHeight: Int

        init?(width: Double, height: Double, scale: Double) {
            guard let fitted = RemoteTabViewport.fitted(width: width, height: height, scale: scale) else { return nil }
            viewport = fitted.viewport
            maxWidth = fitted.maxWidth
            maxHeight = fitted.maxHeight
        }
    }

    /// Why the Mac did not take the person's input, a tab control or a permission's answer.
    enum Refusal: Equatable {
        case refused(RemoteError?)
        /// A `file:` address outside the task's files, which opens only on the Mac (§15.30).
        case fileOutside
        /// The permission prompt answered is no longer up: answered on the Mac, or the page moved on or asked again.
        case permissionGone
    }

    // MARK: - What the Mac answers

    /// The Mac shows a task's tabs to the phone (`browserTabs`).
    private(set) var isOffered = false
    /// It follows a task's list without a watched tab (`tabLists`).
    private(set) var listsTabs = false
    /// It takes addresses and closes tabs (`tabControls`, §15.30).
    private(set) var controlsTabs = false
    /// It takes the answer to a site's permission prompt (`tabPermissions`).
    private(set) var answersPermissions = false
    /// It sends what the page copies after the phone's own input (`tabCopy`).
    @ObservationIgnored private var copiesFromPage = false
    /// It sends the next frame while the last one's acknowledgement is on its way (`tabFramesInFlight`): frames show in
    /// the order they came, so the phone asks for two.
    @ObservationIgnored private var takesFramesInFlight = false

    /// Sends a request in the order of the ones before it; `HostSession` sets it.
    @ObservationIgnored var transport: (RemoteRequest, ((RemoteResponse) -> Void)?) -> Void = { _, _ in }
    @ObservationIgnored var isConnected: () -> Bool = { false }

    // MARK: - The tab screen

    /// The task whose browser the tab screen shows; nil while it is not on screen.
    private(set) var taskID: String?
    private(set) var tabs: [RemoteBrowserTab] = []
    private(set) var tabID: String?
    private(set) var picture: Picture?
    /// The Mac answered the watch, so `tabs` is its list.
    private(set) var isListed = false
    /// The Mac has no browser to show now.
    private(set) var isUnavailable = false
    var refusal: Refusal?
    /// The permission prompt answered from here: its bar stays down while the Mac's list still has it.
    private(set) var answeredPrompt: Int?

    /// Each task's tabs as the Mac last listed them, for the conversation's browser button.
    private var remembered: [String: [RemoteBrowserTab]] = [:]
    /// The task whose conversation is on screen, followed while the tab screen shows none.
    @ObservationIgnored private var followed: String?
    @ObservationIgnored private var size: Size?
    /// Opened without a tab named: the tab that waits on the person comes first.
    @ObservationIgnored private var prefersWaiting = false
    @ObservationIgnored private var watchRevision = 0
    @ObservationIgnored private var resize: Task<Void, Never>?
    @ObservationIgnored private var pendingScroll: (x: Double, y: Double, deltaX: Double, deltaY: Double)?
    @ObservationIgnored private var scrollFlush: Task<Void, Never>?
    /// Counts connections: an answer or a frame of an earlier one changes nothing.
    @ObservationIgnored private var connection = 0
    /// Frames in the order they arrived, so a picture decoded late never replaces a newer one.
    @ObservationIgnored private var framesArrived = 0
    @ObservationIgnored private var frameShown = 0

    /// How long the screen stays at a new size before the tab takes it: the screen's first layouts pass through others.
    nonisolated static let resizeRest: Duration = .milliseconds(200)
    /// Scrolling goes at most this often, the movements between added up.
    nonisolated static let scrollInterval: Duration = .milliseconds(100)

    var watchedTab: RemoteBrowserTab? { tabs.first { $0.tabId == tabID } }

    /// The watched tab's permission prompt for its bar, while the Mac takes its answer from here and it was not answered
    /// from here already.
    var pendingPermission: RemoteTabPermission? {
        guard answersPermissions, let permission = watchedTab?.permission, permission.prompt != answeredPrompt else { return nil }
        return permission
    }

    /// The task's tabs as the Mac last listed them to the phone.
    func tabs(for taskID: String) -> [RemoteBrowserTab] {
        remembered[taskID] ?? []
    }

    /// What the snapshot says the Mac answers.
    func apply(_ snapshot: RemoteResponse) {
        isOffered = snapshot.browserTabs == true
        listsTabs = isOffered && snapshot.tabLists == true
        controlsTabs = isOffered && snapshot.tabControls == true
        answersPermissions = isOffered && snapshot.tabPermissions == true
        copiesFromPage = isOffered && snapshot.tabCopy == true
        takesFramesInFlight = isOffered && snapshot.tabFramesInFlight == true
    }

    // MARK: - Watching

    /// The tab screen shows the task's browser: `tabID`, else the tab it showed, else the one waiting, else the front tab.
    func show(_ taskID: String, tabID: String?) {
        if self.taskID != taskID {
            self.taskID = taskID
            tabs = remembered[taskID] ?? []
            self.tabID = nil
            picture = nil
            isListed = false
            isUnavailable = false
            answeredPrompt = nil
            prefersWaiting = tabID == nil
        }
        refusal = nil
        watch(tabID ?? self.tabID)
    }

    /// The tab screen left: the watch ends, or goes back to the followed conversation's list. Its picture goes.
    func hide() {
        guard let taskID else { return }
        self.taskID = nil
        tabs = []
        tabID = nil
        picture = nil
        isListed = false
        isUnavailable = false
        refusal = nil
        answeredPrompt = nil
        resize?.cancel()
        scrollFlush?.cancel()
        scrollFlush = nil
        pendingScroll = nil
        followList(ending: taskID)
    }

    /// The conversation of `taskID` is on screen.
    func follow(_ taskID: String) {
        guard followed != taskID else { return }
        followed = taskID
        if self.taskID == nil { followList(ending: nil) }
    }

    /// The conversation of `taskID` left the screen; another one's follow is not touched.
    func unfollow(_ taskID: String) {
        guard followed == taskID else { return }
        followed = nil
        if self.taskID == nil { followList(ending: taskID) }
    }

    /// A new connection, once its snapshot said what the Mac answers: the tab screen's watch again, else the followed list.
    func rewatch() {
        if taskID != nil {
            watch(tabID)
        } else {
            followList(ending: nil)
        }
    }

    /// The connection ended: what was asked on it is answered no more, and a scroll waiting to go goes nowhere.
    func connectionEnded() {
        connection += 1
        scrollFlush?.cancel()
        scrollFlush = nil
        pendingScroll = nil
        resize?.cancel()
        // An answer that may not have reached the Mac: the next list says whether the prompt is still up.
        answeredPrompt = nil
    }

    func select(_ tabID: String) {
        guard tabID != self.tabID else { return }
        prefersWaiting = false
        watch(tabID)
    }

    /// The screen's page area, watched once it rests there: the screen opening, the phone turning, a bar coming.
    func setSize(_ size: Size) {
        guard size != self.size else { return }
        self.size = size
        resize?.cancel()
        guard taskID != nil else { return }
        resize = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeRest)
            guard !Task.isCancelled, let self, self.taskID != nil else { return }
            self.watch(self.tabID)
        }
    }

    /// The list alone (`listOnly`), where the Mac offers it; with nothing to follow, the watch of `ending` stops.
    private func followList(ending: String?) {
        watchRevision += 1
        guard let task = followed, listsTabs else {
            if let ending { send(.unwatchTab(taskID: ending)) }
            return
        }
        let revision = watchRevision
        send(.watchTab(taskID: task, tabID: nil, maxWidth: nil, maxHeight: nil, listOnly: true)) { [weak self] response in
            guard let self, response.ok, self.taskID == nil, self.watchRevision == revision else { return }
            self.remember(response.tabs ?? [], for: task)
        }
    }

    /// Watches `tabID` of the shown task (the front tab when nil), once the screen's size is known.
    private func watch(_ tabID: String?) {
        guard let taskID else { return }
        if tabID != self.tabID {
            self.tabID = tabID
            picture = nil
        }
        guard let size, isOffered else { return }
        resize?.cancel()
        watchRevision += 1
        let revision = watchRevision
        send(.watchTab(taskID: taskID, tabID: tabID, maxWidth: size.maxWidth, maxHeight: size.maxHeight,
                       viewport: size.viewport, framesInFlight: takesFramesInFlight ? 2 : nil)) { [weak self] response in
            guard let self, self.taskID == taskID, self.watchRevision == revision else { return }
            if response.ok {
                self.watched(taskID, response)
            } else if response.error?.code == .notFound, tabID != nil {
                // The tab closed meanwhile: the front tab.
                self.watch(nil)
            } else {
                self.isListed = true
                self.isUnavailable = response.error?.code == .unavailable
            }
        }
    }

    private func watched(_ taskID: String, _ response: RemoteResponse) {
        let listed = response.tabs ?? []
        remember(listed, for: taskID)
        tabs = listed
        isListed = true
        isUnavailable = false
        let chosen = response.tabId.flatMap { id in listed.contains { $0.tabId == id } ? id : nil }
        if chosen != tabID {
            tabID = chosen
            picture = nil
        }
        if prefersWaiting {
            prefersWaiting = false
            let waiting = listed.first { $0.requestId != nil } ?? listed.first { $0.waiting != nil }
            if let waiting, waiting.tabId != chosen { watch(waiting.tabId) }
        }
    }

    private func remember(_ tabs: [RemoteBrowserTab], for taskID: String) {
        if remembered[taskID] != tabs { remembered[taskID] = tabs }
    }

    // MARK: - What the Mac sends

    func receive(_ event: RemoteEvent) {
        switch event.event {
        case .tabFrame:
            frame(event)
        case .browserTabsChanged:
            tabsChanged(event)
        case .tabCopied:
            // Copied by the page after this phone's own input: a copy made here (§15.25).
            if copiesFromPage, let text = event.text, !text.isEmpty { UIPasteboard.general.string = text }
        default:
            break
        }
    }

    /// Decoded off the main thread, then acknowledged on the connection it came on, then shown if still watched.
    private func frame(_ event: RemoteEvent) {
        guard let number = event.frame else { return }
        let connection = connection
        framesArrived += 1
        let order = framesArrived
        let data = event.image
        Task { [weak self] in
            let image = await Self.decode(data)
            guard let self, self.connection == connection else { return }
            self.send(.tabFrameAck(taskID: event.taskId ?? "", tabID: event.tabId ?? "", frame: number))
            guard order > self.frameShown, let taskID = self.taskID, event.taskId == taskID, let tabID = self.tabID,
                  event.tabId == tabID, let viewportWidth = event.viewportWidth, let viewportHeight = event.viewportHeight,
                  viewportWidth > 0, viewportHeight > 0,
                  // A picture that does not decode keeps the last one on screen.
                  let image else { return }
            self.frameShown = order
            self.picture = Picture(image: image, tabID: tabID, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }
    }

    nonisolated private static func decode(_ data: Data?) async -> UIImage? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let image = UIImage(data: data)
            return image?.preparingForDisplay() ?? image
        }.value
    }

    private func tabsChanged(_ event: RemoteEvent) {
        guard let taskID = event.taskId else { return }
        let listed = event.tabs ?? []
        remember(listed, for: taskID)
        guard self.taskID == taskID else { return }
        tabs = listed
        // The watched tab closed, or the task had none: the Mac's front tab now.
        if let tabID, !listed.contains(where: { $0.tabId == tabID }) {
            watch(listed.first { $0.active == true }?.tabId ?? listed.first?.tabId)
        } else if tabID == nil, !listed.isEmpty {
            watch(nil)
        }
    }

    // MARK: - The person's input

    /// One input to the watched tab; a long text goes in parts the Mac takes. A scroll waiting to go goes first.
    func input(_ input: RemoteTabInput) {
        guard let taskID, let tabID else { return }
        if input.kind != .scroll { flushScroll() }
        let parts = input.kind == .text ? Self.textParts(input.text ?? "").map(RemoteTabInput.text) : [input]
        for part in parts {
            send(.tabInput(taskID: taskID, tabID: tabID, input: part)) { [weak self] response in
                guard !response.ok else { return }
                self?.refuse(taskID, .refused(response.error))
            }
        }
    }

    /// A finger's movement on the page, sent at most ten times a second with the movements between added up.
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        let pending = pendingScroll
        pendingScroll = (x, y, (pending?.deltaX ?? 0) + deltaX, (pending?.deltaY ?? 0) + deltaY)
        guard scrollFlush == nil else { return }
        scrollFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.scrollInterval)
            guard !Task.isCancelled, let self else { return }
            self.scrollFlush = nil
            self.flushScroll()
        }
    }

    private func flushScroll() {
        guard let pending = pendingScroll else { return }
        scrollFlush?.cancel()
        scrollFlush = nil
        let deltaX = pending.deltaX.rounded(), deltaY = pending.deltaY.rounded()
        // What is under a whole pixel stays for the next movement: the Mac refuses a scroll of nothing.
        pendingScroll = (pending.x, pending.y, pending.deltaX - deltaX, pending.deltaY - deltaY)
        guard deltaX != 0 || deltaY != 0 else { return }
        input(RemoteTabInput(kind: .scroll, x: pending.x, y: pending.y, deltaX: deltaX, deltaY: deltaY))
    }

    /// §15.30: an address or a search in the watched tab, as the Mac's address field takes it; the screen then watches
    /// the tab it opened in.
    func openAddress(_ address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard controlsTabs, let taskID, !text.isEmpty else { return }
        flushScroll()
        send(.openTab(taskID: taskID, tabID: tabID, address: text)) { [weak self] response in
            guard let self, self.taskID == taskID else { return }
            if response.ok {
                if let opened = response.tabId, !opened.isEmpty {
                    self.prefersWaiting = false
                    self.watch(opened)
                }
            } else if response.error?.code == .notAllowed, text.lowercased().hasPrefix("file:") {
                self.refusal = .fileOutside
            } else {
                self.refusal = .refused(response.error)
            }
        }
    }

    /// §15.30: asks the tab to close; the list says whether it did.
    func closeTab(_ tabID: String) {
        guard controlsTabs, let taskID else { return }
        send(.closeTab(taskID: taskID, tabID: tabID)) { [weak self] response in
            guard !response.ok else { return }
            self?.refuse(taskID, .refused(response.error))
        }
    }

    /// The site's permission prompt on the watched tab, answered as the Mac panel's bar answers it, in order with the
    /// tab's input. The bar goes at once; a refusal brings it back, unless the prompt is no longer up, which nothing waits
    /// for. The prompt's number goes back exactly as the Mac sent it.
    func answerPermission(_ answer: RemoteTabPermissionAnswer) {
        guard let taskID, let tabID, let prompt = pendingPermission?.prompt else { return }
        flushScroll()
        answeredPrompt = prompt
        refusal = nil
        let sent = send(.answerTabPermission(taskID: taskID, tabID: tabID, prompt: prompt, answer: answer)) { [weak self] response in
            guard let self, !response.ok else { return }
            let gone = response.error?.code == .notFound
            if !gone, self.answeredPrompt == prompt { self.answeredPrompt = nil }
            self.refuse(taskID, gone ? .permissionGone : .refused(response.error))
        }
        if !sent { answeredPrompt = nil }
    }

    private func refuse(_ taskID: String, _ refusal: Refusal) {
        if self.taskID == taskID { self.refusal = refusal }
    }

    /// Sends `request` while connected; its answer is read only while the connection it went on lasts.
    @discardableResult
    private func send(_ request: RemoteRequest, onResponse: ((RemoteResponse) -> Void)? = nil) -> Bool {
        guard isConnected() else { return false }
        let connection = connection
        transport(request) { [weak self] response in
            guard let self, self.connection == connection else { return }
            onResponse?(response)
        }
        return true
    }

    /// Parts of at most `maxTabInputCharacters` characters and `maxTabInputBytes` bytes, never a character split in two.
    nonisolated static func textParts(_ text: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var characters = 0
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            if characters == RemoteProtocol.maxTabInputCharacters || bytes + size > RemoteProtocol.maxTabInputBytes, !part.isEmpty {
                parts.append(part)
                part = ""
                characters = 0
                bytes = 0
            }
            part.append(character)
            characters += 1
            bytes += size
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }
}

/// Follows the phone's field under the tab's picture and says what the page should get (§15.25): committed text as
/// `text`, and a Backspace for each character of sent text the field lost. What the keyboard is still composing stays on
/// the phone until committed: marked text (a word with its candidates), and on a keyboard that composes in place, as
/// iOS's Korean keyboard replaces the last syllable while its letters join, a new last syllable until the next character
/// or a commit. While a keyboard marks text, nothing is taken back, since it may take a sent word back into its
/// composition and commit it again.
struct TypedText {
    enum Typed: Equatable {
        case text(String)
        /// One Backspace on the page: text already sent was deleted in the field.
        case backspace
    }

    /// What the page has from the field, as the field still shows it.
    private var sent = ""

    /// The field now holds `text`, the keyboard marking from `composingFrom` (UTF-16 offset) to the end, or composing
    /// its last character in place (`composesInPlace`).
    mutating func changed(_ text: String, composingFrom start: Int? = nil, composesInPlace: Bool = false) -> [Typed] {
        if let start, start < text.utf16.count {
            let index = String.Index(utf16Offset: max(0, start), in: text)
            let committed = String(text[..<index])
            guard committed.count > sent.count, committed.hasPrefix(sent) else { return [] }
            let added = String(committed.dropFirst(sent.count))
            sent = committed
            return [.text(added)]
        }
        let common = zip(sent, text).prefix { $0 == $1 }.count
        var typed = [Typed](repeating: .backspace, count: sent.count - common)
        var added = String(text.dropFirst(common))
        var page = text
        if composesInPlace, let last = added.last, Self.isHangul(last) {
            added.removeLast()
            page.removeLast()
        }
        if !added.isEmpty { typed.append(.text(added)) }
        sent = page
        return typed
    }

    /// The field was emptied; the page keeps what it has.
    mutating func reset() {
        sent = ""
    }

    /// A Hangul syllable or letter, which the next letter typed may still change.
    static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value)
                || (0xA960...0xA97F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value)
                || (0xD7B0...0xD7FF).contains($0.value)
        }
    }
}
