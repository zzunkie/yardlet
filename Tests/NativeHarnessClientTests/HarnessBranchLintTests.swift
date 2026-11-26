import Foundation
import XCTest

/// Keeps the screens free of harness comparisons (docs/ARCHITECTURE.md, "Checks that only tighten"):
/// the Mac views, the Windows app and the remote bridge read what differs between harnesses from a
/// projection (`ComposerSessionOptionsProjection` for the composer), so a difference is decided once
/// for all of them. A file named `…Projection.swift` is a projection and may compare. Existing
/// comparisons are listed per file and may only shrink.
final class HarnessBranchLintTests: XCTestCase {
    /// The folders that read projections instead of comparing harnesses.
    private static let folders = ["Views/", "WinUI/", "Remote/"]

    /// Existing comparisons, by file and count. Lower a count or remove the entry when a file
    /// loses one; never add one.
    private static let allowed: [String: Int] = [
        "Remote/AppModelRemoteBridge+Accounts.swift": 1,
        "Remote/AppModelRemoteBridge+FileRewind.swift": 1,
        "Remote/AppModelRemoteBridge+NextSteps.swift": 2,
        "Remote/AppModelRemoteBridge+Rail.swift": 2,
        "Remote/AppModelRemoteBridge+Schedules.swift": 6,
        "Remote/AppModelRemoteBridge+Settings.swift": 1,
        "Remote/AppModelRemoteBridge+Subtasks.swift": 1,
        "Remote/AppModelRemoteBridge+Suggestions.swift": 1,
        "Remote/AppModelRemoteBridge+TaskActions.swift": 1,
        "Remote/AppModelRemoteBridge+TaskControls.swift": 6,
        "Remote/AppModelRemoteBridge+UsageReset.swift": 2,
        "Remote/AppModelRemoteBridge.swift": 5,
        "Remote/Client/RemoteNewTaskForm.swift": 1,
        "Remote/Client/RemoteSuggestionOptions.swift": 1,
        "Views/AccountCenterView.swift": 3,
        "Views/AccountListView.swift": 2,
        "Views/AppShell/HomeSurface.swift": 1,
        "Views/AppShell/SidebarAccountMenu.swift": 1,
        "Views/AppShell/TaskHeader.swift": 1,
        "Views/AppShell/TaskSurface.swift": 6,
        "Views/ImportConversationSheet.swift": 3,
        "Views/MainWindow.swift": 6,
        "Views/OtherAppImportSheet.swift": 1,
        "Views/ProviderConnectionsView.swift": 4,
        "Views/Remote/RemoteHostWindow.swift": 1,
        "Views/Remote/RemoteNewTaskView.swift": 2,
        "Views/Remote/RemoteSchedules+Editing.swift": 3,
        "Views/Remote/RemoteTaskActionAlerts.swift": 2,
        "Views/Schedules/ScheduledTaskEditor.swift": 2,
        "Views/SessionRail/SessionRailHost.swift": 1,
        "WinUI/HarnessSignIn.swift": 3,
        "WinUI/ImportConversationPane.swift": 3,
        "WinUI/MainWindow.swift": 1,
        "WinUI/NewTaskPane.swift": 2,
        "WinUI/NewTaskParts.swift": 1,
        "WinUI/QAHarnessCheck.swift": 1,
        "WinUI/SidebarRows.swift": 1,
        "WinUI/TaskComposer.swift": 4,
        "WinUI/TaskHeader.swift": 1,
        "WinUI/TaskSource.swift": 1
    ]

    private static let patterns = [
        // `harness == .codex`, `session.harness != .claudeCode`, `$0.harness == x`
        #"\bharness\s*(?:==|!=)"#,
        // `.codex == harness`, `kind != session.harness`
        #"(?:==|!=)\s*[\w.$]*\bharness\b"#,
        // `switch harness`, `switch session.harness`
        #"\bswitch\s+[\w.$]*\bharness\b"#
    ]

    func testScreensDoNotCompareHarnesses() throws {
        let sources = try Self.sources()
        XCTAssertTrue(sources.keys.contains("Views/Composer/PromptComposer.swift"), "The composer was not scanned")
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            let found = try Self.comparisons(in: text)
            let allowed = Self.allowed[path] ?? 0
            XCTAssertLessThanOrEqual(found.count, allowed,
                "\(path) compares harnesses: \(found.joined(separator: " | ")). "
                    + "Read the harness's options from its projection instead.")
        }
    }

    func testAllowedComparisonsOnlyShrink() throws {
        let sources = try Self.sources()
        for (path, count) in Self.allowed.sorted(by: { $0.key < $1.key }) {
            guard let text = sources[path] else {
                XCTFail("\(path) is gone; remove it from the allowed comparisons")
                continue
            }
            XCTAssertEqual(try Self.comparisons(in: text).count, count,
                           "\(path) has fewer comparisons now; lower its allowance")
        }
    }

    func testTheScannerCatchesEachForm() throws {
        let sample = """
        if harness == .codex { }
        guard session.harness != .claudeCode else { return }
        let codex = sessions.filter { $0.harness == .codex }
        if .codex == draft.harness { }
        switch session.harness { default: break }
        // harness == .codex in a comment is not a comparison
        let options = Projection.make(harness: harness, session: session)
        """
        XCTAssertEqual(try Self.comparisons(in: sample).count, 5)
    }

    private static func comparisons(in source: String) throws -> [String] {
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
        for folder in folders {
            let directory = root.appending(path: folder, directoryHint: .isDirectory)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator
            where url.pathExtension == "swift" && !url.lastPathComponent.hasSuffix("Projection.swift") {
                let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
                sources[path] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return sources
    }
}
