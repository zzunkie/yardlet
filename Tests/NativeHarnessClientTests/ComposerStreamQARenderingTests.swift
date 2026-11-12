import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The task composer as the person sees it while working (2026-10-16): one "+" for adding files,
/// folders, commands and connectors; while a turn runs, the placeholder that says where Return
/// and ⌘Return send a message (and that Return queues while the task waits to move to another
/// account), and queue chips that say where each queued message goes. Images go
/// to `.build/composer-stream-qa/` in both appearances, with each composer's accessibility row.
@MainActor
final class ComposerStreamQARenderingTests: XCTestCase {
    private typealias F = ComposerUnificationFixtures

    /// One message Claude Code holds for its next step, and one Yardlet holds for the turn's end.
    private static let claudeQueue = [
        CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Use the staging database")]), state: .sent,
                              providerMessageID: "held-by-claude"),
        CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Then update the README")]))
    ]
    private static let waitingQueue = [
        CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Then deploy it")]))
    ]
    /// A task that moves to another account when its turn ends.
    private static let accountMove = TaskAccountMoveNotice(accountName: "work@example.test · Example Team", cancel: {})

    private static var scenarios: [ComposerUnificationFixtures.Scenario] {
        [
            .init(name: "composer-claude-idle", size: NSSize(width: 760, height: 150)) {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: F.draft("Fix the parser"),
                    providerSession: F.session(.claudeCode), providerCapabilities: F.claudeLiveCapabilities,
                    providerUsage: F.providerUsage, isProviderAttached: true, isRunning: false,
                    workspaceURL: F.workspace, actions: F.claudeActions))
            },
            .init(name: "composer-claude-running", size: NSSize(width: 760, height: 190)) {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: F.draft(""),
                    providerSession: F.session(.claudeCode, status: .running),
                    providerCapabilities: F.claudeLiveCapabilities, providerUsage: F.providerUsage,
                    isProviderAttached: true, isRunning: true, canSteer: true, codexQueue: claudeQueue,
                    workspaceURL: F.workspace, actions: F.claudeActions))
            },
            .init(name: "composer-codex-running", size: NSSize(width: 760, height: 190)) {
                AnyView(PromptComposer(harness: .codex, composerDraft: F.draft(""), modelCatalog: F.codexCatalog,
                    runLocation: .approveForMe, providerSession: F.session(.codex, status: .running),
                    isProviderAttached: true, isRunning: true, canSteer: true, codexQueue: waitingQueue,
                    codexHasThread: true, codexTokenUsage: F.codexTokenUsage, workspaceURL: F.workspace,
                    actions: F.codexActions))
            },
            .init(name: "composer-antigravity-running", size: NSSize(width: 760, height: 190)) {
                AnyView(PromptComposer(harness: .antigravityCLI, composerDraft: F.draft(""),
                    providerSession: F.session(.antigravityCLI, status: .running), isProviderAttached: true,
                    isRunning: true, codexQueue: waitingQueue, workspaceURL: F.workspace, actions: F.claudeActions))
            },
            .init(name: "composer-claude-moving-account", size: NSSize(width: 760, height: 220)) {
                AnyView(VStack(spacing: 8) {
                    TaskAccountMoveLine(notice: accountMove)
                    PromptComposer(harness: .claudeCode, composerDraft: F.draft(""),
                        providerSession: F.session(.claudeCode, status: .running),
                        providerCapabilities: F.claudeLiveCapabilities, providerUsage: F.providerUsage,
                        isProviderAttached: true, isRunning: true, canSteer: true, codexQueue: waitingQueue,
                        workspaceURL: F.workspace, actions: F.claudeActions)
                }
                .environment(\.taskAccountMove, accountMove))
            }
        ]
    }

    /// One "+" holds what the "@" button did: the bottom row has no second button, and the menu
    /// adds files or photos and folders before commands and connectors, as the Claude app's does.
    func testOnePlusAddsFilesFoldersCommandsAndConnectors() throws {
        let rows = try F.render(Self.scenarios[0], into: WindowlessRender.directory("composer-stream-qa"))
        let labels = rows.map(\.label)
        XCTAssertTrue(labels.contains(L10n.string("Add files and more")), "\(labels)")
        XCTAssertFalse(labels.contains("Add context"), "No separate @ button")
        XCTAssertEqual(labels.filter { $0 == L10n.string("Add files and more") }.count, 1)

        let size = NSSize(width: 280, height: 180)
        try WindowlessRender.hostedInBothAppearances("plus-menu", in: WindowlessRender.directory("composer-stream-qa"),
                                                     size: size) { appearance in
            ComposerMenuList(entries: ComposerPlusMenu.entries(
                carriesImages: true, connectors: ComposerConnectorList(rows: []),
                actions: .init(addFiles: {}, addFolder: {}, openCommands: {}, openConnectors: {})), onDismiss: {})
            .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }

        // A photo the harness carries is attached; any other file, and a photo it cannot carry, is
        // context, as the "@" button added it.
        let folder = FileManager.default.temporaryDirectory.appending(path: "plus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "shot.png"), notes = folder.appending(path: "notes.md")
        try Data("x".utf8).write(to: photo)
        try Data("x".utf8).write(to: notes)
        let claude = HarnessComposerInputPolicy(harness: .claudeCode, negotiatedImageInput: true)
        let added = PromptComposer.addedInputs([photo, notes], policy: claude)
        XCTAssertEqual(added.count, 2)
        if case .localImage = added[0] {} else { XCTFail("A photo is attached: \(added[0])") }
        if case .mention = added[1] {} else { XCTFail("A file is context: \(added[1])") }
        let textOnly = HarnessComposerInputPolicy(harness: .openCode, negotiatedImageInput: false)
        if case .mention = PromptComposer.addedInputs([photo], policy: textOnly).first {} else {
            XCTFail("A photo the harness cannot carry is context")
        }
    }

    func testTheComposerSaysWhereEachMessageGoesInBothAppearances() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        var rows: [String: [WindowlessRender.AccessibilityElement]] = [:]
        for scenario in Self.scenarios {
            rows[scenario.name] = try F.render(scenario, into: directory)
        }
        let labels = { (name: String) in rows[name]?.map(\.label) ?? [] }
        let values = { (name: String) in rows[name]?.map(\.value) ?? [] }
        let after = L10n.string("Send when this turn ends")
        // While a turn runs the field says where Return and ⌘Return send, in each harness's words.
        XCTAssertTrue(labels("composer-claude-running").contains(
            "↩ \(L10n.string("Deliver at the next step")) · ⌘↩ \(after)"), "\(labels("composer-claude-running"))")
        XCTAssertTrue(labels("composer-codex-running").contains(
            "↩ \(L10n.string("Add to the running task")) · ⌘↩ \(after)"))
        XCTAssertTrue(labels("composer-antigravity-running").contains("↩ \(after)"))
        // A task about to move to another account says so above the composer, and Return queues
        // what is sent meanwhile for after the move.
        XCTAssertTrue(labels("composer-claude-moving-account").contains(
            "↩ \(after) · ⌘↩ \(L10n.string("Deliver at the next step"))"), "\(labels("composer-claude-moving-account"))")
        XCTAssertTrue(values("composer-claude-moving-account").contains(
            L10n.format("Moving to %@ after this turn", Self.accountMove.accountName)))
        XCTAssertTrue(labels("composer-claude-moving-account").contains(L10n.string("Cancel account change")))
        // Each chip says where its message goes.
        let claudeChips = (rows["composer-claude-running"] ?? []).filter { $0.label.hasPrefix(L10n.string("Queue") + ", ") }
        XCTAssertEqual(claudeChips.map(\.label), [
            L10n.string("Queue") + ", " + L10n.string("Delivered · Claude reads it at its next step"),
            L10n.string("Queue") + ", " + after
        ])
        XCTAssertFalse(values("composer-codex-running").isEmpty)
        // A queued message offers "Send now" in words, in Claude Code and Codex; Antigravity sends
        // it when the turn ends.
        XCTAssertTrue(labels("composer-claude-running").contains(L10n.string("Send now")))
        XCTAssertTrue(labels("composer-codex-running").contains(L10n.string("Send now")))
        XCTAssertFalse(labels("composer-antigravity-running").contains(L10n.string("Send now")))
    }
}
