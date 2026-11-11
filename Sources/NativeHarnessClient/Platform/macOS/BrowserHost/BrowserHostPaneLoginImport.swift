import Foundation

/// "Import from Another Browser…" from the page's menu, the panel's ⋯ menu or Settings › Passwords
/// (docs/BROWSER_SESSION_ISOLATION.md 10).
struct BrowserLoginImportRequest: Identifiable {
    let id = UUID()
    /// The site of the page the person was on, chosen at first when the browser has cookies for it.
    var site: String?
    /// Opened from a task's browser panel, whose task takes the sign-ins too; false from Settings.
    var forTask = true
}

/// Another browser's sign-ins in the browser panel: the menu items, and the import into the default profile, which
/// tasks share, and into this task's profile of its own if it has one (docs/BROWSER_SESSION_ISOLATION.md 10).
extension BrowserHostPaneController {
    func loginImportMenuItems() -> [(title: String, action: () -> Void)] {
        [(L10n.string("Import from Another Browser…"), { [weak self] in self?.startLoginImport() })]
    }

    func startLoginImport() {
        let host = tab?.currentURL.flatMap { URL(string: $0)?.host(percentEncoded: false) }
        loginImport = BrowserLoginImportRequest(site: host.map { BrowserLoginImport.site(of: $0, suffixes: vault.suffixes) })
    }

    /// Brings the chosen sites' cookies over from `profile`, and its visit history when `history`, then reloads the
    /// page when it is one of the sites. `password` stands in for a Chromium browser's keychain item in QA runs.
    func importLogins(from profile: BrowserLoginImport.Profile, sites: [String], history: Bool = false,
                      password: (@Sendable () throws -> Data)? = nil) async throws {
        var profiles: [String?] = [nil]
        if let own = client.profileForSession?(session)?.key { profiles.append(own) }
        showVaultNotice(try await client.importFromBrowser(profile, sites: sites, history: history, into: profiles,
                                                           password: password))
        if let host = tab?.currentURL.flatMap({ URL(string: $0)?.host(percentEncoded: false) }),
           sites.contains(where: { BrowserLoginImport.covers($0, host) }) {
            navigate(.reload)
        }
    }
}

extension BrowserHostClient {
    /// What the person chose in the import sheet: the cookies of `sites` from `profile` into each of `profiles` (a
    /// key; nil for the default profile), and, when `history`, the profile's visit history into the address field's
    /// history. Both are read off the main thread before anything is written, so a refused keychain item or an
    /// unreadable database imports nothing. A Chromium browser's keychain item is read only when there are sites, after
    /// the person chose Import. Returns what the panel or Settings says.
    func importFromBrowser(_ profile: BrowserLoginImport.Profile, sites: [String], history: Bool, into profiles: [String?],
                           password: (@Sendable () throws -> Data)? = nil) async throws -> String {
        let addressHistory = history ? addressHistory : nil
        let readsHistory = addressHistory != nil
        let since = addressHistory?.importedUntil(profile.id)
        let read = try await Task.detached(priority: .userInitiated) {
            () throws -> (cookies: [BrowserImportedCookie], history: BrowserAddressHistory.Imported?) in
            var cookies: [BrowserImportedCookie] = []
            if !sites.isEmpty {
                var secret = profile.browser.keychainService == nil ? Data()
                    : try password?() ?? BrowserLoginImport.keychainPassword(for: profile.browser)
                defer { secret.resetBytes(in: 0..<secret.count) }
                cookies = try BrowserLoginImport.cookies(in: profile, sites: sites, password: secret)
            }
            let imported = readsHistory ? try BrowserLoginImport.history(in: profile, since: since) : nil
            return (cookies, imported)
        }.value
        var notice: [String] = []
        if !sites.isEmpty {
            let counts = try await importCookies(read.cookies, sites: sites, into: profiles)
            guard !counts.contains(-1) else { throw BrowserLoginImport.Failure.hostDidNotAnswer }
            notice.append(sites.count == 1
                          ? L10n.format("Imported the sign-in for %@ from %@.", sites[0], profile.browser.name)
                          : L10n.format("Imported sign-ins for %lld sites from %@.", Int64(sites.count), profile.browser.name))
        }
        if let addressHistory, let imported = read.history {
            addressHistory.merge(imported, from: profile.id)
            // A search counts as its results page.
            let pages = imported.pages.count + imported.searches.count
            notice.append(pages == 0 ? L10n.format("%@ had no new visit history.", profile.browser.name)
                          : pages == 1 ? L10n.format("Imported 1 page of visit history from %@.", profile.browser.name)
                          : L10n.format("Imported %lld pages of visit history from %@.", Int64(pages), profile.browser.name))
        }
        return notice.joined(separator: " ")
    }
}
