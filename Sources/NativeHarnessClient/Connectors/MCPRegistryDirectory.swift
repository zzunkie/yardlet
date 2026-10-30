import Foundation
import Observation

/// What Add connector shows from the MCP registries: the GitHub registry's list a page at a time,
/// and both registries' matches for a search. Kept in memory for the app's run, read again after
/// six hours; nothing is written to disk (docs/CONNECTORS.md, "Registries").
@MainActor
@Observable
final class MCPRegistryDirectory {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var browsed: [MCPRegistryEntry] = []
    private(set) var browsePhase: Phase = .idle
    private(set) var hasMore = false
    private(set) var searched: (query: String, entries: [MCPRegistryEntry])?
    private(set) var searchPhase: Phase = .idle

    @ObservationIgnored private let client: MCPRegistryClient?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loading: Task<Void, Never>?
    static let maximumAge: TimeInterval = 6 * 60 * 60
    /// The GitHub registry lists several hundred; this is far above it and keeps a loop of pages
    /// from running on.
    static let maximumBrowsed = 2_000

    /// - Parameter client: nil where the registries are not asked (a render with fixed entries).
    init(client: MCPRegistryClient?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// Shows these entries without asking a registry (renders and tests).
    func show(_ entries: [MCPRegistryEntry], search: (query: String, entries: [MCPRegistryEntry])? = nil) {
        browsed = entries
        browsePhase = .loaded
        searched = search
        searchPhase = search == nil ? .idle : .loaded
        loadedAt = now()
    }

    /// The first page, unless one was read in the last six hours.
    func loadIfNeeded() async {
        if let loadedAt, now().timeIntervalSince(loadedAt) < Self.maximumAge, browsePhase == .loaded { return }
        if client != nil, browsePhase == .loaded || browsePhase == .idle || browsePhase.isFailure {
            browsed = []
            cursor = nil
            hasMore = false
            await loadPage()
        }
    }

    /// The next page, when there is one and none is being read.
    func loadMore() async {
        guard hasMore, loading == nil else { return }
        await loadPage()
    }

    private func loadPage() async {
        if let loading { return await loading.value }
        guard let client else { return }
        let task = Task { [cursor] in
            browsePhase = .loading
            do {
                let page = try await client.browse(cursor: cursor)
                browsed = MCPRegistryEntry.merged([browsed, page.entries])
                self.cursor = page.nextCursor
                hasMore = page.nextCursor != nil && browsed.count < Self.maximumBrowsed
                loadedAt = now()
                browsePhase = .loaded
            } catch {
                browsePhase = .failed(error.localizedDescription)
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    /// Both registries' matches for the words; the caller waits a moment after typing.
    func search(_ query: String) async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            searched = nil
            searchPhase = .idle
            return
        }
        guard searched?.query != words, let client else { return }
        searchPhase = .loading
        do {
            let lists = try await client.search(words)
            guard !Task.isCancelled else { return }
            searched = (words, MCPRegistryEntry.merged(lists))
            searchPhase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            searched = (words, [])
            searchPhase = .failed(error.localizedDescription)
        }
    }

    /// What the list shows: without a search, the servers that run at the service; with one,
    /// every match from the registries' answers and the pages read, programs and the rest
    /// included. Servers at a directory service's address or already added are left out.
    func entries(query: String, excludingAddresses excluded: Set<String>) -> [MCPRegistryEntry] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return MCPRegistryEntry.ranked(MCPRegistryEntry.merged([browsed], excludingAddresses: excluded)
                .filter(\.showsWithoutSearch))
        }
        let found = searched?.query == words ? searched?.entries ?? [] : []
        return MCPRegistryEntry.ranked(MCPRegistryEntry.merged([found, browsed.filter { $0.matches(words) }],
                                                                excludingAddresses: excluded))
    }
}

private extension MCPRegistryDirectory.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
