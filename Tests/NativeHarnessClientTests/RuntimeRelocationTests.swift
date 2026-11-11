import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class RuntimeRelocationTests: XCTestCase {
    func testChatGPTCodexFollowsTheBundleToItsNewLayout() throws {
        let root = temporaryDirectory()
        let app = root.appending(path: "Applications/ChatGPT.app", directoryHint: .isDirectory)
        let old = app.appending(path: "Contents/Resources/codex")
        let moved = try executable(at: app.appending(path: "Contents/Resources/codex-cli/bin/codex"))

        XCTAssertEqual(RuntimeRelocation.successor(of: old, for: .codex), moved)
        // A runtime that still exists is never replaced, and other harnesses are not guessed.
        XCTAssertNil(RuntimeRelocation.successor(of: moved, for: .codex))
        XCTAssertNil(RuntimeRelocation.successor(of: old, for: .claudeCode))
        XCTAssertNil(RuntimeRelocation.successor(of: root.appending(path: "bin/codex"), for: .codex))
    }

    func testClaudeDesktopRuntimeContinuesWithTheNewestRemainingVersion() throws {
        let root = temporaryDirectory()
        let versions = root.appending(path: "Library/Application Support/Claude/claude-code", directoryHint: .isDirectory)
        let removed = versions.appending(path: "2.1.266/claude.app/Contents/MacOS/claude")
        _ = try executable(at: versions.appending(path: "2.1.280/claude.app/Contents/MacOS/claude"))
        let newest = try executable(at: versions.appending(path: "2.1.281/claude.app/Contents/MacOS/claude"))

        XCTAssertEqual(RuntimeRelocation.successor(of: removed, for: .claudeCode), newest)

        // Claude Desktop updates while Yardlet runs and deletes the version Yardlet chose.
        let suite = testDefaultsSuite("Yardlet.RuntimeRemovedWhileRunning")
        let selections = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), discoversRuntimes: false)
        selections.select(newest, for: .claudeCode)
        let update = try executable(at: versions.appending(path: "2.1.282/claude.app/Contents/MacOS/claude"))
        try FileManager.default.removeItem(at: versions.appending(path: "2.1.281"))
        XCTAssertEqual(selections.selectedURL(for: .claudeCode), update)
    }

    func testASavedChoiceFollowsAMovedBundledRuntime() throws {
        let root = temporaryDirectory()
        let app = root.appending(path: "Applications/ChatGPT.app", directoryHint: .isDirectory)
        let moved = try executable(at: app.appending(path: "Contents/Resources/codex-cli/bin/codex"))
        let suite = testDefaultsSuite("Yardlet.RuntimeRelocationTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(app.appending(path: "Contents/Resources/codex").path(percentEncoded: false),
                     forKey: "runtime.codex.executablePath")

        let store = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false)

        XCTAssertEqual(store.selectedURL(for: .codex), moved)
        XCTAssertEqual(defaults.string(forKey: "runtime.codex.executablePath"), moved.path(percentEncoded: false))
    }

    func testClaudeDiscoveryAndSavedChoiceFollowOnlyCompletedHashedPackages() throws {
        let root = temporaryDirectory()
        let versions = root.appending(path: "Library/Application Support/Claude/claude-code")
        let removed = versions.appending(path: "2.1.284/claude.app/Contents/MacOS/claude")
        let older = try executable(at: versions.appending(path: "2.1.283/claude.app/Contents/MacOS/claude"))
        let package = versions.appending(path: "2.1.286/f2326db61802")
        let newest = try executable(at: package.appending(path: "claude.app/Contents/MacOS/claude"))
        try Data().write(to: package.appending(path: ".verified"))
        _ = try executable(at: versions.appending(path: "2.1.287/unfinished/claude.app/Contents/MacOS/claude"))
        let wrongMarker = versions.appending(path: "2.1.288/not-a-marker")
        _ = try executable(at: wrongMarker.appending(path: "claude.app/Contents/MacOS/claude"))
        try FileManager.default.createDirectory(at: wrongMarker.appending(path: ".verified"), withIntermediateDirectories: true)
        let symlinkVersion = versions.appending(path: "2.1.289")
        try FileManager.default.createDirectory(at: symlinkVersion, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkVersion.appending(path: "linked"), withDestinationURL: package)

        XCTAssertEqual(RuntimeSelectionStore.claudeDesktopCandidates(home: root), [newest, older])
        XCTAssertEqual(RuntimeRelocation.successor(of: removed, for: .claudeCode), newest)
        let suite = testDefaultsSuite("Yardlet.HashedRuntime")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = "runtime.\(HarnessKind.claudeCode.rawValue).executablePath"
        defaults.set(removed.path, forKey: key)
        let selections = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false)
        XCTAssertEqual(selections.selectedURL(for: .claudeCode), newest)
        XCTAssertEqual(defaults.string(forKey: key), newest.path)
        XCTAssertNil(RuntimeRelocation.successor(of: newest, for: .claudeCode))
        XCTAssertNil(RuntimeRelocation.successor(of: root.appending(path: "bin/claude"), for: .claudeCode))
    }

    /// A task runs on its harness's current runtime whatever CLI it recorded (`AppModel.runtime(of:)`),
    /// so Codex tasks of one account share one adapter and one App Server. Restoring the index writes
    /// nothing; the row is pointed at the CLI when the task starts, and only the executable changes.
    /// A harness with no runtime leaves a task the path it recorded.
    func testTasksRunOnTheHarnessRuntimeWhateverCLITheyRecorded() async throws {
        let root = temporaryDirectory()
        let app = root.appending(path: "Applications/ChatGPT.app", directoryHint: .isDirectory)
        let current = try executable(at: app.appending(path: "Contents/Resources/codex-cli/bin/codex"))
        let older = try executable(at: root.appending(path: "bin/codex"))
        let present = try executable(at: root.appending(path: "bin/grok"))
        let gone = SessionRecord(harness: .codex, workspaceURL: root,
                                 runtimeExecutableURL: app.appending(path: "Contents/Resources/codex"),
                                 title: "Gone", providerSessionID: "thread-1", environmentScope: .yardlet)
        let kept = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: older,
                                 title: "Older", providerSessionID: "thread-2", environmentScope: .yardlet)
        let grokTask = SessionRecord(harness: .grokBuild, workspaceURL: root, runtimeExecutableURL: present,
                                     title: "Grok", providerSessionID: "grok-1")
        let repository = InMemorySessionRepository(sessions: [gone, kept, grokTask])
        let made = Box<[ObjectIdentifier: URL]>([:])
        let suite = testDefaultsSuite("Yardlet.RuntimeRelocationTests")
        let selections = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), discoversRuntimes: false)
        selections.select(current, for: .codex)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: selections,
            registry: HarnessRegistry(factory: { harness, url in
                let adapter = UnsupportedHarnessAdapter(kind: harness, executableURL: url)
                made.value[ObjectIdentifier(adapter)] = url
                return adapter
            }),
            transcriptRepository: FileTranscriptRepository(directoryURL: URL(filePath: "/nonexistent/transcripts")),
            restoresIndexOnLaunch: true
        )

        await model.restoreIndex()

        let records = { (sessions: [SessionRecord]) in Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.runtimeExecutableURL) }) }
        let recorded = records([gone, kept, grokTask])
        XCTAssertEqual(records(model.store.sessions), recorded, "Restoring the index writes nothing")
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(records(persisted), recorded)
        XCTAssertEqual(model.runtime(of: gone), current)
        XCTAssertEqual(model.runtime(of: kept), current, "A recorded CLI that exists is not run either")
        XCTAssertEqual(model.runtimeKey(of: gone), model.runtimeKey(of: kept))
        let first = await model.registryAdapter(for: gone)
        let second = await model.registryAdapter(for: kept)
        XCTAssertTrue(first as AnyObject === second as AnyObject, "Tasks of one account share one App Server")
        XCTAssertEqual(made.value[ObjectIdentifier(first as AnyObject)], current)
        XCTAssertEqual(model.runtime(of: grokTask), present, "A harness with no runtime leaves the recorded path")

        let started = await model.sessionWithCurrentRuntime(kept)
        XCTAssertEqual(started.runtimeExecutableURL, current)
        XCTAssertEqual(started.providerSessionID, "thread-2")
        XCTAssertEqual(started.environmentScope, .yardlet)
        let saved = try await repository.loadSessions()
        XCTAssertEqual(saved.first { $0.id == kept.id }?.runtimeExecutableURL, current)
        await model.shutdown()
    }

    /// A desktop app removes the CLI it bundles while Yardlet runs too, and the harness's runtime
    /// follows it, so whatever runs or asks a task's CLI between attaches does the same
    /// (`AppModel.runtime(of:)`): reading a detached task, its limits, a title request. Asking writes
    /// nothing to the task's row.
    func testAHarnessRuntimeRemovedWhileYardletRunsIsFollowedWithoutAnAttach() async throws {
        let root = temporaryDirectory()
        let app = root.appending(path: "Applications/ChatGPT.app", directoryHint: .isDirectory)
        let recorded = try executable(at: app.appending(path: "Contents/Resources/codex"))
        let task = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: recorded, title: "Codex",
                                 providerSessionID: "thread-1")
        // The CLI each adapter was made for. What the model asked for while the recorded CLI was there
        // (restoring the index reads the task's saved thread) is its own adapter and no concern here.
        let made = Box<[ObjectIdentifier: URL]>([:])
        let suite = testDefaultsSuite("Yardlet.RuntimeRelocationTests.running")
        let selections = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), discoversRuntimes: false)
        selections.select(recorded, for: .codex)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [task])),
            runtimeSelections: selections,
            registry: HarnessRegistry(factory: { harness, url in
                let adapter = UnsupportedHarnessAdapter(kind: harness, executableURL: url)
                made.value[ObjectIdentifier(adapter)] = url
                return adapter
            }),
            transcriptRepository: FileTranscriptRepository(directoryURL: URL(filePath: "/nonexistent/transcripts")),
            restoresIndexOnLaunch: true
        )
        await model.restoreIndex()
        XCTAssertEqual(model.runtime(of: task), recorded)

        // The ChatGPT app updates: the recorded CLI goes and the bundle's new layout holds it.
        try FileManager.default.removeItem(at: recorded)
        let moved = try executable(at: app.appending(path: "Contents/Resources/codex-cli/bin/codex"))

        XCTAssertEqual(model.runtime(of: task), moved)
        XCTAssertEqual(model.runtimeKey(of: task).executableURL, moved)
        let adapter = await model.registryAdapter(for: task)
        XCTAssertEqual(made.value[ObjectIdentifier(adapter as AnyObject)], moved,
                       "The adapter a detached task is read with runs the CLI that is there")
        let startedExecutable = await model.startedExecutable(of: task)
        XCTAssertEqual(startedExecutable, moved)
        XCTAssertEqual(model.store.sessions.first?.runtimeExecutableURL, recorded, "Asking leaves the row as it was")
        await model.shutdown()
    }

    private func executable(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url.standardizedFileURL
    }

    private func temporaryDirectory() -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "yardlet-relocation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.standardizedFileURL
    }
}
