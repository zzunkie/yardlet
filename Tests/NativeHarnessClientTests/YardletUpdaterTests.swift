import XCTest
@testable import NativeHarnessClient

/// Self-update: a staged build replaces the installed bundle only after the app has quit, keeps the
/// previous bundle, and changes nothing when the staged build cannot be verified.
final class YardletUpdaterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "yardlet-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testOnlyAStagedBuildOfThisAppThatDiffersFromTheInstalledOneIsOffered() throws {
        let updates = root.appending(path: "Updates")
        let installed = try bundle(at: root.appending(path: "Installed/Yardlet.app"), marker: "installed")
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .nothingStaged)
        }
        let staged = updates.appending(path: "Pending/Yardlet.app")
        try bundle(at: staged, marker: "other", identifier: "com.example.other")
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .otherApp)
        }
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: installed, to: staged)
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .alreadyInstalled)
        }
        try FileManager.default.removeItem(at: staged)
        try bundle(at: staged, marker: "new", executableSuffix: "new build")
        try Data(#"{"commit":"abc1234","dirty":true,"builtAt":"2026-10-06T13:00:00Z"}"#.utf8)
            .write(to: updates.appending(path: "Pending/manifest.json"))
        let candidate = try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)
        XCTAssertEqual(candidate.commit, "abc1234")
        XCTAssertTrue(candidate.hasUncommittedChanges)
        XCTAssertEqual(candidate.builtAt, Date(timeIntervalSince1970: 1_791_291_600))
        XCTAssertNoThrow(try YardletUpdater.verifySignature(of: candidate.bundleURL))

        // Install Update… does not go back: a staged build numbered below the installed one is not offered, by
        // number and not by spelling; one of the same number or a later one is.
        let numbered = try bundle(at: root.appending(path: "Numbered/Yardlet.app"), marker: "installed", version: "100")
        for (version, isOffered) in [("99", false), ("9.9", false), ("100", true), ("100.1", true), ("101", true)] {
            try FileManager.default.removeItem(at: staged)
            try bundle(at: staged, marker: "new", executableSuffix: "build \(version)", version: version)
            let offer = Result { try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: numbered) }
            switch offer {
            case .success: XCTAssertTrue(isOffered, version)
            case let .failure(error):
                XCTAssertEqual(error as? YardletUpdater.Problem, .earlier(staged: version, installed: "100"), version)
                XCTAssertFalse(isOffered, version)
            }
        }
        XCTAssertTrue(YardletUpdater.isEarlier(nil, than: "100"), "A build without a number does not replace one with it")
        XCTAssertFalse(YardletUpdater.isEarlier("1", than: nil))

        // A link to a build elsewhere is not moved into place.
        let elsewhere = root.appending(path: "Elsewhere/Yardlet.app")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .linked)
        }
    }

    /// The sidebar's "Restart to update" and its menu bar line follow the staged build without checking
    /// its signature: nothing staged, another app's build or the installed build shows nothing; a new
    /// build shows, and a build staged over it is read again although the last digest is kept.
    @MainActor
    func testRestartToUpdateShowsOnlyAStagedBuildOfThisAppThatDiffersFromTheInstalledOne() async throws {
        let updates = root.appending(path: "Updates")
        let pending = updates.appending(path: "Pending")
        let staged = pending.appending(path: "Yardlet.app")
        let installed = try bundle(at: root.appending(path: "Installed/Yardlet.app"), marker: "installed")
        let watch = YardletStagedUpdate(root: updates, bundleIdentifier: identifier, installedBundle: installed)
        await watch.check()
        XCTAssertNil(watch.ready, "Nothing staged")

        try bundle(at: staged, marker: "other", identifier: "com.example.other", executableSuffix: "other")
        await watch.check()
        XCTAssertNil(watch.ready, "Another app's build")

        try FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: installed, to: staged)
        await watch.check()
        XCTAssertNil(watch.ready, "The installed build")

        try FileManager.default.removeItem(at: pending)
        try bundle(at: staged, marker: "new", executableSuffix: "new build")
        try Data(#"{"commit":"abc1234","dirty":false}"#.utf8).write(to: pending.appending(path: "manifest.json"))
        await watch.check()
        let ready = try XCTUnwrap(watch.ready)
        XCTAssertEqual(ready.commit, "abc1234")
        XCTAssertEqual(MenuBarMenu.UpdateLine(ready: ready, isWaiting: false), .ready(build: "abc1234"))
        XCTAssertEqual(MenuBarMenu.UpdateLine(ready: ready, isWaiting: true), .waiting)
        XCTAssertEqual(MenuBarMenu.UpdateLine.ready(build: "abc1234").help,
                       L10n.string("Restart to update") + " · abc1234")

        try FileManager.default.removeItem(at: pending)
        try bundle(at: staged, marker: "newer", executableSuffix: "a newer build")
        await watch.check()
        XCTAssertNotNil(watch.ready)
        XCTAssertNotEqual(watch.ready?.executableDigest, ready.executableDigest)
        XCTAssertNil(watch.ready?.commit, "No manifest, no commit")

        try FileManager.default.removeItem(at: pending)
        await watch.check()
        XCTAssertNil(watch.ready, "Installed, or taken away")
    }

    func testStagingScriptPublishesACompleteBuildWithItsManifest() throws {
        let built = try bundle(at: root.appending(path: "build/Yardlet.app"), marker: "built", executableSuffix: "built")
        let installed = try bundle(at: root.appending(path: "Installed/Yardlet.app"), marker: "installed")
        let updates = root.appending(path: "Updates")
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "scripts/stage-update.sh")
        let result = try run("/bin/zsh", [script.path, built.path],
                             environment: ["YARDLET_UPDATES_DIR": updates.path, "YARDLET_INSTALLED_APP": installed.path])
        XCTAssertEqual(result.status, 0, result.output)
        let candidate = try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)
        XCTAssertNotNil(candidate.commit)
        XCTAssertNotNil(candidate.builtAt)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: updates.path).filter { $0.hasPrefix(".incoming") }
        XCTAssertEqual(leftovers, [])

        // A build numbered below the installed app's is refused here, before anything is copied.
        let newer = try bundle(at: root.appending(path: "Newer/Yardlet.app"), marker: "installed", version: "34")
        let older = try bundle(at: root.appending(path: "older/Yardlet.app"), marker: "older", executableSuffix: "older",
                               version: "33")
        let refused = try run("/bin/zsh", [script.path, older.path],
                              environment: ["YARDLET_UPDATES_DIR": root.appending(path: "OtherUpdates").path,
                                            "YARDLET_INSTALLED_APP": newer.path])
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertTrue(refused.output.contains("earlier than"), refused.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "OtherUpdates/Pending").path))
        let same = try run("/bin/zsh", [script.path, older.path],
                           environment: ["YARDLET_UPDATES_DIR": root.appending(path: "OtherUpdates").path,
                                         "YARDLET_INSTALLED_APP": older.path])
        XCTAssertEqual(same.status, 0, same.output)
    }

    func testInstallerSwapsAfterTheAppQuitsAndKeepsThePreviousApp() throws {
        let updates = root.appending(path: "Updates")
        let target = try bundle(at: root.appending(path: "Applications/Yardlet.app"), marker: "old")
        try bundle(at: updates.appending(path: "Pending/Yardlet.app"), marker: "new", executableSuffix: "new")
        try Data("{}".utf8).write(to: updates.appending(path: "Pending/manifest.json"))
        let app = try Process.run(URL(filePath: "/bin/sleep"), arguments: ["1"])
        let installer = try YardletUpdater.launchInstaller(target: target, processID: app.processIdentifier,
            root: updates, relaunch: false)
        XCTAssertEqual(try marker(target), "old", "Nothing moves while the app is still running")
        XCTAssertNotEqual(getsid(installer), getsid(0), "The installer does not share the app's session")
        XCTAssertEqual(exitStatus(installer), 0)
        XCTAssertEqual(try marker(target), "new")
        XCTAssertEqual(try marker(updates.appending(path: "Previous/Yardlet.app")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: updates.appending(path: "Pending/Yardlet.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: updates.appending(path: "installed.json").path))
        XCTAssertNoThrow(try YardletUpdater.verifySignature(of: target))
    }

    func testATamperedStagedBuildChangesNothing() throws {
        let updates = root.appending(path: "Updates")
        let target = try bundle(at: root.appending(path: "Applications/Yardlet.app"), marker: "old")
        let staged = try bundle(at: updates.appending(path: "Pending/Yardlet.app"), marker: "new", executableSuffix: "new")
        try Data("changed after signing".utf8).write(to: staged.appending(path: "Contents/Resources/marker.txt"))
        XCTAssertThrowsError(try YardletUpdater.verifySignature(of: staged))
        let installer = try YardletUpdater.launchInstaller(target: target, processID: 999_999, root: updates, relaunch: false)
        XCTAssertNotEqual(exitStatus(installer), 0)
        XCTAssertEqual(try marker(target), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(try String(contentsOf: updates.appending(path: "install.log"), encoding: .utf8)
            .contains("nothing changed"))

        // A build holding a file linked from elsewhere stays out too, though its signature verifies.
        try FileManager.default.removeItem(at: staged)
        let linked = try bundle(at: staged, marker: "linked", executableSuffix: "linked")
        try FileManager.default.linkItem(at: linked.appending(path: "Contents/Resources/marker.txt"),
                                         to: root.appending(path: "outside-marker.txt"))
        let refused = try YardletUpdater.launchInstaller(target: target, processID: 999_999, root: updates, relaunch: false)
        XCTAssertNotEqual(exitStatus(refused), 0)
        XCTAssertEqual(try marker(target), "old")
        XCTAssertTrue(try String(contentsOf: updates.appending(path: "install.log"), encoding: .utf8)
            .contains("holds a link"))

        // Nor does a build numbered below the installed one, staged while the app was quitting.
        let current = try bundle(at: root.appending(path: "Current/Yardlet.app"), marker: "current", version: "34")
        try FileManager.default.removeItem(at: staged)
        try bundle(at: staged, marker: "older", executableSuffix: "older", version: "33.9")
        let back = try YardletUpdater.launchInstaller(target: current, processID: 999_999, root: updates, relaunch: false)
        XCTAssertNotEqual(exitStatus(back), 0)
        XCTAssertEqual(try marker(current), "current")
        XCTAssertTrue(try String(contentsOf: updates.appending(path: "install.log"), encoding: .utf8)
            .contains("is earlier than the installed one"))
        try FileManager.default.removeItem(at: staged)
        try bundle(at: staged, marker: "same number", executableSuffix: "same number", version: "34")
        let sideways = try YardletUpdater.launchInstaller(target: current, processID: 999_999, root: updates, relaunch: false)
        XCTAssertEqual(exitStatus(sideways), 0)
        XCTAssertEqual(try marker(current), "same number")
    }

    // MARK: - Fixtures

    private let identifier = "com.zzunkie.yardlet"

    /// A minimal ad-hoc signed app bundle whose resources carry a marker.
    @discardableResult
    private func bundle(at url: URL, marker: String, identifier: String = "com.zzunkie.yardlet",
                        executableSuffix: String = "", version: String? = nil) throws -> URL {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Yardlet",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "Yardlet"]
        info["CFBundleVersion"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "MacOS/Yardlet")
        try Data("#!/bin/sh\n# \(executableSuffix)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(marker.utf8).write(to: contents.appending(path: "Resources/marker.txt"))
        let signed = try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        XCTAssertEqual(signed.status, 0, signed.output)
        return url
    }

    private func exitStatus(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return (status >> 8) & 0xff
    }

    private func marker(_ bundle: URL) throws -> String {
        try String(contentsOf: bundle.appending(path: "Contents/Resources/marker.txt"), encoding: .utf8)
    }

    private func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
