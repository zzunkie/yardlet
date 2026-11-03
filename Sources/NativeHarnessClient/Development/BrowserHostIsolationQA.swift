#if DEBUG
import AppKit
import Foundation
import YardletAgentTools

/// QA for the profiles tasks' tabs use against the real browser host (docs/BROWSER_SESSION_ISOLATION.md): tasks share
/// the default profile, and a task takes a profile of its own just before its agent signs in to a site itself. Run by
/// `run-check.sh … --ui-fixture-browser-check-only=isolation` in a temporary home, which may hold an earlier QA run's
/// browser data: each check uses new tasks and sets what it reads. Made-up cookies on the QA server only. Phase
/// markers let run-check.sh sample the process tree's memory as contexts are added. Checks land in `result.json`.
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
        // Per task, as Yardlet starts; an earlier run may have left this QA home shared.
        profiles.storage = .perTask
        // `--ui-fixture-isolation-cookies` runs only the check that copied cookies stay as Chromium stored them, and
        // `--ui-fixture-isolation-sign-ins` only the checks of the person's and the agents' sign-ins.
        if CommandLine.arguments.contains("--ui-fixture-isolation-cookies") {
            record["storage"] = .string(profiles.storage.rawValue)
            await copiesCookiesAsStored()
            return await finish()
        }
        if CommandLine.arguments.contains("--ui-fixture-isolation-sign-ins") {
            record["storage"] = .string(profiles.storage.rawValue)
            await keepsEveryAccount()
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

        // A tab of no task is in the default profile, which tasks share.
        guard let baseline = try? client.openTab(url: page, viewport: .offscreenDefault), await loaded(baseline, page) else {
            check("the default profile's page loads", false, "no tab")
            return await finish()
        }
        _ = await value(baseline, "document.cookie = 'baseline=1; path=/; max-age=3600'; document.cookie = 'who=; path=/; max-age=0'; "
                        + "localStorage.removeItem('who'); 1")
        await phase("iso-0-default")

        // Tasks use the default profile, as the tabs of one browser do.
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        guard let firstA = await taskTab(a, page), let tabB = await taskTab(b, page) else { return await finish() }
        _ = await value(firstA, "document.cookie = 'who=S; path=/; max-age=3600'; 1")
        let sharedB = await cookies(tabB), sharedDefault = await cookies(baseline)
        check("new tasks use the default profile: a cookie one sets reaches the other and the default profile, and no folder is made",
              sharedB.contains("baseline=1") && sharedB.contains("who=S") && sharedDefault.contains("who=S")
                && !profiles.folderExists(profiles.key(for: a)) && !profiles.folderExists(profiles.key(for: b)),
              "B \(sharedB) / default \(sharedDefault)")

        // Task A's agent is about to sign in itself: A takes a profile of its own, a copy of the default profile's
        // cookies, and its tab opens again there, once.
        let took = MacBrowserHost.shared.takeOwnProfile(for: a, site: "localhost", how: "QA")
        let ownA = await reopened(a, from: firstA, page)
        let again = MacBrowserHost.shared.takeOwnProfile(for: a, site: "localhost", how: "QA")
        let departure = client.departure(of: firstA.id)?.departure
        guard let tabA = ownA else {
            check("a task that is to sign in itself takes a profile of its own and its tab opens again there", false,
                  "took \(took), no tab")
            return await finish()
        }
        let startA = await cookies(tabA)
        check("a task that is to sign in itself takes a profile of its own, a copy of the default profile's cookies, and its tab "
              + "opens again there once",
              took && !again && client.tabs(forSession: a).map(\.id) == [tabA.id]
                && departure == .reopened(key: firstA.key, cause: .ownProfile) && profiles.folderExists(profiles.key(for: a))
                && startA.contains("baseline=1") && startA.contains("who=S"),
              "took \(took), again \(again), tabs \(client.tabs(forSession: a).map(\.id)), \(String(describing: departure)), A \(startA)")
        _ = await value(tabA, "document.cookie = 'who=A; path=/; max-age=3600'; localStorage.setItem('who', 'A'); 1")
        let nowA = await cookies(tabA), nowB = await cookies(tabB), nowDefault = await cookies(baseline)
        let storeB = await value(tabB, "localStorage.getItem('who')")
        check("the task's own sign-in stays in its profile, and the other tasks and the default profile keep theirs",
              nowA.contains("who=A") && nowB.contains("who=S") && !nowB.contains("who=A") && nowDefault.contains("who=S")
                && storeB != .string("A"),
              "A \(nowA) / B \(nowB) \(String(describing: storeB)) / default \(nowDefault)")

        // A child task of a task with a profile of its own starts with a copy of it; a child of a task in the default
        // profile stays there.
        profiles.parentOf = { $0 == c ? a : $0 == d ? b : nil }
        guard let tabC = await taskTab(c, page), let tabD = await taskTab(d, page) else { return await finish() }
        let cookieC = await cookies(tabC), cookieD = await cookies(tabD)
        check("a child of a task with a profile of its own starts with a copy of it; a child of a task in the default profile stays there",
              cookieC.contains("who=A") && profiles.hasOwnProfile(c) && cookieD.contains("who=S") && !cookieD.contains("who=A")
                && !profiles.hasOwnProfile(d) && !profiles.folderExists(profiles.key(for: d)),
              "C \(cookieC) / D \(cookieD)")

        let taskPreferences = (try? Data(contentsOf: profiles.folder(for: profiles.key(for: a)).appending(path: "Preferences")))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let copiedKey = taskPreferences?["webauthn"]?["touchid"]?["metadata_secret"]?.stringValue
        check("a task profile carries the default profile's Touch ID passkey key", copiedKey == Self.passkeyKey,
              copiedKey == nil ? "missing" : "present")
        await phase("iso-4-contexts")

        // Memory: four more tasks with profiles of their own.
        var more: [UUID] = []
        for _ in 0..<4 {
            let task = UUID()
            more.append(task)
            _ = await ownTab(task, page)
        }
        await phase("iso-8-contexts")

        // The host ends when no tab is left: each task opens again in the profile it had. A's sign-in, its session
        // cookie and its local storage are on disk, and the folder is not seeded again.
        _ = await value(tabA, "document.cookie = 'visit=A; path=/'; 1")
        for task in [a, b, c, d] + more { client.closeTabs(forSession: task) }
        baseline.close()
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        let reread = BrowserTaskProfiles(root: MacBrowserHost.shared.paths.root)
        if let againA = await taskTab(a, page), let againB = await taskTab(b, page), let againC = await taskTab(c, page) {
            let cookieA = await cookies(againA), store = await value(againA, "localStorage.getItem('who')")
            let cookieB = await cookies(againB), cookieC = await cookies(againC)
            check("after the host restarts each task opens in the profile it had: A's own sign-in, session cookie and local "
                  + "storage, C's copy, and B in the default profile",
                  cookieA.contains("who=A") && cookieA.contains("visit=A") && store == .string("A")
                    && cookieB.contains("who=S") && !cookieB.contains("who=A") && cookieC.contains("who=A")
                    && reread.profile(for: a)?.key == profiles.key(for: a) && reread.profile(for: b) == nil,
                  "A \(cookieA) \(String(describing: store)) / B \(cookieB) / C \(cookieC)")
        }

        // Shared storage: a task with a profile of its own opens in the default profile.
        client.closeTabs(forSession: a)
        profiles.storage = .shared
        if let tabShared = await taskTab(a, page) {
            let sharedCookies = await cookies(tabShared)
            check("with shared storage a task with a profile of its own opens in the default profile",
                  sharedCookies.contains("who=S") && !sharedCookies.contains("who=A"), sharedCookies)
        }
        client.closeTabs(forSession: a)
        profiles.storage = .perTask
        for task in [b, c] { client.closeTabs(forSession: task) }

        await copiesCookiesAsStored()
        await keepsEveryAccount()
        await removesTheOldCopysDomainCookies()
        let earlier = await sharesEarlierProfiles()

        // Archived and deleted tasks' profiles go once the host has let them go; the folder of a task that moved to the
        // default profile is in the Trash already.
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        let unkept = Set(([c] + more).map(profiles.key(for:)))
        let keptKeys = [profiles.key(for: a)] + (earlier.map { [profiles.key(for: $0.kept)] } ?? [])
        let removed = Set(profiles.removeFolders(keeping: Set([a] + (earlier.map { [$0.kept, $0.moved] } ?? []))))
        // Chromium's own list of the profiles it opened forgets the removed ones too.
        let localState = (try? Data(contentsOf: MacBrowserHost.shared.paths.root.appending(path: "Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let listed = Set(((localState?["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?.keys.map { $0 } ?? [])
        let listedUnkept = unkept.filter { listed.contains(BrowserTaskProfiles.folderPrefix + $0) }
        check("removing profiles keeps the folders of kept tasks with profiles of their own and removes the rest, from "
              + "Chromium's profile list too",
              keptKeys.allSatisfy(profiles.folderExists) && unkept.isSubset(of: removed) && !unkept.contains(where: profiles.folderExists)
                && earlier.map { !profiles.folderExists(profiles.key(for: $0.moved)) } != false
                && listed.contains(BrowserTaskProfiles.folderPrefix + profiles.key(for: a)) && listedUnkept.isEmpty,
              "removed \(removed.count), this run's \(unkept.intersection(removed).count) of \(unkept.count); "
                + "Local State lists \(listed.count), removed ones still listed \(listedUnkept.count)")
        await finish()
    }

    // MARK: Cookies copied as stored

    /// A task's profile of its own must start with the cookies Chromium stored in the default profile.
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
        if let tabE = await ownTab(e, verify) {
            let copied = await value(tabE, "window.qa.cookieCheck")
            check("cookie check: a task's profile of its own signs in across two sites with the cookies it started with",
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
        guard let tabF = await ownTab(f, base + "isolation") else { return }
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
        check("cookies: a task's profile of its own starts with each cookie as the default profile stores it",
              planted.count == 5 && kept(started) == kept(planted)
                && !started.contains { $0.hasPrefix("qa_partitioned ") && $0.contains(" partition=- ") }
                && signIn.allSatisfy { sent[$0]?.count == 1 },
              "task \(started) / accounts.example.com gets \(sent)")

        // The default profile also holds the domain cookie the copy before 2026-10-25 made of the sign-in cookie, as the
        // person's profiles did on 2026-10-26: a profile of its own takes the site's host-only cookie and leaves the
        // domain one, or the accounts site gets two values (Google's /CookieMismatch).
        _ = try? await home.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "B"), cookie("__Host-qa_signin", "B"), cookie("qa_signin", "OLD", domain: ".accounts.example.com")
        ])])
        let g = UUID()
        var fromG: [String: [String]] = [:]
        if let tabG = await ownTab(g, base + "isolation") { fromG = await sentCookies(tabG, accounts) }
        check("cookies: a profile of its own leaves out the earlier copy's domain cookie beside the site's host-only one",
              signIn.allSatisfy { fromG[$0] == ["B"] }, "a new profile of its own sends \(fromG)")
        _ = try? await home.devTools.send("Network.deleteCookies", ["name": .string("qa_signin"), "domain": .string(".accounts.example.com")])
        for task in [e, f, g] { client.closeTabs(forSession: task) }
        home.close()
    }

    // MARK: Sign-ins

    /// The person's sign-ins reach every task in the default profile as they are made, and a site that keeps several
    /// accounts in one set of cookies keeps them all, as Google does (the QA server's `/follow/accounts`: a list of
    /// accounts, 30 cookies of the session and one the page reads, and the page reloads when its session changes).
    /// The person signs in on task A's page and adds a second account on task B's. Task G's agent then signs in with
    /// an account of its own through its tools: typing into the password field first gives G a profile of its own and
    /// opens its tab again there once, and the person's accounts stay as they were in A, B and the default profile.
    private func keepsEveryAccount() async {
        let page = base + "follow/accounts"
        let names = Self.accountCookies
        guard let start = try? client.openTab(url: page, viewport: .offscreenDefault), await loaded(start, page) else {
            return check("sign-ins: the default profile's page loads", false, "no tab")
        }
        // An earlier run's accounts in this QA home go first.
        for name in names {
            _ = try? await start.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string("localhost")])
        }
        let a = UUID(), b = UUID(), g = UUID()
        guard let tabA = await taskTab(a, page), let tabB = await taskTab(b, page) else { return }
        func signIn(_ tab: BrowserTab, _ account: String) async {
            await personClick(tab, "#password")
            _ = await value(tab, "document.querySelector('#user').value = '\(account)'; document.querySelector('#password').value = 'x'; 1")
            await personClick(tab, "#go")
            try? await Task.sleep(for: .seconds(3))
        }
        func held(_ tab: BrowserTab) async -> (accounts: [String]?, whole: Bool, said: String) {
            let sent = await sentCookies(tab, page)
            let sessions = Set(names.dropFirst(2).compactMap { sent[$0]?.first })
            let missing = names.dropFirst(2).filter { sent[$0] == nil }.count
            let whole = sessions.count == 1 && missing == 0 && sent["qa_seen"].map(Set.init) == sessions
            return (sent["qa_accounts"], whole, "accounts \(sent["qa_accounts"]?.joined(separator: ",") ?? "none"), "
                    + "\(sessions.count) sessions, \(missing) of 30 missing")
        }
        await signIn(tabA, "ONE")
        await signIn(tabB, "TWO")
        var person: [(name: String, held: (accounts: [String]?, whole: Bool, said: String))] = []
        for (name, tab) in [("A", tabA), ("B", tabB), ("default", start)] { person.append((name, await held(tab))) }
        check("sign-ins: an account the person adds on one task reaches the other task and the default profile, each holding both",
              person.allSatisfy { $0.held.accounts == ["ONE.TWO"] && $0.held.whole },
              person.map { "\($0.name) \($0.held.said)" }.joined(separator: "; "))

        // Task G's agent signs in with an account of its own through the Yardlet tools, as a harness calls them.
        let broker = MacAgentToolService.shared.broker
        guard let launch = broker.agentToolServer(for: g, workspaceRoots: []) else {
            return check("sign-ins: the broker issues a task its tools", false, "no launch")
        }
        let token = launch.environment[AgentToolEnvironment.token] ?? ""
        func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
            await broker.handle(AgentToolCall(token: token, session: g.uuidString, tool: tool, arguments: .object(arguments)))
        }
        _ = await call(AgentToolCatalog.navigate, ["url": .string(page)])
        guard let first = client.tab(forSession: g) else { return check("sign-ins: the agent's tab opens", false, "no tab") }
        let fields = Self.refs(in: await call(AgentToolCatalog.snapshot).text, role: "textbox")
        let typed = fields.count == 2 ? await call(AgentToolCatalog.type, ["ref": .string(fields[1]), "text": .string("x")]) : nil
        let reopened = await reopened(g, from: first, page)
        let departure = client.departure(of: first.id)?.departure
        check("sign-ins: the agent typing into a password field first gives its task a profile of its own, and its tab opens "
              + "again there once, with nothing typed",
              typed?.isError == true && typed?.text.contains("profile of its own") == true && reopened != nil
                && client.tabs(forSession: g).count == 1 && departure == .reopened(key: first.key, cause: .ownProfile)
                && profiles.hasOwnProfile(g),
              "fields \(fields.count), \(typed?.text ?? "no call"), \(String(describing: departure))")
        // Its sign-in now goes into its own profile, without another reload.
        let again = Self.refs(in: await call(AgentToolCatalog.snapshot).text, role: "textbox")
        var signedIn: AgentToolResult?
        if again.count == 2 {
            _ = await call(AgentToolCatalog.type, ["ref": .string(again[0]), "text": .string("AGENT")])
            signedIn = await call(AgentToolCatalog.type, ["ref": .string(again[1]), "text": .string("x"), "submit": .bool(true)])
            try? await Task.sleep(for: .seconds(3))
        }
        let agent = client.tab(forSession: g)
        let agentHeld = agent == nil ? nil : await held(agent!)
        person = []
        for (name, tab) in [("A", tabA), ("B", tabB), ("default", start)] { person.append((name, await held(tab))) }
        check("sign-ins: the agent's sign-in stays in its task's profile, and the person's accounts stay as they were in the "
              + "other tasks and the default profile",
              signedIn?.isError == false && agent === reopened && agentHeld?.accounts == ["ONE.TWO.AGENT"]
                && person.allSatisfy { $0.held.accounts == ["ONE.TWO"] && $0.held.whole },
              "G \(agentHeld?.said ?? "no tab") \(signedIn?.text ?? "no call"); "
                + person.map { "\($0.name) \($0.held.said)" }.joined(separator: "; "))
        // The sign-ins log names the task that took a profile of its own and how, and no value.
        let logged = ((try? String(contentsOf: MacBrowserHost.shared.paths.log.deletingLastPathComponent()
            .appending(path: "sign-ins.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains("task \(g.uuidString.prefix(8))") }.map(String.init)
        check("sign-ins: the log names the task that took a profile of its own and how, with no cookie value",
              logged.count == 1 && logged[0].contains("localhost: task \(g.uuidString.prefix(8)) took a profile of its own before "
                + "its agent's sign-in (typed into a password or code field)") && !logged[0].contains("AGENT"),
              logged.joined(separator: " | "))
        for task in [a, b, g] { client.closeTabs(forSession: task) }
        // The page's own cookie would show in the next run's other checks, which read the default profile's cookies.
        for name in names {
            _ = try? await start.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string("localhost")])
        }
        start.close()
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
        guard let tab = await ownTab(task, site + "isolation") else { return }
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

    // MARK: Earlier task profiles

    /// Task profiles from before tasks shared the default profile are sorted once, before the host starts
    /// (docs/BROWSER_SESSION_ISOLATION.md 7). X had signed in to a site itself and keeps its profile. Y held copies of
    /// the person's sign-ins and a cookie of a site the default profile has none of, which the default profile takes
    /// as Chromium stored it (and must read) before Y moves to the default profile and Y's folder to the Trash. The tasks.
    private func sharesEarlierProfiles() async -> (kept: UUID, moved: UUID)? {
        let page = base + "isolation", only = "https://only.qa-earlier.test/"
        let x = UUID(), y = UUID()
        guard let home = try? client.openTab(url: page, viewport: .offscreenDefault), await loaded(home, page),
              let tabX = await ownTab(x, page), let tabY = await ownTab(y, page) else {
            check("earlier profiles: the tabs load", false, "no tab")
            return nil
        }
        // An earlier run's cookie of that site in the default profile would keep it from being taken.
        _ = try? await home.devTools.send("Network.deleteCookies", ["name": .string("qa_earlier"), "domain": .string("only.qa-earlier.test")])
        _ = await value(home, "document.cookie = 'qa_mine=DEFAULT; path=/; max-age=3600'; 1")
        _ = await value(tabX, "document.cookie = 'qa_mine=X; path=/; max-age=3600'; 1")
        _ = await value(tabY, "document.cookie = 'qa_mine=Y; path=/; max-age=3600'; 1")
        _ = try? await tabY.devTools.send("Network.setCookie", [
            "name": .string("qa_earlier"), "value": .string("Y"), "url": .string(only), "path": .string("/"), "secure": .bool(true),
            "httpOnly": .bool(true), "expires": .number(Date().timeIntervalSince1970 + 3600)
        ])
        let keyY = profiles.key(for: y)
        for task in [x, y] { client.closeTabs(forSession: task) }
        home.close()
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        let started = Date()
        profiles.restoreEarlierProfiles(emptying: [keyY])

        // The host starts again, and sorts the earlier profiles first.
        guard let again = try? client.openTab(url: page, viewport: .offscreenDefault), await loaded(again, page),
              let againX = await taskTab(x, page), let againY = await taskTab(y, page) else {
            check("earlier profiles: the tabs load again", false, "no tab")
            return nil
        }
        let fromDefault = await sentCookies(again, only), fromY = await sentCookies(againY, only)
        let mineX = await sentCookies(againX, page)["qa_mine"], mineY = await sentCookies(againY, page)["qa_mine"]
        check("earlier profiles: one that signed in itself stays its task's; one of copies moves its task to the default "
              + "profile, which first takes, as stored, the sites it had none of",
              profiles.hasOwnProfile(x) && !profiles.hasOwnProfile(y) && mineX == ["X"] && mineY == ["DEFAULT"]
                && fromDefault["qa_earlier"] == ["Y"] && fromY["qa_earlier"] == ["Y"],
              "X own \(profiles.hasOwnProfile(x)) \(mineX ?? []), Y own \(profiles.hasOwnProfile(y)) \(mineY ?? []), "
                + "default \(fromDefault), Y \(fromY)")
        // The default profile's cookies were copied to the Trash first, Y's folder went there whole, and the log says
        // what moved.
        let trash = URL(filePath: NSHomeDirectory()).appending(path: ".Trash")
        let recent = ((try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >= started.addingTimeInterval(-1) }
        let backups = recent.filter { $0.lastPathComponent.hasPrefix("Yardlet cookie backup ")
            && FileManager.default.fileExists(atPath: $0.appending(path: "Default/Cookies").path(percentEncoded: false)) }
        let setAside = recent.filter { $0.lastPathComponent.hasPrefix("Yardlet task profiles ")
            && FileManager.default.fileExists(atPath: $0.appending(path: "Task-\(keyY)/Cookies").path(percentEncoded: false)) }
        let logged = ((try? String(contentsOf: MacBrowserHost.shared.paths.log.deletingLastPathComponent()
            .appending(path: "sign-ins.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").last { $0.contains("tasks share the default profile") }.map(String.init) ?? ""
        check("earlier profiles: the default profile's cookies go to the Trash before it changes, the moved task's folder goes "
              + "there whole, and the log says how many moved",
              !backups.isEmpty && setAside.count == 1 && !profiles.folderExists(keyY)
                && logged.contains("task profiles moved to it, their folders to the Trash (\(setAside.first?.lastPathComponent ?? "?"))")
                && logged.contains("sites it had no cookie of"),
              "backups \(backups.map(\.lastPathComponent)), set aside \(setAside.map(\.lastPathComponent)), log \(logged)")
        for task in [x, y] { client.closeTabs(forSession: task) }
        _ = try? await again.devTools.send("Network.deleteCookies", ["name": .string("qa_earlier"), "domain": .string("only.qa-earlier.test")])
        again.close()
        return (x, y)
    }

    /// The person's click on an element of the page, through the host's input as the panel sends it.
    private func personClick(_ tab: BrowserTab, _ selector: String) async {
        let rect = await value(tab, "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); "
                               + "return [r.left + r.width / 2, r.top + r.height / 2]; })()")
        guard let point = rect?.arrayValue, point.count == 2, let x = point[0].doubleValue, let y = point[1].doubleValue else {
            return check("the page shows \(selector)", false, "not found")
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

    /// A task's tab in a profile of its own, as its agent's first sign-in makes one: the tab opens in the default
    /// profile, the task takes its profile, and the tab opens again there at the same page.
    private func ownTab(_ session: UUID, _ url: String) async -> BrowserTab? {
        guard let first = await taskTab(session, url) else { return nil }
        guard MacBrowserHost.shared.takeOwnProfile(for: session, site: "localhost", how: "QA") else { return first }
        return await reopened(session, from: first, url)
    }

    /// The tab that took `first`'s place in its task, once it is at `url`.
    private func reopened(_ session: UUID, from first: BrowserTab, _ url: String) async -> BrowserTab? {
        let ready = await waitUntil(.seconds(20)) {
            guard let tab = self.client.tab(forSession: session) else { return false }
            return tab !== first && tab.currentURL == url && !tab.isLoading
        }
        return ready ? client.tab(forSession: session) : nil
    }

    /// The refs of a snapshot's elements of `role`, in order.
    private static func refs(in snapshot: String, role: String) -> [String] {
        snapshot.split(separator: "\n").filter { $0.contains("- \(role)") }.compactMap { line in
            line.range(of: #"\[ref=(@e\d+)\]"#, options: .regularExpression).map { String(line[$0].dropFirst(5).dropLast()) }
        }
    }

    private func taskTab(_ session: UUID, _ url: String) async -> BrowserTab? {
        guard let tab = try? client.openTab(forSession: session, url: url, viewport: .offscreenDefault), await loaded(tab, url) else {
            check("a task's tab loads (\(session.uuidString.prefix(8)))", false, "not loaded")
            return nil
        }
        return tab
    }

    /// Waits for the page: a new task profile's tab first takes its starting cookies on about:blank.
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
