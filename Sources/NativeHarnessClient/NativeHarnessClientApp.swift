import AppKit
import SwiftUI

private struct YardletSettingsPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct YardletCommandPalettePresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct YardletImportPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct YardletRefreshFromOtherAppsKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

private struct YardletOtherAppImportPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var yardletCommandPalettePresented: Binding<Bool>? {
        get { self[YardletCommandPalettePresentedKey.self] }
        set { self[YardletCommandPalettePresentedKey.self] = newValue }
    }
    var yardletImportPresented: Binding<Bool>? {
        get { self[YardletImportPresentedKey.self] }
        set { self[YardletImportPresentedKey.self] = newValue }
    }
    var yardletOtherAppImportPresented: Binding<Bool>? {
        get { self[YardletOtherAppImportPresentedKey.self] }
        set { self[YardletOtherAppImportPresentedKey.self] = newValue }
    }

    /// File › Refresh from the Claude App and Codex; nil while a pass runs.
    var yardletRefreshFromOtherApps: (@MainActor () -> Void)? {
        get { self[YardletRefreshFromOtherAppsKey.self] }
        set { self[YardletRefreshFromOtherAppsKey.self] = newValue }
    }
    var yardletSettingsPresented: Binding<Bool>? {
        get { self[YardletSettingsPresentedKey.self] }
        set { self[YardletSettingsPresentedKey.self] = newValue }
    }
}

private struct YardletSettingsCommands: Commands {
    @FocusedBinding(\.yardletSettingsPresented) private var isPresentingSettings
    @FocusedBinding(\.yardletCommandPalettePresented) private var isPresentingCommandPalette
    @FocusedBinding(\.yardletImportPresented) private var isPresentingImport
    @FocusedBinding(\.yardletOtherAppImportPresented) private var isPresentingOtherAppImport
    @FocusedValue(\.yardletRefreshFromOtherApps) private var refreshFromOtherApps

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.string("Settings…")) {
                isPresentingSettings = true
            }
            .keyboardShortcut(YardletAppShortcut.settings)
            .disabled(isPresentingSettings == nil)
        }
        CommandGroup(after: .newItem) {
            Button(L10n.string("Search tasks and commands")) {
                isPresentingCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(isPresentingCommandPalette == nil)
            Button(L10n.string("Import conversation…")) {
                isPresentingImport = true
            }
            .disabled(isPresentingImport == nil)
            Button(L10n.string("Import Conversations from Other Apps…")) {
                isPresentingOtherAppImport = true
            }
            .disabled(isPresentingOtherAppImport == nil)
            Button(L10n.string("Refresh from the Claude App and Codex")) {
                refreshFromOtherApps?()
            }
            .disabled(refreshFromOtherApps == nil)
        }
    }
}

private struct YardletInstallUpdateKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    /// Yardlet › Install Update…, for the places in the window that offer it too (the sidebar's
    /// account menu). Nil where there is no app to install into, as in a test's window.
    var yardletInstallUpdate: (@MainActor @Sendable () -> Void)? {
        get { self[YardletInstallUpdateKey.self] }
        set { self[YardletInstallUpdateKey.self] = newValue }
    }
}

private struct YardletUpdateWaitKey: EnvironmentKey {
    static let defaultValue: YardletUpdateWait? = nil
}

private struct YardletSparkleKey: EnvironmentKey {
    static let defaultValue: YardletSparkle? = nil
}

private struct YardletStagedUpdateKey: EnvironmentKey {
    static let defaultValue: YardletStagedUpdate? = nil
}

extension EnvironmentValues {
    /// Sparkle in a public build, for the account menu's Check for Updates… and Settings' switch.
    /// Nil in a development build and where there is no app, as in a test's window.
    var yardletSparkle: YardletSparkle? {
        get { self[YardletSparkleKey.self] }
        set { self[YardletSparkleKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// An update waiting for tasks to finish, which the account menu shows and cancels as the app
    /// menu does. Nil where there is no app to install into.
    var yardletUpdateWait: YardletUpdateWait? {
        get { self[YardletUpdateWaitKey.self] }
        set { self[YardletUpdateWaitKey.self] = newValue }
    }

    /// A staged build ready to install, for the sidebar's "Restart to update". Nil where there is no
    /// app to install into.
    var yardletStagedUpdate: YardletStagedUpdate? {
        get { self[YardletStagedUpdateKey.self] }
        set { self[YardletStagedUpdateKey.self] = newValue }
    }
}

/// Yardlet > Install Update…: installs a build staged by `scripts/stage-update.sh` and restarts,
/// now or once tasks finish. A build that updates with Sparkle has Check for Updates… there instead.
/// While an update waits for tasks the menu says so and offers Cancel Update.
private struct YardletUpdateCommands: Commands {
    let appDelegate: NativeHarnessClientAppDelegate
    let updateWait: YardletUpdateWait

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            ForEach(YardletUpdateMenu.items(isWaiting: updateWait.isWaiting,
                                            checksForUpdates: appDelegate.sparkle != nil), id: \.self) { item in
                Button(item.title) {
                    switch item {
                    case .install: appDelegate.offerStagedUpdate()
                    case .checkForUpdates: appDelegate.sparkle?.checkForUpdates()
                    case .cancelWaiting: updateWait.cancel()
                    case .waiting: break
                    }
                }
                .disabled(!item.isEnabled || item == .checkForUpdates && appDelegate.sparkle?.canCheckForUpdates != true)
                .help(item.help ?? "")
            }
        }
    }
}

@MainActor
final class NativeHarnessClientAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet { openPendingLinks() }
    }
    /// Links and HTML files opened with Yardlet before the window's model was ready, as when a link launched it.
    private var pendingLinks: [URL] = []
    let workActivity = RunningWorkActivity()
    /// The network path, for turns a lost connection cut off (`AppModel.networkPathChanged`).
    let networkWatch = NetworkWatch()
    /// Yardlet's menu bar item, made once the app model is ready.
    var menuBar: MenuBarStatusItem?
    /// A staged build the person chose to install. The installer starts only once quitting is
    /// confirmed, so cancelling the quit leaves the installed app as it is.
    private var updateToInstall: YardletUpdater.Candidate?
    /// Install Update… › Restart When Tasks Finish, waiting for no task to run.
    let updateWait = YardletUpdateWait()
    /// A staged build ready to install, shown in the sidebar and the menu bar menu. It looks only in a
    /// build without Sparkle (started with the window).
    let stagedUpdate = YardletStagedUpdate()
    /// The quit was started by that wait, which never stops a task: a task running when it comes
    /// cancels the quit and the wait goes on.
    private var quitIsForWaitedUpdate = false
    /// Sparkle in a public build; nil in a development build, which keeps Install Update….
    let sparkle = YardletSparkle()
    /// The next quit is the one Sparkle asks for after Install and Relaunch. With tasks running it
    /// waits for them instead of offering to stop them.
    private var quitIsForSparkleRelaunch = false
    /// Sparkle's installer waits for Yardlet to exit to install the update and open it again, from
    /// Install and Relaunch until its update session ends, whichever quit comes.
    private var sparkleRelaunchIsPending = false
    /// Test seam for the destructive termination decision. Production leaves this nil and uses
    /// the native warning alert below; tests can exercise Cancel/Quit without presenting a modal.
    var terminationPrompt: (([SessionRecord]) -> Bool)?
    private var isShuttingDown = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs are the window's own task tabs (`SplitStore.tabs`); macOS's window tabs would add a
        // second kind (View › Show Tab Bar, Window › Merge All Windows) whose tabs all show the
        // same task, since every Yardlet window shows the one selection.
        NSWindow.allowsAutomaticWindowTabbing = false
        // A button's name (`.help`) shows once the pointer rests on it for as long as the Codex app waits for its
        // tooltips, 200 ms, not AppKit's 1.5 s, which read as no name at all (2026-10-27). Registered, so a delay
        // the person set for their Mac still wins and nothing is saved.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let sparkle {
            sparkle.willRelaunch = { [weak self] in self?.sparkleWillRelaunch() }
            sparkle.updateCycleEnded = { [weak self] in self?.sparkleUpdateEnded() }
            sparkle.start()
        }
        // QA runs launched with `open -g` must not take focus from the person using the Mac, nor show them
        // a window to click.
        if QABackground.isOn { return QABackground.start() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A link or an HTML file another app opened with Yardlet, the person's default browser (`AppModel.openExternalLinks`).
    /// An open main window takes them, so SwiftUI opens no window for them (`handlesExternalEvents(preferring:allowing:)`).
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingLinks += urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
        openPendingLinks()
    }

    private func openPendingLinks() {
        guard let model, !pendingLinks.isEmpty else { return }
        let links = pendingLinks
        pendingLinks = []
        model.openExternalLinks(links, elsewhere: OutsideBrowser.open)
        // As Chrome shows the window it opens a link in: out of the Dock, or opened again once closed. Bringing Yardlet
        // in front is Launch Services' part, as the app that opened the link asked, and brings a hidden Yardlet back with
        // its windows; a window already showing is left as it is, so the window the person types in keeps the keyboard.
        guard !QABackground.isOn, !NSApp.isHidden else { return }
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }
        guard !windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return }
        if let window = windows.first(where: \.isMiniaturized) {
            window.deminiaturize(nil)
        } else {
            TaskResourceUsageWindow.reopenMainWindow?()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.composerDrafts.persistNow()
        model?.taskWorkspaces.persistNow()
        model?.splits.persistNow()
        // Keep the native-surface boundary intact even when AppKit terminates without running
        // the asynchronous confirmed-Quit reply path (for example, a normal system shutdown).
        NativeSurfaceResourceRegistry.shared.stopAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            startUpdateInstallerIfChosen()
            return .terminateNow
        }

        if isShuttingDown { return .terminateLater }
        // A visual fixture's running tasks are only pictures: quitting it, or logging out, never asks.
        let activeSessions = model.usesVisualFixture ? [] : model.activeLocalSessions
        let isForWaitedUpdate = quitIsForWaitedUpdate
        let isForSparkleRelaunch = quitIsForSparkleRelaunch
        quitIsForWaitedUpdate = false
        quitIsForSparkleRelaunch = false
        if !activeSessions.isEmpty {
            // The update waits for tasks to finish and never stops one: a task that started after
            // the wait last looked cancels this quit, and the wait goes on.
            if isForWaitedUpdate {
                updateToInstall = nil
                updateWait.keepWaiting()
                return .terminateCancel
            }
            // Sparkle's installer waits for Yardlet to exit, so refusing its quit costs nothing:
            // Yardlet waits for the tasks and then quits on its own.
            if isForSparkleRelaunch {
                waitForTasks(then: .sparkle)
                return .terminateCancel
            }
            let shouldTerminate = terminationPrompt?(activeSessions) ?? {
                QuitConfirmation(active: activeSessions, continuing: model.tasksContinuingAfterRestart(),
                                 enabledSchedules: model.scheduledTasks.enabledCount)
                    .alert().runModal() == .alertFirstButtonReturn
            }()
            guard shouldTerminate else {
                updateToInstall = nil
                return .terminateCancel
            }
        }

        isShuttingDown = true
        // Before anything stops: which turns this quit cuts off, for the next launch to continue.
        model.recordWorkForRestart(trigger: updateToInstall == nil && !sparkleRelaunchIsPending ? .quit : .update)
        Task { @MainActor in
            NativeSurfaceResourceRegistry.shared.stopAll()
            await model.remoteControl?.shutdown()
            await model.shutdown()
            startUpdateInstallerIfChosen()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func offerStagedUpdate() {
        Task { @MainActor in
            let installed = Bundle.main.bundleURL
            let identifier = Bundle.main.bundleIdentifier
            let result = await Task.detached(priority: .userInitiated) {
                Result<YardletUpdater.Candidate, Error> {
                    let candidate = try YardletUpdater.pending(bundleIdentifier: identifier, installedBundle: installed)
                    try YardletUpdater.verifySignature(of: candidate.bundleURL, replacing: installed)
                    return candidate
                }
            }.value
            let alert: NSAlert
            let candidate: YardletUpdater.Candidate?
            // Asked as the alert opens: a task that started or ended since still counts right.
            let hasRunningTasks = !(model?.activeLocalSessions.isEmpty ?? true)
            switch result {
            case let .failure(error):
                alert = NSAlert()
                alert.messageText = L10n.string("No update to install")
                alert.informativeText = error.localizedDescription
                candidate = nil
            case let .success(value):
                let date = value.builtAt?.formatted(date: .abbreviated, time: .shortened) ?? "-"
                alert = YardletUpdateOffer.alert(build: value.build ?? "-", date: date, hasRunningTasks: hasRunningTasks)
                candidate = value
            }
            // A sheet on the main window stays in front of the task it concerns; a free-standing
            // alert can open behind other apps' windows.
            if !QABackground.isOn { NSApp.activate(ignoringOtherApps: true) }
            let response: NSApplication.ModalResponse
            if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard let candidate else { return }
            switch YardletUpdateOffer.choice(for: response, hasRunningTasks: hasRunningTasks) {
            case .installNow:
                updateToInstall = candidate
                quitToInstall()
            case .waitForTasks:
                waitForTasks(then: .staged(candidate))
            case .cancel:
                return
            }
        }
    }

    /// The staged build's line in the sidebar and the menu bar menu.
    var stagedUpdateLine: MenuBarMenu.UpdateLine? {
        MenuBarMenu.UpdateLine(ready: stagedUpdate.ready, isWaiting: updateWait.isWaiting)
    }

    private func waitForTasks(then update: YardletUpdateWait.Update) {
        updateWait.start(update, activeTasks: { [weak self] in self?.model?.activeLocalSessions.count ?? 0 },
                         install: { [weak self] chosen in await self?.installWaitedUpdate(chosen) ?? .stop })
    }

    /// Sparkle is about to ask Yardlet to quit, to install its update and open it again.
    func sparkleWillRelaunch() {
        quitIsForSparkleRelaunch = true
        sparkleRelaunchIsPending = true
    }

    /// Sparkle's update session ended without Yardlet quitting for it, as when the installer failed.
    private func sparkleUpdateEnded() {
        quitIsForSparkleRelaunch = false
        sparkleRelaunchIsPending = false
        if updateWait.update == .sparkle { updateWait.cancel() }
    }

    /// The wait found no task running: installs the update, a staged build only if it is still the
    /// one staged.
    private func installWaitedUpdate(_ chosen: YardletUpdateWait.Update) async -> YardletUpdateWait.Outcome {
        guard case let .staged(chosen) = chosen else { return quitForWaitedUpdate(.sparkle) }
        let installed = Bundle.main.bundleURL
        let identifier = Bundle.main.bundleIdentifier
        let staged = await Task.detached(priority: .userInitiated) { () -> YardletUpdater.Candidate? in
            guard let candidate = try? YardletUpdater.pending(bundleIdentifier: identifier, installedBundle: installed),
                  (try? YardletUpdater.verifySignature(of: candidate.bundleURL, replacing: installed)) != nil else { return nil }
            return candidate
        }.value
        guard YardletUpdateWaitPolicy.isStillChosen(chosen, staged: staged) else {
            NSLog("Yardlet stopped waiting to update: the staged build is no longer the one chosen")
            return .stop
        }
        return quitForWaitedUpdate(.staged(chosen))
    }

    /// Quits to install `chosen` if no task runs now; otherwise the wait goes on. Sparkle's
    /// installer, already waiting, installs its update once Yardlet has exited.
    func quitForWaitedUpdate(_ chosen: YardletUpdateWait.Update) -> YardletUpdateWait.Outcome {
        guard model?.activeLocalSessions.isEmpty ?? true else { return .keepWaiting }
        if case let .staged(candidate) = chosen { updateToInstall = candidate }
        quitIsForWaitedUpdate = true
        quitToInstall()
        return .quitting
    }

    /// Asks AppKit to quit. Quitting waits in a nested run loop for `model.shutdown()`, which runs
    /// on the main queue. Called from a main-queue block (a task, or `DispatchQueue.main.async`),
    /// the queue cannot drain until that block returns, so nothing ever answers. A run-loop timer
    /// calls it outside the main queue, the way choosing Quit from the menu does. Tests replace it.
    var requestTermination: @MainActor () -> Void = {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private func quitToInstall() {
        requestTermination()
    }

    private func startUpdateInstallerIfChosen() {
        guard updateToInstall != nil else { return }
        updateToInstall = nil
        do {
            try YardletUpdater.launchInstaller(target: Bundle.main.bundleURL, processID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            NSLog("Yardlet update installer could not start: %@", error.localizedDescription)
        }
    }
}

@main
struct NativeHarnessClientApp: App {
    @NSApplicationDelegateAdaptor(NativeHarnessClientAppDelegate.self) private var appDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        // A fixed scene ID keeps SwiftUI's own saved window frame from depending on the root view's type.
        WindowGroup(id: "main") {
            YardletWindowPreferences(usesVisualFixture: model.usesVisualFixture) {
                mainContent
                    .frame(minWidth: 760, minHeight: 560)
                    .background {
                        // Fixture windows take an exact size and must not replace the person's saved frame.
                        if !model.usesVisualFixture { MainWindowFrameAutosave() }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .imageViewerHost()
            }
                // A link another app opens with Yardlet goes to a tab of the window's task (`application(_:open:)`): an
                // open window takes it, where SwiftUI would otherwise open a window for each one. A link that launches
                // Yardlet still gets the first window.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environment(\.yardletInstallUpdate, { [appDelegate] in appDelegate.offerStagedUpdate() })
                .environment(\.yardletUpdateWait, appDelegate.updateWait)
                .environment(\.yardletSparkle, appDelegate.sparkle)
                .environment(\.yardletStagedUpdate, appDelegate.stagedUpdate)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.resourceMonitor.setApplicationActive(true)
                    model.pullRequests.setApplicationActive(true)
                    appDelegate.stagedUpdate.checkNow()
                    // The person may have changed Yardlet's badge setting in System Settings.
                    Task { await model.refreshNotificationPermission() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.resourceMonitor.setApplicationActive(false)
                    model.pullRequests.setApplicationActive(false)
                }
                .task {
                    appDelegate.model = model
                    if !model.usesVisualFixture, appDelegate.workActivity.lidHelper == nil {
                        let lidHelper = LidSleepHelper.live()
                        model.lidSleepHelper = lidHelper
                        appDelegate.workActivity.lidHelper = lidHelper
                    }
                    appDelegate.workActivity.follow(model)
                    if !model.usesVisualFixture, appDelegate.menuBar == nil {
                        appDelegate.menuBar = MenuBarStatusItem.live(
                            model: model, update: { [appDelegate] in appDelegate.stagedUpdateLine },
                            installUpdate: { [appDelegate] in appDelegate.offerStagedUpdate() })
                    }
                    // Sparkle shows its own window for an update; a fixture or QA run never shows the
                    // person's staged build.
                    if !model.usesVisualFixture, !QABackground.isOn, appDelegate.sparkle == nil {
                        appDelegate.stagedUpdate.start()
                    }
                    model.agentTools = MacAgentToolService.shared.broker
                    // The agent's first browser call finds the tabs the task's side panel saved.
                    MacAgentToolService.shared.tabs.prepareSession = { [weak model] id in
                        _ = model?.taskWorkspaces.state(for: id)
                    }
                    MacAgentToolService.shared.broker.suggestions = model
                    MacAgentToolService.shared.broker.sessions = model
                    MacAgentToolService.shared.broker.schedules = model
                    MacAgentToolService.shared.broker.handoffs = model
                    // A browser tab waiting on the person marks its task, tells them once, and waits in its tab.
                    model.followBrowserWaits(of: MacBrowserHost.shared.client)
#if DEBUG
                    BrowserHostQAFixture.model = model
#endif
                    MacAgentToolService.shared.broker.isTaskInTurn = { [weak model] in model?.isInTurn($0) ?? false }
                    if !model.usesVisualFixture {
                        // A finished subagent's conversation is kept with its task in Yardlet's own folder.
                        model.sessionTools.runDirectory = FileManager.default.homeDirectoryForCurrentUser
                            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
                            .appending(path: "agent-runs", directoryHint: .isDirectory)
                    }
                    // A visual fixture may have put its own in place already.
                    if model.connectorCenter == nil { model.connectorCenter = MacAgentToolService.shared.connectors }
                    if !model.usesVisualFixture {
                        // A new task's browser profile starts from its parent's; a task's profile goes with it.
                        MacBrowserHost.shared.profiles.parentOf = { [weak model] id in
                            model?.store.sessions.first(where: { $0.id == id })?.parentTaskID
                        }
                        MacBrowserHost.shared.keptTasks = { [weak model] in
                            guard let model, model.hasRestoredIndex else { return nil }
                            return Set(model.store.sessions.map(\.id))
                        }
                    }
                    MacAgentToolService.shared.vault.describeTask = { [weak model] in model?.vaultTaskDescription($0) }
                    MacAgentToolService.shared.vault.notify = { [weak model] title, body, sessionID in
                        Task { await model?.postVaultNotification(title: title, body: body, sessionID: sessionID) }
                    }
                    // Settings lists each account's own servers, read-only, and offers them for import.
                    MacAgentToolService.shared.connectors.setNativeHomes { [weak model] in
                        NativeMCPHome.all(connections: model?.connections.connections ?? [])
                    }
                    // Yardlet instructions reach every launch from the first restored task on.
                    if !model.usesVisualFixture, model.yardletInstructions == nil {
                        model.yardletInstructions = YardletInstructionsStore.live()
                    }
                    // The routing ledger records from the first restored task on, while its switch is on.
                    if !model.usesVisualFixture, model.routingEvaluation == nil {
                        model.routingEvaluation = RoutingEvaluationStore.live()
                    }
#if DEBUG
                    MacAgentToolService.shared.writeQALaunchIfRequested()
                    MacAgentToolService.shared.runConnectorQAIfRequested()
                    if model.usesVisualFixture {
                        WindowTabsKeyQA.runIfRequested(model: model)
                        ShowcaseFixture.install(in: model)
                    }
#endif
                    // The newest install of each harness the person chose no runtime for, read off
                    // the main thread; only files changed since the last launch run `--version`.
                    Task { await model.runtimeSelections.findNewest() }
                    await model.restoreIndex()
                    if !model.usesVisualFixture {
                        // What the last quit cut off continues alongside the rest of the launch.
                        Task { await model.continueWorkInterruptedByRestart() }
                        // Idle tasks' runtimes end while the memory saver is on, and resume at the next message.
                        model.startHarnessMemorySaver()
                        // And what a lost connection cuts off, once the network is back.
                        appDelegate.networkWatch.start(reporting: model)
                        model.startRoutingEvaluationLoop()
                        model.resourceMonitor.setApplicationActive(NSApp.isActive)
                        model.resourceMonitor.start()
                        model.pullRequests.setApplicationActive(NSApp.isActive)
                        model.startPullRequestLookups()
                        // Scheduled tasks run while Yardlet is open; one missed meanwhile runs once now.
                        model.startScheduledTasks()
                        await model.refreshNotificationPermission()
                        await model.linkTasksStartedInTheClaudeAppOnce()
                        // The Claude app's and Codex's lists, now that the index is loaded.
                        Task { await model.followSessionListsIfDue() }
                        // The phone remote listens only once the person turns it on in Settings.
                        if model.remoteControl == nil {
                            let remote = RemoteControlService.live(model: model)
                            model.remoteControl = remote
                            await remote.start()
                        }
                        // Checks the harness CLIs now and every six hours (Settings › CLI Updates).
                        if model.cliUpdates == nil {
                            let updates = CLIUpdateCenter.live(model: model)
                            model.cliUpdates = updates
                            updates.start()
                        }
                    }
#if DEBUG
                    if model.usesVisualFixture,
                       let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-window=") }) {
                        let parts = argument.dropFirst("--ui-fixture-window=".count).split(separator: "x")
                        if parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                           (760...1800).contains(width), (560...1200).contains(height) {
                            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                                window.setContentSize(NSSize(width: width, height: height))
                                // Wholly on the screen, so a capture of the display holds all of it.
                                window.center()
                            }
                        }
                    }
#endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            YardletSettingsCommands()
            YardletUpdateCommands(appDelegate: appDelegate, updateWait: appDelegate.updateWait)
            YardletTaskCommands()
            YardletWindowLayerCommands()
            YardletTabCommands()
            YardletConversationFindCommands()
            TaskResourceUsageCommands()
        }

        Window(L10n.string("Task Resource Usage"), id: TaskResourceUsageWindow.sceneID) {
            YardletWindowPreferences(usesVisualFixture: model.usesVisualFixture, appliesInterfaceSize: false) {
                TaskResourceUsageWindow(monitor: model.resourceMonitor) { taskID in
                    model.splits.activate(.session(taskID))
                    TaskResourceUsageWindow.bringMainWindowForward()
                }
            }
        }
        .defaultSize(width: 720, height: 360)
        .handlesExternalEvents(matching: [])
        .commandsRemoved()
    }

    @ViewBuilder
    private var mainContent: some View {
#if DEBUG
        if model.usesVisualFixture && CommandLine.arguments.contains("--ui-fixture=inline-output") {
            InlineOutputReadingFixtureView()
        } else if model.usesVisualFixture && CommandLine.arguments.contains("--ui-fixture=codex-reading") {
            CodexReadingFixtureView()
        } else if model.usesVisualFixture && CommandLine.arguments.contains("--ui-fixture=reading") {
            TranscriptReadingFixtureView()
        } else if model.usesVisualFixture && CommandLine.arguments.contains("--ui-fixture=home") {
            NewTaskHomeFixtureView()
        } else {
            MainWindow(model: model)
        }
#else
        MainWindow(model: model)
#endif
    }
}

/// A window's content in the appearance and interface size Settings chose. They are read here, not
/// in the app's scene: `@AppStorage` re-reads on every UserDefaults write, even of another key or of
/// a key that is not there, and a scene holding it was rebuilt, with its windows' roots and the menu
/// bar's commands, whenever Yardlet saved any state there. Here such a write re-applies the same
/// values to the same content, which leaves the content alone.
private struct YardletWindowPreferences<Content: View>: View {
    let usesVisualFixture: Bool
    var appliesInterfaceSize = true
    @ViewBuilder let content: Content
    @AppStorage(YardletPreferenceKeys.appearance) private var appearanceRawValue =
        YardletAppearancePreference.system.rawValue
    @AppStorage(YardletPreferenceKeys.interfaceSize) private var interfaceSizeRawValue =
        YardletInterfaceSizePreference.standard.rawValue

    var body: some View {
        if appliesInterfaceSize {
            content
                .preferredColorScheme(effectiveColorScheme)
                .environment(\.yardletInterfaceScale, effectiveInterfaceSize.scale)
                .dynamicTypeSize(effectiveInterfaceSize.dynamicTypeSize)
        } else {
            content.preferredColorScheme(effectiveColorScheme)
        }
    }

    private var fixtureColorScheme: ColorScheme? {
#if DEBUG
        VisualFixtureAppearance.requested()?.colorScheme
#else
        nil
#endif
    }

    private var effectiveColorScheme: ColorScheme? {
        fixtureColorScheme
            ?? YardletAppearancePreference(rawValue: appearanceRawValue)?.colorScheme
    }

    private var effectiveInterfaceSize: YardletInterfaceSizePreference {
#if DEBUG
        if usesVisualFixture,
           let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-interface-size=") }),
           let size = YardletInterfaceSizePreference(rawValue: String(argument.dropFirst("--ui-fixture-interface-size=".count))) {
            return size
        }
#endif
        guard !usesVisualFixture else { return .standard }
        return YardletInterfaceSizePreference(rawValue: interfaceSizeRawValue) ?? .standard
    }
}
