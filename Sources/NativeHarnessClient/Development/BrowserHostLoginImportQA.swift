#if DEBUG
import AppKit
import Foundation

/// QA for bringing another browser's sign-ins over (docs/BROWSER_SESSION_ISOLATION.md 10) against the real browser
/// host, run by `run-check.sh … --ui-fixture-browser-check-only=import` in a temporary home. A made-up Whale folder in
/// that home's Application Support holds made-up cookies encrypted under a test password, which the run passes in
/// place of the keychain item, and a made-up Firefox folder holds plain ones: it never reads the keychain or a real
/// browser's data. A made-up Chrome folder whose `Local State` cannot be read stands for one macOS 27 keeps from
/// Yardlet. In the task's browser panel the page's menu opens the sheet (drawn to `import-sheet.png`), and each import
/// puts the chosen sites' cookies in the default profile and the task's own, each once, as the other browser stores
/// them. Checks land in `result.json`.
@MainActor
final class BrowserHostLoginImportQA {
    private let output: URL
    private let base: String
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    /// Made-up values; each run's check that none reaches a log looks for them.
    nonisolated private static let password = Data("qa-safe-storage-not-real".utf8)
    private static let marker = "qa-imported-"
    private static let accounts = "https://accounts.example.com/"

    init(output: URL, base: String) {
        self.output = output
        self.base = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        // The made-up browser goes in the QA home only.
        let support = BrowserLoginImport.applicationSupport
        guard support.path(percentEncoded: false).contains("/browser-host-qa/") else {
            check("the run's home is a QA home", false, support.path(percentEncoded: false))
            return await finish()
        }
        let whale = support.appending(path: "Naver/Whale", directoryHint: .isDirectory)
        do {
            try ChromiumProfileFixture.make(at: whale, profiles: [
                .init(folder: "Default", name: "Person 1", cookies: [
                    .init(host: ".example.com", name: "qa_session", value: Self.marker + "default-profile")
                ]),
                .init(folder: "Profile 1", name: "Work", cookies: [
                    .init(host: "accounts.example.com", name: "qa_signin", value: Self.marker + "signin"),
                    .init(host: "accounts.example.com", name: "__Host-qa_signin", value: Self.marker + "host", sameSite: 1),
                    .init(host: ".example.com", name: "qa_session", value: Self.marker + "session"),
                    .init(host: ".example.com", name: "qa_plain", value: Self.marker + "plain", secure: false, httpOnly: false,
                          sameSite: 1, expires: nil),
                    .init(host: "widget.example.com", name: "qa_partitioned", value: Self.marker + "chips",
                          partitionedUnder: "https://example.org"),
                    .init(host: ".example.com", name: "qa_expired", value: Self.marker + "expired",
                          expires: Date().addingTimeInterval(-60)),
                    .init(host: "localhost", name: "qa_local", value: Self.marker + "local", secure: false, httpOnly: false, sameSite: 1),
                    .init(host: "www.other.test", name: "qa_other", value: Self.marker + "other")
                ])
            ], lastUsed: "Profile 1", password: Self.password)
            try FirefoxProfileFixture.make(at: support.appending(path: "Firefox", directoryHint: .isDirectory), profiles: [
                .init(path: "Profiles/qa.default-release", name: "default-release", cookies: [
                    .init(host: "accounts.example.net", name: "qa_ff_signin", value: Self.marker + "ff-signin", sameSite: 2),
                    .init(host: ".example.net", name: "qa_ff_session", value: Self.marker + "ff-session", sameSite: 256),
                    .init(host: ".example.net", name: "qa_ff_cross", value: Self.marker + "ff-cross", sameSite: 0),
                    .init(host: ".example.net", name: "qa_ff_plain", value: Self.marker + "ff-plain", secure: false,
                          httpOnly: false, sameSite: 0),
                    .init(host: "accounts.example.net", name: "qa_ff_signin", value: Self.marker + "ff-container",
                          originAttributes: "^userContextId=1"),
                    .init(host: "widget.example.net", name: "qa_ff_partitioned", value: Self.marker + "ff-chips",
                          originAttributes: "^partitionKey=%28https%2Cexample.org%29"),
                    .init(host: ".example.net", name: "qa_ff_expired", value: Self.marker + "ff-expired",
                          expires: Date().addingTimeInterval(-60))
                ]),
                .init(path: "Profiles/qa.old", name: "old", cookies: [])
            ], installed: "Profiles/qa.default-release", marked: "Profiles/qa.old")
            let chrome = support.appending(path: "Google/Chrome", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: chrome.appending(path: "Local State"))
            try Data("{}".utf8).write(to: chrome.appending(path: "Local State"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: chrome.appending(path: "Local State").path(percentEncoded: false))
        } catch {
            check("the made-up browser folders are written", false, error.localizedDescription)
            return await finish()
        }
        let found = BrowserLoginImport.find()
        let profiles = found.profiles
        record["profiles"] = .array(profiles.map { .string($0.title) })
        guard let work = profiles.first, work.title == "Whale · Work",
              work.cookies.path(percentEncoded: false).hasPrefix(whale.path(percentEncoded: false)) else {
            check("Whale's last used profile is found first, in the QA home", false, "\(profiles.map(\.title))")
            return await finish()
        }
        check("Firefox's profiles follow, the installation's own first, and Chrome is named as unreadable",
              profiles.map(\.title) == ["Whale · Work", "Whale · Person 1", "Firefox · default-release", "Firefox · old"]
                && found.unreadable.map(\.name) == ["Chrome"],
              "\(profiles.map(\.title)) / unreadable \(found.unreadable.map(\.name))")
        let sites = (try? BrowserLoginImport.sites(in: work).map(\.domain)) ?? []
        check("the profile's sites are listed by registrable domain, without partitioned or expired cookies' alone",
              Set(sites) == ["example.com", "localhost", "other.test"], "\(sites)")
        guard let firefox = profiles.first(where: { $0.browser.name == "Firefox" }) else { return await finish() }
        let firefoxSites = (try? BrowserLoginImport.sites(in: firefox).map(\.domain)) ?? []
        check("Firefox's sites are read from a copy that takes its WAL along", firefoxSites == ["example.net"], "\(firefoxSites)")

        // Before: the default profile holds the copy before 2026-10-25's domain form of the sign-in cookie, the site's
        // own host-only one, another cookie of the site and a cookie of a site not chosen; the task holds its own sign-in.
        guard let home = try? client.openTab(url: base + "isolation", viewport: .offscreenDefault),
              await waitUntil(.seconds(20), { home.currentURL == self.base + "isolation" && !home.isLoading }) else {
            check("the default profile's page loads", false, "no tab")
            return await finish()
        }
        await clearQACookies(home)
        _ = try? await home.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "OLD", domain: ".accounts.example.com"), cookie("qa_signin", "Y"),
            cookie("qa_leftover", "Y", domain: ".example.com"), cookie("qa_keep", "Y", url: "https://keep.test/")
        ])])
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            check("the task's browser panel opens", false, "no panel")
            return await finish()
        }
        controller.addressInput = base + "isolation/import"
        controller.submitAddress()
        guard await waitUntil(.seconds(20), { controller.tab?.currentURL == self.base + "isolation/import" && controller.tab?.isLoading == false }),
              let tab = controller.tab else {
            check("the panel's page loads", false, "not loaded")
            return await finish()
        }
        await clearQACookies(tab)
        _ = try? await tab.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "T"), cookie("qa_leftover", "T", domain: ".example.com")
        ])])

        // The page's menu has the item (read, not opened: QA never opens a real menu), which opens the sheet with the
        // page's site chosen.
        let menu = controller.view?.extraContextMenuItems?().map(\.title) ?? []
        check("the page's menu offers the import", menu.contains(L10n.string("Import Sign-ins from Another Browser…")), "\(menu)")
        controller.startLoginImport()
        let shown = await waitUntil(.seconds(10)) { controller.view?.window?.attachedSheet != nil }
        try? await Task.sleep(for: .seconds(2))
        if let sheet = controller.view?.window?.attachedSheet, let content = sheet.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: "import-sheet.png"))
        }
        check("the page's menu opens the sheet with the page's own site", shown && controller.loginImport?.site == "localhost",
              "sheet \(shown), site \(controller.loginImport?.site ?? "none")")

        do {
            try await controller.importLogins(from: work, sites: ["example.com", "localhost"], password: { Self.password })
        } catch {
            check("the import runs", false, error.localizedDescription)
        }
        controller.loginImport = nil
        let notice = controller.notice ?? ""
        check("the panel says what it imported", notice.contains("Whale"), notice)

        // Each profile now holds the other browser's cookies of the chosen sites, once, as Whale stores them.
        let expected = [Self.marker + "signin", Self.marker + "host", Self.marker + "session"]
        let names = ["qa_signin", "__Host-qa_signin", "qa_session"]
        func signedIn(_ sent: [String: [String]]) -> Bool {
            zip(names, expected).allSatisfy { sent[$0.0] == [$0.1] } && sent["qa_leftover"] == nil
        }
        let fromDefault = await sentCookies(home, Self.accounts)
        let defaultStored = await storedCookies(home)
        record["defaultProfile"] = .array(defaultStored.map(JSONValue.string))
        check("the default profile takes each chosen cookie once and loses the site's earlier ones",
              signedIn(fromDefault) && defaultStored == Self.shapes, "sent \(fromDefault) / stored \(defaultStored)")
        let kept = await sentCookies(home, "https://keep.test/")
        let other = await sentCookies(home, "https://www.other.test/")
        check("other sites keep their cookies, and a site not chosen is not imported", kept["qa_keep"] == ["Y"] && other.isEmpty,
              "keep.test \(kept) / other.test \(other)")

        let fromTask = await sentCookies(tab, Self.accounts)
        let page = await waitUntil(.seconds(10)) { controller.tab?.isLoading == false }
        let local = await value(tab, "document.cookie")?.stringValue ?? ""
        check("the task's own profile takes them too, and its page reloads signed in",
              signedIn(fromTask) && page && local.contains("qa_local=" + Self.marker + "local"), "sent \(fromTask) / page \(local)")

        let later = UUID()
        var fromLater: [String: [String]] = [:]
        if let laterTab = try? client.openTab(forSession: later, url: base + "isolation", viewport: .offscreenDefault),
           await waitUntil(.seconds(20), { laterTab.currentURL == self.base + "isolation" && !laterTab.isLoading }) {
            fromLater = await sentCookies(laterTab, Self.accounts)
        }
        check("a task started after the import begins with them, once", signedIn(fromLater), "\(fromLater)")
        client.closeTabs(forSession: later)

        // Firefox: plain cookies, no keychain. Its container's and partitioned cookies and the expired one stay
        // behind; each SameSite is Chromium's (unset and a None that is not Secure become unspecified).
        do {
            try await controller.importLogins(from: firefox, sites: ["example.net"])
        } catch {
            check("the import from Firefox runs", false, error.localizedDescription)
        }
        let firefoxNotice = controller.notice ?? ""
        let firefoxStored = await storedCookies(home, site: "example.net")
        record["defaultProfileFromFirefox"] = .array(firefoxStored.map(JSONValue.string))
        check("the default profile takes Firefox's cookies in Chromium's shape, and the panel says so",
              firefoxStored == Self.firefoxShapes && firefoxNotice.contains("Firefox"), "stored \(firefoxStored) / \(firefoxNotice)")
        let firefoxSent = await sentCookies(tab, "https://accounts.example.net/")
        let expectedFirefox = ["qa_ff_signin": "ff-signin", "qa_ff_session": "ff-session", "qa_ff_cross": "ff-cross",
                               "qa_ff_plain": "ff-plain"].mapValues { [Self.marker + $0] }
        check("the task's own profile takes them too, not the container's", firefoxSent == expectedFirefox, "\(firefoxSent)")
        home.close()

        // No value reaches the app's or the host's log.
        try? await Task.sleep(for: .seconds(1))
        let logs = [output.appending(path: "app.log"), MacBrowserHost.shared.paths.log]
        let leaked = logs.filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains(Self.marker) == true }
        check("no imported cookie value is in the app's or the browser host's log", leaked.isEmpty,
              leaked.map(\.lastPathComponent).joined(separator: ", "))
        await finish()
    }

    /// The imported cookies as Chromium stores them in a profile: name, domain (a leading dot for a domain cookie),
    /// Secure, HttpOnly, SameSite and whether it has an expiry.
    private static let shapes = [
        "__Host-qa_signin accounts.example.com Secure HttpOnly Lax expires",
        "qa_plain .example.com - - Lax session",
        "qa_session .example.com Secure HttpOnly None expires",
        "qa_signin accounts.example.com Secure HttpOnly None expires"
    ]

    /// Firefox's as Chromium stores them: no SameSite shown is unspecified.
    private static let firefoxShapes = [
        "qa_ff_cross .example.net Secure HttpOnly None expires",
        "qa_ff_plain .example.net - - - expires",
        "qa_ff_session .example.net Secure HttpOnly - expires",
        "qa_ff_signin accounts.example.net Secure HttpOnly Strict expires"
    ]

    private func storedCookies(_ tab: BrowserTab, site: String = "example.com") async -> [String] {
        let all = try? await tab.devTools.send("Network.getAllCookies", [:], timeout: .seconds(10))
        return (all?["cookies"]?.arrayValue ?? []).compactMap { cookie -> String? in
            guard let name = cookie["name"]?.stringValue, name.contains("qa_"),
                  let domain = cookie["domain"]?.stringValue, BrowserLoginImport.covers(site, domain) else { return nil }
            return "\(name) \(cookie["domain"]?.stringValue ?? "?") \(cookie["secure"]?.boolValue == true ? "Secure" : "-") "
                + "\(cookie["httpOnly"]?.boolValue == true ? "HttpOnly" : "-") \(cookie["sameSite"]?.stringValue ?? "-") "
                + "\(cookie["session"]?.boolValue == true ? "session" : "expires")"
                + (cookie["partitionKey"] == nil ? "" : " partitioned")
        }.sorted()
    }

    /// The values of each QA cookie Chromium would send to `url`.
    private func sentCookies(_ tab: BrowserTab, _ url: String) async -> [String: [String]] {
        let list = try? await tab.devTools.send("Network.getCookies", ["urls": .array([.string(url)])], timeout: .seconds(10))
        var sent: [String: [String]] = [:]
        for cookie in list?["cookies"]?.arrayValue ?? [] {
            guard let name = cookie["name"]?.stringValue, name.contains("qa_") else { continue }
            sent[name, default: []].append(cookie["value"]?.stringValue ?? "?")
        }
        return sent
    }

    /// An earlier run's QA cookies in this profile go first.
    private func clearQACookies(_ tab: BrowserTab) async {
        let all = try? await tab.devTools.send("Network.getAllCookies", [:], timeout: .seconds(10))
        for cookie in all?["cookies"]?.arrayValue ?? [] {
            guard let name = cookie["name"]?.stringValue, name.contains("qa_"), let domain = cookie["domain"]?.stringValue else { continue }
            var fields: [String: JSONValue] = ["name": .string(name), "domain": .string(domain)]
            if let partition = cookie["partitionKey"] { fields["partitionKey"] = partition }
            _ = try? await tab.devTools.send("Network.deleteCookies", fields)
        }
    }

    private func cookie(_ name: String, _ value: String, url: String = BrowserHostLoginImportQA.accounts,
                        domain: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string(name), "value": .string(value), "url": .string(url), "path": .string("/"),
                                           "secure": .bool(true), "expires": .number(Date().timeIntervalSince1970 + 3600)]
        if let domain { fields["domain"] = .string(domain) }
        return .object(fields)
    }

    private func value(_ tab: BrowserTab, _ expression: String) async -> JSONValue? {
        let result = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        return result?["result"]?["value"]
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string("import: " + name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        endBrowserQA(checks: checks)
    }
}
#endif
