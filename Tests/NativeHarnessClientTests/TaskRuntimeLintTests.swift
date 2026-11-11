import Foundation
import XCTest

/// Keeps a task's recorded CLI path from being run as it is. The CLI a task recorded can go while
/// Yardlet runs (a desktop app that bundles it removes the version when it updates), so whatever
/// starts a task's CLI, asks it something or looks up its adapter gets the CLI from
/// `AppModel+TaskRuntime.swift` (`runtime(of:)`, `registryAdapter(for:)`, `startedExecutable(of:)`),
/// which follows a missing one. A new feature that passes `runtimeExecutableURL` on as an executable
/// works until the next update of that app and then fails for every task that recorded the old path.
final class TaskRuntimeLintTests: XCTestCase {
    /// The one file that reads the recorded path to decide what runs.
    private static let owner = "AppModel+TaskRuntime.swift"

    private static let patterns = [
        // `executableURL: session.runtimeExecutableURL`, `requested: task.runtimeExecutableURL`
        #"(?<![A-Za-z])(?:executableURL|requested):\s*[\w.$?!]*\.runtimeExecutableURL\b"#,
        // `isProgram(session.runtimeExecutableURL)`
        #"\bisProgram\(\s*[\w.$?!]*\.runtimeExecutableURL\b"#
    ]

    func testOnlyTheResolverRunsATasksRecordedCLI() throws {
        let sources = try Self.sources()
        XCTAssertNotNil(sources[Self.owner], "The resolver was not scanned")
        XCTAssertFalse(try Self.uses(in: sources[Self.owner] ?? "").isEmpty, "The resolver no longer reads the recorded path")
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) where path != Self.owner {
            let found = try Self.uses(in: text)
            XCTAssertTrue(found.isEmpty,
                "\(path) runs a task's recorded CLI path as it is: \(found.joined(separator: " | ")). "
                    + "Ask AppModel+TaskRuntime.swift for the task's CLI instead.")
        }
    }

    func testTheScannerCatchesEachForm() throws {
        let sample = """
        let adapter = await registry.adapter(for: session.harness, executableURL: session.runtimeExecutableURL)
        let started = await registry.startedExecutable(for: .codex, requested: task.runtimeExecutableURL)
        guard ExecutableLookup.current.isProgram(session.runtimeExecutableURL) else { return }
        // executableURL: session.runtimeExecutableURL in a comment runs nothing
        let child = SessionRecord(harness: parent.harness, runtimeExecutableURL: parent.runtimeExecutableURL)
        let same = current.runtimeExecutableURL == saved.runtimeExecutableURL
        let adapter = await registry.adapter(for: session.harness, executableURL: runtime(of: session))
        """
        XCTAssertEqual(try Self.uses(in: sample).count, 3)
    }

    private static func uses(in source: String) throws -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        return lines.filter { line in
            let range = NSRange(line.startIndex..., in: line)
            return expressions.contains { $0.firstMatch(in: line, range: range) != nil }
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func sources() throws -> [String: String] {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NativeHarnessClient", directoryHint: .isDirectory).standardizedFileURL
        let rootPath = root.path(percentEncoded: false)
        var sources: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
            sources[path] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }
}
