import Foundation
import Observation
import YardletRemote

/// A host's task browser as this Mac's window shows it (docs/REMOTE_PROTOCOL.md §15.25): the task's tabs, the watched
/// tab's latest picture, and the person's input to it. One task's browser at a time, while the window's browser panel
/// is open; frames stay in memory only and go with the panel.
@MainActor
@Observable
final class RemoteBrowserModel {
    struct Frame: Equatable {
        var number: Int
        var image: Data
        var width: Int
        var height: Int
        /// The visible page's size in CSS pixels: what input counts in.
        var viewportWidth: Double
        var viewportHeight: Double
    }

    /// The task whose browser the panel shows; nil while the panel is closed.
    private(set) var taskID: String?
    private(set) var tabs: [RemoteBrowserTab] = []
    private(set) var tabID: String?
    private(set) var frame: Frame?
    /// The host answered the watch: the list is the host's.
    private(set) var isListed = false
    /// The last input the host refused, in a line for the panel.
    var refusal: String?

    /// The host's name, for the panel's words.
    @ObservationIgnored var hostName = ""
    /// The largest picture to ask for: the panel's page area in pixels.
    @ObservationIgnored var pictureSize = (width: RemoteProtocol.defaultTabFrameWidth, height: RemoteProtocol.defaultTabFrameHeight)
    /// Sends a request in the order of the ones before it.
    @ObservationIgnored var send: (RemoteRequest, ((RemoteResponse) -> Void)?) -> Void = { _, _ in }
    @ObservationIgnored private var scroll: (x: Double, y: Double, deltaX: Double, deltaY: Double)?
    @ObservationIgnored private var scrollFlush: Task<Void, Never>?
    /// What the watch asked for, to ask again when the panel grows past it.
    @ObservationIgnored private var watchedSize: (width: Int, height: Int)?

    var watchedTab: RemoteBrowserTab? { tabs.first { $0.tabId == tabID } }

    // MARK: - Watching

    /// Opens the panel on the task's browser: the tab named, else the one its host's panel shows.
    func show(taskID: String, tabID: String? = nil) {
        if self.taskID != taskID {
            tabs = []
            isListed = false
            frame = nil
        }
        self.taskID = taskID
        refusal = nil
        watch(tabID ?? (self.taskID == taskID ? self.tabID : nil))
    }

    func hide() {
        guard let taskID else { return }
        send(.unwatchTab(taskID: taskID), nil)
        self.taskID = nil
        tabs = []
        tabID = nil
        frame = nil
        isListed = false
        watchedSize = nil
    }

    /// Watches the task's tab again after a new connection: what the panel showed, or its host's front tab.
    func rewatch() {
        guard taskID != nil else { return }
        watch(tabID)
    }

    func select(_ tabID: String) {
        guard tabID != self.tabID else { return }
        watch(tabID)
    }

    /// The panel's page area changed: a picture much larger than the one asked for is asked for again.
    func setPictureSize(width: Int, height: Int) {
        pictureSize = (min(max(width, 320), RemoteProtocol.maxTabFrameSide), min(max(height, 320), RemoteProtocol.maxTabFrameSide))
        guard let watchedSize, tabID != nil,
              pictureSize.width > watchedSize.width * 5 / 4 || pictureSize.height > watchedSize.height * 5 / 4 else { return }
        watch(tabID)
    }

    private func watch(_ tabID: String?) {
        guard let taskID else { return }
        let size = pictureSize
        watchedSize = size
        if tabID != self.tabID { frame = nil }
        self.tabID = tabID
        send(.watchTab(taskID: taskID, tabID: tabID, maxWidth: size.width, maxHeight: size.height)) { [weak self] response in
            guard let self, self.taskID == taskID else { return }
            if response.ok {
                self.tabs = response.tabs ?? []
                self.isListed = true
                if self.tabID != response.tabId { self.frame = nil }
                self.tabID = response.tabId
            } else if response.error?.code == .notFound, tabID != nil {
                // The tab closed meanwhile: the host's front tab.
                self.watch(nil)
            } else {
                self.isListed = true
            }
        }
    }

    // MARK: - What the host sends

    func receive(_ event: RemoteEvent) {
        guard let taskID, event.taskId == taskID else { return }
        switch event.event {
        case .tabFrame:
            guard event.tabId == tabID, let number = event.frame, let image = event.image else { return }
            frame = Frame(number: number, image: image, width: event.width ?? 0, height: event.height ?? 0,
                          viewportWidth: event.viewportWidth ?? 0, viewportHeight: event.viewportHeight ?? 0)
            send(.tabFrameAck(taskID: taskID, tabID: event.tabId ?? "", frame: number), nil)
        case .browserTabsChanged:
            tabs = event.tabs ?? []
            // The watched tab closed, or the task had none: the host's front tab now.
            if let tabID, !tabs.contains(where: { $0.tabId == tabID }) {
                watch(tabs.first { $0.active == true }?.tabId ?? tabs.first?.tabId)
            } else if tabID == nil, !tabs.isEmpty {
                watch(nil)
            }
        default:
            break
        }
    }

    // MARK: - Input

    /// A point of the picture as drawn `drawnWidth` wide, in the page's CSS pixels.
    func pagePoint(x: Double, y: Double, drawnWidth: Double) -> (x: Double, y: Double)? {
        guard let frame, drawnWidth > 0, frame.viewportWidth > 0 else { return nil }
        let factor = frame.viewportWidth / drawnWidth
        return (x * factor, y * factor)
    }

    func input(_ input: RemoteTabInput) {
        guard let taskID, let tabID else { return }
        if input.kind != .scroll { flushScroll() }
        send(.tabInput(taskID: taskID, tabID: tabID, input: input)) { [weak self] response in
            guard let self, !response.ok else { return }
            self.refusal = Self.refusal(response.error, host: self.hostName)
        }
    }

    /// A wheel's movement, sent at most ten times a second, the deltas between added up.
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        let pending = scroll
        scroll = (x, y, (pending?.deltaX ?? 0) + deltaX, (pending?.deltaY ?? 0) + deltaY)
        guard scrollFlush == nil else { return }
        scrollFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.scrollFlush = nil
            self?.flushScroll()
        }
    }

    private func flushScroll() {
        guard let pending = scroll else { return }
        scroll = nil
        scrollFlush?.cancel()
        scrollFlush = nil
        guard pending.deltaX != 0 || pending.deltaY != 0 else { return }
        input(RemoteTabInput(kind: .scroll, x: pending.x, y: pending.y, deltaX: pending.deltaX.rounded(),
                             deltaY: pending.deltaY.rounded()))
    }

    static func refusal(_ error: RemoteError?, host: String) -> String {
        switch error?.code {
        case .notAllowed?: L10n.format("A window or dialog over this page waits on %@.", host)
        case .notFound?: L10n.string("This tab is closed.")
        case .rateLimited?: L10n.string("Too many requests. Try again in a moment.")
        default: L10n.string("The page didn't take that.")
        }
    }
}
