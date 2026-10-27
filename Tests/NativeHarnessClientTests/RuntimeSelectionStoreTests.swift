import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class RuntimeSelectionStoreTests: XCTestCase {
    func testMuseAcceptsExplicitOfficialExecutableName() {
        XCTAssertTrue(
            RuntimeSelectionStore.isCompatibleRuntime(
                URL(filePath: "/tmp/muse"),
                for: .museCode
            )
        )
    }

    func testConnectedDescriptorsContainOnlyExecutableSelections() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "nhc-connected-runtimes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let codex = root.appending(path: "codex")
        let claude = root.appending(path: "claude")
        for executable in [codex, claude] {
            XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let store = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: false
        )
        store.select(codex, for: .codex)
        store.select(claude, for: .claudeCode)

        XCTAssertEqual(store.connectedDescriptors.map(\.id), [.codex, .claudeCode])
    }

    func testDeletedSelectedRuntimeCannotRemainAvailable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "nhc-missing-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "pi")
        XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let store = RuntimeSelectionStore(defaults: defaults)
        store.select(executable, for: .pi)
        XCTAssertEqual(store.selectedURL(for: .pi), executable.standardizedFileURL)

        try fileManager.removeItem(at: executable)

        XCTAssertNil(store.selectedURL(for: .pi))
    }

    func testAntigravityRejectsLegacyIDELauncherAndAcceptsOfficialAgyCLI() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "nhc-antigravity-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let legacy = root
            .appending(path: ".antigravity/antigravity/bin", directoryHint: .isDirectory)
            .appending(path: "antigravity")
        let agy = root.appending(path: "agy")
        try fileManager.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for executable in [legacy, agy] {
            XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set(
            legacy.path,
            forKey: "runtime.antigravity-cli.executablePath"
        )
        let store = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: true
        )

        XCTAssertNil(store.selectedURL(for: .antigravityCLI))
        XCTAssertNil(defaults.string(forKey: "runtime.antigravity-cli.executablePath"))
        XCTAssertFalse(RuntimeSelectionStore.isCompatibleRuntime(legacy, for: .antigravityCLI))
        XCTAssertTrue(RuntimeSelectionStore.isCompatibleRuntime(agy, for: .antigravityCLI))

        store.select(agy, for: .antigravityCLI)
        XCTAssertEqual(store.selectedURL(for: .antigravityCLI), agy.standardizedFileURL)
        store.select(legacy, for: .antigravityCLI)
        XCTAssertEqual(store.selectedURL(for: .antigravityCLI), agy.standardizedFileURL)
    }

    /// A removed harness's saved runtime choice is forgotten; the other choices stay.
    func testRemovedHarnessRuntimeChoiceIsForgotten() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set("/tmp/gjc", forKey: "runtime.gajae-code.executablePath")
        defaults.set("/usr/bin/true", forKey: "runtime.pi.executablePath")
        let store = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: true
        )

        XCTAssertNil(defaults.string(forKey: "runtime.gajae-code.executablePath"))
        XCTAssertEqual(defaults.string(forKey: "runtime.pi.executablePath"), "/usr/bin/true")
        XCTAssertEqual(store.selectedURL(for: .pi), URL(filePath: "/usr/bin/true"))
    }

    /// With no runtime chosen, a harness uses its newest install: before the versions are read,
    /// the first in order; after, the newest, also at the next launch without running anything.
    /// A file that changed is read again, and nothing is saved as the person's choice.
    func testAHarnessWithNoChosenRuntimeUsesItsNewestInstall() async throws {
        let root = try temporaryFolder("nhc-newest-runtime")
        let homebrew = try versionScript(root.appending(path: "opt/homebrew/bin/codex"), "codex-cli 0.163.0")
        let chatGPT = try versionScript(root.appending(path: "ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
                                        "codex-cli 0.164.0-alpha.11.1")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let reads = ReadLog()
        func store() -> RuntimeSelectionStore {
            RuntimeSelectionStore(defaults: defaults, candidates: { $0 == .codex ? [homebrew, chatGPT] : [] },
                versions: RuntimeVersionCache(defaults: defaults) { url in
                    reads.add(url)
                    return await RuntimeVersionCache.readVersion(url)
                })
        }

        let first = store()
        XCTAssertEqual(first.selectedURL(for: .codex), homebrew.standardizedFileURL)
        await first.findNewest()
        XCTAssertEqual(first.selectedURL(for: .codex), chatGPT.standardizedFileURL)
        XCTAssertEqual(reads.count, 2)
        XCTAssertNil(first.newerInstalls[.codex])
        XCTAssertNil(defaults.string(forKey: "runtime.codex.executablePath"))

        let next = store()
        XCTAssertEqual(next.selectedURL(for: .codex), chatGPT.standardizedFileURL)
        await next.findNewest()
        XCTAssertEqual(reads.count, 2)

        // Homebrew moves past the app's bundle: only that file runs `--version` again.
        try versionScript(homebrew, "codex-cli 0.170.12")
        await next.findNewest()
        XCTAssertEqual(next.selectedURL(for: .codex), homebrew.standardizedFileURL)
        XCTAssertEqual(reads.urls.dropFirst(2), [homebrew.standardizedFileURL])
    }

    /// A runtime the person chose stays when a newer install appears elsewhere. The newer one is
    /// offered (an older one is not), and using it drops the choice.
    func testAChosenRuntimeStaysAndANewerInstallIsOffered() async throws {
        let root = try temporaryFolder("nhc-chosen-runtime")
        let local = try versionScript(root.appending(path: ".local/bin/codex"), "codex-cli 0.150.0")
        let homebrew = try versionScript(root.appending(path: "opt/homebrew/bin/codex"), "codex-cli 0.163.0")
        let chatGPT = try versionScript(root.appending(path: "ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
                                        "codex-cli 0.164.0-alpha.11.1")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        defaults.set(homebrew.path(percentEncoded: false), forKey: "runtime.codex.executablePath")
        let store = RuntimeSelectionStore(defaults: defaults, candidates: { $0 == .codex ? [local, homebrew, chatGPT] : [] },
                                          versions: RuntimeVersionCache(defaults: defaults))

        await store.findNewest()
        XCTAssertEqual(store.selectedURL(for: .codex), homebrew.standardizedFileURL)
        XCTAssertEqual(store.newerInstalls[.codex],
                       RuntimeSelectionStore.Install(url: chatGPT.standardizedFileURL, version: "0.164.0-alpha.11.1"))
        XCTAssertEqual(defaults.string(forKey: "runtime.codex.executablePath"), homebrew.path(percentEncoded: false))

        store.useNewest(for: .codex)
        XCTAssertEqual(store.selectedURL(for: .codex), chatGPT.standardizedFileURL)
        XCTAssertNil(store.newerInstalls[.codex])
        XCTAssertNil(defaults.string(forKey: "runtime.codex.executablePath"))
    }

    /// The order breaks a tie between equal versions (product document 13.100). A GUI launch's
    /// `PATH` has only the system's folders, so an install a package manager put elsewhere (npm
    /// under nvm, Volta, pnpm) is looked for where the person's shell would find it.
    func testCodexCandidatesListUserManagedInstallsBeforeChatGPTBundle() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "nhc-codex-candidates-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let nvm = home.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        for version in ["v9.11.2", "v22.11.0"] {
            try FileManager.default.createDirectory(at: nvm.appending(path: "\(version)/bin"), withIntermediateDirectories: true)
        }
        let candidates = RuntimeSelectionStore.codexCandidates(
            home: home,
            searchPath: "/custom/bin:/usr/bin"
        ).map { $0.path(percentEncoded: false) }

        let expected = [
            home.appending(path: ".local/bin/codex"),
            home.appending(path: ".volta/bin/codex"),
            home.appending(path: "Library/pnpm/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex"),
            // nvm's newest Node first.
            nvm.appending(path: "v22.11.0/bin/codex"),
            nvm.appending(path: "v9.11.2/bin/codex"),
            URL(filePath: "/custom/bin/codex"),
            URL(filePath: "/usr/bin/codex"),
            // ChatGPT moved its bundled runtime in September 2026; the older layout stays last.
            URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
            URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ].map { $0.path(percentEncoded: false) }
        XCTAssertEqual(candidates.filter(expected.contains), expected)
        XCTAssertEqual(Array(candidates.suffix(2)), Array(expected.suffix(2)))
        XCTAssertEqual(candidates.filter { $0 == "/usr/bin/codex" }.count, 1, "a folder in PATH and in the list is looked in once")
    }

    func testClaudeDesktopCandidatesPreferNewestExecutableVersion() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appending(path: "nhc-runtime-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: home) }

        for version in ["2.1.99", "2.1.227", "2.1.195"] {
            let executable = home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory)
                .appending(path: "Claude", directoryHint: .isDirectory)
                .appending(path: "claude-code", directoryHint: .isDirectory)
                .appending(path: version, directoryHint: .isDirectory)
                .appending(path: "claude.app", directoryHint: .isDirectory)
                .appending(path: "Contents", directoryHint: .isDirectory)
                .appending(path: "MacOS", directoryHint: .isDirectory)
                .appending(path: "claude")
            try fileManager.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                fileManager.createFile(
                    atPath: executable.path(percentEncoded: false),
                    contents: Data()
                )
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path(percentEncoded: false)
            )
        }

        let candidates = RuntimeSelectionStore.claudeDesktopCandidates(
            home: home,
            fileManager: fileManager
        )

        XCTAssertEqual(
            candidates.map { $0.pathComponents.dropLast(4).last },
            ["2.1.227", "2.1.195", "2.1.99"]
        )
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// An executable that prints `version` for `--version`, as a harness CLI does.
    @discardableResult
    private func versionScript(_ url: URL, _ version: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho '\(version)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
}

/// The runtimes a version cache ran `--version` on, in order.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URL] = []

    func add(_ url: URL) { lock.withLock { all.append(url.standardizedFileURL) } }
    var urls: [URL] { lock.withLock { all } }
    var count: Int { urls.count }
}
