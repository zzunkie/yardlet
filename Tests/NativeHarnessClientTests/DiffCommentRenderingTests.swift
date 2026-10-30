import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Diff comments drawn with no window on screen, light and dark, into `.build/diff-comments-qa/`:
///
/// - `diff-comments-*`: the review's file with two waiting comments under their lines (one on a deleted
///   line, one on two added lines), a new comment open under the line after them, and a comment across
///   the sides under the second hunk.
/// - `composer-comments-*`: the task composer with the "3 comments" chip beside the request.
/// - `claude-sent-comments-*`: a Claude Code message sent with comments: the request in the bubble and
///   the comment chip above it, none of the comment text.
@MainActor
final class DiffCommentRenderingTests: XCTestCase {
    private typealias Fixtures = DiffCommentTests

    private static func draft(comments: [DiffComment], text: String = "") -> TaskComposerDraft {
        let draft = TaskComposerDraft()
        draft.text = text
        draft.diffComments = comments
        return draft
    }

    private static let reviewComments: [DiffComment] = {
        let file = Fixtures.file
        let deleted = file.comment(from: Fixtures.lineID(.left, 41), to: Fixtures.lineID(.left, 41),
                                   workspaceRoot: "/work/app", body: "Why not keep the index check?")!
        return [Fixtures.comments[0], deleted, Fixtures.comments[1]]
    }()

    private func diff(_ draft: TaskComposerDraft, opening line: Int?) -> some View {
        DiffFileContent(
            file: Fixtures.file, width: 820, showsHeader: true, commentRoot: "/work/app",
            comments: Binding(get: { draft.diffComments }, set: { draft.diffComments = $0 }),
            newComment: line.map(DiffLineSelection.init(line:))
        )
    }

    func testTheDiffShowsItsCommentsUnderTheirLines() throws {
        let directory = try WindowlessRender.directory("diff-comments-qa")
        let size = NSSize(width: 820, height: 760)
        let newLine = Fixtures.lineID(.right, 43)
        let captures = try WindowlessRender.hostedInBothAppearances("diff-comments", in: directory, size: size) { appearance in
            diff(Self.draft(comments: Self.reviewComments), opening: newLine)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .textBackgroundColor))
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let draft = Self.draft(comments: Self.reviewComments)
        let host = WindowlessRender.Host(diff(draft, opening: newLine).frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        for drawn in [
            L10n.format("Local comment on lines %@ to %@", "R41", "R42"), "Return an error instead of nil.",
            L10n.format("Local comment on line %@", "L41"), "Why not keep the index check?",
            L10n.format("Local comment on lines %@ to %@", "L81", "R82"), "Use the logger.",
            L10n.format("Local comment on line %@", "R43"), L10n.string("Comment"), L10n.string("Cancel"),
            L10n.string("Delete"), L10n.string("You")
        ] {
            XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
        }

        // The first waiting card is the deleted line's: Delete removes it from the task's comments.
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Delete")), texts)
        host.settle()
        XCTAssertEqual(draft.diffComments, [Fixtures.comments[0], Fixtures.comments[1]])
        // Cancel closes the new comment and leaves the waiting ones.
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Cancel")))
        host.settle()
        let after = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertFalse(after.contains(L10n.format("Local comment on line %@", "R43")), after)
        XCTAssertEqual(draft.diffComments.count, 2)
    }

    func testAFileWithoutAFolderTakesNoComments() throws {
        let draft = Self.draft(comments: Self.reviewComments)
        let host = WindowlessRender.Host(
            DiffFileContent(file: Fixtures.file, width: 600, showsHeader: false, commentRoot: nil,
                            comments: Binding(get: { draft.diffComments }, set: { draft.diffComments = $0 }))
                .frame(width: 600, height: 400), size: NSSize(width: 600, height: 400))
        defer { host.close() }
        host.settle()
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertFalse(texts.contains("Return an error instead of nil."), texts)
    }

    func testTheComposerCountsTheWaitingCommentsAndRemovesThem() throws {
        let directory = try WindowlessRender.directory("diff-comments-qa")
        let size = NSSize(width: 760, height: 170)
        let captures = try WindowlessRender.hostedInBothAppearances("composer-comments", in: directory, size: size) { appearance in
            PromptComposer(harness: .claudeCode,
                           composerDraft: Self.draft(comments: Self.reviewComments, text: "Please address these."),
                           isRunning: false)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .bottom)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let draft = Self.draft(comments: Self.reviewComments, text: "Please address these.")
        let host = WindowlessRender.Host(
            PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false)
                .frame(width: size.width, height: size.height, alignment: .bottom), size: size)
        defer { host.close() }
        host.settle()
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(texts.contains(L10n.format("%lld attached comments", 3)), texts)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Remove comments attachment")), texts)
        host.settle()
        XCTAssertTrue(draft.diffComments.isEmpty)
        XCTAssertEqual(draft.text, "Please address these.")
        let after = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertFalse(after.contains(L10n.format("%lld attached comments", 3)), after)
    }

    func testAClaudeMessageSentWithCommentsShowsTheRequestAndTheChip() throws {
        let directory = try WindowlessRender.directory("diff-comments-qa")
        let sent = Fixtures.codexText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = [TranscriptEntry(content: .user(text: sent)),
                       TranscriptEntry(content: .assistant(text: "Both fixed.", isStreaming: false))]
        let size = NSSize(width: 760, height: 300)
        let timeline = ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                                latestTurnIsComplete: true))
        let captures = try WindowlessRender.hostedInBothAppearances("claude-sent-comments", in: directory, size: size) { appearance in
            timeline
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(timeline.frame(width: size.width, height: size.height, alignment: .top), size: size)
        defer { host.close() }
        host.settle(passes: 10)
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(texts.contains("Please address these."), texts)
        XCTAssertTrue(texts.contains(L10n.format("%lld attached comments", 2)), texts)
        for hidden in ["Diff comments", "User Comment", "Diff hunk", "Return an error instead of nil.", "## My request"] {
            XCTAssertFalse(texts.contains(hidden), "\(hidden) is drawn:\n\(texts)")
        }
    }
}
