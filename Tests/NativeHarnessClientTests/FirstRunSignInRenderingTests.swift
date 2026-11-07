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

    /// A start stopped for its sign-in stays on the new-task screen with the draft, says so beside
    /// the sign-in, and clears once the sign-in is done. Every harness whose reading stops a start
    /// draws here, and the chip of a login a status check could not vouch for.
    func testANewTaskStoppedForItsSignIn() throws {
        let directory = try WindowlessRender.directory("first-run-claude-qa")
        let language = ProcessInfo.processInfo.environment["QA_LANGUAGE"] ?? "en"
        let workspace = FileManager.default.temporaryDirectory.appending(path: "first-run-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // A runtime is known for its harness by its name.
        let agy = workspace.appending(path: "agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        let size = NSSize(width: 820, height: 330)
        let details: [(HarnessKind, String)] = [
            (.claudeCode, ProviderSignIn.neededHere(.claudeCode)),
            (.codex, ProviderSignIn.neededHere(.codex)),
            (.antigravityCLI, L10n.string("No Antigravity CLI credentials were found in macOS Keychain."))]
        for (harness, detail) in details {
            let store = ProviderConnectionStore()
            store.usesFixtureSnapshots = true
            func reading(_ state: AccountAuthState, label: String? = nil) -> HarnessAccountSnapshot {
                HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: nil, state: state,
                    accountLabel: label, detail: detail, credentialOwner: harness.displayName, checkedAt: Date(),
                    usage: [], canLogin: state != .signedIn, canLogout: state == .signedIn)
            }
            store.publishDefaults([reading(.signedOut)])
            let runtime = RuntimeSelectionStore(defaults: SuggestionVolatileDefaults(), discoversRuntimes: false,
                                                loadsPersistedSelections: false)
            let cli = harness == .antigravityCLI ? agy : URL(filePath: "/usr/bin/true")
            runtime.select(cli, for: harness)
            let project = Project(name: "yardlet-sandbox", primaryRoot: workspace)
            let draft = NewTaskDraft()
            draft.workspaceURL = workspace
            draft.projectID = project.id
            draft.harness = harness
            draft.text = "Explain the build"
            let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: cli))
            draft.complete(submission, succeeded: false, error: HarnessSignInRequired().localizedDescription)

            func page(_ appearance: WindowlessRender.Appearance) -> some View {
                NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtime,
                    connections: store, onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
                    onCreate: { _ in nil })
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in try WindowlessRender.hostedInBothAppearances("stopped-start-\(harness.rawValue)-\(language)",
                                                                        in: directory, size: size, content: page) {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
            }
            let host = WindowlessRender.Host(page(.light), size: size, appearance: .light)
            defer { host.close() }
            host.settle()
            XCTAssertEqual(draft.text, "Explain the build", "The draft stays")
            XCTAssertTrue(draft.creationFailed)
            store.publishDefaults([reading(.signedIn, label: "owner@example.test")])
            host.settle()
            XCTAssertFalse(draft.creationFailed, "Signed in, the stopped start no longer stands")
            XCTAssertEqual(draft.text, "Explain the build")
        }

        let unverified = AccountChoice(harness: .claudeCode, connection: nil, snapshot: HarnessAccountSnapshot(
            id: "claudeCode", harness: .claudeCode, providerID: nil, state: .unknown, accountLabel: "owner@example.test",
            detail: "", credentialOwner: "Claude Code", checkedAt: Date(), usage: [], canLogin: true, canLogout: false))
        let chipSize = NSSize(width: 320, height: 44)
        for capture in try WindowlessRender.hostedInBothAppearances("chip-unverified-\(language)", in: directory, size: chipSize, content: { appearance in
            let display = ProviderConnectionDisplay(choice: unverified)
            return ProviderConnectionControl(title: display.title, accessibilityTitle: display.accessibilityTitle) {}
                .padding(14).frame(width: chipSize.width, height: chipSize.height, alignment: .leading)
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
