import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What someone with Claude history and no Claude Code login sees on a first run, drawn in an unshown
/// window in both appearances into `.build/first-run-claude-qa`: the new-task account chip, the
/// account list and the failed turn. They draw in the Mac's language; `QA_LANGUAGE` names the files.
@MainActor final class FirstRunSignInRenderingTests: XCTestCase {
    func testTheSignedOutFirstRun() throws {
        let directory = try WindowlessRender.directory("first-run-claude-qa")
        let language = ProcessInfo.processInfo.environment["QA_LANGUAGE"] ?? "en"
        let store = ProviderConnectionStore()
        store.usesFixtureSnapshots = true
        store.publishDefaults([HarnessAccountSnapshot(id: "claudeCode", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "Claude Code", checkedAt: Date(),
            usage: [], canLogin: true, canLogout: false)])
        let choice = try XCTUnwrap(store.choices(for: [.claudeCode]).first)
        let runtime = RuntimeSelectionStore(discoversRuntimes: false)

        let chipSize = NSSize(width: 320, height: 44)
        for capture in try WindowlessRender.hostedInBothAppearances("chip-\(language)", in: directory, size: chipSize, content: { appearance in
            let display = ProviderConnectionDisplay(choice: choice)
            return ProviderConnectionControl(title: display.title, accessibilityTitle: display.accessibilityTitle) {}
                .padding(14).frame(width: chipSize.width, height: chipSize.height, alignment: .leading)
                .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme)
        }) { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1))) }

        let listSize = NSSize(width: 642, height: 240)
        for capture in try WindowlessRender.hostedInBothAppearances("account-row-\(language)", in: directory, size: listSize, content: { appearance in
            AccountList(mode: .newTask(.claudeCode), store: store, runtimeSelections: runtime, onChoose: { _ in },
                onConnect: { _ in }, onAdd: { _ in }, onManage: {}, maxListHeight: 200)
                .padding(16).frame(width: listSize.width, height: listSize.height, alignment: .top)
                .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme)
        }) { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1))) }

        let cardSize = NSSize(width: 640, height: 190)
        for capture in try WindowlessRender.hostedInBothAppearances("failed-turn-\(language)", in: directory, size: cardSize, content: { appearance in
            failedTurn.padding(16).frame(width: cardSize.width, height: cardSize.height, alignment: .top)
                .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme)
        }) { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1))) }
    }

    private var failedTurn: some View {
        TranscriptErrorCard(harness: .claudeCode, message: "Not logged in · Please run /login", recoverable: true,
            onEditRequest: {}, onShowHarnessSettings: {}, signIn: signInForRender)
    }

    private var signInForRender: ConversationSignIn? {
        ConversationSignIn(signIn: {}, moveTo: ("owner@example.test", {}))
    }
}
