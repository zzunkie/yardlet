import Foundation

/// "Import Sign-ins from Another Browser…" from the page's menu (docs/BROWSER_SESSION_ISOLATION.md 10).
struct BrowserLoginImportRequest: Identifiable {
    let id = UUID()
    /// The site of the page the person was on, chosen at first when the browser has cookies for it.
    var site: String?
}

/// Another browser's sign-ins in the browser panel: the page's menu item, and the import into the default profile,
/// which tasks share, and into this task's profile of its own if it has one (docs/BROWSER_SESSION_ISOLATION.md 10).
extension BrowserHostPaneController {
    func loginImportMenuItems() -> [(title: String, action: () -> Void)] {
        [(L10n.string("Import Sign-ins from Another Browser…"), { [weak self] in self?.startLoginImport() })]
    }

    func startLoginImport() {
        let host = tab?.currentURL.flatMap { URL(string: $0)?.host(percentEncoded: false) }
        loginImport = BrowserLoginImportRequest(site: host.map { BrowserLoginImport.site(of: $0, suffixes: vault.suffixes) })
    }

    /// Brings the chosen sites' cookies over from `profile`, then reloads the page when it is one of the sites. A
    /// Chromium browser's keychain item is read here, after the person chose Import; `password` stands in for it in QA
    /// runs.
    func importLogins(from profile: BrowserLoginImport.Profile, sites: [String],
                      password: (@Sendable () throws -> Data)? = nil) async throws {
        let cookies = try await Task.detached(priority: .userInitiated) { () throws -> [BrowserImportedCookie] in
            var secret = profile.browser.keychainService == nil ? Data()
                : try password?() ?? BrowserLoginImport.keychainPassword(for: profile.browser)
            defer { secret.resetBytes(in: 0..<secret.count) }
            return try BrowserLoginImport.cookies(in: profile, sites: sites, password: secret)
        }.value
        var profiles: [String?] = [nil]
        if let own = client.profileForSession?(session)?.key { profiles.append(own) }
        let counts = try await client.importCookies(cookies, sites: sites, into: profiles)
        guard !counts.contains(-1) else { throw BrowserLoginImport.Failure.hostDidNotAnswer }
        showVaultNotice(sites.count == 1
                        ? L10n.format("Imported the sign-in for %@ from %@.", sites[0], profile.browser.name)
                        : L10n.format("Imported sign-ins for %lld sites from %@.", Int64(sites.count), profile.browser.name))
        if let host = tab?.currentURL.flatMap({ URL(string: $0)?.host(percentEncoded: false) }),
           sites.contains(where: { BrowserLoginImport.covers($0, host) }) {
            navigate(.reload)
        }
    }
}
