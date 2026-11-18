import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Simulator tab drawn in an unshown window with fictional devices: the launcher with Simulator after Browser,
/// the device list with a device another task uses, iOS simulators and Android emulators listed together, what each
/// missing part says, both platforms missing at once, a saved tab whose Xcode or Android SDK is gone, a device
/// booting, a device that is off, and a screen the helper could not show, for each reason. Drawn under
/// `.build/simulator-panel/`, in both appearances. The live screen is checked against a real simulator in
/// `SimulatorPanelQATests`.
@MainActor
final class SimulatorPanelRenderingTests: XCTestCase {
    private let size = NSSize(width: 460, height: 760)

    func testTheSimulatorTabDrawsEachOfItsStates() async throws {
        // The window is never on screen; the screen must still ask for frames.
        SimulatorScreenView.ignoresWindowOcclusion = true
        defer { SimulatorScreenView.ignoresWindowOcclusion = false }
        let directory = try WindowlessRender.directory("simulator-panel")
        let language = L10n.string("Simulator") == "시뮬레이터" ? "ko" : "en"
        let (task, other) = (UUID(), UUID())
        let titles = [other: "Build the app"]

        for appearance in WindowlessRender.Appearance.allCases {
            let name = { (state: String) in "\(state)-\(language)-\(appearance.suffix).png" }

            // The launcher: Simulator stands after Browser.
            let launcher = WindowlessRender.Host(
                SidePanelLauncher(workspaceURL: URL(filePath: "/tmp/project"),
                                  choices: TaskSidePanelTabs.choices(canOpenSideChat: true, offersReview: true,
                                                                     offersSimulator: true),
                                  tasks: { [] }, onOpen: { _ in }, onClose: {})
                    .environment(\.colorScheme, appearance.colorScheme),
                size: size, appearance: appearance)
            launcher.settle()
            try WindowlessRender.writePNG(launcher.capture().bitmap, to: directory.appending(path: name("launcher")))
            XCTAssertTrue(launcher.accessibilityElements().map(\.label).contains(L10n.string("Simulator")))
            launcher.close()

            // The list: the device another task uses says so; those that are on come first.
            let backend = PanelFakeBackend()
            let center = SimulatorCenter(backends: [backend])
            await center.setEnabled(true)
            _ = await center.attach(PanelFakeBackend.pro, to: other, by: .agent)
            try await draw(center, task: task, attached: nil, titles: titles, appearance: appearance,
                           to: directory.appending(path: name("list")),
                           showing: [L10n.string("Running"), "iOS 27.2", "iOS 26.4", "iPhone 16"]) { words in
                XCTAssertTrue(words.contains { $0.hasPrefix("iPhone 17 Pro") && $0.contains("Build the app") }, "\(words)")
            }

            // iOS simulators and Android emulators together: Android's after iOS's, by API level.
            let both = SimulatorCenter(backends: [PanelFakeBackend(), PanelFakeAndroidBackend()])
            await both.setEnabled(true)
            try await draw(both, task: task, attached: nil, titles: titles, appearance: appearance,
                           to: directory.appending(path: name("list-android")),
                           showing: ["iOS 26.4", "Android API 35", "Android API 34", "Pixel 9", "Tablet"])

            // Neither platform can run here: what each one needs, one under the other.
            let neither = SimulatorCenter(backends: [PanelFakeBackend(availability: .xcodeMissing),
                                                     PanelFakeAndroidBackend(availability: .sdkMissing)])
            await neither.setEnabled(true)
            let noXcode = SimulatorUnavailableText(.xcodeMissing), noSDK = SimulatorUnavailableText(.sdkMissing)
            try await draw(neither, task: task, attached: nil, titles: titles, appearance: appearance,
                           to: directory.appending(path: name("unavailable-both")),
                           showing: [noXcode.title, noXcode.message ?? "", noSDK.title, noSDK.message ?? ""])

            // A saved tab whose Android SDK is gone says only that, with Close.
            let sdkGone = SimulatorCenter(backends: [PanelFakeBackend(), PanelFakeAndroidBackend(availability: .sdkMissing)])
            await sdkGone.setEnabled(true)
            try await draw(sdkGone, task: task, attached: .androidEmulator(avd: "Pixel_9_API_35"), titles: titles,
                           appearance: appearance, to: directory.appending(path: name("sdk-gone")),
                           showing: [L10n.string("The Android SDK can't be found."), L10n.string("Close")])

            // What each missing part says.
            for availability in [SimulatorAvailability.xcodeMissing, .xcodeNotSetUp, .runtimeMissing] {
                let missing = SimulatorCenter(backends: [PanelFakeBackend(availability: availability)])
                await missing.setEnabled(true)
                let text = SimulatorUnavailableText(availability)
                try await draw(missing, task: task, attached: nil, titles: titles, appearance: appearance,
                               to: directory.appending(path: name("unavailable-\(availability)")),
                               showing: [text.title, text.message ?? ""])
            }
            // A saved tab whose Xcode is gone says only that, with Close.
            let gone = SimulatorCenter(backends: [PanelFakeBackend(availability: .xcodeMissing)])
            await gone.setEnabled(true)
            try await draw(gone, task: task, attached: .iOSSimulator(udid: PanelFakeBackend.phone), titles: titles,
                           appearance: appearance, to: directory.appending(path: name("xcode-gone")),
                           showing: [L10n.string("Xcode can't be found."), L10n.string("Close")])

            // A device the person picked boots, with progress; a device that is off offers to turn it on.
            let booting = PanelFakeBackend(holdsBoot: true)
            let bootingCenter = SimulatorCenter(backends: [booting])
            await bootingCenter.setEnabled(true)
            let phone = SimulatorDeviceIdentity.iOSSimulator(udid: PanelFakeBackend.phone)
            let boot = Task { await bootingCenter.attach(phone, to: task, by: .person) }
            try await waitUntil { bootingCenter.state(of: phone) == .booting }
            try await draw(bootingCenter, task: task, attached: phone, titles: titles, appearance: appearance,
                           to: directory.appending(path: name("booting")),
                           showing: [L10n.format("Starting %@…", "iPhone 17")])
            booting.releaseBoot()
            _ = await boot.value
            try await draw(center, task: task, attached: phone, titles: titles, appearance: appearance,
                           to: directory.appending(path: name("off")),
                           showing: [L10n.string("This simulator is off."), L10n.string("Turn On")])

            // An Xcode the helper does not support yet: the device lists and runs, and its screen says why.
            let unsupported = SimulatorCenter(backends: [PanelFakeBackend()])
            await unsupported.setEnabled(true)
            _ = await unsupported.attach(PanelFakeBackend.pro, to: task, by: .person)
            unsupported.markNotSupportedYet(SimulatorToolchain(directory: "/Applications/Xcode.app/Contents/Developer",
                                                               version: "27.2"))
            try await draw(unsupported, task: task, attached: .iOSSimulator(udid: PanelFakeBackend.pro), titles: titles,
                           appearance: appearance, to: directory.appending(path: name("not-supported")),
                           showing: [L10n.string("This Xcode isn't supported yet."),
                                     L10n.format("Yardlet can't show simulator screens with Xcode %@ yet.", "27.2")])

            // A device that is on, whose screen the helper could not show: why in the person's words, never the
            // system's error, with Try Again where trying again can help. A helper that ends at once (here `false`)
            // stopped; one that is not there at all is missing.
            let failing = SimulatorCenter(backends: [PanelFakeBackend()])
            await failing.setEnabled(true)
            _ = await failing.attach(PanelFakeBackend.pro, to: task, by: .person)
            for (helper, failure) in [("/usr/bin/false", SimulatorScreenFailure.helperEnded),
                                      ("/nonexistent/Yardlet Simulator Host", .helperMissing)] {
                try await draw(failing, task: task, attached: .iOSSimulator(udid: PanelFakeBackend.pro), titles: titles,
                               appearance: appearance, helper: helper,
                               to: directory.appending(path: name("screen-\(failure)")),
                               showing: [L10n.string("The simulator's screen can't be shown."), failure.message,
                                         "iPhone 17 Pro"] + (failure.canTryAgain ? [L10n.string("Try Again")] : [])) { words in
                    XCTAssertFalse(words.contains { $0.contains("No such file") || $0.contains("파일 또는 디렉토리") },
                                   "\(words)")
                }
            }
        }

        // Each way the helper fails reads as one of the panel's own reasons.
        let missing = URL(filePath: "/nonexistent/Yardlet Simulator Host")
        XCTAssertEqual(SimulatorScreenFailure(POSIXError(.ENOENT), executable: missing), .helperMissing)
        XCTAssertEqual(SimulatorScreenFailure(POSIXError(.EPERM), executable: URL(filePath: "/usr/bin/false")),
                       .helperDidNotStart)
        let present = URL(filePath: "/usr/bin/false")
        XCTAssertEqual(SimulatorScreenFailure(SimulatorHostClient.Failure.helperEnded("signal 9"), executable: missing),
                       .helperMissing)
        XCTAssertEqual(SimulatorScreenFailure(SimulatorHostClient.Failure.helperEnded("signal 9"), executable: present),
                       .helperEnded)
        XCTAssertEqual(SimulatorScreenFailure(SimulatorHostClient.Failure.device("not booted"), executable: present),
                       .deviceRefused)
    }

    /// The Simulator tab of `task` in the side panel's strip, beside a Files tab, with the + menu's choices, drawn
    /// once it reads out every text of `showing`.
    private func draw(_ center: SimulatorCenter, task: UUID, attached: SimulatorDeviceIdentity?,
                      titles: [UUID: String], appearance: WindowlessRender.Appearance,
                      helper: String = "/nonexistent/Yardlet Simulator Host", to url: URL,
                      showing expected: [String], check: ([String]) -> Void = { _ in }) async throws {
        let screens = MacSimulatorScreens()
        screens.executable = URL(filePath: helper)
        let services = SimulatorPanelServices(center: center, screens: screens, taskTitle: { titles[$0] })
        let tab = TaskSidePanelTabs.simulatorTab(device: attached.flatMap(center.device))
        let files = try XCTUnwrap(TaskSidePanelTabs.tab("files", selectedFilePath: nil))
        let navigation = WorkSurfaceNavigation(
            tabs: [files, tab], activeID: tab.id,
            choices: TaskSidePanelTabs.choices(canOpenSideChat: true, offersSimulator: true),
            select: { _ in }, open: { _ in }, closeTab: { _ in }, closePanel: {})
        let host = WindowlessRender.Host(
            SimulatorPane(task: task, workspaceURL: URL(filePath: "/tmp/project"), services: services,
                          attached: attached, onClose: {})
                .environment(\.workSurfaceNavigation, navigation)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height),
            size: size, appearance: appearance)
        defer {
            host.close()
            screens.endAll()
        }
        // What the tab reads out: buttons' and rows' labels, and texts' values.
        let words = { host.accessibilityElements().flatMap { [$0.label, $0.value] }.filter { !$0.isEmpty } }
        await host.settle(until: { Set(expected.filter { !$0.isEmpty }).isSubset(of: words()) })
        host.settle(passes: 6)
        try WindowlessRender.writePNG(host.capture().bitmap, to: url)
        let missing = expected.filter { !$0.isEmpty && !words().contains($0) }
        XCTAssertEqual(missing, [], "\(url.lastPathComponent) reads out \(words())")
        check(words())
    }
}

/// Fictional Android emulators, none of them running, with the check's answer chosen by the test.
private struct PanelFakeAndroidBackend: SimulatorBackend {
    var availability = SimulatorAvailability.available
    var platform: SimulatorPlatform { .android }

    func check() async -> SimulatorPlatformCheck {
        SimulatorPlatformCheck(availability: availability, toolchain: availability.listsDevices
            ? SimulatorToolchain(directory: "/Users/test/Library/Android/sdk") : nil)
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] {
        [("Pixel_9_API_35", "Pixel 9", "35"), ("Pixel_6_API_34", "Pixel 6", "34"), ("Tablet_API_34", "Tablet", "34")]
            .map { avd, name, api in
                SimulatorDevice(identity: .androidEmulator(avd: avd), name: name, state: .off,
                                osName: "Android API \(api)", osVersion: api)
            }
    }

    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart { .started }
    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {}
    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {}
    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? { nil }
}

/// Fictional iOS simulators, with the check's answer chosen by the test. A boot can be held until the test lets it
/// finish.
private final class PanelFakeBackend: SimulatorBackend, @unchecked Sendable {
    static let pro = "6F1D7E9A-0000-4000-8000-000000000001"
    static let phone = "6F1D7E9A-0000-4000-8000-000000000002"
    static let air = "6F1D7E9A-0000-4000-8000-000000000003"
    static let pad = "6F1D7E9A-0000-4000-8000-000000000004"
    static let older = "6F1D7E9A-0000-4000-8000-000000000005"

    let platform = SimulatorPlatform.iOS
    private let availability: SimulatorAvailability
    private let holdsBoot: Bool
    private let lock = NSLock()
    private var states: [String: SimulatorDeviceState] = [pro: .on, phone: .off, air: .off, pad: .off, older: .off]
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    init(availability: SimulatorAvailability = .available, holdsBoot: Bool = false) {
        self.availability = availability
        self.holdsBoot = holdsBoot
    }

    func check() async -> SimulatorPlatformCheck {
        SimulatorPlatformCheck(availability: availability,
                               toolchain: availability.listsDevices
                                   ? SimulatorToolchain(directory: "/Applications/Xcode.app/Contents/Developer",
                                                        version: "27.2") : nil)
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] {
        let states = lock.withLock { self.states }
        let device = { (udid: String, name: String, version: String) in
            SimulatorDevice(identity: .iOSSimulator(udid: udid), name: name, state: states[udid] ?? .off,
                            osName: "iOS \(version)", osVersion: version)
        }
        return [device(Self.pro, "iPhone 17 Pro", "27.2"), device(Self.phone, "iPhone 17", "27.2"),
                device(Self.air, "iPhone Air", "27.2"), device(Self.pad, "iPad Pro 13-inch (M5)", "27.2"),
                device(Self.older, "iPhone 16", "26.4")]
    }

    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart {
        .started
    }

    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        guard holdsBoot else { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if released { return true }
                waiting = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    /// The held boot finishes, leaving the device off as if it shut down again: the tab offers to turn it on.
    func releaseBoot() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        lock.withLock { states[device.identity.value] = .off }
    }

    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? {
        nil
    }
}
