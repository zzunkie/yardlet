import Foundation
import XCTest
@testable import NativeHarnessClient

/// The file change card's rows as the Codex app lists a patch. Change shapes follow the App Server
/// `FileUpdateChange` (absolute paths, hunks alone for an update, whole text for an added or
/// deleted file) and its statuses `inProgress`, `completed`, `failed` and `declined`.
final class CodexFileChangeCardTests: XCTestCase {
    private typealias Projection = CodexFileChangeCardProjection
    private let workspace = URL(filePath: "/Users/me/project", directoryHint: .isDirectory)

    private func change(_ path: String, _ type: String, _ diff: String?, movePath: String? = nil) -> JSONValue {
        var kind: [String: JSONValue] = ["type": .string(type)]
        if type == "update" { kind["move_path"] = movePath.map(JSONValue.string) ?? .null }
        var value: [String: JSONValue] = ["path": .string(path), "kind": .object(kind)]
        if let diff { value["diff"] = .string(diff) }
        return .object(value)
    }

    private func rows(_ changes: [JSONValue], status: String = "completed", finished: Bool = true) -> [Projection.Row] {
        Projection.rows(
            for: CodexFileChangeItem(changes: changes, status: status),
            isTurnFinished: finished,
            workspaceURL: workspace
        )
    }

    private var threeKinds: [JSONValue] {
        [
            change("/Users/me/project/Sources/App.swift", "update", "@@ -1,2 +1,2 @@\n-old\n+new\n keep\n"),
            change("/Users/me/project/notes.md", "add", "# Title\nBody\n"),
            change("/Users/me/project/old.txt", "delete", "gone\n")
        ]
    }

    func testEachKindAndStateReadsAsTheCodexAppNamesIt() {
        XCTAssertEqual(rows(threeKinds).map(\.verb), [
            L10n.string("Edited"), L10n.string("Created"), L10n.string("Deleted")
        ])
        XCTAssertEqual(rows(threeKinds).map(\.expandedTitle), [
            L10n.string("Edited file"), L10n.string("Created file"), L10n.string("Deleted file")
        ])
        XCTAssertEqual(rows(threeKinds, status: "inProgress", finished: false).map(\.verb), [
            L10n.string("Editing"), L10n.string("Creating"), L10n.string("Deleting")
        ])
        XCTAssertEqual(rows(threeKinds, status: "inProgress", finished: true).map(\.verb), [
            L10n.string("Stopped editing"), L10n.string("Stopped creating"), L10n.string("Stopped deleting")
        ])
        for status in ["declined", "failed"] {
            XCTAssertEqual(Set(rows(threeKinds, status: status).map(\.verb)), [L10n.string("Rejected")])
            XCTAssertEqual(rows(threeKinds, status: status).compactMap(\.expandedTitle), [])
        }
        XCTAssertEqual(rows(threeKinds, status: "inProgress", finished: false).compactMap(\.expandedTitle), [])
        XCTAssertEqual(L10n.string("Stopped editing", languageCode: "ko"), "편집 중지됨")
        XCTAssertEqual(L10n.string("Diff too large to preview", languageCode: "ko"), "변경 내용이 너무 커서 미리 볼 수 없습니다")
    }

    func testARowShowsTheFileNameItsCountsAndOpensTheFileItChanged() throws {
        let rows = rows(threeKinds + [
            change("/Users/me/project/a.swift", "update", "@@ -1 +1 @@\n-x\n+y\n", movePath: "/Users/me/project/Sources/b.swift"),
            change("/tmp/scratch.txt", "add", "one\n"),
            change("/Users/me/project/empty.txt", "update", "")
        ])
        XCTAssertEqual(rows.map(\.displayPath), [
            "Sources/App.swift", "notes.md", "old.txt", "Sources/b.swift", "/tmp/scratch.txt", "empty.txt"
        ])
        XCTAssertEqual(rows.map(\.fileName), ["App.swift", "notes.md", "old.txt", "b.swift", "scratch.txt", "empty.txt"])
        XCTAssertEqual(rows.map(\.id).first, "/Users/me/project/Sources/App.swift")
        XCTAssertEqual(rows.map(\.lineCounts), [
            Projection.LineCounts(additions: 1, deletions: 1), Projection.LineCounts(additions: 2, deletions: 0), Projection.LineCounts(additions: 0, deletions: 1),
            Projection.LineCounts(additions: 1, deletions: 1), Projection.LineCounts(additions: 1, deletions: 0), nil
        ])
        XCTAssertEqual(rows.map { $0.fileURL?.path(percentEncoded: false) }, [
            "/Users/me/project/Sources/App.swift", "/Users/me/project/notes.md", "/Users/me/project/old.txt",
            // A file outside the task's folder opens too, read-only in the files panel.
            "/Users/me/project/Sources/b.swift", "/tmp/scratch.txt", "/Users/me/project/empty.txt"
        ])
        XCTAssertEqual(rows[0].accessibilityValue, "\(L10n.string("Edited")), +1 −1")
        XCTAssertEqual(rows[5].accessibilityValue, L10n.string("Edited"))
        XCTAssertTrue(rows.allSatisfy(\.canExpand))
    }

    /// `item/fileChange/patchUpdated` replaces the whole list while the model writes. Rows keep the
    /// path as identity, so an opened row stays open; a later change to the same path replaces the
    /// earlier one where it stood, as the Codex app keys a patch by path.
    func testAPatchUpdateKeepsEachFileRowAndALaterChangeReplacesItInPlace() {
        let first = change("/Users/me/project/a.swift", "update", "@@ -1 +1 @@\n-a\n+b\n")
        let grown = change("/Users/me/project/a.swift", "update", "@@ -1 +1,2 @@\n-a\n+b\n+c\n")
        let other = change("/Users/me/project/b.swift", "add", "new\n")
        let before = rows([first], status: "inProgress", finished: false)
        let after = rows([grown, other], status: "inProgress", finished: false)
        XCTAssertEqual(before.map(\.id), ["/Users/me/project/a.swift"])
        XCTAssertEqual(after.map(\.id), ["/Users/me/project/a.swift", "/Users/me/project/b.swift"])
        XCTAssertEqual(after.first?.lineCounts, Projection.LineCounts(additions: 2, deletions: 1))

        let repeated = rows([first, other, grown])
        XCTAssertEqual(repeated.map(\.id), ["/Users/me/project/a.swift", "/Users/me/project/b.swift"])
        XCTAssertEqual(repeated.first?.change, grown)
        XCTAssertEqual(rows([.object(["kind": .string("add")]), first]).count, 1)
    }

    func testALargeDiffFoldsIntoANoticeAndTheCardCapsItsTotal() {
        // Lines of a hundred bytes, near what source diffs carry.
        let line = "+" + String(repeating: "x", count: 98) + "\n"
        let oversized = String(repeating: line, count: Projection.fileByteLimit / 100 + 1)
        let large = rows([
            change("/Users/me/project/big.swift", "update", "@@ -0,0 +1 @@\n" + oversized),
            change("/Users/me/project/legacy.swift", "update", nil)
        ])
        XCTAssertEqual(large.map(\.preview), [.tooLarge, .missing])
        XCTAssertEqual(large.map(\.lineCounts), [nil, nil])
        XCTAssertEqual(large.map(\.canExpand), [true, false])
        XCTAssertNil(large[0].expandedTitle)

        let nearlyFull = "@@ -0,0 +1 @@\n" + String(repeating: line, count: (Projection.fileByteLimit - 20) / 100)
        let files = (0..<5).map { change("/Users/me/project/f\($0).swift", "update", nearlyFull) }
        XCTAssertEqual(rows(files).map(\.preview), [.available, .available, .available, .available, .tooLarge])
    }

    func testThePreviewDropsHeadersKeepsLineNumbersAndSeparatesHunks() {
        let preview = Projection.preview(for: change(
            "/Users/me/project/App.swift", "update",
            "@@ -3,3 +3,3 @@\n keep\n-old\n+new\n@@ -20,2 +20,3 @@\n tail\n+added\n\\ No newline at end of file\n"
        ))
        XCTAssertEqual(preview.lines.map(\.kind), [.context, .deletion, .addition, .separator, .context, .addition])
        XCTAssertEqual(preview.lines.map(\.number), [3, 4, 4, nil, 20, 21])
        XCTAssertEqual(preview.lines.map(\.text), ["keep", "old", "new", "", "tail", "added"])
        XCTAssertEqual(preview.lines.map(\.id), Array(0..<6))
        XCTAssertEqual(preview.firstChangedLine, 4)
        XCTAssertEqual(preview.hiddenLineCount, 0)

        let deletedFirst = Projection.preview(for: change("/x", "update", "@@ -1,2 +1,1 @@\n-a\n b\n@@ -9 +8 @@\n-c\n+d\n"))
        XCTAssertEqual(deletedFirst.firstChangedLine, 8)

        let added = Projection.preview(for: change("/x", "add", "one\n\ntwo\n"))
        XCTAssertEqual(added.lines.map(\.kind), [.addition, .addition, .addition])
        XCTAssertEqual(added.lines.map(\.number), [1, 2, 3])
        XCTAssertEqual(added.lines.map(\.text), ["one", "", "two"])
        XCTAssertEqual(added.firstChangedLine, 1)

        let deleted = Projection.preview(for: change("/x", "delete", "gone\nagain\n"))
        XCTAssertEqual(deleted.lines.map(\.kind), [.deletion, .deletion])
        XCTAssertEqual(deleted.firstChangedLine, 1)

        XCTAssertEqual(Projection.preview(for: change("/x", "update", "")), .empty)
        XCTAssertEqual(Projection.preview(for: change("/x", "delete", "")), .empty)
    }

    func testThePreviewCountsTheLinesItLeavesOutAndCutsLongLines() {
        let manyLines = (1...(Projection.previewLineLimit + 5)).map { "line \($0)" }.joined(separator: "\n")
        let capped = Projection.preview(for: change("/x", "add", manyLines))
        XCTAssertEqual(capped.lines.count, Projection.previewLineLimit)
        XCTAssertEqual(capped.hiddenLineCount, 5)
        XCTAssertEqual(capped.lines.last?.number, Projection.previewLineLimit)

        let short = Projection.preview(for: change("/x", "add", "a\nb\nc\nd\n"), lineLimit: 3)
        XCTAssertEqual(short.lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(short.hiddenLineCount, 1)

        let long = String(repeating: "가", count: Projection.lineCharacterLimit + 10)
        let cut = Projection.preview(for: change("/x", "add", long))
        XCTAssertEqual(cut.lines.first?.text.count, Projection.lineCharacterLimit + 1)
        XCTAssertEqual(cut.lines.first?.text.last, "…")
    }

    func testOnlyAFileInsideTheTaskFolderCanBeOpened() {
        XCTAssertEqual(
            Projection.fileURL(for: "/Users/me/project/Sources/App.swift", workspaceURL: workspace)?.path(percentEncoded: false),
            "/Users/me/project/Sources/App.swift"
        )
        XCTAssertEqual(
            Projection.fileURL(for: "Sources/App.swift", workspaceURL: workspace)?.path(percentEncoded: false),
            "/Users/me/project/Sources/App.swift"
        )
        XCTAssertNil(Projection.fileURL(for: "/Users/me/project-other/App.swift", workspaceURL: workspace))
        XCTAssertNil(Projection.fileURL(for: "/Users/me/project/../secret", workspaceURL: workspace))
        XCTAssertNil(Projection.fileURL(for: "/Users/me/project", workspaceURL: workspace))
        XCTAssertNil(Projection.fileURL(for: "  ", workspaceURL: workspace))
    }
}
