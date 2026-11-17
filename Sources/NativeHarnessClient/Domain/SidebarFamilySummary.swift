import Foundation

/// What the line under a collapsed family says, as the Claude app's `df-family-stub`: how many nested tasks it hides,
/// and of those how many failed, have something new and are working. The Mac's line
/// (`SidebarFamilySummaryLine`) and the Windows sidebar's both read it.
struct SidebarFamilySummary: Equatable, Sendable {
    var sessions = 0
    var failed = 0
    var new = 0
    var working = 0

    static func counts(of hidden: [SessionRecord], details: [UUID: TaskAttentionDetail] = [:],
                       shellBusy: Set<UUID> = []) -> SidebarFamilySummary {
        var counts = SidebarFamilySummary(sessions: hidden.count)
        for session in hidden {
            switch SidebarTaskIndicatorProjection.status(of: session, detail: details[session.id],
                                                         isShellBusy: shellBusy.contains(session.id)) {
            case .failed?: counts.failed += 1
            case .running?: counts.working += 1
            default: break
            }
            if session.hasUnreadUpdate { counts.new += 1 }
        }
        return counts
    }

    /// "3 nested sessions", or "3 more nested sessions" when some are still listed.
    static func sessionsText(_ count: Int, more: Bool) -> String {
        if more {
            return count == 1 ? L10n.string("1 more nested session") : L10n.format("%lld more nested sessions", count)
        }
        return count == 1 ? L10n.string("1 nested session") : L10n.format("%lld nested sessions", count)
    }

    /// The parts after the count, in the Claude app's order.
    static func detailTexts(_ counts: SidebarFamilySummary) -> (failed: String?, new: String?, working: String?) {
        (counts.failed > 0 ? L10n.format("%lld failed", counts.failed) : nil,
         counts.new > 0 ? L10n.format("%lld new", counts.new) : nil,
         counts.working > 0 ? L10n.format("%lld working", counts.working) : nil)
    }

    /// What the line says to assistive apps: Claude's "Show {sessions}, {news}".
    static func accessibilityLabel(_ counts: SidebarFamilySummary, more: Bool) -> String {
        let sessions = sessionsText(counts.sessions, more: more)
        guard let new = detailTexts(counts).new else { return L10n.format("Show %@", sessions) }
        return L10n.format("Show %@, %@", sessions, new)
    }

    /// The whole line as one text, as its tooltip shows it: the count, then the details.
    static func help(_ counts: SidebarFamilySummary, more: Bool) -> String {
        let details = detailTexts(counts)
        let parts = [details.failed, details.new, details.working].compactMap { $0 }
        return ([sessionsText(counts.sessions, more: more)] + parts).joined(separator: " · ")
    }
}
