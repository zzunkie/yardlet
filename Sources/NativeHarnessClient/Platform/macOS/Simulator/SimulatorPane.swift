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

/// A task's Simulator tab: the device the task attached, live, with its Home button and device menu; the list of
/// devices to pick one from while none is attached; or what is missing to use simulators on this Mac.
///
/// Picking a device attaches it to the task, claims its input when no task has it, and starts it when it is off,
/// with progress while it boots. Several tasks' tabs can show the same device; the others offer "Use in This Task"
/// to take its input. Closing the tab keeps the attachment, as hiding the panel does.
struct SimulatorPane: View {
    let task: UUID
    let workspaceURL: URL
    let services: SimulatorPanelServices
    /// The device the task attached, which its workspace keeps (`TaskWorkspaceState.simulator`).
    let attached: SimulatorDeviceIdentity?
    let onClose: () -> Void
    /// The devices were read since the tab appeared: until then an empty list is not taken for no devices.
    @State private var hasListed = false

    private var center: SimulatorCenter { services.center }
    private var screens: MacSimulatorScreens { services.screens }
    private var check: SimulatorPlatformCheck? { center.checks[.iOS] }
    private var device: SimulatorDevice? { attached.flatMap(center.device) }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: device?.name ?? L10n.string("Simulator"),
                systemName: SimulatorTabSymbol.name(for: device?.platform),
                workspaceURL: workspaceURL,
                onClose: onClose
            ) {
                if let device, center.state(of: device.identity) == .on, device.platform == .iOS,
                   let udid = UUID(uuidString: device.identity.value), screens.link(of: udid).isAttached {
                    ParityIconButton(systemName: "house", help: L10n.string("Home (⇧⌘H)")) {
                        center.notePersonInput(on: device.identity)
                        screens.press(.home, on: udid)
                    }
                }
                if device != nil { deviceMenu }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ParityTheme.canvas)
        .onAppear {
            center.panelAppeared(for: task)
            Task {
                await center.refreshChecks()
                await center.refreshDevices()
                hasListed = true
            }
        }
        .onDisappear { center.panelDisappeared(for: task) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !center.isEnabled || check == nil || (center.devices.isEmpty && !hasListed) {
            ProgressView().controlSize(.small)
        } else if let check, !check.availability.listsDevices {
            unavailable(check.availability)
        } else if let device {
            deviceContent(device)
        } else {
            SimulatorDeviceList(task: task, entries: center.entries(for: task).filter { $0.device.platform == .iOS },
                                taskTitle: services.taskTitle, pick: pick)
        }
    }

    /// What is missing to use iOS simulators, and what the person does about it. A saved tab whose Xcode is gone says
    /// only that.
    @ViewBuilder
    private func unavailable(_ availability: SimulatorAvailability) -> some View {
        if attached != nil, availability == .xcodeMissing {
            WorkSurfaceEmptyState(title: L10n.string("Xcode can't be found."), systemName: "iphone.slash") {
                Button(L10n.string("Close"), action: onClose).controlSize(.small)
            }
        } else {
            let text = SimulatorUnavailableText(availability)
            WorkSurfaceEmptyState(title: text.title, message: text.message, systemName: "iphone.slash")
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
            if case let .xcodeNotSupportedYet(version) = check?.availability {
                let text = SimulatorUnavailableText(.xcodeNotSupportedYet(xcodeVersion: version))
                WorkSurfaceEmptyState(title: text.title, message: text.message, systemName: "iphone.slash")
            } else if let udid = UUID(uuidString: device.identity.value), let toolchain = center.toolchain(for: .iOS) {
                liveScreen(device, udid: udid, toolchain: toolchain)
            }
        }
    }

    private func liveScreen(_ device: SimulatorDevice, udid: UUID, toolchain: SimulatorToolchain) -> some View {
        let link = screens.link(of: udid)
        return ZStack {
            SimulatorScreenRepresentable(
                screens: screens, configuration: .init(device: udid, toolchain: toolchain), link: link,
                onPersonInput: { center.notePersonInput(on: device.identity) },
                onCloseTab: onClose)
            switch link {
            case .attaching, nil:
                ProgressView().controlSize(.small)
            case let .failed(message):
                WorkSurfaceEmptyState(title: L10n.string("The simulator's screen can't be shown."), message: message,
                                      systemName: "iphone.slash") {
                    Button(L10n.string("Try Again")) { screens.retry(udid) }.controlSize(.small)
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

    // MARK: - Actions

    private func pick(_ identity: SimulatorDeviceIdentity) {
        Task { _ = await center.attach(identity, to: task, by: .person) }
    }

    // MARK: - Device menu

    private var deviceMenu: some View {
        let menu = SimulatorDeviceMenu.make(for: task, in: center, taskTitle: services.taskTitle)
        return Menu {
            Menu(L10n.string("Switch Device")) {
                Picker(L10n.string("Switch Device"), selection: Binding(
                    get: { attached },
                    set: { identity in if let identity, identity != attached { pick(identity) } })) {
                    ForEach(menu.devices.filter { $0.device.platform == .iOS }, id: \.device.identity) { entry in
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
            Button(L10n.string("Use in This Task")) { center.claim(for: task) }
        case .disconnect:
            Button(L10n.string("Disconnect")) { center.detach(task) }
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
            message = L10n.string("Open Xcode once and finish its setup, then come back.")
        case .runtimeMissing:
            title = L10n.string("No iOS simulator runtime.")
            message = L10n.string("Add an iOS runtime in Xcode › Settings › Components.")
        case let .xcodeNotSupportedYet(version):
            title = L10n.string("This Xcode isn't supported yet.")
            message = version.map { L10n.format("Yardlet can't show simulator screens with Xcode %@ yet.", $0) }
                ?? L10n.string("Yardlet can't show simulator screens with this Xcode yet.")
        case .sdkMissing, .available:
            // Android's devices are not in the panel yet; an available platform shows its devices.
            title = ""
            message = nil
        }
    }
}

/// The devices to pick from: those that are on first, then iOS simulators by runtime. A device another task uses
/// says which.
struct SimulatorDeviceList: View {
    let task: UUID
    let entries: [SimulatorListEntry]
    let taskTitle: @MainActor (UUID) -> String?
    let pick: (SimulatorDeviceIdentity) -> Void

    var body: some View {
        if entries.isEmpty {
            WorkSurfaceEmptyState(title: L10n.string("No simulators"),
                                  message: L10n.string("Add a simulator in Xcode › Window › Devices and Simulators."),
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
