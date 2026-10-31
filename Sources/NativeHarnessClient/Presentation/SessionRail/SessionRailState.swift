import Foundation
import Observation

/// The cards of a task's session rail, the Claude app's Code tab "Session details" rail
/// (2.42304.0, `c227f4d5e-*.js` `xZ`), in its default order. Every harness shows the same rail; a card
/// whose harness reports nothing for it is left out rather than drawn empty.
enum SessionRailCardKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case environment
    case goal
    case settings
    case context
    case usage
    case connectors
    case progress
    case outputs
    /// The Claude app's `pullRequests` card, titled "Changes".
    case changes
    case servers
    /// The task's suggested tasks (`spawn_task` chips) nobody has started or dismissed, kept in sight
    /// however far the conversation scrolls; just before the Agents card, where a started one goes on
    /// as a child task.
    case suggestions
    /// The agents working for the task (`SessionRailAgents`), before its background tasks as the Codex
    /// app's "Subagents" comes before its "Background processes".
    case agents
    case backgroundTasks
    /// A small live view of the browser tab or the computer the agent is using (`SessionRailPreview`),
    /// where the Codex app puts its Computer Use picture in picture: after the background processes.
    case preview

    var id: String { rawValue }

    static let defaultOrder: [SessionRailCardKind] = allCases

    /// `kZ`: the cards that start folded.
    static let foldedByDefault: Set<SessionRailCardKind> = [.connectors, .context, .usage, .backgroundTasks]

    /// `SZ`: the environment card cannot be hidden.
    var canHide: Bool { self != .environment }

    /// The Claude app's titles (`K7kuIZkkhY`, `0VV/sKbpDb`, `D3idYvSLF9`, `V2qutIKrxy`, `wbsq7OdxnV`,
    /// `2mMJRvsAg1`, `sIMS7iH+wa`, `ohKjpG6KDI`, `dgqhUM6BxJ`, `QOxktDjUiT`, `PO+0DdDIId`); Agents is the
    /// Claude app's `+0I7HUJ9U4`, Preview Yardlet's for the Codex app's picture in picture.
    var title: String {
        switch self {
        case .environment: L10n.string("Environment")
        case .goal: L10n.string("Goal")
        case .settings: L10n.string("Settings")
        case .context: L10n.string("Context")
        case .usage: L10n.string("Usage")
        case .connectors: L10n.string("Connectors")
        case .progress: L10n.string("Progress")
        case .outputs: L10n.string("Outputs")
        case .changes: L10n.string("Changes")
        case .servers: L10n.string("Servers")
        case .suggestions: L10n.string("Suggested tasks")
        case .agents: L10n.string("Agents")
        case .backgroundTasks: L10n.string("Background tasks")
        case .preview: L10n.string("Preview")
        }
    }

    /// Kinds read from storage, dropping any this build does not know.
    fileprivate static func known(_ values: [String]) -> [SessionRailCardKind] {
        values.compactMap(SessionRailCardKind.init(rawValue:))
    }
}

/// What the person chose for every task's rail: which cards it hides and their order. The Claude
/// app keeps the same two globally (`epitaxy.sessionRailSections` `hidden`, `order`).
struct SessionRailPreferences: Equatable, Sendable {
    private(set) var hidden: Set<SessionRailCardKind> = []
    /// The order as the person left it; `resolvedOrder` adds what it lacks.
    private(set) var order: [SessionRailCardKind] = SessionRailCardKind.defaultOrder

    init(hidden: Set<SessionRailCardKind> = [], order: [SessionRailCardKind] = SessionRailCardKind.defaultOrder) {
        self.hidden = hidden.filter(\.canHide)
        self.order = order
    }

    var isDefault: Bool { hidden.isEmpty && resolvedOrder == SessionRailCardKind.defaultOrder }

    /// Two preferences are the same when they hide the same cards and draw them in the same order.
    static func == (left: Self, right: Self) -> Bool {
        left.hidden == right.hidden && left.resolvedOrder == right.resolvedOrder
    }

    /// Every card once, in the person's order. A card the stored order lacks (one a later build
    /// added) goes after the nearest card that comes before it by default, as the Claude app puts a
    /// missing `servers` before `backgroundTasks` (`qZ`).
    var resolvedOrder: [SessionRailCardKind] {
        var result: [SessionRailCardKind] = []
        for kind in order where !result.contains(kind) { result.append(kind) }
        let defaults = SessionRailCardKind.defaultOrder
        for (index, kind) in defaults.enumerated() where !result.contains(kind) {
            let earlier = defaults[..<index].reversed().first { result.contains($0) }
            let position = earlier.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(kind, at: position)
        }
        return result
    }

    func isHidden(_ kind: SessionRailCardKind) -> Bool { kind.canHide && hidden.contains(kind) }

    /// "Show ▸ {card}" in a card header's menu.
    mutating func setHidden(_ kind: SessionRailCardKind, _ isHidden: Bool) {
        guard kind.canHide else { return }
        if isHidden { hidden.insert(kind) } else { hidden.remove(kind) }
    }

    /// A card dropped on another: it takes that card's place, and the cards from there move down.
    /// Dropped past the last card (`target` nil), it goes last.
    mutating func move(_ kind: SessionRailCardKind, before target: SessionRailCardKind?) {
        guard kind != target else { return }
        var result = resolvedOrder.filter { $0 != kind }
        let position = target.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(kind, at: position)
        order = result
    }

    /// "Move up" / "Move down": past the next card the rail shows (`shown`), so hidden and empty
    /// cards are passed over rather than costing a step.
    mutating func move(_ kind: SessionRailCardKind, by offset: Int, among shown: [SessionRailCardKind]) {
        guard offset != 0, let index = shown.firstIndex(of: kind) else { return }
        let destination = index + offset
        guard shown.indices.contains(destination) else { return }
        let neighbor = shown[destination]
        var result = resolvedOrder.filter { $0 != kind }
        guard let neighborIndex = result.firstIndex(of: neighbor) else { return }
        // Up goes just before the card passed, down just after it.
        result.insert(kind, at: offset < 0 ? neighborIndex : neighborIndex + 1)
        order = result
    }

    /// "Reset to defaults": every card shown, in the default order.
    mutating func reset() {
        hidden = []
        order = SessionRailCardKind.defaultOrder
    }
}

extension SessionRailPreferences: Codable {
    private enum CodingKeys: String, CodingKey { case hidden, order }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hidden = SessionRailCardKind.known(try container.decodeIfPresent([String].self, forKey: .hidden) ?? [])
        let order = SessionRailCardKind.known(try container.decodeIfPresent([String].self, forKey: .order) ?? [])
        self.init(hidden: Set(hidden), order: order.isEmpty ? SessionRailCardKind.defaultOrder : order)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        try container.encode(resolvedOrder.map(\.rawValue), forKey: .order)
    }
}

/// Which cards one task's rail has folded, kept with the task's other panel state. As the Claude app
/// keeps them per session (`foldsBySession`), a card that starts folded records only that it was
/// opened, and any other card only that it was folded, so a later default still reaches the cards
/// the person never touched.
struct SessionRailFolds: Equatable, Sendable {
    private(set) var opened: Set<SessionRailCardKind> = []
    private(set) var folded: Set<SessionRailCardKind> = []

    init(opened: Set<SessionRailCardKind> = [], folded: Set<SessionRailCardKind> = []) {
        self.opened = opened.intersection(SessionRailCardKind.foldedByDefault)
        self.folded = folded.subtracting(SessionRailCardKind.foldedByDefault)
    }

    var isDefault: Bool { opened.isEmpty && folded.isEmpty }

    func isFolded(_ kind: SessionRailCardKind) -> Bool {
        SessionRailCardKind.foldedByDefault.contains(kind) ? !opened.contains(kind) : folded.contains(kind)
    }

    mutating func setFolded(_ kind: SessionRailCardKind, _ isFolded: Bool) {
        if SessionRailCardKind.foldedByDefault.contains(kind) {
            if isFolded { opened.remove(kind) } else { opened.insert(kind) }
        } else {
            if isFolded { folded.insert(kind) } else { folded.remove(kind) }
        }
    }

    /// A header's Option-click folds or opens every card, as the Claude app's `setAllOpen`.
    mutating func setAll(folded isFolded: Bool, kinds: [SessionRailCardKind] = SessionRailCardKind.allCases) {
        for kind in kinds { setFolded(kind, isFolded) }
    }
}

extension SessionRailFolds: Codable {
    private enum CodingKeys: String, CodingKey { case opened, folded }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            opened: Set(SessionRailCardKind.known(try container.decodeIfPresent([String].self, forKey: .opened) ?? [])),
            folded: Set(SessionRailCardKind.known(try container.decodeIfPresent([String].self, forKey: .folded) ?? [])))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opened.map(\.rawValue).sorted(), forKey: .opened)
        try container.encode(folded.map(\.rawValue).sorted(), forKey: .folded)
    }
}

/// The person's rail preferences, kept in Yardlet's own defaults for every window and task.
@MainActor
@Observable
final class SessionRailPreferenceStore {
    static let defaultsKey = "Yardlet.sessionRail"

    private(set) var preferences: SessionRailPreferences
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .yardlet) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(SessionRailPreferences.self, from: $0) } ?? SessionRailPreferences()
    }

    func update(_ change: (inout SessionRailPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        if next.isDefault {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Whether a window's rail is shown, and where. The Claude app keeps one switch (`sessionRailShown`,
/// default on); Yardlet keeps it per window (`MainWindow`'s scene storage). The rail sits beside the
/// conversation when the task's area has room for it (`SessionRailPlacement`); where it has not, the
/// same switch raises it over the task's trailing edge until it is dismissed, as the Claude app's
/// toggle "raises" its rail in a narrow window (`raises`, `dn`).
struct SessionRailVisibility: Equatable, Sendable {
    /// The window's switch.
    var isShown = true
    /// The task whose rail is raised over its content, while one is.
    private(set) var raisedTaskID: UUID?
    /// The tasks whose area had room for the rail beside the conversation when last on screen. A task
    /// that shows tells it again (`setFits`).
    private(set) var fittingTaskIDs: Set<UUID> = []

    init(isShown: Bool = true) {
        self.isShown = isShown
    }

    func isInline(_ taskID: UUID) -> Bool { isShown && fittingTaskIDs.contains(taskID) }

    func isRaised(_ taskID: UUID) -> Bool { raisedTaskID == taskID && !isInline(taskID) }

    /// The rail is on screen for the task, beside the conversation or raised over it.
    func isOnScreen(_ taskID: UUID) -> Bool { isInline(taskID) || isRaised(taskID) }

    /// The title bar button, the View menu and ⌃⌘I (the Claude app's `vn`): a rail on screen goes
    /// away — a raised one is dismissed, an inline one turns the switch off — and otherwise the switch
    /// turns on and, where the task's area has no room, the rail rises over it.
    mutating func toggle(for taskID: UUID?) {
        guard let taskID else {
            isShown.toggle()
            raisedTaskID = nil
            return
        }
        if isRaised(taskID) {
            raisedTaskID = nil
        } else if isInline(taskID) {
            isShown = false
        } else {
            isShown = true
            raisedTaskID = fittingTaskIDs.contains(taskID) ? nil : taskID
        }
    }

    /// The task's area grew or shrank past what the rail needs. A raised rail that now fits takes
    /// its place beside the conversation.
    mutating func setFits(_ fits: Bool, for taskID: UUID) {
        if fits {
            fittingTaskIDs.insert(taskID)
            if isShown, raisedTaskID == taskID { raisedTaskID = nil }
        } else {
            fittingTaskIDs.remove(taskID)
        }
    }

    /// Escape or a click outside the raised rail.
    mutating func dismissRaised() { raisedTaskID = nil }

    /// A task left the screen: a rail raised over it goes. Whether its area has room stays until it
    /// shows again and tells it, so a task whose views the window keeps (`TaskSurfaceHost`) changes
    /// nothing its rail reads on the way out.
    mutating func forget(_ taskID: UUID) {
        if raisedTaskID == taskID { raisedTaskID = nil }
    }
}

/// One window's rail visibility, observed by the views that draw or toggle it and not by the window.
@MainActor
@Observable
final class SessionRailWindowState {
    var visibility: SessionRailVisibility

    init(isShown: Bool = true) {
        visibility = SessionRailVisibility(isShown: isShown)
    }

    func toggle(for taskID: UUID?) { visibility.toggle(for: taskID) }

    func setFits(_ fits: Bool, for taskID: UUID) {
        guard visibility.fittingTaskIDs.contains(taskID) != fits else { return }
        visibility.setFits(fits, for: taskID)
    }

    func dismissRaised() {
        guard visibility.raisedTaskID != nil else { return }
        visibility.dismissRaised()
    }

    func forget(_ taskID: UUID) {
        guard visibility.raisedTaskID == taskID else { return }
        visibility.forget(taskID)
    }

    /// "Hide session rail" while it is on screen for the task, otherwise "Show session rail"
    /// (the Claude app's `U0R7oYkTM1`, `JYaBivMdHH`).
    func toggleTitle(for taskID: UUID?) -> String {
        let onScreen = taskID.map(visibility.isOnScreen) ?? visibility.isShown
        return L10n.string(onScreen ? "Hide session rail" : "Show session rail")
    }
}

/// Where the rail fits: a fixed 280 pt column beside the conversation (the Claude app's
/// `--session-rail-w`, 17.5rem), shown when the task's area — the conversation's side of it, without
/// a side panel — is at least 611 pt wide, or 771 pt while a side panel is open beside it (`My`: `Ay`,
/// `jy`). A side panel expanded over the conversation leaves no room.
enum SessionRailPlacement {
    static let width: CGFloat = 280
    static let cardSpacing: CGFloat = 10
    static let minimumAloneWidth: CGFloat = 611
    static let minimumBesidePanelWidth: CGFloat = 771

    /// - Parameters:
    ///   - sessionWidth: the width the conversation and the rail share (the task's area less an open
    ///     side panel and its divider).
    ///   - panelOpen: a side panel is open beside it.
    static func fits(sessionWidth: CGFloat, panelOpen: Bool) -> Bool {
        sessionWidth >= (panelOpen ? minimumBesidePanelWidth : minimumAloneWidth)
    }
}
