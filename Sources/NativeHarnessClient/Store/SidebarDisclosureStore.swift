import Foundation
import Observation

/// Which sidebar projects are collapsed and how far each has been opened with "Show more", kept
/// as the Codex app keeps them: collapsing is remembered across launches (the app stores it per
/// project in local storage), "Show more" lasts until the project is collapsed or the app quits.
/// A project nobody collapsed is expanded.
@MainActor
@Observable
final class SidebarDisclosureStore {
    static let collapsedProjectsKey = "Yardlet.sidebar.collapsedProjects"

    private(set) var collapsedKeys: Set<String>
    private(set) var revealedPages: [String: Int] = [:]

    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameter defaults: where collapsing is kept; nil keeps it only while the store lives (another Mac's window,
    ///   which leaves nothing of its host's projects on this Mac).
    init(defaults: UserDefaults? = .yardlet) {
        self.defaults = defaults
        collapsedKeys = Set(defaults?.stringArray(forKey: Self.collapsedProjectsKey) ?? [])
    }

    /// The state the sidebar layout reads, with the Codex app's row limit.
    var disclosure: SidebarDisclosure {
        SidebarDisclosure(
            collapsedKeys: collapsedKeys,
            revealedPages: revealedPages,
            rowLimit: SidebarDisclosure.codexRowLimit
        )
    }

    func isCollapsed(_ key: String) -> Bool {
        collapsedKeys.contains(key)
    }

    func toggle(_ key: String) {
        if isCollapsed(key) { expand(key) } else { collapse(key) }
    }

    /// Collapsing also forgets "Show more", as the Codex app does.
    func collapse(_ key: String) {
        revealedPages[key] = nil
        guard collapsedKeys.insert(key).inserted else { return }
        persist()
    }

    func expand(_ key: String) {
        guard collapsedKeys.remove(key) != nil else { return }
        persist()
    }

    /// Lists ten more of the project's rows.
    func showMore(_ key: String) {
        revealedPages[key, default: 0] += 1
    }

    private func persist() {
        defaults?.set(collapsedKeys.sorted(), forKey: Self.collapsedProjectsKey)
    }
}
