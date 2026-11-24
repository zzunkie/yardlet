import AppKit
import SwiftUI
import YardletSimulatorHostProtocol

/// What a task's Simulator tab needs from the app: the devices and who uses them (`SimulatorCenter`), their
/// screens (`MacSimulatorScreens`), and other tasks' titles for the devices they use. Nil where no Simulator tab
/// shows (a side chat, another task's conversation in a panel).
struct SimulatorPanelServices {
    let center: SimulatorCenter
    let screens: MacSimulatorScreens
    /// A task's title, while it is neither archived nor gone.
    let taskTitle: @MainActor (UUID) -> String?
    /// The devices the person let agents use, which the device menu takes back; nil offers no such item.
    var approvals: SimulatorApprovals? = nil
    /// What Install gets for a missing part; nil offers no Install.
    var installs: SimulatorInstalls? = nil
    /// Opens a store page (Xcode's, in the App Store).
    var openURL: @MainActor (URL) -> Void = { _ in }
    /// The devices agents handed to the person (`simulator_handoff`), whose bar the tab shows above the device.
    var handoffs: SimulatorHandoffs? = nil
}

private struct SimulatorPanelKey: EnvironmentKey {
    static let defaultValue: SimulatorPanelServices? = nil
}

extension EnvironmentValues {
    var simulatorPanel: SimulatorPanelServices? {
        get { self[SimulatorPanelKey.self] }
        set { self[SimulatorPanelKey.self] = newValue }
    }
}

/// One of a task's Simulator tabs: the device attached in it, live, with its platform's buttons and the device menu;
/// the list of iOS simulators and Android emulators to pick one from while none is attached; or what is missing to use
/// them on this Mac.
///
/// Picking a device attaches it in the tab, claims its input for the task when no task has it, and starts it when it
/// is off, with progress while it boots. A task can have several Simulator tabs, each with its own device, and several
/// tasks' tabs can show the same device; the others offer "Use in This Task" to take its input. Closing the tab lets
/// go of its device; hiding the panel keeps it.
struct SimulatorPane: View {
    let task: UUID
    /// The tab's key (`TaskSurfaceNavigationProjection.simulatorTabID`).
    let tab: UUID
    let workspaceURL: URL
    let services: SimulatorPanelServices
    /// The device attached in the tab, which the task's workspace keeps (`TaskWorkspaceState.simulators`).
    let attached: SimulatorDeviceIdentity?
    let onClose: () -> Void
    /// The devices were read since the tab appeared: until then an empty list is not taken for no devices.
    @State private var hasListed = false

    private var center: SimulatorCenter { services.center }
    private var screens: MacSimulatorScreens { services.screens }
    private var device: SimulatorDevice? { attached.flatMap(center.device) }
    /// The platforms whose devices this Mac can list and run.
    private var listing: [SimulatorPlatform] {
        SimulatorPlatform.allCases.filter { center.checks[$0]?.availability.listsDevices == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: device?.name ?? L10n.string("Simulator"),
                systemName: SimulatorTabSymbol.name(for: device?.platform),
                workspaceURL: workspaceURL,
                onClose: onClose
            ) {
                if let device, center.state(of: device.identity) == .on, screens.link(of: device.identity).isAttached {
                    platformButtons(device)
                }
                if device != nil { deviceMenu }
            }
            if let handoffs = services.handoffs, let handoff = handoffs.waiting(for: task), handoff.device == attached {
                // As `browser_handoff`'s bar over a tab.
                BrowserHandoffBar(title: L10n.string("The agent handed this device to you"), reason: handoff.reason,
                                  decline: { handoffs.answer(.declined, for: task) },
                                  done: { handoffs.answer(.done, for: task) })
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ParityTheme.canvas)
        .onAppear {
            center.panelAppeared(for: task, tab: tab)
            Task {
                await center.refreshChecks()
                await center.refreshDevices()
                hasListed = true
            }
        }
        .onDisappear { center.panelDisappeared(for: task, tab: tab) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !center.isEnabled || center.checks.isEmpty || (center.devices.isEmpty && !hasListed) {
            ProgressView().controlSize(.small)
        } else if let attached, let check = center.checks[attached.kind.platform], !check.availability.listsDevices {
            attachedUnavailable(attached.kind.platform, check)
        } else if let device {
            deviceContent(device)
        } else if listing.isEmpty {
            SimulatorUnavailableView(checks: center.checks, installs: services.installs, openURL: services.openURL)
        } else {
            SimulatorDeviceList(task: task, entries: center.entries(for: task, tab: tab), platforms: listing,
                                taskTitle: services.taskTitle, pick: pick)
        }
    }

    /// The attached device's platform can't run here: a saved tab whose Xcode or Android SDK is gone says only that;
    /// otherwise, what is missing and what the person does about it, with Install where Yardlet can get it.
    @ViewBuilder
    private func attachedUnavailable(_ platform: SimulatorPlatform, _ check: SimulatorPlatformCheck) -> some View {
        if check.availability == .xcodeMissing || check.availability == .sdkMissing {
            WorkSurfaceEmptyState(title: check.availability == .xcodeMissing ? L10n.string("Xcode can't be found.")
                                      : L10n.string("The Android SDK can't be found."),
                                  systemName: "iphone.slash") {
                Button(L10n.string("Close"), action: onClose).controlSize(.small)
            }
        } else {
            SimulatorUnavailableView(checks: [platform: check], installs: services.installs, openURL: services.openURL)
        }
    }

    @ViewBuilder
    private func deviceContent(_ device: SimulatorDevice) -> some View {
        switch center.state(of: device.identity) {
        case .booting:
            progress(L10n.format("Starting %@…", device.name))
        case .shuttingDown:
            progress(L10n.format("Shutting down %@…", device.name))
        case .off:
            WorkSurfaceEmptyState(title: L10n.string("This simulator is off."), systemName: "iphone") {
                Button(L10n.string("Turn On")) { pick(device.identity) }.controlSize(.small)
            }
        case .on:
            if device.platform == .iOS, let check = center.checks[.iOS], case .xcodeNotSupportedYet = check.availability {
                SimulatorUnavailableView(checks: [.iOS: check])
            } else if let toolchain = center.toolchain(for: device.platform) {
                liveScreen(device, toolchain: toolchain)
            }
        }
    }

    private func liveScreen(_ device: SimulatorDevice, toolchain: SimulatorToolchain) -> some View {
        let link = screens.link(of: device.identity)
        return ZStack {
            SimulatorScreenRepresentable(
                screens: screens,
                configuration: .init(device: device.identity, adbSerial: device.adbSerial, toolchain: toolchain),
                link: link,
                onPersonInput: { center.notePersonInput(on: device.identity) },
                onCloseTab: onClose)
            switch link {
            case .attaching, nil:
                ProgressView().controlSize(.small)
            case let .failed(failure):
                let title = device.identity.kind.isPhysical ? L10n.string("The device's screen can't be shown.")
                    : L10n.string("The simulator's screen can't be shown.")
                WorkSurfaceEmptyState(title: title, message: failure.message, systemName: "iphone.slash") {
                    if failure.canTryAgain {
                        Button(L10n.string("Try Again")) { screens.retry(device.identity) }.controlSize(.small)
                    }
                }
                .background(ParityTheme.canvas)
            case .attached:
                EmptyView()
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// An iOS simulator's Home button; an Android device's Back, Home and Recents, in the order of its navigation bar.
    @ViewBuilder
    private func platformButtons(_ device: SimulatorDevice) -> some View {
        switch device.platform {
        case .iOS:
            ParityIconButton(systemName: "house", help: L10n.string("Home (⇧⌘H)")) {
                center.notePersonInput(on: device.identity)
                screens.press(.home, on: device.identity)
            }
        case .android:
            ForEach(AndroidNavigationButton.allCases, id: \.self) { button in
                ParityIconButton(systemName: Self.symbol(of: button), help: Self.help(of: button)) {
                    center.notePersonInput(on: device.identity)
                    screens.pressNavigation(button, on: device.identity)
                }
            }
        }
    }

    /// Android's own navigation glyphs: a triangle, a circle and a square.
    static func symbol(of button: AndroidNavigationButton) -> String {
        switch button {
        case .back: "arrowtriangle.backward"
        case .home: "circle"
        case .recents: "square"
        }
    }

    static func help(of button: AndroidNavigationButton) -> String {
        switch button {
        case .back: L10n.string("Back")
        case .home: L10n.string("Home (⇧⌘H)")
        case .recents: L10n.string("Recents")
        }
    }

    // MARK: - Actions

    private func pick(_ identity: SimulatorDeviceIdentity) {
        Task { _ = await center.attach(identity, to: task, tab: tab, by: .person) }
    }

    // MARK: - Device menu

    private var deviceMenu: some View {
        let menu = SimulatorDeviceMenu.make(for: task, tab: tab, in: center, taskTitle: services.taskTitle,
                                            approvals: services.approvals)
        return Menu {
            Menu(L10n.string("Switch Device")) {
                Picker(L10n.string("Switch Device"), selection: Binding(
                    get: { attached },
                    set: { identity in if let identity, identity != attached { pick(identity) } })) {
                    ForEach(menu.devices, id: \.device.identity) { entry in
                        Text(SimulatorDeviceList.menuTitle(entry)).tag(Optional(entry.device.identity))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                menuItem(item)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityLabel(L10n.string("Device"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("Device"))
        .help(L10n.string("Device"))
    }

    @ViewBuilder
    private func menuItem(_ item: SimulatorDeviceMenu.Item) -> some View {
        switch item {
        case let .useInThisTask(heldBy):
            Text(L10n.format("Used by “%@”", heldBy))
            Button(L10n.string("Use in This Task")) { center.claim(for: task, tab: tab) }
        case .disconnect:
            Button(L10n.string("Disconnect")) { center.detach(task, tab: tab) }
        case .revokeAgentAccess:
            Button(L10n.string("Revoke Agent Access")) {
                guard let attached else { return }
                services.approvals?.revoke(attached)
            }
        case .shutDown:
            Button(L10n.string("Shut Down")) {
                guard let attached else { return }
                Task { await center.stopStartedDevice(attached) }
            }
        case .startedByYardletNote:
            Text(L10n.string("Yardlet started this simulator and shuts it down when no task uses it."))
        }
    }
}

/// What a missing part says in the Simulator tab, and what the person does about it.
struct SimulatorUnavailableText: Equatable {
    var title: String
    var message: String?

    init(_ availability: SimulatorAvailability) {
        switch availability {
        case .xcodeMissing:
            title = L10n.string("Xcode isn't installed.")
            message = L10n.string("Install Xcode from the App Store to use iOS simulators here.")
        case .xcodeNotSetUp:
            title = L10n.string("Xcode isn't set up yet.")
            message = L10n.string("Open Xcode once and finish its setup, which asks for an administrator password, then come back.")
        case .runtimeMissing:
            title = L10n.string("No iOS simulator runtime.")
            message = L10n.string("Add an iOS runtime in Xcode › Settings › Components.")
        case let .xcodeNotSupportedYet(version):
            title = L10n.string("This Xcode isn't supported yet.")
            message = version.map { L10n.format("Yardlet can't show simulator screens with Xcode %@ yet.", $0) }
                ?? L10n.string("Yardlet can't show simulator screens with this Xcode yet.")
        case .sdkMissing:
            title = L10n.string("No Android SDK.")
            message = L10n.string("Install Android Studio and create a virtual device in its Device Manager to use Android emulators here.")
        case .available:
            // An available platform shows its devices.
            title = ""
            message = nil
        }
    }
}

/// What is missing for each platform the tab can't list devices of, one under the other.
/// What each platform that can't run here lacks and what the person does about it, one under the other, with Install
/// under each where Yardlet can get it. Once Install is pressed, that platform's install (`SimulatorMissingPart`) has
/// the tab to itself until it ends or is cancelled.
struct SimulatorUnavailableView: View {
    /// What the check found for each platform.
    let checks: [SimulatorPlatform: SimulatorPlatformCheck]
    var installs: SimulatorInstalls? = nil
    var openURL: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        let missing = SimulatorPlatform.allCases.filter { checks[$0].map { $0.availability != .available } ?? false }
        if let installs, let platform = missing.first(where: { SimulatorMissingPart.isUnderWay(installs.state(of: $0)) }),
           let check = checks[platform] {
            SimulatorMissingPart(platform: platform, check: check, installs: installs, openURL: openURL)
        } else if let first = missing.first, let check = checks[first] {
            let text = SimulatorUnavailableText(check.availability)
            WorkSurfaceEmptyState(title: text.title, message: text.message, systemName: "iphone.slash") {
                installButton(first)
                ForEach(missing.dropFirst(), id: \.self) { platform in
                    if let check = checks[platform] {
                        let text = SimulatorUnavailableText(check.availability)
                        VStack(spacing: 9) {
                            Text(text.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                            if let message = text.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: 420)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            installButton(platform)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func installButton(_ platform: SimulatorPlatform) -> some View {
        if let installs, let check = checks[platform] {
            SimulatorInstallButton(platform: platform, check: check, installs: installs, openURL: openURL)
        }
    }
}

/// The devices to pick from: those that are on first, then iOS simulators by runtime, then Android emulators by API
/// level. A device another task uses says which.
struct SimulatorDeviceList: View {
    let task: UUID
    let entries: [SimulatorListEntry]
    /// The platforms whose devices are listed, which an empty list says how to add.
    var platforms: [SimulatorPlatform] = [.iOS]
    let taskTitle: @MainActor (UUID) -> String?
    let pick: (SimulatorDeviceIdentity) -> Void

    var body: some View {
        if entries.isEmpty {
            WorkSurfaceEmptyState(title: L10n.string("No simulators"),
                                  message: platforms.map(Self.howToAdd).joined(separator: "\n"),
                                  systemName: "iphone")
        } else {
            ScrollView {
                // A Mac's simulators are dozens at most.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.sections(entries), id: \.title) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(section.entries, id: \.device.identity) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ entry: SimulatorListEntry) -> some View {
        Button { pick(entry.device.identity) } label: {
            HStack(spacing: 10) {
                Image(systemName: SimulatorTabSymbol.name(for: entry.device.platform)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.device.name).foregroundStyle(.primary)
                    if let detail = detail(entry) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                if entry.device.state == .booting || entry.device.state == .shuttingDown {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel([entry.device.name, detail(entry)].compactMap(\.self).joined(separator: ", "))
    }

    /// The line under a device: its runtime among the devices that are on, and the task that uses it.
    private func detail(_ entry: SimulatorListEntry) -> String? {
        var parts: [String] = []
        if entry.device.state.isRunning { parts.append(entry.device.osName) }
        if let holder = entry.claimingTask, holder != task {
            parts.append(L10n.format("Used by “%@”", taskTitle(holder) ?? L10n.string("Another task")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func howToAdd(_ platform: SimulatorPlatform) -> String {
        switch platform {
        case .iOS: L10n.string("Add a simulator in Xcode › Window › Devices and Simulators.")
        case .android: L10n.string("Create a virtual device in Android Studio › Device Manager.")
        }
    }

    /// A device in the device menu: its name, with its runtime.
    static func menuTitle(_ entry: SimulatorListEntry) -> String {
        entry.device.osName.isEmpty ? entry.device.name : "\(entry.device.name) (\(entry.device.osName))"
    }

    struct Section {
        var title: String
        var entries: [SimulatorListEntry]
    }

    /// Devices that are on, then each runtime's devices, in the center's order.
    static func sections(_ entries: [SimulatorListEntry]) -> [Section] {
        let running = entries.filter { $0.device.state.isRunning }
        var runtimes: [Section] = []
        for entry in entries where !entry.device.state.isRunning {
            if let index = runtimes.firstIndex(where: { $0.title == entry.device.osName }) {
                runtimes[index].entries.append(entry)
            } else {
                runtimes.append(Section(title: entry.device.osName, entries: [entry]))
            }
        }
        return (running.isEmpty ? [] : [Section(title: L10n.string("Running"), entries: running)]) + runtimes
    }
}

private extension Optional where Wrapped == MacSimulatorScreens.Link {
    var isAttached: Bool {
        if case .attached = self { return true }
        return false
    }
}

/// The device's live screen in SwiftUI.
struct SimulatorScreenRepresentable: NSViewRepresentable {
    let screens: MacSimulatorScreens
    let configuration: SimulatorScreenView.Configuration
    /// Read so the view follows the screen's size as the helper reports it.
    let link: MacSimulatorScreens.Link?
    let onPersonInput: () -> Void
    let onCloseTab: () -> Void

    func makeNSView(context: Context) -> SimulatorScreenView {
        let view = SimulatorScreenView(screens: screens)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SimulatorScreenView, context: Context) {
        view.onPersonInput = onPersonInput
        view.onCloseTab = onCloseTab
        view.configuration = configuration
        view.screenDidChange()
    }

    static func dismantleNSView(_ view: SimulatorScreenView, coordinator: ()) {
        view.stopFrames()
        view.configuration = nil
    }
}
