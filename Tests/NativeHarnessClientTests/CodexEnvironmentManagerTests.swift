import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexEnvironmentManagerTests: XCTestCase {
    func testLivePathsPreferExplicitNativeAndYardletHomes() {
        let home = URL(filePath: "/Users/example")
        let paths = CodexEnvironmentPaths.live(
            environment: [
                "CODEX_HOME": "/ignored/codex",
                "YARDLET_NATIVE_CODEX_HOME": "~/native-codex",
                "YARDLET_HOME": "~/yardlet-data"
            ],
            homeURL: home
        )

        XCTAssertEqual(paths.nativeHomeURL.path(), "/Users/example/native-codex")
        XCTAssertEqual(paths.yardletRootURL.path(), "/Users/example/yardlet-data")
        XCTAssertEqual(
            paths.runtimeHomeURL.path(),
            "/Users/example/yardlet-data/harnesses/codex/home/"
        )
    }

    func testSnapshotInheritsCapabilitiesAppliesOverlayAndExcludesRuntimeState() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("model = \"native\"\nsqlite_home = \"/native/history\"\n".utf8)
            .write(to: native.appending(path: "config.toml"))
        try write("native skill", to: native.appending(path: "skills/native/SKILL.md"))
        try write("native plugin", to: native.appending(path: "plugins/cache/sample/plugin.json"))
        try write("runtime socket", to: native.appending(path: "plugins/.plugin-appserver/socket"))
        try write("native agents", to: native.appending(path: "AGENTS.md"))
        try write("secret", to: native.appending(path: "auth.json"))
        try write("native session", to: native.appending(path: "sessions/thread.jsonl"))

        let paths = CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        try write("overlay skill", to: paths.overlayURL.appending(path: "skills/native/SKILL.md"))
        try write("yardlet skill", to: paths.overlayURL.appending(path: "skills/yardlet/SKILL.md"))
        let manager = CodexEnvironmentManager(paths: paths)

        let snapshot = try await manager.prepare()
        let runtime = paths.runtimeHomeURL

        XCTAssertEqual(snapshot.inheritedPaths, ["config.toml", "AGENTS.md", "skills", "plugins/cache"])
        XCTAssertEqual(snapshot.overlayPaths, ["skills"])
        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "skills/native/SKILL.md"), encoding: .utf8),
            "overlay skill"
        )
        XCTAssertEqual(
            try String(contentsOf: runtime.appending(path: "skills/yardlet/SKILL.md"), encoding: .utf8),
            "yardlet skill"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: runtime.appending(path: "plugins/cache/sample/plugin.json").path(percentEncoded: false)
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime.appending(path: "plugins/.plugin-appserver").path(percentEncoded: false)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appending(path: "auth.json").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appending(path: "sessions").path(percentEncoded: false)))

        let config = try String(contentsOf: runtime.appending(path: "config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("model = \"native\""))
        XCTAssertTrue(config.contains("sqlite_home = \"\(root.path(percentEncoded: false))yardlet/harnesses/codex/home\""))
        XCTAssertFalse(config.contains("/native/history"))
    }

    func testSnapshotRefreshesWhenNativeChangesButLeavesCodexRuntimeStateAlone() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        let manager = CodexEnvironmentManager(paths: paths)
        try write("first", to: native.appending(path: "skills/sample/SKILL.md"))
        _ = try await manager.prepare()
        try write("yardlet auth", to: paths.runtimeHomeURL.appending(path: "auth.json"))
        try write("yardlet session", to: paths.runtimeHomeURL.appending(path: "sessions/thread.jsonl"))

        try Data("second".utf8).write(to: native.appending(path: "skills/sample/SKILL.md"))
        _ = try await manager.prepare()

        XCTAssertEqual(
            try String(contentsOf: paths.runtimeHomeURL.appending(path: "skills/sample/SKILL.md"), encoding: .utf8),
            "second"
        )
        XCTAssertEqual(
            try String(contentsOf: paths.runtimeHomeURL.appending(path: "auth.json"), encoding: .utf8),
            "yardlet auth"
        )
        XCTAssertEqual(
            try String(contentsOf: paths.runtimeHomeURL.appending(path: "sessions/thread.jsonl"), encoding: .utf8),
            "yardlet session"
        )
    }

    func testSkillSymlinkIsMaterializedAsAStableSnapshot() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        let sharedSkill = root.appending(path: "shared-skill", directoryHint: .isDirectory)
        try write("linked skill", to: sharedSkill.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(
            at: native.appending(path: "skills"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: native.appending(path: "skills/linked"),
            withDestinationURL: sharedSkill
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        let manager = CodexEnvironmentManager(paths: paths)

        _ = try await manager.prepare()
        let runtimeSkill = paths.runtimeHomeURL.appending(path: "skills/linked")

        XCTAssertFalse(try runtimeSkill.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        XCTAssertEqual(
            try String(contentsOf: runtimeSkill.appending(path: "SKILL.md"), encoding: .utf8),
            "linked skill"
        )
    }

    func testBrokenOptionalSkillSymlinkIsSkippedWithoutBlockingSnapshot() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        let skills = native.appending(path: "skills", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skills.appending(path: "missing-skill"),
            withDestinationURL: root.appending(path: "does-not-exist")
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        let manager = CodexEnvironmentManager(paths: paths)

        _ = try await manager.prepare()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.runtimeHomeURL.appending(path: "skills").path(percentEncoded: false)
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.runtimeHomeURL.appending(path: "skills/missing-skill").path(percentEncoded: false)
            )
        )
    }

    func testProcessEnvironmentTargetsOnlyYardletCodexHome() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        let manager = CodexEnvironmentManager(paths: paths)

        let environment = try await manager.processEnvironment(
            base: ["PATH": "/usr/bin"], scope: .yardlet
        ).values

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["CODEX_HOME"], root.path(percentEncoded: false) + "yardlet/harnesses/codex/home")
        XCTAssertEqual(environment["YARDLET_NATIVE_CODEX_HOME"], root.path(percentEncoded: false) + "native")
    }

    func testProcessLaunchUsesPreparedSnapshotUntilExplicitRefresh() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try write("model = \"first\"\n", to: native.appending(path: "config.toml"))
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        let manager = CodexEnvironmentManager(paths: paths)
        _ = try await manager.prepare()
        try write("model = \"second\"\n", to: native.appending(path: "config.toml"))

        _ = try await manager.processEnvironment(base: [:], scope: .yardlet)
        var effective = try String(
            contentsOf: paths.runtimeHomeURL.appending(path: "config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(effective.contains("model = \"first\""))

        _ = try await manager.prepare()
        effective = try String(
            contentsOf: paths.runtimeHomeURL.appending(path: "config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(effective.contains("model = \"second\""))
    }

    /// Sign-in on a computer where Codex never ran: Codex ends at once when `CODEX_HOME` names no folder, so the home
    /// it names, written as the file system writes it (the root's name has a space and Hangul), is made first.
    func testCodexAccountCommandsUseNativeHomeWithoutMaterializingIsolation() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CodexEnvironmentManager(
            paths: CodexEnvironmentPaths(nativeHomeURL: native, yardletRootURL: yardlet)
        )
        let broker = HarnessAccountBroker(codexEnvironmentManager: manager)

        let command = await broker.loginCommand(
            for: .codex,
            executableURL: URL(filePath: "/usr/bin/true")
        )

        XCTAssertEqual(command?.environment["CODEX_HOME"], root.path(percentEncoded: false) + "native")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path(percentEncoded: false) + "native", isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        XCTAssertEqual(command?.arguments, ["login"])
        let logout = await broker.logoutCommand(for: .codex, executableURL: URL(filePath: "/usr/bin/true"))
        XCTAssertEqual(logout?.environment["CODEX_HOME"], root.path(percentEncoded: false) + "native")
        XCTAssertEqual(logout?.arguments, ["logout"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: yardlet.path(percentEncoded: false)))
    }

    func testBrokenLegacyIsolationDoesNotBlockNativeAccountCommands() async throws {
        let root = temporaryRoot()
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CodexEnvironmentManager(
            paths: CodexEnvironmentPaths(
                nativeHomeURL: native,
                yardletRootURL: native.appending(path: "yardlet", directoryHint: .isDirectory)
            )
        )

        do {
            _ = try await manager.prepare()
            XCTFail("Expected overlapping Codex homes to be rejected")
        } catch let error as CodexEnvironmentError {
            guard case .sourceAndRuntimeHomesOverlap = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let broker = HarnessAccountBroker(codexEnvironmentManager: manager)
        let command = await broker.loginCommand(
            for: .codex,
            executableURL: URL(filePath: "/usr/bin/true")
        )
        XCTAssertEqual(command?.environment["CODEX_HOME"], root.path(percentEncoded: false) + "native")
    }

    func testNativeEnvironmentPreservesInputsAndNeverCopiesProviderState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appending(path: "native", directoryHint: .isDirectory)
        let yardlet = root.appending(path: "yardlet", directoryHint: .isDirectory)
        let config = "model = \"native\"\nsqlite_home = \"/custom/index\"\n"
        try write(config, to: native.appending(path: "config.toml"))
        try write("fixture credential", to: native.appending(path: "auth.json"))
        try write("fixture session", to: native.appending(path: "sessions/thread.jsonl"))
        let manager = CodexEnvironmentManager(paths: .init(nativeHomeURL: native, yardletRootURL: yardlet))

        let environment = try await manager.processEnvironment(base: [
            "PATH": "/usr/bin", "CODEX_HOME": "/stale/isolated/home", "KEEP_SETTING": "yes"
        ]).values

        XCTAssertEqual(environment["CODEX_HOME"], root.path(percentEncoded: false) + "native")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["KEEP_SETTING"], "yes")
        XCTAssertEqual(try String(contentsOf: native.appending(path: "config.toml"), encoding: .utf8), config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: yardlet.path(percentEncoded: false)))
        let snapshot = await manager.currentSnapshot()
        XCTAssertNil(snapshot)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "yardlet codex 환경-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }
}
