#if DEBUG
import AppKit
import Foundation

/// QA for each task's own browser profile against the real browser host (docs/BROWSER_SESSION_ISOLATION.md),
/// run by `run-check.sh … --ui-fixture-browser-check-only=isolation` in a temporary home, which may hold an
/// earlier QA run's browser data: each check uses new tasks and sets what it reads. Made-up cookies on the
/// QA server only. Phase markers let run-check.sh sample the process tree's memory as contexts are added.
/// Checks land in `result.json`.
@MainActor
final class BrowserHostIsolationQA {
    private let output: URL
    private let base: String
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var profiles: BrowserTaskProfiles { MacBrowserHost.shared.profiles }
    private static let passkeyKey = "qa-metadata-key-not-real"
    /// The cookies of the QA server's sign-in with several accounts (`/follow/accounts`): the accounts, the session the
    /// page reads, and the session's 30 cookies.
    private static let accountCookies = ["qa_accounts", "qa_seen"] + (1...30).map { String(format: "qa_s%02d", $0) }

    init(output: URL, base: String) {
        self.output = output
        self.base = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        let page = base + "isolation"
        // The default profile before the host opens it: a Touch ID metadata key a new task profile must carry.
        let defaultPreferences = MacBrowserHost.shared.paths.profile.appending(path: "Preferences")
        try? FileManager.default.createDirectory(at: MacBrowserHost.shared.paths.profile, withIntermediateDirectories: true)
        var preferences = (try? Data(contentsOf: defaultPreferences))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var webauthn = preferences["webauthn"] as? [String: Any] ?? [:]
        webauthn["touchid"] = ["metadata_secret": Self.passkeyKey]
        preferences["webauthn"] = webauthn
        try? JSONSerialization.data(withJSONObject: preferences).write(to: defaultPreferences)
        // `--ui-fixture-isolation-cookies` runs only the check that copied cookies stay as Chromium stored them, and
        // `--ui-fixture-isolation-follow` only the checks of the sign-ins tasks follow.
        if CommandLine.arguments.contains("--ui-fixture-isolation-cookies") {
            record["storage"] = .string(profiles.storage.rawValue)
            await copiesCookiesAsStored()
            return await finish()
        }
        if CommandLine.arguments.contains("--ui-fixture-isolation-follow") {
            record["storage"] = .string(profiles.storage.rawValue)
            await followsSignIns()
            return await finish()
        }
        // `--ui-fixture-isolation-shapes` runs only the check that the cleanup removes the old copy's domain cookies.
        if CommandLine.arguments.contains("--ui-fixture-isolation-shapes") {
            record["storage"] = .string(profiles.storage.rawValue)
            await removesTheOldCopysDomainCookies()
            return await finish()
        }
        // `--ui-fixture-isolation-shared` measures the same tabs in the one default profile, for comparison.
        if CommandLine.arguments.contains("--ui-fixture-isolation-shared") {
            profiles.storage = .shared
            record["storage"] = .string(profiles.storage.rawValue)
            _ = try? client.openTab(url: page, viewport: .offscreenDefault)
            try? await Task.sleep(for: .seconds(2))
            await phase("iso-0-default")
            for name in ["iso-4-shared", "iso-8-shared"] {
                for _ in 0..<4 { _ = await taskTab(UUID(), page) }
                await phase(name)
            }
            profiles.storage = .perTask
            return await finish()
        }
        record["storage"] = .string(profiles.storage.rawValue)

        // A tab of no task is in the default profile: a cookie there is what new tasks start with.
        guard let baseline = try? client.openTab(url: page, viewport: .offscreenDefault), await loaded(baseline, page) else {
            check("the default profile's page loads", false, "no tab")
            return await finish()
        }
        _ = await value(baseline, "document.cookie = 'baseline=1; path=/; max-age=3600'; document.cookie = 'who=; path=/; max-age=0'; 1")
        await phase("iso-0-default")

        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        guard let tabA = await taskTab(a, page), let tabB = await taskTab(b, page) else { return await finish() }
        let startA = await cookies(tabA), startB = await cookies(tabB)
        check("a new task starts with the default profile's cookies", startA.contains("baseline=1") && startB.contains("baseline=1"),
              "A \(startA) / B \(startB)")
        _ = await value(tabA, "document.cookie = 'who=A; path=/; max-age=3600'; localStorage.setItem('who', 'A'); 1")
        _ = await value(tabB, "document.cookie = 'who=B; path=/; max-age=3600'; localStorage.setItem('who', 'B'); 1")
        let cookieA = await cookies(tabA), cookieB = await cookies(tabB)
        let storeA = await value(tabA, "localStorage.getItem('who')"), storeB = await value(tabB, "localStorage.getItem('who')")
        check("two tasks signed in to the same site keep their own cookies and local storage",
              cookieA.contains("who=A") && !cookieA.contains("who=B") && cookieB.contains("who=B") && !cookieB.contains("who=A")
                && storeA == .string("A") && storeB == .string("B"),
              "A \(cookieA) \(String(describing: storeA)) / B \(cookieB) \(String(describing: storeB))")
        let baselineAfter = await cookies(baseline)
        check("a task's sign-in stays out of the default profile", !baselineAfter.contains("who="), baselineAfter)

        // A child task starts signed in as its parent.
        profiles.parentOf = { $0 == c ? a : nil }
        guard let tabC = await taskTab(c, page) else { return await finish() }
        let cookieC = await cookies(tabC)
        check("a child task starts with its parent task's cookies", cookieC.contains("who=A"), cookieC)

        // The person signed in on task B's page: that site's cookies go to the default profile and the running tasks
        // that follow it, in place of theirs; a task started after that begins with them
        // (docs/BROWSER_SESSION_ISOLATION.md 11).
        MacBrowserHost.shared.loginFollow.signedIn(session: b, site: "localhost")
        try? await Task.sleep(for: .seconds(2))
        guard let tabD = await taskTab(d, page) else { return await finish() }
        let cookieD = await cookies(tabD), nowA = await cookies(tabA)
        check("a person's sign-in reaches the default profile, the running tasks and the tasks started after it",
              cookieD.contains("who=B") && nowA.contains("who=B") && !nowA.contains("who=A"), "D \(cookieD) / A \(nowA)")

        let taskPreferences = (try? Data(contentsOf: profiles.folder(for: profiles.key(for: a)).appending(path: "Preferences")))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let copiedKey = taskPreferences?["webauthn"]?["touchid"]?["metadata_secret"]?.stringValue
        check("a task profile carries the default profile's Touch ID passkey key", copiedKey == Self.passkeyKey,
              copiedKey == nil ? "missing" : "present")
        await phase("iso-4-contexts")

        // Memory: four more tasks, then eight tabs of one task for comparison.
        var more: [UUID] = []
        for _ in 0..<4 {
            let task = UUID()
            more.append(task)
            _ = await taskTab(task, page)
        }
        await phase("iso-8-contexts")

        // The host ends when no tab is left: a task's sign-in, session cookies too, and its local storage
        // are on disk when its tab opens again, and the folder is not seeded again.
        _ = await value(tabA, "document.cookie = 'visit=A; path=/'; 1")
        for task in [a, b, c, d] + more { client.closeTabs(forSession: task) }
        baseline.close()
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        if let againA = await taskTab(a, page) {
            let cookie = await cookies(againA), store = await value(againA, "localStorage.getItem('who')")
            check("a task's profile keeps its cookies and local storage across host restarts",
                  cookie.contains("who=B") && cookie.contains("visit=A") && store == .string("A"),
                  "A \(cookie) \(String(describing: store))")
        }

        // Shared storage: a tab opens in the default profile again.
        profiles.storage = .shared
        let shared = UUID()
        if let tabShared = await taskTab(shared, page) {
            let sharedCookies = await cookies(tabShared)
            check("with shared storage a task's tab uses the default profile", sharedCookies.contains("baseline=1")
                  && sharedCookies.contains("who=B") && !profiles.folderExists(shared.uuidString), sharedCookies)
        }
        profiles.storage = .perTask

        await copiesCookiesAsStored()
        await followsSignIns()
        await removesTheOldCopysDomainCookies()

        // Archived and deleted tasks' profiles go once the host has let them go.
        for task in [a, shared] { client.closeTabs(forSession: task) }
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        let removed = Set(profiles.removeFolders(keeping: [a]))
        let unkept = Set(([b, c, d] + more).map(\.uuidString))
        // Chromium's own list of the profiles it opened forgets the removed ones too.
        let localState = (try? Data(contentsOf: MacBrowserHost.shared.paths.root.appending(path: "Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let listed = Set(((localState?["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?.keys.map { $0 } ?? [])
        let listedUnkept = unkept.filter { listed.contains(BrowserTaskProfiles.folderPrefix + $0) }
        check("removing unkept profiles keeps the kept task's folder and removes the rest, from Chromium's profile list too",
              profiles.folderExists(profiles.key(for: a)) && unkept.isSubset(of: removed) && !unkept.contains(where: profiles.folderExists)
                && listed.contains(BrowserTaskProfiles.folderPrefix + profiles.key(for: a)) && listedUnkept.isEmpty,
              "removed \(removed.count), this run's \(unkept.intersection(removed).count) of \(unkept.count); "
                + "Local State lists \(listed.count), removed ones still listed \(listedUnkept.count)")
        await finish()
    }

    // MARK: Cookies copied as stored

    /// A new task's starting cookies, and the person's sign-in copied back, must be the cookies Chromium stored.
    /// Google's accounts site answers a missing __Host- cookie, or a sign-in cookie that comes twice, with
    /// /CookieMismatch, as the Google Cloud console did in Yardlet's tasks until 2026-10-25
    /// (docs/BROWSER_SESSION_ISOLATION.md 8). Two parts: the QA server's sign-in check across two sites
    /// (`/cookie-check`, console 127.0.0.1 and accounts localhost), and Google-shaped cookies on a registrable
    /// domain set through DevTools and read back the same way (example.com is never loaded), since Chromium keeps a
    /// localhost cookie host-only whatever domain it is given.
    private func copiesCookiesAsStored() async {
        let console = base.replacingOccurrences(of: "localhost", with: "127.0.0.1")
        guard let home = try? client.openTab(url: console + "cookie-check/start", viewport: .offscreenDefault),
              await waitUntil(.seconds(20), { home.currentURL?.contains("/cookie-check/verify") == true && !home.isLoading }),
              let verify = home.currentURL else {
            check("cookie check: the default profile signs in across two sites", false, "no verify page")
            return
        }
        let signedIn = await value(home, "window.qa.cookieCheck")
        record["cookieCheckAgent"] = .object(["userAgent": signedIn?["userAgent"] ?? .null,
                                              "secChUa": signedIn?["secChUa"] ?? .null,
                                              "secChUaPlatform": signedIn?["secChUaPlatform"] ?? .null])
        check("cookie check: the default profile signs in across two sites", signedIn?["status"]?.stringValue == "ok",
              Self.describe(signedIn))
        // The accounts site in a frame of the console: a partitioned cookie and an unpartitioned third-party one.
        if let framed = try? client.openTab(url: console + "cookie-check/console", viewport: .offscreenDefault) {
            _ = await waitUntil(.seconds(10)) { !framed.isLoading && framed.currentURL?.contains("/cookie-check/console") == true }
            var frame: JSONValue?
            for _ in 0..<50 where frame == nil {
                frame = await value(framed, "window.qa.frame")
                if frame == nil { try? await Task.sleep(for: .milliseconds(200)) }
            }
            record["cookieCheckFrame"] = frame ?? .null
            framed.close()
        }
        let e = UUID()
        let tabE = await taskTab(e, verify)
        if let tabE {
            let copied = await value(tabE, "window.qa.cookieCheck")
            check("cookie check: a new task signs in across two sites with the cookies it started with",
                  copied?["status"]?.stringValue == "ok", Self.describe(copied))
        }

        // Google-shaped cookies on a registrable domain in the default profile: host-only sign-in cookies on the
        // accounts host (one __Host-), a Secure domain cookie and a non-Secure one (set over HTTP: DevTools makes a
        // cookie it sets over HTTPS Secure), and a cookie partitioned under another top-level site.
        let accounts = "https://accounts.example.com/"
        let expires = JSONValue.number(Date().timeIntervalSince1970 + 3600)
        func cookie(_ name: String, _ value: String, url: String = accounts, domain: String? = nil, secure: Bool = true,
                    partitionedUnder site: String? = nil) -> JSONValue {
            // SameSite=None needs Secure, so a non-Secure cookie is Lax.
            var fields: [String: JSONValue] = ["name": .string(name), "value": .string(value), "url": .string(url),
                                               "path": .string("/"), "secure": .bool(secure), "httpOnly": .bool(true),
                                               "sameSite": .string(secure ? "None" : "Lax"), "expires": expires]
            if let domain { fields["domain"] = .string(domain) }
            if let site { fields["partitionKey"] = .object(["topLevelSite": .string(site), "hasCrossSiteAncestor": .bool(false)]) }
            return .object(fields)
        }
        let signIn = ["qa_signin", "__Host-qa_signin"]
        // An earlier run's cookies in this QA home go first: DevTools deletes a cookie of the exact domain given.
        let partition = JSONValue.object(["topLevelSite": .string("https://example.org"), "hasCrossSiteAncestor": .bool(false)])
        for name in signIn + ["qa_session", "qa_plain", "qa_partitioned", "qa_probe"] {
            for domain in ["accounts.example.com", ".accounts.example.com", ".example.com", "widget.example.net",
                           ".widget.example.net", "probe.test"] {
                _ = try? await home.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string(domain)])
                if name == "qa_partitioned" {
                    _ = try? await home.devTools.send("Network.deleteCookies", [
                        "name": .string(name), "domain": .string(domain), "partitionKey": partition
                    ])
                }
            }
        }
        _ = try? await home.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "A"), cookie("__Host-qa_signin", "A"),
            cookie("qa_session", "A", domain: ".example.com"),
            cookie("qa_plain", "A", url: "http://accounts.example.com/", domain: ".example.com", secure: false),
            cookie("qa_partitioned", "A", url: "https://widget.example.net/", partitionedUnder: "https://example.org")
        ])])
        let planted = await storedCookies(home)
        // Whether Chromium binds a cookie to the scheme that set it: a non-Secure cookie set over HTTP, asked for
        // over HTTPS. The copy sets a non-Secure cookie over HTTP, since CEF does not say which scheme set it.
        _ = try? await home.devTools.send("Network.setCookie", [
            "name": .string("qa_probe"), "value": .string("1"), "url": .string("http://probe.test/"), "path": .string("/"),
            "sourceScheme": .string("NonSecure"), "sourcePort": .integer(80), "expires": expires
        ])
        record["schemeBoundCookies"] = .bool(await sentCookies(home, "https://probe.test/")["qa_probe"] == nil)
        let f = UUID()
        guard let tabF = await taskTab(f, base + "isolation") else { return }
        let started = await storedCookies(tabF)
        let sent = await sentCookies(tabF, accounts)
        // CEF's cookie manager cannot set a partitioned cookie: a copy leaves it out rather than make it a cookie of
        // every top-level site. Nor does it say which scheme and port set a cookie (`from=`, recorded only).
        let kept = { (cookies: [String]) in
            cookies.filter { $0.contains(" partition=- ") }
                .map { $0.replacingOccurrences(of: #" from=\S+"#, with: "", options: .regularExpression) }
        }
        record["cookiesCopied"] = .object(["default": .array(planted.map(JSONValue.string)),
                                           "task": .array(started.map(JSONValue.string))])
        check("cookies: a new task starts with each cookie as the default profile stores it",
              planted.count == 5 && kept(started) == kept(planted)
                && !started.contains { $0.hasPrefix("qa_partitioned ") && $0.contains(" partition=- ") }
                && signIn.allSatisfy { sent[$0]?.count == 1 },
              "task \(started) / accounts.example.com gets \(sent)")

        // The person signs in again on task F's page: new host-only sign-in cookies there, copied to the default
        // profile for the site. The accounts site must then get one of each from the default profile and from a
        // task started after it, the new one.
        // Both profiles also hold the domain cookie the copy before 2026-10-25 made of the sign-in cookie, as the
        // person's profiles did on 2026-10-26: the copy carries the site's host-only cookie and leaves neither
        // domain cookie, or the accounts site gets two values (Google's /CookieMismatch).
        let legacy = JSONValue.array([cookie("qa_signin", "OLD", domain: ".accounts.example.com")])
        _ = try? await home.devTools.send("Network.setCookies", ["cookies": legacy])
        _ = try? await tabF.devTools.send("Network.setCookies", ["cookies": legacy])
        _ = try? await tabF.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "B"), cookie("__Host-qa_signin", "B")
        ])])
        MacBrowserHost.shared.loginFollow.signedIn(session: f, site: "example.com")
        try? await Task.sleep(for: .seconds(2))
        let g = UUID()
        let fromDefault = await sentCookies(home, accounts)
        let fromE = await sentCookies(tabE ?? home, accounts)
        var fromG: [String: [String]] = [:]
        if let tabG = await taskTab(g, base + "isolation") { fromG = await sentCookies(tabG, accounts) }
        check("cookies: a person's sign-in copied to the default profile replaces its sign-in cookies and the copied domain cookie beside them, in running and later tasks too",
              tabE != nil && signIn.allSatisfy { fromDefault[$0] == ["B"] && fromE[$0] == ["B"] && fromG[$0] == ["B"] },
              "default \(fromDefault) / running task \(fromE) / later task \(fromG)")
        for task in [e, f, g] { client.closeTabs(forSession: task) }
        home.close()
    }

    // MARK: Sign-ins tasks follow

    /// The person's sign-ins reach every task that follows the site, a task's own sign-in stays its own, and a task
    /// that predates following keeps its cookies (docs/BROWSER_SESSION_ISOLATION.md 11). The QA server's
    /// `/follow/signin` (localhost) has a password form and a "Sign in with QA" link through another site
    /// (127.0.0.1, whose page waits for a click like an account chooser) back to `/follow/callback`; both set
    /// `qa_follow`. The person clicks through the host's input as a panel does; the agent acts through DevTools and
    /// reports its use, as its tools do.
    private func followsSignIns() async {
        let signIn = base + "follow/signin", home = base + "follow/home"
        let site = "localhost"
        let follow = MacBrowserHost.shared.loginFollow
        guard let start = try? client.openTab(url: signIn, viewport: .offscreenDefault), await loaded(start, signIn) else {
            return check("follow: the default profile's page loads", false, "no tab")
        }
        // An earlier run's sign-in in the default profile would be what new tasks start with.
        for name in ["qa_follow", "qa_rotate", "qa_pre"] + Self.accountCookies {
            for domain in ["localhost", "127.0.0.1"] {
                _ = try? await start.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string(domain)])
            }
        }
        // The QA home may hold an earlier run's sign-ins: this run counts its own.
        let earlier = profiles.following.signIns[site] ?? 0
        let signIns = { (self.profiles.following.signIns[site] ?? 0) - earlier }
        let p = UUID(), f = UUID(), g = UUID()
        guard let tabP = await taskTab(p, signIn), let tabF = await taskTab(f, signIn), let tabG = await taskTab(g, signIn) else {
            return
        }

        // The agent signs in on task G with an account of its own: the site becomes G's.
        client.noteAgentActivity(on: tabG)
        _ = await value(tabG, "document.querySelector('#password').focus(); 1")
        try? await Task.sleep(for: .seconds(1))
        client.noteAgentActivity(on: tabG)
        _ = await value(tabG, "document.querySelector('#user').value = 'AGENT'; document.querySelector('#password').value = 'x'; "
                        + "document.querySelector('form').submit(); 1")
        _ = await waitUntil(.seconds(10)) { tabG.currentURL == home && !tabG.isLoading }
        let ownG = await waitUntil(.seconds(8)) { self.profiles.isOwn(site, in: self.profiles.key(for: g)) }
        var sentG = await sentCookies(tabG, signIn), sentF = await sentCookies(tabF, signIn)
        check("follow: the agent's password sign-in stays its task's own, not the person's",
              ownG && signIns() == 0 && sentG["qa_follow"] == ["AGENT"] && sentF["qa_follow"] == nil,
              "own \(ownG), sign-ins \(signIns()), G \(sentG), F \(sentF)")

        // The person signs in with a password on task P's page: task F, open all along, and the default profile take it;
        // G keeps its own.
        await personClick(tabP, "#password")
        try? await Task.sleep(for: .seconds(1))
        _ = await value(tabP, "document.querySelector('#user').value = 'PERSON'; document.querySelector('#password').value = 'x'; 1")
        await personClick(tabP, "#go")
        _ = await waitUntil(.seconds(10)) { tabP.currentURL == home && !tabP.isLoading }
        _ = await waitUntil(.seconds(8)) { signIns() == 1 }
        try? await Task.sleep(for: .seconds(2))
        sentF = await sentCookies(tabF, signIn)
        sentG = await sentCookies(tabG, signIn)
        let sentDefault = await sentCookies(start, signIn)
        check("follow: the person's password sign-in reaches a running task and the default profile, not a task's own",
              signIns() == 1 && sentF["qa_follow"] == ["PERSON"] && sentDefault["qa_follow"] == ["PERSON"] && sentG["qa_follow"] == ["AGENT"],
              "sign-ins \(signIns()), F \(sentF), default \(sentDefault), G \(sentG)")

        // A page that renews a cookie as the person uses it, with no sign-in under way, is not copied.
        let q = UUID()
        var rotated: [String]?
        if let tabQ = await taskTab(q, signIn) {
            await personClick(tabQ, "#rotate")
            _ = await waitUntil(.seconds(10)) { tabQ.currentURL?.contains("rotate") == true && !tabQ.isLoading }
            try? await Task.sleep(for: .seconds(3))
            rotated = await sentCookies(tabQ, signIn)["qa_rotate"]
        }
        sentF = await sentCookies(tabF, signIn)
        check("follow: a cookie the site renews while the person browses is not copied", rotated != nil && sentF["qa_rotate"] == nil
              && signIns() == 1, "Q \(String(describing: rotated)), F \(sentF), sign-ins \(signIns())")

        // A page nobody drives that goes through the sign-in site and back on its own signs nobody in.
        let u = UUID()
        var sentU: [String: [String]] = [:]
        if let tabU = await taskTab(u, signIn) {
            _ = await value(tabU, "location.href = document.querySelector('#sso').href; 1")
            _ = await waitUntil(.seconds(10)) { tabU.currentURL?.contains("/follow/idp") == true && !tabU.isLoading }
            try? await Task.sleep(for: .seconds(1))
            _ = await value(tabU, "location.href = document.querySelector('#continue').href; 1")
            _ = await waitUntil(.seconds(10)) { tabU.currentURL == home && !tabU.isLoading }
            try? await Task.sleep(for: .seconds(3))
            sentU = await sentCookies(tabU, signIn)
        }
        sentF = await sentCookies(tabF, signIn)
        check("follow: a page nobody drives that signs in through another site on its own is no one's sign-in",
              sentU["qa_follow"] == ["SSO"] && sentF["qa_follow"] == ["PERSON"] && signIns() == 1,
              "U \(sentU), F \(sentF), sign-ins \(signIns())")

        // The person signs in without a password, through another site and back (a single sign-on).
        _ = await value(tabP, "location.href = '\(signIn)'; 1")
        _ = await loaded(tabP, signIn)
        await personClick(tabP, "#sso")
        _ = await waitUntil(.seconds(10)) { tabP.currentURL?.contains("/follow/idp") == true && !tabP.isLoading }
        try? await Task.sleep(for: .seconds(1))
        await personClick(tabP, "#continue")
        _ = await waitUntil(.seconds(10)) { tabP.currentURL == home && !tabP.isLoading }
        _ = await waitUntil(.seconds(8)) { signIns() == 2 }
        try? await Task.sleep(for: .seconds(2))
        sentF = await sentCookies(tabF, signIn)
        sentG = await sentCookies(tabG, signIn)
        let h = UUID()
        var sentH: [String: [String]] = [:]
        if let tabH = await taskTab(h, signIn) { sentH = await sentCookies(tabH, signIn) }
        check("follow: the person's sign-in without a password reaches running and later tasks, not a task's own",
              signIns() == 2 && sentF["qa_follow"] == ["SSO"] && sentH["qa_follow"] == ["SSO"] && sentG["qa_follow"] == ["AGENT"],
              "sign-ins \(signIns()), F \(sentF), later \(sentH), G \(sentG)")

        // The agent hands its tab over and the person signs in there: the person's sign-in, which reaches the others too.
        let k = UUID()
        var sentK: [String: [String]] = [:], ownK = true
        if let tabK = await taskTab(k, signIn) {
            client.noteAgentActivity(on: tabK)
            _ = tabK.handOff(reason: "Sign in")
            await personClick(tabK, "#password")
            try? await Task.sleep(for: .seconds(1))
            _ = await value(tabK, "document.querySelector('#user').value = 'HANDED'; document.querySelector('#password').value = 'x'; 1")
            await personClick(tabK, "#go")
            _ = await waitUntil(.seconds(10)) { tabK.currentURL == home && !tabK.isLoading }
            _ = await waitUntil(.seconds(8)) { signIns() == 3 }
            try? await Task.sleep(for: .seconds(2))
            tabK.endHandoff()
            sentK = await sentCookies(tabK, signIn)
            ownK = profiles.isOwn(site, in: profiles.key(for: k))
        }
        sentF = await sentCookies(tabF, signIn)
        sentG = await sentCookies(tabG, signIn)
        check("follow: the person's sign-in on a page the agent handed over reaches the others, not a task's own",
              signIns() == 3 && !ownK && sentK["qa_follow"] == ["HANDED"] && sentF["qa_follow"] == ["HANDED"]
                && sentG["qa_follow"] == ["AGENT"],
              "sign-ins \(signIns()), K own \(ownK) \(sentK), F \(sentF), G \(sentG)")

        // A task from before following keeps its cookies: when it opens again, it takes only the sites it has no cookie
        // of from the default profile, and the person's sign-ins made since.
        let old = UUID()
        let fill = "https://fill.qa-follow.test/"
        guard let tabOld = await taskTab(old, signIn) else { return }
        _ = try? await tabOld.devTools.send("Network.setCookie", [
            "name": .string("qa_pre"), "value": .string("OLD"), "url": .string(signIn.replacingOccurrences(of: "localhost", with: "127.0.0.1")),
            "path": .string("/")
        ])
        _ = try? await start.devTools.send("Network.setCookies", ["cookies": .array([
            .object(["name": .string("qa_pre"), "value": .string("DEFAULT"), "path": .string("/"),
                     "url": .string(signIn.replacingOccurrences(of: "localhost", with: "127.0.0.1"))]),
            .object(["name": .string("qa_fill"), "value": .string("DEFAULT"), "url": .string(fill), "path": .string("/"),
                     "secure": .bool(true)])
        ])])
        let oldKey = profiles.key(for: old)
        client.closeTabs(forSession: old)
        profiles.following.followers.remove(oldKey)
        profiles.following.received[oldKey] = nil
        try? await Task.sleep(for: .seconds(1))
        var sentOld: [String: [String]] = [:], filled: [String: [String]] = [:]
        if let again = await taskTab(old, signIn) {
            sentOld = await sentCookies(again, signIn.replacingOccurrences(of: "localhost", with: "127.0.0.1"))
            filled = await sentCookies(again, fill)
            sentOld["qa_follow"] = await sentCookies(again, signIn)["qa_follow"]
        }
        check("follow: a task from before following keeps its cookies and takes the sites it had none of",
              sentOld["qa_pre"] == ["OLD"] && filled["qa_fill"] == ["DEFAULT"] && sentOld["qa_follow"] == ["HANDED"],
              "127.0.0.1 and localhost \(sentOld), fill.qa-follow.test \(filled)")
        record["follow"] = .object(["signIns": .integer(Int64(signIns())),
                                    "own": .array((profiles.following.own[profiles.key(for: g)] ?? []).sorted().map(JSONValue.string))])
        for task in [p, f, g, h, q, u, k, old] { client.closeTabs(forSession: task) }
        await addsAnAccountOnce(start)
        start.close()
    }

    /// Several accounts in one sign-in, as Google keeps them (the QA server's `/follow/accounts`), reach every task
    /// whole: the person adds a second account on task A while five other tasks, at the same site's sign-in page, are
    /// watched for a sign-in of their own. The cookies Yardlet puts into them are not their sign-ins, so the second
    /// account is passed on once and none passes back the cookies it was being given (docs/BROWSER_SESSION_ISOLATION.md
    /// 11).
    private func addsAnAccountOnce(_ start: BrowserTab) async {
        let page = base + "follow/accounts"
        let site = "localhost"
        let names = Self.accountCookies
        let earlier = profiles.following.signIns[site] ?? 0
        let signIns = { (self.profiles.following.signIns[site] ?? 0) - earlier }
        let a = UUID(), others = (1...5).map { _ in UUID() }
        guard let tabA = await taskTab(a, page) else { return }
        var watched: [BrowserTab] = []
        for task in others {
            guard let tab = await taskTab(task, page) else { return }
            watched.append(tab)
        }
        func signIn(_ account: String) async {
            await personClick(tabA, "#password")
            try? await Task.sleep(for: .seconds(1))
            _ = await value(tabA, "document.querySelector('#user').value = '\(account)'; document.querySelector('#password').value = 'x'; 1")
            await personClick(tabA, "#go")
        }
        await signIn("ONE")
        _ = await waitUntil(.seconds(10)) { signIns() == 1 }
        try? await Task.sleep(for: .seconds(4))
        // The person is at the others' sign-in pages too: each is watched for three minutes.
        for tab in watched { await personClick(tab, "#password") }
        try? await Task.sleep(for: .seconds(2))
        await signIn("TWO")
        _ = await waitUntil(.seconds(10)) { signIns() >= 2 }
        // The others' pages reload as their session changes, and each is checked a second after its load.
        try? await Task.sleep(for: .seconds(15))
        var held: [String] = []
        var whole = true
        for (name, tab) in zip(["A", "B", "C", "D", "E", "F", "default"], [tabA] + watched + [start]) {
            let sent = await sentCookies(tab, page)
            let sessions = Set(names.dropFirst(2).compactMap { sent[$0]?.first })
            let missing = names.dropFirst(2).filter { sent[$0] == nil }.count
            whole = whole && sent["qa_accounts"] == ["ONE.TWO"] && sessions.count == 1 && missing == 0
                && sent["qa_seen"].map(Set.init) == sessions
            held.append("\(name) accounts \(sent["qa_accounts"]?.joined(separator: ",") ?? "none"), \(sessions.count) sessions, "
                        + "\(missing) of 30 missing")
        }
        record["accounts"] = .object(["signIns": .integer(Int64(signIns())), "held": .array(held.map(JSONValue.string))])
        check("follow: an account added on one task is passed on once, and every task keeps both accounts",
              signIns() == 2 && whole, "sign-ins \(signIns()); " + held.joined(separator: "; "))
        // The sign-ins log names the second account's sign-in, its task and where it went, and no value.
        let session = await sentCookies(tabA, page)["qa_seen"]?.first ?? "?"
        let logged = ((try? String(contentsOf: MacBrowserHost.shared.paths.log.deletingLastPathComponent()
            .appending(path: "sign-ins.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains(" \(site): ") }.suffix(signIns()).map(String.init)
        let second = "the person's sign-in \(earlier + 2) in task \(a.uuidString.prefix(8)) (passwordField) went to "
        check("follow: the sign-ins log names each of the person's sign-ins and where it went, with no cookie value",
              logged.count == 2 && logged[1].contains(second) && !logged.contains { $0.contains(session) }, logged.joined(separator: " | "))
        for task in [a] + others { client.closeTabs(forSession: task) }
        // The page's own cookie would show in the next run's other checks, which read the default profile's cookies.
        for name in names {
            _ = try? await start.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string(site)])
        }
    }

    // MARK: The old copy's domain cookies

    /// A site that sets and deletes a cookie host-only can neither replace nor delete the domain cookie the copy before
    /// 2026-10-25 made of it, which its host still receives, as porkbun.com could not in Yardlet's profiles until
    /// 2026-10-31 (docs/BROWSER_SESSION_ISOLATION.md 8). The QA server's `/shapes/login`, opened as qa.localhost (a host
    /// whose domain cookies Chromium keeps), stays "Passwordless login" while a request carries qa_npw, and its sign-in
    /// goes back to the sign-in page when the first qa_prb it receives is not the one it set last. A task holds the old
    /// copy's domain cookies of both, set through DevTools as the copy set them through the cookie manager, before the
    /// site sets its own qa_prb. The host ends, the one-time cleanup runs again as it does before the host starts, and
    /// the site's sign-in must then work.
    private func removesTheOldCopysDomainCookies() async {
        let site = base.replacingOccurrences(of: "localhost", with: "qa.localhost")
        let login = site + "shapes/login"
        let task = UUID()
        guard let tab = await taskTab(task, site + "isolation") else { return }
        for name in ["qa_npw", "qa_prb"] {
            for domain in ["qa.localhost", ".qa.localhost"] {
                _ = try? await tab.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string(domain)])
            }
        }
        _ = try? await tab.devTools.send("Network.setCookies", ["cookies": .array(["qa_npw", "qa_prb"].map { name -> JSONValue in
            .object(["name": .string(name), "value": .string("OLD"), "url": .string(site), "domain": .string(".qa.localhost"),
                     "path": .string("/"), "httpOnly": .bool(true), "expires": .number(Date().timeIntervalSince1970 + 3600)])
        })])
        let before = await shapesSignIn(tab, login)
        let sent = try? await tab.devTools.send("Network.getCookies", ["urls": .array([.string(login)])], timeout: .seconds(10))
        let sentBefore = (sent?["cookies"]?.arrayValue ?? []).compactMap { cookie -> String? in
            guard let name = cookie["name"]?.stringValue, name.hasPrefix("qa_") else { return nil }
            return "\(name) \(cookie["domain"]?.stringValue ?? "?") \(cookie["value"]?.stringValue == "OLD" ? "OLD" : "site's")"
        }
        var shapes: [String: JSONValue] = ["before": before.json, "sentBefore": .array(sentBefore.map(JSONValue.string))]
        record["shapes"] = .object(shapes)
        check("shapes: the old copy's domain cookies keep the site from showing its password field and from signing in",
              before.passwordless && before.passwordlessAfterShow && !before.signedIn,
              "\(Self.describe(before.json)), the sign-in page gets \(sentBefore)")

        client.closeTabs(forSession: task)
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        // This QA home's record of the cleanup keeps it from running again.
        try? FileManager.default.removeItem(at: MacBrowserHost.shared.paths.root.appending(path: BrowserCookieCopyRepair.recordName))
        guard let again = await taskTab(task, site + "isolation") else { return }
        let after = await shapesSignIn(again, login)
        let all = try? await again.devTools.send("Network.getAllCookies", [:], timeout: .seconds(10))
        let left = (all?["cookies"]?.arrayValue ?? []).compactMap { cookie -> String? in
            guard let name = cookie["name"]?.stringValue, ["qa_npw", "qa_prb"].contains(name),
                  let domain = cookie["domain"]?.stringValue, domain.hasSuffix("qa.localhost") else { return nil }
            return "\(name) \(domain)"
        }.sorted()
        shapes["after"] = after.json
        record["shapes"] = .object(shapes)
        check("shapes: once the cleanup removes them, the site shows its password field and signs in",
              !after.passwordless && after.signedIn && left == ["qa_prb qa.localhost"],
              "\(Self.describe(after.json)), qa.localhost holds \(left)")
        client.closeTabs(forSession: task)
    }

    private struct ShapesSignIn {
        var passwordless = false, passwordlessAfterShow = false, signedIn = false

        var json: JSONValue {
            .object(["passwordless": .bool(passwordless), "passwordlessAfterShow": .bool(passwordlessAfterShow),
                     "signedIn": .bool(signedIn)])
        }
    }

    /// Opens the QA server's sign-in page, presses "Show password field" when it is passwordless, and signs in.
    private func shapesSignIn(_ tab: BrowserTab, _ login: String) async -> ShapesSignIn {
        var result = ShapesSignIn()
        _ = await value(tab, "location.href = '\(login)'; 1")
        guard await loaded(tab, login) else { return result }
        result.passwordless = await value(tab, "window.qa.shapes.passwordless")?.boolValue == true
        result.passwordlessAfterShow = result.passwordless
        if result.passwordless {
            // The button reloads the page once the site has answered.
            _ = await value(tab, "window.qaBeforeShow = true; document.querySelector('#show').click(); 1")
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(200))
                if !tab.isLoading, await value(tab, "window.qaBeforeShow === undefined && !!window.qa")?.boolValue == true { break }
            }
            result.passwordlessAfterShow = await value(tab, "window.qa.shapes.passwordless")?.boolValue == true
        }
        _ = await value(tab, "document.querySelector('#user').value = 'qa'; document.querySelector('form').submit(); 1")
        _ = await waitUntil(.seconds(10)) {
            !tab.isLoading && (tab.currentURL?.contains("/shapes/account") == true || tab.currentURL?.contains("weird") == true)
        }
        result.signedIn = tab.currentURL?.contains("/shapes/account") == true
        return result
    }

    /// The person's click on an element of the page, through the host's input as the panel sends it.
    private func personClick(_ tab: BrowserTab, _ selector: String) async {
        let rect = await value(tab, "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); "
                               + "return [r.left + r.width / 2, r.top + r.height / 2]; })()")
        guard let point = rect?.arrayValue, point.count == 2, let x = point[0].doubleValue, let y = point[1].doubleValue else {
            return check("follow: the page shows \(selector)", false, "not found")
        }
        tab.send(.focus(tab: tab.id, isFocused: true))
        tab.send(.mouse(tab: tab.id, input: BrowserMouseInput(kind: .down, x: x, y: y, button: .left)))
        tab.send(.mouse(tab: tab.id, input: BrowserMouseInput(kind: .up, x: x, y: y, button: .left)))
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The cookies this check plants, in a tab's profile as Chromium stores them: name, domain (a leading dot for a
    /// domain cookie), Secure, the site it is partitioned under, the scheme and port that set it, and the value.
    private func storedCookies(_ tab: BrowserTab) async -> [String] {
        let planted: Set = ["qa_signin", "__Host-qa_signin", "qa_session", "qa_plain", "qa_partitioned"]
        let all = try? await tab.devTools.send("Network.getAllCookies", [:], timeout: .seconds(10))
        return (all?["cookies"]?.arrayValue ?? []).compactMap { cookie -> String? in
            guard let name = cookie["name"]?.stringValue, planted.contains(name),
                  cookie["domain"]?.stringValue?.contains("example.") == true else { return nil }
            let partition = cookie["partitionKey"]?["topLevelSite"]?.stringValue ?? "-"
            let port = cookie["sourcePort"].map { Self.describe($0) } ?? "?"
            return "\(name) \(cookie["domain"]?.stringValue ?? "?") \(cookie["secure"]?.boolValue == true ? "Secure" : "-") "
                + "partition=\(partition) from=\(cookie["sourceScheme"]?.stringValue ?? "?"):\(port) "
                + "value=\(cookie["value"]?.stringValue ?? "?")"
        }.sorted()
    }

    /// The values of each QA cookie Chromium would send to `url`, as a site's server reads its Cookie header.
    private func sentCookies(_ tab: BrowserTab, _ url: String) async -> [String: [String]] {
        let list = try? await tab.devTools.send("Network.getCookies", ["urls": .array([.string(url)])], timeout: .seconds(10))
        var sent: [String: [String]] = [:]
        for cookie in list?["cookies"]?.arrayValue ?? [] {
            guard let name = cookie["name"]?.stringValue, name.contains("qa_") else { continue }
            sent[name, default: []].append(cookie["value"]?.stringValue ?? "?")
        }
        return sent
    }

    private static func describe(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Pieces

    private func taskTab(_ session: UUID, _ url: String) async -> BrowserTab? {
        guard let tab = try? client.openTab(forSession: session, url: url, viewport: .offscreenDefault), await loaded(tab, url) else {
            check("a task's tab loads (\(session.uuidString.prefix(8)))", false, "not loaded")
            return nil
        }
        return tab
    }

    /// Waits for the page: a new task's tab first takes its starting cookies on about:blank.
    private func loaded(_ tab: BrowserTab, _ url: String) async -> Bool {
        await waitUntil(.seconds(20)) { tab.currentURL == url && !tab.isLoading }
    }

    private func value(_ tab: BrowserTab, _ expression: String) async -> JSONValue? {
        let result = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        return result?["result"]?["value"]
    }

    private func cookies(_ tab: BrowserTab) async -> String {
        await value(tab, "document.cookie")?.stringValue ?? ""
    }

    private func phase(_ name: String) async {
        try? JSONEncoder().encode(JSONValue.object(["name": .string(name)]))
            .write(to: output.appending(path: "markers/\(name).json"))
        try? await Task.sleep(for: .seconds(6))
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
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(600)))]))
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
