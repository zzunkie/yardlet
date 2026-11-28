import Foundation
import YardletCEFBridge

/// Checks browser signals and queries every frame before releasing a hidden tab's browser. A renderer-only
/// discard also confirms that the process holds no other browser's frames before terminating it.
@MainActor
final class TabDiscarder {
    enum Action {
        case discardRenderer
        case releaseBrowser(allowAgentForm: Bool)
    }

    private struct Asking {
        let query: Int32
        let urgent: Bool
        let action: Action
        let asked: Int
        var answers: [Int32] = []
        /// Every frame answered and nothing kept the page: the main frame's last answer ends it.
        var confirming = false
    }

    /// How long the host waits for every frame to answer; a frame that does not (its renderer is busy) keeps the tab.
    static let answerWait: TimeInterval = 3

    private let send: ([String: Any]) -> Void
    private var asking: [Int: Asking] = [:]
    /// Tabs whose renderer `yardlet_cef_discard` is ending.
    private var ending: Set<Int> = []
    private var nextQuery: Int32 = 1

    init(send: @escaping ([String: Any]) -> Void) {
        self.send = send
    }

    /// `urgent`: the Mac is short of memory (Chrome's urgent discarding, which does not keep a tab for its notification
    /// permission).
    func discard(tab: Int, urgent: Bool, action: Action = .discardRenderer) {
        guard asking[tab] == nil else { return }
        guard !ending.contains(tab) else { return refuse(tab, "ending") }
        var signals = YardletCEFPageSignals()
        guard yardlet_cef_page_signals(Int32(tab), &signals) == 1 else { return refuse(tab, "gone") }
        if let reason = Self.refusal(signals, urgent: urgent) { return refuse(tab, reason) }
        let query = takeQuery()
        let asked = Int(yardlet_cef_ask_page_state(Int32(tab), query))
        guard asked > 0 else { return refuse(tab, asked < 0 ? "gone" : "no frames") }
        asking[tab] = Asking(query: query, urgent: urgent, action: action, asked: asked)
        expire(tab: tab, query: query)
    }

    /// A frame of the tab answered (YardletCEFEventPageState).
    func answered(tab: Int, query: Int, flags: Int32) {
        guard var state = asking[tab], Int(state.query) == query else { return }
        if state.confirming { return confirmed(tab: tab, state: state, main: flags) }
        state.answers.append(flags)
        asking[tab] = state
        guard state.answers.count >= state.asked else { return }
        // What the browser process knows may have changed while the frames answered (a load began).
        var signals = YardletCEFPageSignals()
        guard yardlet_cef_page_signals(Int32(tab), &signals) == 1 else { return drop(tab, "gone") }
        if let reason = Self.refusal(signals, urgent: state.urgent) ?? Self.refusal(state.answers, action: state.action) {
            return drop(tab, reason)
        }
        if case .releaseBrowser = state.action {
            asking[tab] = nil
            send(["demotionReady": ["tab": tab]])
            return
        }
        let last = takeQuery()
        guard yardlet_cef_ask_main_frame(Int32(tab), last) == 1 else { return drop(tab, "gone") }
        asking[tab] = Asking(query: last, urgent: state.urgent, action: .discardRenderer, asked: 1, confirming: true)
        expire(tab: tab, query: last)
    }

    /// The tab's renderer ended for the discard (YardletCEFEventDiscarded).
    func discarded(tab: Int) {
        ending.remove(tab)
        HostLog.write("tab discarded tab=\(tab)")
        send(["discarded": ["tab": tab]])
    }

    /// The tab's renderer ended some other way (YardletCEFEventPageCrashed): a discard it was ending for is over.
    func rendererEnded(tab: Int) {
        ending.remove(tab)
        asking[tab] = nil
    }

    /// The person or the agent turned to the tab, its page asked something of the person or began a download, or the tab
    /// closed: a question still out is dropped, and the tab is kept.
    func cancel(tab: Int) {
        guard asking.removeValue(forKey: tab) != nil else { return }
        refuse(tab, "shown")
    }

    /// The main frame's last answer: the page ends unless its renderer holds another tab's frame by now.
    private func confirmed(tab: Int, state: Asking, main flags: Int32) {
        asking[tab] = nil
        let main = Int(flags)
        guard main & Int(YardletPageStateMain) != 0, main & Int(YardletPageStateUnknown) == 0 else { return refuse(tab, "unread") }
        // Ending the renderer would end another tab's page or frame too.
        if main & Int(YardletPageStateShared) != 0 { return refuse(tab, "shared") }
        var signals = YardletCEFPageSignals()
        guard yardlet_cef_page_signals(Int32(tab), &signals) == 1 else { return refuse(tab, "gone") }
        if let reason = Self.refusal(signals, urgent: state.urgent) { return refuse(tab, reason) }
        guard yardlet_cef_discard(Int32(tab)) == 1 else { return refuse(tab, "not ended") }
        ending.insert(tab)
    }

    private func takeQuery() -> Int32 {
        let query = nextQuery
        nextQuery = nextQuery == Int32.max ? 1 : nextQuery + 1
        return query
    }

    /// A question not answered within `answerWait` keeps the tab.
    private func expire(tab: Int, query: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.asking[tab]?.query == query else { return }
                self.drop(tab, "unanswered")
            }
        }
    }

    private func drop(_ tab: Int, _ reason: String) {
        asking[tab] = nil
        refuse(tab, reason)
    }

    private func refuse(_ tab: Int, _ reason: String) {
        HostLog.write("tab discard refused tab=\(tab) reason=\(reason)")
        send(["discardRefused": ["tab": tab, "reason": reason]])
    }

    /// What the browser process knows that keeps a page, as Chrome's DiscardEligibilityPolicy keeps it. Chrome keeps a
    /// page that is audible or was within a minute; CEF says only when a page begins to play sound, not when it stops,
    /// so a page that began to in its current document is kept until it moves to another.
    static func refusal(_ signals: YardletCEFPageSignals, urgent: Bool) -> String? {
        if signals.loading != 0 { return "loading" }
        if signals.capturing != 0 { return "capturing" }
        if signals.audibleAgo >= 0 { return "audible" }
        // A reload would send the form again; Chrome would ask first.
        if signals.postData != 0 { return "post" }
        if signals.pdf != 0 { return "pdf" }
        if !urgent, signals.notifications != 0 { return "notifications" }
        return nil
    }

    /// What the page's renderers said that keeps it: playing media (also where no sound began, as a muted page
    /// unmuted), a form field changed, or a frame that could not be read.
    static func refusal(_ answers: [Int32], action: Action) -> String? {
        func any(_ flag: Int) -> Bool { answers.contains { Int($0) & flag != 0 } }
        if any(Int(YardletPageStateUnknown)) { return "unread" }
        if any(Int(YardletPageStatePlaying)) { return "media" }
        guard let main = answers.first(where: { Int($0) & Int(YardletPageStateMain) != 0 }) else { return "unanswered" }
        // Ending the renderer would end another tab's page or frame too.
        switch action {
        case .discardRenderer:
            if any(Int(YardletPageStateEdited)) { return "form" }
            return Int(main) & Int(YardletPageStateShared) != 0 ? "shared" : nil
        case .releaseBrowser(let allowAgentForm):
            return !allowAgentForm && any(Int(YardletPageStateEdited)) ? "form" : nil
        }
    }
}
