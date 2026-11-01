import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Claude's provider notices: the cards on their own, and as the conversation draws them (images in
/// `.build/claude-provider-notices-qa`). The limit card is every harness's; a Codex one is drawn with
/// them.
@MainActor
final class ClaudeProviderNoticeRenderingTests: XCTestCase {
    /// The limit cards, compaction markers and the lines above the composer, in both appearances.
    /// Rendered without a window into `.build/claude-provider-notices-qa`.
    func testLimitCardsCompactionMarkersAndNoticeLinesRender() throws {
        let directory = try WindowlessRender.directory("claude-provider-notices-qa")
        let account = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode, providerID: nil,
            homePath: "/tmp/claude-work", credentialSelector: nil)
        let session = HarnessRateLimit(status: .rejected, window: .session,
            resetsAt: Date().addingTimeInterval(2 * 3_600), usedFraction: 1,
            message: "You've hit your session limit · resets 3pm (Asia/Seoul)")
        let model = HarnessRateLimit(status: .rejected, window: .model, model: "Fable",
            resetsAt: Date().addingTimeInterval(3 * 86_400))
        let latest = UUID(), armed = UUID()
        let store = ProviderConnectionStore()
        try store.save(account)
        let task = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Limit", connection: nil)
        let accounts = UsageLimitAccounts(session: task, store: store,
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false), others: [account])
        let notices = TaskProviderNotices(
            retry: HarnessProviderRetry(attempt: 3, maxRetries: 10, cause: .overloaded),
            limitWarning: HarnessRateLimit(status: .warning, window: .weekly,
                resetsAt: Date().addingTimeInterval(4 * 86_400), usedFraction: 0.91),
            autoContinueEntryID: armed,
            canContinue: true,
            accounts: { accounts }
        )
        // A Codex task stopped by its weekly limit, whose account holds two resets (D7: no reset
        // time, no other account).
        let resetsStore = ProviderConnectionStore()
        resetsStore.usesFixtureSnapshots = true
        resetsStore.publishDefaults([HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex",
            state: .signedIn, accountLabel: "codex@example.test", detail: "", credentialOwner: "", checkedAt: Date(),
            usage: [], usageResets: AccountUsageResets(availableCount: 2), canLogin: false, canLogout: true)])
        let resetContext = UsageResetContext(store: resetsStore,
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false))
        let codexNotices = TaskProviderNotices(canContinue: true, usageReset: {
            (resetsStore.choice(for: .codex, connection: nil), resetContext)
        })
        for appearance in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 18) {
                UsageLimitCard(entryID: UUID(), limit: HarnessRateLimit(status: .rejected,
                    message: "You've hit your usage limit. Upgrade to Pro, or try again later."),
                    isLatest: true, notices: codexNotices)
                UsageLimitCard(entryID: latest, limit: session, isLatest: true, notices: notices)
                UsageLimitCard(entryID: armed, limit: model, isLatest: true, notices: notices)
                UsageLimitCard(entryID: UUID(), limit: HarnessRateLimit(status: .rejected,
                    message: "You've hit your limit · resets 3pm"), isLatest: false, notices: notices)
                CompactionMarker(compaction: HarnessContextCompaction(phase: .started))
                CompactionMarker(compaction: HarnessContextCompaction(phase: .completed,
                    tokensBefore: 167_012, tokensAfter: 41_230))
                CompactionMarker(compaction: HarnessContextCompaction(phase: .failed,
                    message: "Conversation too long to summarize"))
                ProviderNoticeLines(notices: notices)
            }
            .padding(20)
            .frame(width: 720)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance)
            // ImageRenderer leaves AppKit-backed controls (the menu, the switch, the spinners) as
            // placeholders, so the view is also drawn through a hosting view that draws them.
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.frame.height, 400)
            try WindowlessRender.writePNG(WindowlessRender.capture(host), to:
                directory.appending(path: appearance == .dark ? "notices-dark.png" : "notices-light.png"))
        }
    }

    /// In the conversation, only the latest entry's limit card offers to continue, the armed one
    /// shows its switch on, and compactions read where they happened. Once the latest limit has
    /// reset, as for a task the person comes back to after it, that card offers Resume in place of
    /// the switch, and Resume continues from that card.
    func testTheConversationOffersToContinueOnlyFromTheLatestLimit() throws {
        let directory = try WindowlessRender.directory("claude-provider-notices-qa")
        let earlier = TranscriptEntry(content: .usageLimit(HarnessRateLimit(
            status: .rejected, window: .session, resetsAt: Date().addingTimeInterval(-3_600),
            message: "You've hit your session limit · resets 1pm"
        )))
        let waiting = TranscriptEntry(content: .usageLimit(HarnessRateLimit(
            status: .rejected, window: .weekly, resetsAt: Date().addingTimeInterval(2 * 86_400)
        )))
        let reset = TranscriptEntry(content: .usageLimit(HarnessRateLimit(
            status: .rejected, window: .session, resetsAt: Date().addingTimeInterval(-600),
            message: "You've hit your session limit · resets 3pm"
        )))
        func entries(endingWith latest: TranscriptEntry) -> [TranscriptEntry] {
            [
                TranscriptEntry(content: .user(text: "Summarize the open issues")),
                TranscriptEntry(content: .assistant(text: "Reading the tracker.", isStreaming: false)),
                earlier,
                TranscriptEntry(content: .user(text: "Continue")),
                TranscriptEntry(content: .compaction(HarnessContextCompaction(phase: .completed, tokensBefore: 167_012,
                                                                              tokensAfter: 41_230))),
                TranscriptEntry(content: .assistant(text: "There are three open issues.", isStreaming: false)),
                latest
            ]
        }
        var resumed: [UUID] = []
        let notices = TaskProviderNotices(autoContinueEntryID: waiting.id, canContinue: true,
                                          continueAfterReset: { resumed.append($0) })
        func conversation(endingWith latest: TranscriptEntry) -> TaskConversationView {
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
                                 entries: entries(endingWith: latest), sessionStatus: .ready,
                                 actions: ConversationActions(providerNotices: notices))
        }
        let sizes = [NSSize(width: 1_280, height: 920), NSSize(width: 920, height: 920)]
        for (latest, name) in [(waiting, "conversation"), (reset, "conversation-reset")] {
            for appearance in WindowlessRender.Appearance.allCases {
                for size in sizes {
                    let drawing = try ConversationDrawing.draw(conversation(endingWith: latest), size: size,
                                                               appearance: appearance)
                    try WindowlessRender.writePNG(drawing.capture.bitmap, to: directory.appending(
                        path: "\(name)-\(Int(size.width))-\(appearance.suffix).png"))
                    let listed = drawing.elements.map(\.description).joined(separator: "\n")
                    // The switch reads as one check box named by its label, as the parity switch does.
                    let switches = drawing.elements.filter { $0.role == "AXCheckBox" }
                    let resumes = drawing.elements.filter { $0.role == "AXButton" && $0.label == L10n.string("Resume") }
                    if latest.id == waiting.id {
                        XCTAssertEqual(switches.count, 1, listed)
                        XCTAssertEqual(switches.first?.value, "1", "the latest card is the armed one")
                        XCTAssertEqual(switches.first?.label, L10n.string("Auto-continue when limits reset"), listed)
                        XCTAssertTrue(resumes.isEmpty, "Nothing resumes before the reset\n\(listed)")
                    } else {
                        XCTAssertTrue(switches.isEmpty, "A reset that passed has nothing to wait for\n\(listed)")
                        XCTAssertEqual(resumes.count, 1, "Only the latest card resumes\n\(listed)")
                    }
                    // Both cards report their limit, and the compaction reads between them.
                    let images = drawing.elements.filter { $0.role == "AXImage" }.count
                    XCTAssertEqual(images, 2, listed)
                }
            }
        }

        let host = WindowlessRender.Host(
            conversation(endingWith: reset).frame(width: sizes[0].width, height: sizes[0].height, alignment: .top),
            size: sizes[0], appearance: .light)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Resume")))
        XCTAssertEqual(resumed, [reset.id])
    }
}
