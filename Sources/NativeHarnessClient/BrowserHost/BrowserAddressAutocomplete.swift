import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Settings › General "Autocomplete searches and URLs", Chrome's `search.suggest_enabled`, on unless turned off as
/// in Chrome: what the person types in the address field goes to Google for suggested searches. Off, no request is
/// sent (Chrome's `CanSendSuggestRequest`); suggestions from the browser's history stay, as they do in Chrome.
enum SearchSuggestionPreference {
    static let key = "Yardlet.browser.searchSuggestions"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Chrome's `SearchProvider` request to its default engine's suggest service, Google's: from Yardlet, not the
/// page's profile, so it carries no cookies and Google's suggestions are not personalized. Requests go at most one
/// per 100 ms (`kDefaultMinimumTimeBetweenSuggestQueriesMs`), and an address that may be private is not sent.
@MainActor
final class BrowserSearchSuggestService {
    nonisolated static let endpoint = "https://www.google.com/complete/search"
    static let minimumInterval: Duration = .milliseconds(100)

    private let session: URLSession
    private var lastRequest: ContinuousClock.Instant?

    init(session: URLSession = BrowserSearchSuggestService.makeSession()) {
        self.session = session
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    /// Chromium's request (`client=chrome`), its answer in UTF-8 and in the languages the browser host sends.
    nonisolated static func request(for query: String, korean: Bool) -> URLRequest? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "client", value: "chrome"), URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "oe", value: "UTF-8"), URLQueryItem(name: "hl", value: korean ? "ko" : "en"),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(korean ? "ko-KR,ko,en-US,en" : "en-US,en,ko", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Chrome sends no suggest request for an address that may hold something private (`IsQueryPotentiallyPrivate`):
    /// a path or another scheme than http(s), a user name, a port, a query or fragment, or an https address's path.
    nonisolated static func mayAsk(about text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value.hasPrefix("?") { return true }
        guard BrowserURLPolicy.looksLikeAddress(value) else { return true }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("@") || value.contains("?") || value.contains("#") {
            return false
        }
        let scheme = BrowserURLPolicy.scheme(of: value)
        if let scheme, value.contains("://"), !["http", "https"].contains(scheme) { return false }
        let rest = value.range(of: "://").map { String(value[$0.upperBound...]) } ?? value
        let host = rest.prefix { $0 != "/" }
        if host.contains(":") { return false }
        if scheme == "https", rest.count > host.count + 1 { return false }
        return true
    }

    func suggestions(for query: String, korean: Bool) async -> BrowserSearchSuggestions? {
        if let lastRequest {
            let wait = Self.minimumInterval - (ContinuousClock.now - lastRequest)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        guard !Task.isCancelled, let request = Self.request(for: query, korean: korean) else { return nil }
        lastRequest = .now
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled else { return nil }
        return BrowserSearchSuggestions.parse(data)
    }
}

/// The address field's suggestions while the person types (Chrome's `OmniboxEditModel`, in short): the rows, the
/// selected one, and what the person typed apart from the completion after it (docs/BROWSER_HOST.md, "Address
/// suggestions").
@MainActor
@Observable
final class BrowserAddressAutocomplete {
    private(set) var rows: [BrowserAddressSuggestion] = []
    /// The first row unless the person moved with the arrows or Tab.
    private(set) var selection = 0
    /// What the person typed, without the completion.
    private(set) var typed = ""
    @ObservationIgnored private var allowsInline = false
    @ObservationIgnored private var remote: BrowserSearchSuggestions?
    @ObservationIgnored private var fetch: Task<Void, Never>?
    @ObservationIgnored private let history: () -> BrowserAddressHistory
    @ObservationIgnored private let service: BrowserSearchSuggestService
    @ObservationIgnored private let suggestsSearches: () -> Bool
    @ObservationIgnored private let korean: Bool
    @ObservationIgnored private let now: () -> Date

    init(history: @escaping () -> BrowserAddressHistory, service: BrowserSearchSuggestService,
         suggestsSearches: @escaping () -> Bool = { SearchSuggestionPreference.isOn() },
         korean: Bool = Locale.preferredLanguages.first?.hasPrefix("ko") == true, now: @escaping () -> Date = Date.init) {
        self.history = history
        self.service = service
        self.suggestsSearches = suggestsSearches
        self.korean = korean
        self.now = now
    }

    var isOpen: Bool { !rows.isEmpty }

    var selected: BrowserAddressSuggestion? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// The person typed `text`; `allowsInline` when they typed at its end and did not just delete, so the first row
    /// may complete it.
    func update(typed text: String, allowsInline: Bool) {
        typed = text
        self.allowsInline = allowsInline
        selection = 0
        rank()
        askForSearches()
    }

    /// The next or previous row, wrapping around (`OmniboxPopupSelection::GetNextSelection`).
    func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        selection = ((selection + offset) % rows.count + rows.count) % rows.count
    }

    func select(_ index: Int) {
        if rows.indices.contains(index) { selection = index }
    }

    func close() {
        fetch?.cancel()
        fetch = nil
        remote = nil
        rows = []
        selection = 0
    }

    /// Removes the selected row's page or search from the history; the selection stays at its place
    /// (`TryDeletingPopupLine`). False for a row the history does not hold.
    @discardableResult
    func removeSelected() -> Bool {
        guard let row = selected, row.isFromHistory else { return false }
        let history = history()
        switch row.kind {
        case .page:
            for url in history.pages.keys where BrowserURLPolicy.sameAddress(url, row.destination) { history.remove(page: url) }
        case .search:
            history.remove(search: row.fill)
        }
        let place = selection
        rank()
        selection = rows.isEmpty ? 0 : min(place, rows.count - 1)
        return true
    }

    private func rank() {
        let history = history()
        rows = BrowserAddressRanking.suggestions(for: typed, pages: Array(history.pages.values),
                                                 searches: Array(history.searches.values), remote: remote,
                                                 allowsInline: allowsInline, now: now())
    }

    private func askForSearches() {
        fetch?.cancel()
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = text.hasPrefix("?") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text
        guard suggestsSearches(), !query.isEmpty, BrowserSearchSuggestService.mayAsk(about: text) else {
            remote = nil
            return
        }
        let korean = korean
        fetch = Task { [weak self, service] in
            // Once the person moved to a row, the rows stay as they are: the field shows that row.
            guard let answer = await service.suggestions(for: query, korean: korean), !Task.isCancelled,
                  let self, !self.rows.isEmpty, self.selection == 0 else { return }
            self.remote = answer
            self.rank()
        }
    }
}
