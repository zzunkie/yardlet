import AppKit
import Darwin
import Foundation
import IOSurface
import YardletSurfacePort

/// Where the browser keeps its data. Everything Chromium writes stays under
/// `~/Library/Application Support/Yardlet/Browser`: the shared profile in `Default`, tasks' own profiles
/// in `Task-<key>` (`BrowserTaskProfiles`), Chromium's own per-user files (it also writes outside its
/// cache paths) in `Home`, and logs in `Logs`.
struct BrowserHostPaths: Sendable {
    let root: URL
    var profile: URL { root.appending(path: "Default", directoryHint: .isDirectory) }
    var home: URL { root.appending(path: "Home", directoryHint: .isDirectory) }
    var log: URL { root.appending(path: "Logs/host.log") }
    let downloads: URL

    static func standard(fileManager: FileManager = .default) -> BrowserHostPaths {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Downloads")
        return BrowserHostPaths(
            root: support.appending(path: "\(YardletProduct.applicationSupportDirectoryName)/Browser", directoryHint: .isDirectory),
            downloads: downloads
        )
    }
}

/// macOS transport for the browser host contract: the CEF host runs as
/// `Yardlet.app/Contents/Frameworks/Yardlet Browser Host.app`, commands go to its standard input and
/// events come back on its standard output (length-prefixed JSON), and painted frames arrive as
/// IOSurfaces over a Mach port checked in under a per-launch bootstrap name.
@MainActor
final class CEFBrowserHostProcess: BrowserHostConnection {
    nonisolated static var executableURL: URL {
        Bundle.main.bundleURL.appending(
            path: "Contents/Frameworks/Yardlet Browser Host.app/Contents/MacOS/Yardlet Browser Host"
        )
    }

    /// True in bundles built with CEF; plain `swift run` builds use the WebKit preview instead.
    nonisolated static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false))
    }

    var eventHandler: ((BrowserHostEvent) -> Void)?
    private(set) var processIdentifier: Int32 = 0
    /// Surface messages refused because they came from another process or carried a wrong token.
    var rejectedSurfaceMessages: Int { surfaces.rejectedMessages }
    /// Which panel shows each tab's page frames (`MacBrowserHost.showFrames(of:in:)`).
    let frameRouter = BrowserFrameRouter()

    private let process = Process()
    private let input: FileHandle
    private let token: [UInt8]
    private let portName: String
    private let surfaces: BrowserSurfaceReceiver
    private var didTerminate = false
    /// Signaled once the host has exited, for `waitUntilExit(timeout:)`.
    private let exited = DispatchSemaphore(value: 0)

    init(paths: BrowserHostPaths) throws {
        // Unguessable, and distinct per app, process and launch, so an installed Yardlet and a
        // QA copy never share a name.
        var generator = SystemRandomNumberGenerator()
        token = (0..<Int(YardletSurfaceTokenLength)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        let bundle = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier
        portName = "\(bundle).browser-host.\(getpid()).\(nonce)"
        var port: mach_port_t = 0
        let checkIn = yardlet_surface_port_check_in(portName, &port)
        guard checkIn == KERN_SUCCESS else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Mach bootstrap check-in failed (\(checkIn))"
            ])
        }
        surfaces = BrowserSurfaceReceiver(port: port, token: token)

        let fileManager = FileManager.default
        for directory in [paths.profile, paths.home, paths.log.deletingLastPathComponent()] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let commands = Pipe()
        let events = Pipe()
        input = commands.fileHandleForWriting
        // A host that died must surface as an error, not a SIGPIPE that ends Yardlet.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = Self.executableURL
        let korean = Locale.preferredLanguages.first?.hasPrefix("ko") == true
        process.arguments = [
            "--root-cache", paths.root.path(percentEncoded: false),
            "--profile", paths.profile.path(percentEncoded: false),
            "--downloads", paths.downloads.path(percentEncoded: false),
            "--locale", korean ? "ko" : "en-US",
            "--accept-languages", korean ? "ko-KR,ko,en-US,en" : "en-US,en,ko"
        ]
#if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-browser-check=") }) {
            let directory = String(argument.dropFirst("--ui-fixture-browser-check=".count))
            process.arguments! += ["--accessibility-record", directory + "/accessibility-raw"]
        }
        // A QA run fills the browser with a few tabs (`many-tabs`).
        if let limit = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-browser-limit=") }) {
            process.arguments! += ["--browser-limit", String(limit.dropFirst("--ui-fixture-browser-limit=".count))]
        }
#endif
        var environment = ProcessInfo.processInfo.environment
        environment["YARDLET_BROWSER_HOST_PORT"] = portName
        environment["YARDLET_BROWSER_HOST_TOKEN"] = token.map { String(format: "%02x", $0) }.joined()
        // Chromium writes some per-user files outside its cache paths (CEF/User Data, Google/RLZ);
        // a home of its own keeps them inside Yardlet's folder.
        environment["CFFIXED_USER_HOME"] = paths.home.path(percentEncoded: false)
        process.environment = environment
        process.standardInput = commands
        process.standardOutput = events
        process.standardError = Self.logHandle(at: paths.log) ?? FileHandle.nullDevice
        // Framing and JSON decoding run on the pipe's own serial queue (a large page's accessibility
        // tree is megabytes), and so do page frames: each new surface is taken off the Mach port
        // and a shown tab's frame goes into its panel's layer right there. The main thread gets
        // the decoded events in order, with frames already on screen merged per tab.
        let eventDecoder = EventDecoder()
        let surfaces = surfaces
        let router = frameRouter
        let mainThreadEvents = BrowserMainThreadEvents { [weak self] events in self?.receive(events) }
        events.fileHandleForReading.readChunks { [weak self] data in
            do {
                let events = try eventDecoder.decode(data)
                for event in events {
                    switch event {
                    case .frame(let tab, let frame):
                        // Taken off the port shown or not: a tab no panel shows (the agent's) must
                        // not leave the host's surface messages queued.
                        guard let surface = surfaces.surface(for: frame, tab: tab), frame.layer == .view else { continue }
                        router.route(frame, surface: surface, of: tab)
                    case .hidden(let tab), .closed(let tab):
                        // The host released the tab's rings; the frames written before this are in.
                        surfaces.evict(tab: tab)
                        router.forgetLatestFrame(of: tab)
                    case .popup(let tab, nil):
                        surfaces.evict(tab: tab, layer: .popup)
                    default:
                        break
                    }
                }
                mainThreadEvents.enqueue(events)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.process.terminate() } }
            }
        }
        let exited = exited
        process.terminationHandler = { [weak self] process in
            let reason = process.terminationReason == .uncaughtSignal
                ? "signal \(process.terminationStatus)"
                : "exit status \(process.terminationStatus)"
            exited.signal()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hostExited(reason: reason) } }
        }
        do {
            try process.run()
        } catch {
            surfaces.close()
            throw error
        }
        processIdentifier = process.processIdentifier
        surfaces.setHostProcessID(processIdentifier)
    }

    /// One log across launches, restarted when it passes 4 MB.
    private static func logHandle(at url: URL) -> FileHandle? {
        let path = url.path(percentEncoded: false)
        let fileManager = FileManager.default
        if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size > 4_000_000 {
            try? fileManager.removeItem(atPath: path)
        }
        if !fileManager.fileExists(atPath: path) { fileManager.createFile(atPath: path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

#if DEBUG
    /// For the QA fixture's forged-sender check only.
    var portNameForQA: String? { portName }
    var tokenForQA: [UInt8] { token }
#endif

    func send(_ command: BrowserHostCommand) {
        guard !didTerminate, let data = try? BrowserHostFraming.frame(command) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            process.terminate()
        }
    }

    /// SIGKILL: SIGTERM is the host's orderly shutdown (its main.swift), as `shutdown` is.
    func terminate() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func waitUntilExit(timeout: Duration) -> Bool {
        guard process.isRunning else { return true }
        let (seconds, attoseconds) = timeout.components
        return exited.wait(timeout: .now() + Double(seconds) + Double(attoseconds) / 1e18) == .success
    }

    /// Kills the host without a chance to clean up (QA crash drill).
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    /// The IOSurface for a frame token (see `BrowserSurfaceReceiver`).
    nonisolated func surface(for token: UInt64) -> IOSurfaceRef? {
        surfaces.surface(for: token)
    }

    /// Surfaces the host paints into right now, for QA.
    nonisolated var cachedSurfaceCount: Int { surfaces.count }

    private func receive(_ events: [BrowserHostEvent]) {
        for event in events { eventHandler?(event) }
    }

    /// Used only on the event pipe's readability queue, which runs one handler at a time.
    private final class EventDecoder: @unchecked Sendable {
        private var reader = BrowserHostFrameReader()
        private let decoder = JSONDecoder()

        func decode(_ data: Data) throws -> [BrowserHostEvent] {
            try reader.append(data).compactMap { try? decoder.decode(BrowserHostEvent.self, from: $0) }
        }
    }

    private func hostExited(reason: String) {
        guard !didTerminate else { return }
        didTerminate = true
        frameRouter.removeAll()
        surfaces.close()
        try? input.close()
        eventHandler?(.terminated(reason: reason))
    }
}

/// Other apps' addresses through LaunchServices: the app this Mac opens the address with, by the name Finder
/// shows, as Chrome names it in "Open ‹app›?" (none when that app is Yardlet itself, as Chrome does nothing
/// when it is the default). A QA run opens nothing.
@MainActor
final class LaunchServicesApps: BrowserExternalApps {
    func appName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else { return nil }
        let name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func open(_ url: URL) {
        guard !QABackground.isOn else {
            NSLog("Yardlet QA: not opening another app for %@:", url.scheme ?? "?")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// The app's one browser host client (see `BrowserHostClient` for the lifetime rules). The agent's
/// browser tools reach tabs through `client`: `openTab(forSession:url:viewport:)`,
/// `tab(forSession:)`, and `noteAgentActivity(forSession:)` on every action.
@MainActor
final class MacBrowserHost: NativeSurfaceResource {
    static let shared = MacBrowserHost()

    nonisolated static var isAvailable: Bool { CEFBrowserHostProcess.isAvailable }

    private(set) lazy var client: BrowserHostClient = {
        let client = BrowserHostClient(idleGrace: Self.idleGrace, agentVisibleWindow: Self.agentVisibleWindow) { [unowned self] in
            try self.launchProcess()
        }
        // The rail's Preview card follows the tab the agent drives in each task's turn.
        client.onAgentActivity = { session, tab in BrowserAgentUse.shared.noteUse(session: session, tab: tab) }
        client.onTabClosed = { tab in BrowserAgentUse.shared.tabClosed(tab) }
        client.profileForSession = { [unowned self] in self.profiles.profile(for: $0) }
        client.openingProfileForSession = { [unowned self] in self.profiles.opening(for: $0) }
        client.onTabsMoved = { [unowned self] in self.profiles.tabsMoved(from: $0, to: $1) }
        client.onHostEnded = { [unowned self] in self.removeUnusedProfiles() }
        client.externalApps = LaunchServicesApps()
        client.addressHistory = addressHistory
        client.onChromiumWindowsChange = { [unowned self] in self.chromiumWindows.present() }
        client.carriesFilledValue = { MacAgentToolService.shared.broker.carriesVaultValue($0) }
        followMemorySaver(client)
        return client
    }()
    /// macOS's critical memory pressure, which brings the memory saver's next discard forward.
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var memorySaverObserver: (any NSObjectProtocol)?

    /// The memory saver (`BrowserMemorySaver`): on and at the level the setting says, and told when memory turns critical.
    private func followMemorySaver(_ client: BrowserHostClient) {
        client.isMemoryCritical = { MacConditionReader.memoryPressure() == .critical }
#if DEBUG
        // QA runs shorten Chrome's times: `--ui-fixture-browser-memory-saver=<seconds>` for the level's time, the urgent
        // protection and the agent's unseen tabs.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-browser-memory-saver=") }),
           let seconds = Double(argument.dropFirst("--ui-fixture-browser-memory-saver=".count)) {
            let time = Duration.milliseconds(Int(seconds * 1000))
            client.memorySaverTiming = BrowserMemorySaver.Timing(
                hiddenBeforeDiscard: time, urgentInterval: .seconds(1), urgentProtection: time, unseenAgentTabIdle: time,
                sweepInterval: .seconds(1), retryAfter: .seconds(2))
        }
#endif
        client.memorySaverLevel = MemorySaverPreference.level()
        client.isMemorySaverOn = MemorySaverPreference.isOn()
        // Any defaults written on any thread post this; it is passed on to the main thread without
        // holding the writer, which a main thread waiting for it would never let go.
        memorySaverObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak client] _ in
            guard let client else { return }
            Task { @MainActor in
                client.memorySaverLevel = MemorySaverPreference.level()
                client.isMemorySaverOn = MemorySaverPreference.isOn()
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler { [weak client] in MainActor.assumeIsolated { client?.memoryBecameCritical() } }
        source.resume()
        memoryPressureSource = source
    }
    /// Where Chromium's own windows show: over the panel that shows their tab.
    private(set) lazy var chromiumWindows: ChromiumWindowPresenter = {
        let presenter = ChromiumWindowPresenter()
        presenter.windows = { [unowned self] in self.client.chromiumWindows }
        presenter.send = { [weak self] in self?.process?.send($0) }
        presenter.hostProcessID = { [weak self] in self?.process?.processIdentifier }
        return presenter
    }()
    /// Which profile each task's tabs use (docs/BROWSER_SESSION_ISOLATION.md). The agents' password manager fills
    /// from before tasks followed the person's sign-ins are their tasks' own sign-ins (section 11).
    private(set) lazy var profiles: BrowserTaskProfiles = {
        let profiles = BrowserTaskProfiles(root: paths.root)
        profiles.adoptEarlierAgentFills { MacAgentToolService.shared.vault.agentFills() }
        return profiles
    }()
    /// The sign-ins made in tasks' tabs, which tasks follow or keep (docs/BROWSER_SESSION_ISOLATION.md 11), each
    /// written in `Logs/sign-ins.log` beside the host's log.
    private(set) lazy var loginFollow: BrowserLoginFollow = {
        let log = BrowserSignInLog(file: paths.log.deletingLastPathComponent().appending(path: "sign-ins.log"))
        let follow = BrowserLoginFollow(client: client, profiles: profiles, log: log)
        follow.start()
        return follow
    }()
    /// Every task's visits, for the address field's suggestions (docs/BROWSER_HOST.md, "Address suggestions").
    private(set) lazy var addressHistory = BrowserAddressHistory(file: paths.root.appending(path: "AddressHistory.json"))
    /// The address field's requests for suggested searches, spaced for all panels as for a Chrome profile (a QA run
    /// puts a fake Google's in its place).
    var searchSuggest = BrowserSearchSuggestService()
    /// The tasks whose profiles stay, once the app knows them (nil before the saved tasks are loaded).
    var keptTasks: (@MainActor () -> Set<UUID>?)?

    /// Removes the profiles of archived and deleted tasks, while the host (which holds them open) is not running.
    func removeUnusedProfiles() {
        guard !client.isHostRunning, let kept = keptTasks?() else { return }
        profiles.removeFolders(keeping: kept)
    }
    private(set) weak var process: CEFBrowserHostProcess?
    let paths = BrowserHostPaths.standard()
    private let notifications = LocalSystemNotificationCenter()

    private init() {
        NativeSurfaceResourceRegistry.shared.register(self)
    }

    private static var agentVisibleWindow: Duration {
#if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-browser-agent-visible=") }),
           let seconds = Double(argument.dropFirst("--ui-fixture-browser-agent-visible=".count)) {
            return .milliseconds(Int(seconds * 1000))
        }
#endif
        return .seconds(60)
    }

    private static var idleGrace: Duration {
#if DEBUG
        // QA fixtures may shorten the product's 60-second grace to keep runs short.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-browser-grace=") }),
           let seconds = Double(argument.dropFirst("--ui-fixture-browser-grace=".count)) {
            return .milliseconds(Int(seconds * 1000))
        }
#endif
        return .seconds(60)
    }

    private func launchProcess() throws -> CEFBrowserHostProcess {
        // Before the host opens the profiles' cookie databases; never from a test process.
        if NSClassFromString("XCTestCase") == nil {
            BrowserCookieCopyRepair.runOnce(root: paths.root, trash: BrowserCookieCopyRepair.trash)
        }
        let process = try CEFBrowserHostProcess(paths: paths)
        self.process = process
        // Follows the sign-ins of the tabs this host opens.
        _ = loginFollow
        return process
    }

    func surface(for token: UInt64) -> IOSurfaceRef? {
        process?.surface(for: token)
    }

    /// Sends the tab's page frames straight to the display, off the main thread, until
    /// `stopShowingFrames(of:in:)`.
    func showFrames(of tab: BrowserTabID, in display: BrowserFrameDisplay) {
        process?.frameRouter.set(display, for: tab)
    }

    func stopShowingFrames(of tab: BrowserTabID, in display: BrowserFrameDisplay) {
        process?.frameRouter.remove(display, for: tab)
    }

    /// A panel shows the tab, or stops: Chromium's windows over the tab show over that panel (`ChromiumWindowPresenter`).
    func panelShows(_ tab: BrowserTabID, in view: BrowserHostView) {
        chromiumWindows.panelShows(tab, in: view)
    }

    func panelStopsShowing(_ tab: BrowserTabID, in view: BrowserHostView) {
        chromiumWindows.panelStopsShowing(tab, in: view)
    }

    /// Also sends the tab's page frames to a small preview (the rail's Preview card), off the main
    /// thread like the panel's, and puts the tab's latest frame there now. The preview never shows the
    /// tab to its engine: it draws the frames the tab paints anyway while the agent uses it.
    func showPreviewFrames(of tab: BrowserTabID, in display: BrowserFrameDisplay) {
        guard let router = process?.frameRouter else { return }
        router.setPreview(display, for: tab)
        if let (frame, surface) = router.latestFrame(of: tab) { display.show(frame, surface: surface) }
    }

    func stopShowingPreviewFrames(of tab: BrowserTabID, in display: BrowserFrameDisplay) {
        process?.frameRouter.removePreview(display, for: tab)
    }

    /// Announces a finished download the way Safari does (the Downloads stack bounces) and, when
    /// the person allowed Yardlet's notifications, with a notification.
    func downloadFinished(_ download: BrowserDownload) {
        guard download.state == .completed else { return }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: download.path
        )
        Task { @MainActor in
            guard await notifications.authorization().isDeliverable else { return }
            await notifications.post(
                title: L10n.string("Download finished"),
                body: download.fileName,
                identifier: "yardlet-download-\(download.id)-\(download.path.hashValue)"
            )
        }
    }

    func stop() {}

    func terminateForApplicationShutdown() {
        client.terminateHost()
        addressHistory.saveBeforeQuitting()
    }
}
