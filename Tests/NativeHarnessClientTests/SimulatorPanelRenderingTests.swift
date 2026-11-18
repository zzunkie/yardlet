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

            // Neither platform can run here: what each one needs, one under the other, each with its Install.
            let neither = SimulatorCenter(backends: [PanelFakeBackend(availability: .xcodeMissing),
                                                     PanelFakeAndroidBackend(availability: .sdkMissing)])
            await neither.setEnabled(true)
            let noXcode = SimulatorUnavailableText(.xcodeMissing), noSDK = SimulatorUnavailableText(.sdkMissing)
            let installs = SimulatorInstalls(installers: [
                RenderInstaller(offer: .openStore(MacIOSRuntimeInstaller.appStoreURL)),
                RenderInstaller(offer: .download(name: "Android SDK", bytes: nil, licenses: []), platform: .android),
            ])
            try await draw(neither, task: task, attached: nil, titles: titles, appearance: appearance, installs: installs,
                           to: directory.appending(path: name("unavailable-both")),
                           showing: [noXcode.title, noXcode.message ?? "", L10n.string("Open App Store"),
                                     noSDK.title, noSDK.message ?? "", L10n.string("Install")])

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

    func testInstallShowsWhatItGetsHowLargeAndHowFar() async throws {
        let directory = try WindowlessRender.directory("simulator-panel")
        let language = L10n.string("Simulator") == "시뮬레이터" ? "ko" : "en"
        let task = UUID()
        let size = Int64(8_321_588_736)
        let sized = SimulatorMissingPart.size(size)
        for appearance in WindowlessRender.Appearance.allCases {
            let name = { (state: String) in "install-\(state)-\(language)-\(appearance.suffix).png" }
            let draw = { (availability: SimulatorAvailability, installer: RenderInstaller, state: String,
                          showing: [String]) async throws in
                let center = SimulatorCenter(backends: [PanelFakeBackend(availability: availability)])
                await center.setEnabled(true)
                let installs = SimulatorInstalls(installers: [installer])
                try await installer.drive(installs, check: center.checks[.iOS]!)
                try await self.draw(center, task: task, attached: nil, titles: [:], appearance: appearance,
                                    installs: installs, to: directory.appending(path: name(state)), showing: showing)
                installs.cancelAll()
            }
            let runtime = SimulatorInstallOffer.download(name: "iOS 27.2 Simulator Runtime", bytes: size, licenses: [])
            // What is missing, with Install; without Xcode, Open App Store; Xcode's setup is the person's.
            try await draw(.runtimeMissing, RenderInstaller(offer: runtime), "missing",
                           [L10n.string("No iOS simulator runtime."), L10n.string("Install")])
            try await draw(.xcodeMissing, RenderInstaller(offer: .openStore(MacIOSRuntimeInstaller.appStoreURL)),
                           "xcode-missing", [L10n.string("Xcode isn't installed."), L10n.string("Open App Store")])
            try await draw(.xcodeNotSetUp, RenderInstaller(offer: runtime), "xcode-not-set-up",
                           [L10n.string("Open Xcode once and finish its setup, which asks for an administrator password, then come back.")])
            // Install shows the size first; only Download starts it.
            try await draw(.runtimeMissing, RenderInstaller(offer: runtime, stage: .offered), "offered",
                           [L10n.format("Install %@?", "iOS 27.2 Simulator Runtime"),
                            L10n.format("Downloads %@ from %@.", sized, "Apple"), L10n.string("Download"),
                            L10n.string("Cancel")])
            try await draw(.runtimeMissing, RenderInstaller(offer: runtime, stage: .installing(0.42)), "downloading",
                           [L10n.format("Downloading %@…", "iOS 27.2 Simulator Runtime"), L10n.string("Cancel")])
            try await draw(.runtimeMissing, RenderInstaller(offer: runtime, stage: .failed), "failed",
                           [L10n.string("The install didn't finish."), "iOS 27.2 is not available for download.",
                            L10n.string("Try Again")])

            // Android's offer: the size from Google and the licenses to accept, in full.
            let android = SimulatorInstallOffer.download(
                name: L10n.string("Android SDK and emulator"), bytes: 2_319_245_000,
                licenses: [SimulatorLicense(id: "android-sdk-license",
                                            text: "Terms and Conditions\n\nThis is the Android Software Development Kit License Agreement.")])
            // Once Install is pressed, that platform's install has the tab, the other's missing part waiting.
            let installer = RenderInstaller(offer: android, stage: .offered, platform: .android)
            let installs = SimulatorInstalls(installers: [
                RenderInstaller(offer: .openStore(MacIOSRuntimeInstaller.appStoreURL)), installer,
            ])
            let neither = SimulatorCenter(backends: [PanelFakeBackend(availability: .xcodeMissing),
                                                     PanelFakeAndroidBackend(availability: .sdkMissing)])
            await neither.setEnabled(true)
            try await installer.drive(installs, check: XCTUnwrap(neither.checks[.android]))
            try await self.draw(neither, task: task, attached: nil, titles: [:], appearance: appearance,
                                installs: installs, to: directory.appending(path: name("android-license")),
                                showing: [L10n.format("Install %@?", L10n.string("Android SDK and emulator")),
                                          L10n.string("Accept and Download"), L10n.string("License")]) { words in
                XCTAssertFalse(words.contains(L10n.string("Open App Store")), "\(words)")
            }
            installs.cancelAll()
        }
    }

    func testTheRemovalQuestionListsWhatYardletInstalled() throws {
        let directory = try WindowlessRender.directory("simulator-panel")
        let language = L10n.string("Simulator") == "시뮬레이터" ? "ko" : "en"
        let question = SimulatorRemovalQuestion(items: [
            .iOSRuntime(identifier: "C27103BD", name: "iOS 27.2 Simulator Runtime", bytes: 8_321_588_736),
            .androidPackage(sdkRoot: "/Users/me/Library/Android/sdk", path: "emulator", revision: "37.2.13",
                            name: "Android Emulator", bytes: 416_113_219),
            .androidAVD(home: "/Users/me/.android/avd", name: "Yardlet_Phone"),
        ])
        XCTAssertTrue(question.message.contains("iOS 27.2 Simulator Runtime (\(SimulatorMissingPart.size(8_321_588_736)))"))
        XCTAssertTrue(question.message.contains(L10n.string("What Xcode, Android Studio or you installed stays.")))
        // The system draws the alert; an alert never shown draws in the light appearance only.
        let alert = question.alert()
        alert.window.appearance = NSAppearance(named: .aqua)
        alert.layout()
        let content = try XCTUnwrap(alert.window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "removal-question-\(language).png"))
        XCTAssertEqual(alert.buttons.map(\.title), [L10n.string("Remove"), L10n.string("Keep")])
    }

    /// The Simulator tab of `task` in the side panel's strip, beside a Files tab, with the + menu's choices, drawn
    /// once it reads out every text of `showing`.
    private func draw(_ center: SimulatorCenter, task: UUID, attached: SimulatorDeviceIdentity?,
                      titles: [UUID: String], appearance: WindowlessRender.Appearance,
                      helper: String = "/nonexistent/Yardlet Simulator Host",
                      installs: SimulatorInstalls? = nil, to url: URL,
                      showing expected: [String], check: ([String]) -> Void = { _ in }) async throws {
        let screens = MacSimulatorScreens()
        screens.executable = URL(filePath: helper)
        let services = SimulatorPanelServices(center: center, screens: screens, taskTitle: { titles[$0] },
                                              installs: installs)
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

/// An installer for drawing: it brings the tab's Install to the stage the test names and holds it there.
private final class RenderInstaller: SimulatorInstaller, @unchecked Sendable {
    enum Stage: Equatable {
        case idle
        case offered
        case installing(Double)
        case failed
    }

    let offer: SimulatorInstallOffer
    let stage: Stage
    let platform: SimulatorPlatform

    init(offer: SimulatorInstallOffer, stage: Stage = .idle, platform: SimulatorPlatform = .iOS) {
        self.offer = offer
        self.stage = stage
        self.platform = platform
    }

    @MainActor
    func drive(_ installs: SimulatorInstalls, check: SimulatorPlatformCheck) async throws {
        guard stage != .idle else { return }
        installs.prepare(platform, check: check, openURL: { _ in })
        try await waitUntil { installs.state(of: self.platform) == .offered(self.offer) }
        guard stage != .offered else { return }
        installs.confirm(platform, check: check)
        try await waitUntil {
            switch (self.stage, installs.state(of: self.platform)) {
            case (.installing, .installing(_, let progress)): progress.fraction != nil
            case (.failed, .failed): true
            default: false
            }
        }
    }

    func offer(for check: SimulatorPlatformCheck) async throws -> SimulatorInstallOffer? { offer }

    func install(_ offer: SimulatorInstallOffer, for check: SimulatorPlatformCheck,
                 progress: @escaping @Sendable (SimulatorInstallProgress) -> Void) async throws -> [SimulatorInstalledItem] {
        if case let .installing(fraction) = stage {
            progress(SimulatorInstallProgress(stage: .downloading, fraction: fraction))
            try await Task.sleep(for: .seconds(3600))
        }
        throw SimulatorInstallError(message: "iOS 27.2 is not available for download.")
    }

    func isStillInstalled(_ item: SimulatorInstalledItem) async -> Bool { false }
    func remove(_ item: SimulatorInstalledItem) async throws {}
}
