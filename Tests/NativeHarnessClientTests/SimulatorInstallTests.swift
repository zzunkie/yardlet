import Foundation
import XCTest
@testable import NativeHarnessClient

/// Install in the Simulator tab: nothing downloads before the person accepts what the tab showed, progress shows as
/// it comes, what was installed is written down, and turning the switch off removes only what is still as Yardlet
/// left it. The iOS runtime installer runs a fake `xcodebuild` in a fake Xcode with Apple's list from a fixture; the
/// Android SDK installer unpacks fixture archives, checked against their SHA-1, into a temporary home. Nothing here
/// downloads or installs anything on the Mac.
@MainActor
final class SimulatorInstallTests: XCTestCase {
    func testInstallWaitsForThePersonShowsProgressAndRemovesOnlyWhatIsStillThere() async throws {
        let installer = FakeInstaller()
        let record = InMemorySimulatorInstallRecord()
        let installs = SimulatorInstalls(installers: [installer], record: record)
        var installed: [SimulatorPlatform] = []
        installs.onInstalled = { installed.append($0) }
        let check = SimulatorPlatformCheck(availability: .runtimeMissing,
                                           toolchain: SimulatorToolchain(directory: "/Xcode/Contents/Developer"))
        XCTAssertTrue(installs.offersInstall(for: .iOS, check: check))
        XCTAssertFalse(installs.offersInstall(for: .iOS, check: SimulatorPlatformCheck(availability: .xcodeNotSetUp)))

        // Install reads the offer; nothing installs until Download.
        installs.prepare(.iOS, check: check, openURL: { _ in XCTFail("no store page for a runtime") })
        try await waitUntil { installs.state(of: .iOS) == .offered(FakeInstaller.offer) }
        XCTAssertEqual(installer.installs, 0)

        // Cancel leaves the offer without installing.
        installs.cancel(.iOS)
        XCTAssertEqual(installs.state(of: .iOS), .idle)
        XCTAssertEqual(installer.installs, 0)

        // Download: progress shows, the item is written down, and the center checks again.
        installs.prepare(.iOS, check: check, openURL: { _ in })
        try await waitUntil { installs.state(of: .iOS) == .offered(FakeInstaller.offer) }
        installs.confirm(.iOS, check: check)
        try await waitUntil {
            installs.state(of: .iOS) == .installing(name: "iOS 27.2 Simulator Runtime",
                                                    SimulatorInstallProgress(stage: .downloading, fraction: 0.5))
        }
        installer.finish()
        try await waitUntil { installs.state(of: .iOS) == .idle && installed == [.iOS] }
        XCTAssertEqual(record.load(), [FakeInstaller.runtime])

        // A failure says why and offers to try again.
        installer.failsNext = true
        installs.prepare(.iOS, check: check, openURL: { _ in })
        try await waitUntil { installs.state(of: .iOS) == .offered(FakeInstaller.offer) }
        installs.confirm(.iOS, check: check)
        installer.finish()
        try await waitUntil { installs.state(of: .iOS) == .failed("The download stopped.") }

        // Turned off: only what is still as Yardlet left it is offered for removal; what is gone is forgotten.
        record.save([FakeInstaller.runtime, FakeInstaller.gone])
        let removable = await installs.removableItems()
        XCTAssertEqual(removable, [FakeInstaller.runtime])
        XCTAssertEqual(record.load(), [FakeInstaller.runtime])
        let failures = await installs.remove(removable)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(installer.removed, [FakeInstaller.runtime])
        XCTAssertEqual(record.load(), [])

        // Without Xcode, Install opens Xcode's App Store page and installs nothing.
        var opened: [URL] = []
        installs.prepare(.iOS, check: SimulatorPlatformCheck(availability: .xcodeMissing), openURL: { opened.append($0) })
        try await waitUntil { opened == [MacIOSRuntimeInstaller.appStoreURL] }
        XCTAssertEqual(installs.state(of: .iOS), .idle)
    }

    func testTheIOSRuntimeInstallerSizesTheDownloadAndRunsXcodesOwnDownload() async throws {
        let folder = try temporaryFolder()
        let developer = folder.appending(path: "Xcode.app/Contents/Developer", directoryHint: .isDirectory)
        let sdk = developer.appending(
            path: "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/CoreServices")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": "24B8118", "ProductVersion": "27.2"],
                                           format: .xml, options: 0).write(to: sdk.appending(path: "SystemVersion.plist"))
        // A fake xcodebuild: prints progress as the real one rewrites its line, and writes down how it was run.
        let bin = developer.appending(path: "usr/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let arguments = folder.appending(path: "arguments")
        try """
        #!/bin/sh
        echo "$@" > '\(arguments.path)'
        echo "Finding content..."
        printf 'Downloading... (12.5%%)\\rDownloading... (50.0%%)\\rDownloading... (100.0%%)\\n'
        echo "Done downloading: iOS 27.2 Simulator (24B8117)."
        echo "Done importing: iOS 27.2 Simulator (24B8117)."
        """.write(to: bin.appending(path: "xcodebuild"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "xcodebuild").path)

        let runner = SimctlRuntimes()
        let toolchain = SimulatorToolchain(directory: developer.path(percentEncoded: false), version: "27.2")
        let installer = MacIOSRuntimeInstaller(runner: runner, fetchIndex: { Self.runtimeIndex },
                                               currentToolchain: { toolchain }, architecture: "arm64")
        let check = SimulatorPlatformCheck(availability: .runtimeMissing, toolchain: toolchain)

        // The size is the runtime Apple lists for this SDK build, preferred first, for Apple silicon.
        let offer = try await installer.offer(for: check)
        XCTAssertEqual(offer, .download(name: "iOS 27.2 Simulator Runtime", bytes: 8_321_588_736, licenses: []))
        let missingXcode = try await installer.offer(for: SimulatorPlatformCheck(availability: .xcodeMissing))
        XCTAssertEqual(missingXcode, .openStore(URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!))

        let seen = Readings()
        let items = try await installer.install(try XCTUnwrap(offer), for: check) { seen.add($0) }
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       "-downloadPlatform iOS -architectureVariant arm64")
        XCTAssertEqual(seen.all.compactMap(\.fraction), [0.125, 0.5, 1.0])
        XCTAssertEqual(seen.all.last?.stage, .installing)
        // What it installed is the runtime simctl did not list before.
        XCTAssertEqual(items, [.iOSRuntime(identifier: SimctlRuntimes.installed, name: "iOS 27.2 Simulator Runtime",
                                           bytes: 8_321_588_736)])
        let stillThere = await installer.isStillInstalled(items[0])
        XCTAssertTrue(stillThere)
        try await installer.remove(items[0])
        XCTAssertEqual(runner.deleted, [SimctlRuntimes.installed])

        // A download that fails says what xcodebuild said last.
        try """
        #!/bin/sh
        echo "Finding content..."
        echo "iOS 27.2 is not available for download." >&2
        exit 70
        """.write(to: bin.appending(path: "xcodebuild"), atomically: true, encoding: .utf8)
        do {
            _ = try await installer.install(try XCTUnwrap(offer), for: check) { _ in }
            XCTFail("the download failed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "iOS 27.2 is not available for download.")
        }
        XCTAssertEqual(SimulatorInstallOutput.lastPercentage(in: "45% (3.4 GB of 7.6 GB)"), 0.45)
    }

    func testTheAndroidSDKInstallerUnpacksCheckedPackagesWritesTheLicenseAndMakesAnAVD() async throws {
        let folder = try temporaryFolder()
        let home = folder.appending(path: "home", directoryHint: .isDirectory)
        let archives = try AndroidFixtureArchives(in: folder.appending(path: "archives", directoryHint: .isDirectory))
        let downloaded = Downloads()
        var installer = AndroidSDKInstaller(environment: [:], loginShellPath: { nil }, home: home,
                                            host: AndroidSDKHost(os: "macosx", arch: "aarch64", abi: "arm64-v8a"))
        installer.fetch = { url in url == AndroidSDKInstaller.repositoryURL ? archives.repository : archives.systemImages }
        installer.download = { url, destination, written in
            downloaded.add(url)
            let source = try archives.file(for: url)
            try FileManager.default.copyItem(at: source, to: destination)
            written(Int64((try? Data(contentsOf: destination).count) ?? 0))
            return AndroidFixtureArchives.sha1(of: destination)
        }
        let check = SimulatorPlatformCheck(availability: .sdkMissing)

        // The offer: the three packages, their size, and the licenses to accept, from Google's lists.
        let offer = try await installer.offer(for: check)
        guard case let .download(name, bytes, licenses)? = offer else { return XCTFail("\(String(describing: offer))") }
        XCTAssertEqual(name, L10n.string("Android SDK and emulator"))
        XCTAssertEqual(bytes, archives.totalSize)
        XCTAssertEqual(licenses.map(\.id), ["android-sdk-license", "android-sdk-arm-dbt-license"])
        // The text as an XML parser hands it on: references replaced, line ends as `\n`.
        XCTAssertTrue(licenses[0].text.hasPrefix("Terms & Conditions\n\nThis is"), licenses[0].text)
        XCTAssertEqual(downloaded.all, [], "nothing downloads before the person accepts")

        let items = try await installer.install(try XCTUnwrap(offer), for: check) { _ in }
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let files = FileManager.default
        XCTAssertTrue(files.isExecutableFile(atPath: sdk.appending(path: "platform-tools/adb").path))
        XCTAssertTrue(files.isExecutableFile(atPath: sdk.appending(path: "emulator/emulator").path))
        XCTAssertTrue(files.fileExists(
            atPath: sdk.appending(path: "system-images/android-36/google_apis_playstore/arm64-v8a/source.properties").path))
        XCTAssertFalse(files.fileExists(atPath: sdk.appending(path: ".temp").path))
        // The acceptance sdkmanager reads: the SHA-1 of the license's text.
        let accepted = try String(contentsOf: sdk.appending(path: "licenses/android-sdk-license"), encoding: .utf8)
        XCTAssertTrue(accepted.contains(AndroidSDKLicenses.hash(licenses[0])), accepted)
        // The AVD, as Android Studio describes one, on the image just unpacked.
        let avds = home.appending(path: ".android/avd", directoryHint: .isDirectory)
        let config = try String(contentsOf: avds.appending(path: "Yardlet_Phone.avd/config.ini"), encoding: .utf8)
        XCTAssertTrue(config.contains("image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/"), config)
        XCTAssertTrue(config.contains("abi.type=arm64-v8a"))
        let ini = try String(contentsOf: avds.appending(path: "Yardlet_Phone.ini"), encoding: .utf8)
        XCTAssertTrue(ini.contains("target=android-36"), ini)
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items.first, .androidSDKFolder(path: sdk.nativePath))
        XCTAssertTrue(items.contains(.androidAVD(home: avds.nativePath, name: "Yardlet_Phone")))

        // With everything there, nothing is offered.
        let again = try await installer.offer(for: check)
        XCTAssertNil(again)

        // Turned off, everything goes, the AVD and packages before the folder; a package someone updated stays.
        let record = InMemorySimulatorInstallRecord(items)
        let installs = SimulatorInstalls(installers: [installer], record: record)
        try "Pkg.Revision=37.9.9\n".write(to: sdk.appending(path: "emulator/source.properties"), atomically: true,
                                          encoding: .utf8)
        let removable = await installs.removableItems()
        XCTAssertEqual(removable.count, 4)
        XCTAssertFalse(removable.contains { if case .androidPackage(_, "emulator", _, _, _) = $0 { true } else { false } })
        let failures = await installs.remove(removable)
        // The folder still holds the emulator someone updated, so it stays.
        XCTAssertEqual(failures.map(\.0), [.androidSDKFolder(path: sdk.nativePath)])
        XCTAssertTrue(files.fileExists(atPath: sdk.appending(path: "emulator/emulator").path))
        XCTAssertFalse(files.fileExists(atPath: sdk.appending(path: "platform-tools").path))
        XCTAssertFalse(files.fileExists(atPath: sdk.appending(path: "system-images").path))
        XCTAssertFalse(files.fileExists(atPath: avds.appending(path: "Yardlet_Phone.ini").path))

        // A damaged download stops the install and leaves nothing it made.
        let clean = folder.appending(path: "clean", directoryHint: .isDirectory)
        installer.home = clean
        installer.download = { url, destination, _ in
            try FileManager.default.copyItem(at: try archives.file(for: url), to: destination)
            return "0000000000000000000000000000000000000000"
        }
        let cleanOffer = try await installer.offer(for: check)
        do {
            _ = try await installer.install(try XCTUnwrap(cleanOffer), for: check) { _ in }
            XCTFail("the SHA-1 did not match")
        } catch {}
        XCTAssertFalse(files.fileExists(atPath: clean.appending(path: "Library/Android/sdk").path))
    }

    // MARK: - Fixtures

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-install-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Apple's list, cut to the mappings and runtimes of Xcode 27.2's SDK.
    nonisolated private static var runtimeIndex: Data {
        let runtime = { (build: String, architectures: [String], size: Int64, name: String) -> [String: Any] in
            ["platform": "com.apple.platform.iphoneos", "simulatorVersion": ["buildUpdate": build, "version": "27.2"],
             "architectures": architectures, "fileSize": size, "name": name]
        }
        let index: [String: Any] = [
            "sdkToSimulatorMappings": [
                ["sdkBuildUpdate": "24B8118", "simulatorBuildUpdate": "24B91016s"],
                ["sdkBuildUpdate": "24B8118", "simulatorBuildUpdate": "24B8117", "affinity": "preferred"],
                ["sdkBuildUpdate": "24B113", "simulatorBuildUpdate": "24B114", "affinity": "preferred"],
            ],
            "downloadables": [
                runtime("24B114", ["arm64"], 1, "iOS 27.2 Release Candidate Simulator Runtime"),
                runtime("24B8117", ["arm64", "x86_64"], 9_000_000_000, "iOS 27.2 Simulator Runtime (universal)"),
                runtime("24B8117", ["arm64"], 8_321_588_736, "iOS 27.2 Simulator Runtime"),
            ],
        ]
        return try! PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
    }
}

/// An installer whose install waits for the test, reporting half way first.
private final class FakeInstaller: SimulatorInstaller, @unchecked Sendable {
    static let offer = SimulatorInstallOffer.download(name: "iOS 27.2 Simulator Runtime", bytes: 8_321_588_736, licenses: [])
    static let runtime = SimulatorInstalledItem.iOSRuntime(identifier: "C27103BD", name: "iOS 27.2 Simulator Runtime",
                                                           bytes: 8_321_588_736)
    static let gone = SimulatorInstalledItem.iOSRuntime(identifier: "GONE", name: "iOS 26.4 Simulator Runtime", bytes: nil)

    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var finished = false
    private(set) var installs = 0
    private(set) var removed: [SimulatorInstalledItem] = []
    var failsNext = false

    var platform: SimulatorPlatform { .iOS }

    func offer(for check: SimulatorPlatformCheck) async throws -> SimulatorInstallOffer? {
        check.availability == .xcodeMissing ? .openStore(MacIOSRuntimeInstaller.appStoreURL) : Self.offer
    }

    func install(_ offer: SimulatorInstallOffer, for check: SimulatorPlatformCheck,
                 progress: @escaping @Sendable (SimulatorInstallProgress) -> Void) async throws -> [SimulatorInstalledItem] {
        lock.withLock { installs += 1 }
        progress(SimulatorInstallProgress(stage: .downloading, fraction: 0.5))
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if finished { finished = false; return true }
                waiting = continuation
                return false
            }
            if resume { continuation.resume() }
        }
        if lock.withLock({ failsNext }) {
            lock.withLock { failsNext = false }
            throw SimulatorInstallError(message: "The download stopped.")
        }
        return [Self.runtime]
    }

    func finish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            if waiting == nil { finished = true }
            return waiting
        }
        continuation?.resume()
    }

    func isStillInstalled(_ item: SimulatorInstalledItem) async -> Bool { item != Self.gone }

    func remove(_ item: SimulatorInstalledItem) async throws { lock.withLock { removed.append(item) } }
}

/// `simctl runtime list` before and after a download, and `simctl runtime delete`.
private final class SimctlRuntimes: CLICommandRunning, @unchecked Sendable {
    static let installed = "C27103BD-9D2E-4905-9358-4759D023D9A1"
    private let lock = NSLock()
    private var lists = 0
    private(set) var deleted: [String] = []

    func run(_ command: CLICommand) async -> CLICommandResult {
        let arguments = command.arguments
        if arguments.starts(with: ["simctl", "runtime", "delete"]) {
            lock.withLock { deleted.append(arguments[3]) }
            return CLICommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let listing = lock.withLock { () -> Int in
            lists += 1
            return lists
        }
        let other = #""B0000000-0000-0000-0000-000000000000": {"platformIdentifier": "com.apple.platform.watchsimulator", "deletable": true}"#
        let ios = #""\#(Self.installed)": {"platformIdentifier": "com.apple.platform.iphonesimulator", "deletable": true}"#
        return CLICommandResult(exitCode: 0, stdout: listing == 1 ? "{\(other)}" : "{\(other), \(ios)}", stderr: "")
    }
}

private final class Readings: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [SimulatorInstallProgress] = []
    func add(_ reading: SimulatorInstallProgress) { lock.withLock { readings.append(reading) } }
    var all: [SimulatorInstallProgress] { lock.withLock { readings } }
}

private final class Downloads: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}

/// Small archives laid out as Google's are, one folder each with its `source.properties`, and lists naming them.
private struct AndroidFixtureArchives: Sendable {
    let folder: URL
    let repository: Data
    let systemImages: Data
    let totalSize: Int64

    init(in folder: URL) throws {
        self.folder = folder
        let files = FileManager.default
        func archive(_ name: String, top: String, contents: [String: String], revision: String) throws -> (Int64, String) {
            let staging = folder.appending(path: "staging-\(name)/\(top)", directoryHint: .isDirectory)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            try "Pkg.Revision=\(revision)\n".write(to: staging.appending(path: "source.properties"), atomically: true,
                                                   encoding: .utf8)
            for (file, text) in contents {
                let url = staging.appending(path: file)
                try text.write(to: url, atomically: true, encoding: .utf8)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            let zip = folder.appending(path: name)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", staging.path, zip.path]
            try process.run()
            process.waitUntilExit()
            let size = Int64(try Data(contentsOf: zip).count)
            return (size, Self.sha1(of: zip))
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let tools = try archive("platform-tools_r37.0.1-darwin.zip", top: "platform-tools",
                                contents: ["adb": "#!/bin/sh\n"], revision: "37.0.1")
        let emulator = try archive("emulator-darwin_aarch64-16740729.zip", top: "emulator",
                                   contents: ["emulator": "#!/bin/sh\n"], revision: "37.2.13")
        let image = try archive("arm64-v8a-36_r07.zip", top: "arm64-v8a",
                                contents: ["system.img": "image"], revision: "7")
        totalSize = tools.0 + emulator.0 + image.0
        let license = "Terms &amp; Conditions\r\n\nThis is the Android Software Development Kit License Agreement\n"
        let arm = "Terms and Conditions\n\nThis is the Android SDK ARM DBT License Agreement\n"
        repository = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:common="http://schemas.android.com/repository/android/common/02">
        <license id="android-sdk-license" type="text">\(license)</license>
        <channel id="channel-0">stable</channel><channel id="channel-2">dev</channel>
        <remotePackage path="platform-tools"><revision><major>37</major><minor>0</minor><micro>3</micro></revision>
        <display-name>Android SDK Platform-Tools</display-name><uses-license ref="android-sdk-license"/><channelRef ref="channel-2"/>
        <archives><archive><complete><size>1</size><checksum type="sha1">ff</checksum><url>platform-tools_r37.0.3-darwin.zip</url></complete><host-os>macosx</host-os></archive></archives></remotePackage>
        <remotePackage path="platform-tools"><revision><major>37</major><minor>0</minor><micro>1</micro></revision>
        <display-name>Android SDK Platform-Tools</display-name><uses-license ref="android-sdk-license"/><channelRef ref="channel-0"/>
        <archives>
        <archive><complete><size>9</size><checksum type="sha1">ee</checksum><url>platform-tools_r37.0.1-linux.zip</url></complete><host-os>linux</host-os></archive>
        <archive><complete><size>\(tools.0)</size><checksum type="sha1">\(tools.1)</checksum><url>platform-tools_r37.0.1-darwin.zip</url></complete><host-os>macosx</host-os></archive>
        </archives></remotePackage>
        <remotePackage path="emulator"><revision><major>37</major><minor>2</minor><micro>13</micro></revision>
        <display-name>Android Emulator</display-name><uses-license ref="android-sdk-license"/><channelRef ref="channel-0"/>
        <archives>
        <archive><complete><size>9</size><checksum type="sha1">dd</checksum><url>emulator-darwin_x64-16740729.zip</url></complete><host-os>macosx</host-os><host-arch>x64</host-arch></archive>
        <archive><complete><size>\(emulator.0)</size><checksum type="sha1">\(emulator.1)</checksum><url>emulator-darwin_aarch64-16740729.zip</url></complete><host-os>macosx</host-os><host-arch>aarch64</host-arch></archive>
        </archives></remotePackage>
        </sdk:sdk-repository>
        """.utf8)
        systemImages = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03">
        <license id="android-sdk-arm-dbt-license" type="text">\(arm)</license>
        <remotePackage path="system-images;android-35;google_apis_playstore;arm64-v8a">
        <type-details><api-level>35</api-level><tag><id>google_apis_playstore</id><display>Google Play</display></tag><abi>arm64-v8a</abi></type-details>
        <revision><major>9</major></revision><display-name>Google Play ARM 64 v8a System Image</display-name>
        <uses-license ref="android-sdk-arm-dbt-license"/><channelRef ref="channel-0"/>
        <archives><archive><complete><size>9</size><checksum type="sha1">cc</checksum><url>arm64-v8a-35_r09.zip</url></complete></archive></archives></remotePackage>
        <remotePackage path="system-images;android-36;google_apis_playstore_ps16k;arm64-v8a">
        <type-details><api-level>36</api-level><tag><id>google_apis_playstore_ps16k</id><display>Google Play 16k</display></tag><abi>arm64-v8a</abi></type-details>
        <revision><major>7</major></revision><display-name>Google Play 16k ARM 64 v8a System Image</display-name>
        <uses-license ref="android-sdk-arm-dbt-license"/><channelRef ref="channel-0"/>
        <archives><archive><complete><size>9</size><checksum type="sha1">bb</checksum><url>arm64-v8a-36-16k_r07.zip</url></complete></archive></archives></remotePackage>
        <remotePackage path="system-images;android-36;google_apis_playstore;arm64-v8a">
        <type-details><api-level>36</api-level><tag><id>google_apis_playstore</id><display>Google Play</display></tag><abi>arm64-v8a</abi></type-details>
        <revision><major>7</major></revision><display-name>Google Play ARM 64 v8a System Image</display-name>
        <uses-license ref="android-sdk-arm-dbt-license"/><channelRef ref="channel-0"/>
        <archives><archive><complete><size>\(image.0)</size><checksum type="sha1">\(image.1)</checksum><url>arm64-v8a-36_r07.zip</url></complete></archive></archives></remotePackage>
        </sys-img:sdk-sys-img>
        """.utf8)
    }

    func file(for url: URL) throws -> URL {
        let file = folder.appending(path: url.lastPathComponent)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw SimulatorInstallError(message: "no fixture for \(url.lastPathComponent)")
        }
        return file
    }

    static func sha1(of file: URL) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shasum")
        process.arguments = [file.path]
        let output = Pipe()
        process.standardOutput = output
        try? process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(text.prefix(40))
    }
}
