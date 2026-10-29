import Foundation

/// What the in-window browser visited, for the address field's suggestions (docs/BROWSER_HOST.md, "Address
/// suggestions"). One history for every task's tabs, as Chrome keeps one per profile: task profiles keep sign-ins
/// apart, while the pages are the person's. It is Yardlet's own file in the browser's root, `AddressHistory.json`:
/// Chromium's `History` in each profile counts every address CEF opens as typed (the agent's and restored tabs' too),
/// and CEF's C API neither reads nor deletes from it.
@MainActor
final class BrowserAddressHistory {
    struct Page: Codable, Equatable, Sendable {
        var url: String
        var title: String
        var visitCount: Int
        /// Visits the person started from the address field (Chrome's `typed_count`).
        var typedCount: Int
        var lastVisit: Date
        /// The newest visits first, as many as Chrome scores (`HQPMaxVisitsToScore`).
        var visits: [Visit]
    }

    struct Visit: Codable, Equatable, Sendable {
        var date: Date
        var typed: Bool
    }

    /// A search at the default search engine, suggested again as a search (Chrome's keyword search terms).
    struct Search: Codable, Equatable, Sendable {
        var terms: String
        var count: Int
        var lastVisit: Date
    }

    private struct Saved: Codable {
        var pages: [Page] = []
        var searches: [Search] = []
    }

    nonisolated static let maxVisitsToScore = 10
    /// Chrome expires history after 90 days (`HistoryBackend::kExpireDaysThreshold`).
    static let keptDays = 90
    /// More than the person visits in 90 days; agents that open many pages stop growing the file here.
    static let maxPages = 5000

    /// Nil keeps the history in memory only (tests).
    private let file: URL?
    private let now: () -> Date
    /// Writes in order, off the main thread.
    private static let writer = DispatchQueue(label: "Yardlet.browser.addressHistory", qos: .utility)
    private(set) var pages: [String: Page] = [:]
    private(set) var searches: [String: Search] = [:]
    /// Each page's and each site's icon, never saved (`noteIcon`); the pages' at most `maxIcons`.
    private var pageIcons: [String: Data] = [:]
    private var siteIcons: [String: Data] = [:]
    static let maxIcons = 1000
    private var saveTask: Task<Void, Never>?
    /// Changed since the last save.
    private var isChanged = false

    init(file: URL?, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let oldest = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        for page in saved.pages where page.lastVisit >= oldest { pages[page.url] = page }
        for search in saved.searches where search.lastVisit >= oldest { searches[search.terms.lowercased()] = search }
    }

    /// The address a tab committed. Only web pages and files count, without any user name or password in the
    /// address (as Chrome's history index keeps them); a search results page of the default engine counts as
    /// its search.
    func noteVisit(_ address: String, typed: Bool) {
        guard let url = Self.keptAddress(address) else { return }
        let date = now()
        if let terms = BrowserURLPolicy.searchTerms(in: url) {
            let key = terms.lowercased()
            var search = searches[key] ?? Search(terms: terms, count: 0, lastVisit: date)
            search.count += 1
            search.lastVisit = date
            searches[key] = search
        } else {
            var page = pages[url] ?? Page(url: url, title: "", visitCount: 0, typedCount: 0, lastVisit: date, visits: [])
            page.visitCount += 1
            if typed { page.typedCount += 1 }
            page.lastVisit = date
            page.visits.insert(Visit(date: date, typed: typed), at: 0)
            page.visits = Array(page.visits.prefix(Self.maxVisitsToScore))
            pages[url] = page
        }
        scheduleSave()
    }

    func noteTitle(_ title: String, of address: String) {
        guard let url = Self.keptAddress(address), var page = pages[url], page.title != title else { return }
        page.title = title
        pages[url] = page
        scheduleSave()
    }

    /// The address as the history keeps it: a web page or file, without a user name or password. A task's visited
    /// pages keep the same (`TaskBrowserTabs.visited`).
    nonisolated static func keptAddress(_ address: String) -> String? {
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        components.user = nil
        components.password = nil
        return components.string
    }

    /// A page's icon as a tab last showed it, for the launcher's pages and the start page's sites; empty for a page that
    /// has none. Kept in memory only, as a tab's icon is, so a page shows a globe, and a site its first letter, until a
    /// tab shows it again after Yardlet restarts.
    func noteIcon(_ png: Data, of address: String) {
        guard let page = Self.keptAddress(address) else { return }
        if pageIcons.count >= Self.maxIcons, pageIcons[page] == nil { pageIcons.removeAll() }
        pageIcons[page] = png
        if !png.isEmpty, let site = Self.site(of: address) { siteIcons[site] = png }
    }

    /// The page's own icon, else, for a page no tab showed since Yardlet started, the last icon of its site.
    func icon(of address: String) -> Data? {
        if let page = Self.keptAddress(address), let png = pageIcons[page] { return png.isEmpty ? nil : png }
        return Self.site(of: address).flatMap { siteIcons[$0] }
    }

    /// The sites visited most, for a new tab's start page, as Chrome's Most visited tiles and the Codex app's
    /// Suggested sites: one page per site (a host and port, `www.` aside), the site's most visited page (the latest
    /// of those visited as much), the sites ordered by how often and how recently their pages were visited
    /// (`BrowserAddressRanking.frequency`).
    func topSites(limit: Int) -> [Page] {
        let date = now()
        var sites: [String: (page: Page, best: Double, score: Double)] = [:]
        for page in pages.values {
            guard let site = Self.site(of: page.url) else { continue }
            let frequency = BrowserAddressRanking.frequency(of: page, now: date)
            guard frequency > 0 else { continue }
            if let known = sites[site] {
                let better = frequency != known.best ? frequency > known.best : page.lastVisit > known.page.lastVisit
                sites[site] = better ? (page, frequency, known.score + frequency) : (known.page, known.best, known.score + frequency)
            } else {
                sites[site] = (page, frequency, frequency)
            }
        }
        return sites.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.page.url < $1.page.url }
            .prefix(limit).map(\.page)
    }

    /// A web page's site: its host and port, without `www.`; nil for a file.
    nonisolated static func site(of address: String) -> String? {
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// Shift-Delete on a suggestion: the page and its visits, or the search, as Chrome's `DeleteMatch` does.
    func remove(page address: String) {
        guard pages.removeValue(forKey: address) != nil else { return }
        scheduleSave()
    }

    /// "Remove from History" on a start page's site: every page of the site, so the site leaves the start page.
    func remove(site address: String) {
        guard let site = Self.site(of: address) else { return }
        let count = pages.count
        pages = pages.filter { Self.site(of: $0.key) != site }
        if pages.count != count { scheduleSave() }
    }

    func remove(search terms: String) {
        guard searches.removeValue(forKey: terms.lowercased()) != nil else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        guard file != nil else { return }
        isChanged = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes what changed before Yardlet quits.
    func saveBeforeQuitting() {
        guard isChanged else { return }
        saveTask?.cancel()
        save(waiting: true)
    }

    /// Writes what is kept: the last 90 days, at most `maxPages` pages, the newest first.
    func save(waiting: Bool = false) {
        guard let file else { return }
        isChanged = false
        let oldest = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        let kept = pages.values.filter { $0.lastVisit >= oldest }.sorted { $0.lastVisit > $1.lastVisit }.prefix(Self.maxPages)
        if kept.count < pages.count { pages = Dictionary(uniqueKeysWithValues: kept.map { ($0.url, $0) }) }
        searches = searches.filter { $0.value.lastVisit >= oldest }
        let saved = Saved(pages: Array(kept), searches: searches.values.sorted { $0.lastVisit > $1.lastVisit })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let write = {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic])
        }
        if waiting { Self.writer.sync(execute: write) } else { Self.writer.async(execute: write) }
    }
}
