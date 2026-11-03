import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Claude Code's Bypass permissions (`bypassPermissions`), offered since the user's decision of
/// 2026-10-12: one of the selector's modes wherever Claude's modes are offered, asked about first
/// as Codex's Full access is, drawn as elevated, launched with `--permission-mode`, and switched to
/// in a running session, which every launch allows with `--allow-dangerously-skip-permissions`.
@MainActor
final class ClaudeBypassPermissionTests: XCTestCase {
    private typealias Fixtures = ComposerUnificationFixtures

    func testBypassIsOneOfTheSelectorsModesWithItsOwnName() {
        XCTAssertEqual(ClaudePermissionMode.selectable,
                       ["manual", "plan", "acceptEdits", "auto", "dontAsk", "bypassPermissions"])
        XCTAssertEqual(ClaudePermissionMode.launchArgument(for: "bypassPermissions"), "bypassPermissions")
        XCTAssertTrue(ClaudePermissionMode.isElevated("bypassPermissions"))
        XCTAssertFalse(ClaudePermissionMode.selectable.dropLast().contains(where: ClaudePermissionMode.isElevated))
        XCTAssertEqual(L10n.string("Bypass permissions", languageCode: "en"), "Bypass permissions")
        XCTAssertEqual(L10n.string("Bypass permissions", languageCode: "ko"), "권한 우회")
        XCTAssertEqual(L10n.string("Bypass permission checks?", languageCode: "ko"), "권한 확인을 건너뛸까요?")
        XCTAssertEqual(L10n.string("Claude Code will change files and run commands without asking.", languageCode: "ko"),
                       "Claude Code가 묻지 않고 파일을 바꾸고 명령을 실행합니다.")
        XCTAssertEqual(L10n.string("Use bypass permissions", languageCode: "ko"), "권한 우회 사용")
    }

    // MARK: - Composer

    /// The connected task's menu, the menu of a task that has not connected yet, and the new-task
    /// screen offer the same six modes, and choosing Bypass permissions asks first.
    func testEveryClaudePermissionMenuOffersTheBypassAndAsksFirst() throws {
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: URL(filePath: "/tmp/claude-bypass-none/claude"),
            codexHome: URL(filePath: "/tmp/claude-bypass-none/codex"),
            codexYardletHome: URL(filePath: "/tmp/claude-bypass-none/y")), environment: [:])
        let attached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: nil, isAttached: true).permission)
        let notConnected = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode, options: ["permissionMode": "acceptEdits"]),
            providerCapabilities: Fixtures.claudeDetachedCapabilities, providerUsage: nil, isAttached: false).permission)
        let newTask = try XCTUnwrap(ComposerSessionOptionsProjection.newTask(
            harness: .claudeCode, choice: nil, catalogs: catalogs, connection: nil, workspaceURL: nil).permission)
        let expected = ComposerPermissionSlot.Confirmation(
            title: L10n.string("Bypass permission checks?"),
            message: L10n.string("Claude Code will change files and run commands without asking."),
            confirm: L10n.string("Use bypass permissions"))

        for (name, slot) in [("attached", attached), ("not connected", notConnected), ("new task", newTask)] {
            XCTAssertEqual(slot.selector?.choices.map(\.value), ClaudePermissionMode.selectable, name)
            XCTAssertEqual(slot.selector?.choices.last?.name, L10n.string("Bypass permissions"), name)
            XCTAssertEqual(slot.confirmations, ["bypassPermissions": expected], name)
            XCTAssertEqual(slot.apply.choice(id: "permissionMode", value: "bypassPermissions"),
                           .providerOption(id: "permissionMode", value: "bypassPermissions"), name)
            XCTAssertFalse(slot.isElevated, name)
        }
        // Before it connects, the menu names the saved mode and reads the CLI's own before choosing.
        XCTAssertEqual(notConnected.title, L10n.string("Accept edits"))
        XCTAssertFalse(notConnected.canChoose)
        XCTAssertTrue(notConnected.preparesBeforeOpening)
        XCTAssertNil(notConnected.explanation)

        // Another provider's policies ask nothing new.
        XCTAssertTrue(try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: Fixtures.acpCapabilities,
            providerUsage: nil, isAttached: true).permission).confirmations.isEmpty)
        // Codex's Full access keeps its own words.
        XCTAssertEqual(Array(ComposerSessionOptionsProjection.codexPermission(.askForApproval, config: .init()).confirmations.keys),
                       ["dangerFullAccess"])
    }

    func testTheBypassIsDrawnAsElevatedInEveryMenu() throws {
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: URL(filePath: "/tmp/claude-bypass-none/claude"),
            codexHome: URL(filePath: "/tmp/claude-bypass-none/codex"),
            codexYardletHome: URL(filePath: "/tmp/claude-bypass-none/y")), environment: [:])
        let attached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Self.liveCapabilities(mode: "bypassPermissions"),
            providerUsage: nil, isAttached: true).permission)
        let notConnected = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode, options: ["permissionMode": "bypassPermissions"]),
            providerCapabilities: Fixtures.claudeDetachedCapabilities, providerUsage: nil, isAttached: false).permission)
        let newTask = try XCTUnwrap(ComposerSessionOptionsProjection.newTask(
            harness: .claudeCode, choice: NewTaskModelChoice(model: nil, permissionMode: "bypassPermissions"),
            catalogs: catalogs, connection: nil, workspaceURL: nil).permission)
        for (name, slot) in [("attached", attached), ("not connected", notConnected), ("new task", newTask)] {
            XCTAssertEqual(slot.title, L10n.string("Bypass permissions"), name)
            XCTAssertTrue(slot.isElevated, name)
        }
        // Read from the value too, so the Korean name, which says neither "full" nor "bypass", is orange.
        XCTAssertFalse(ConversationSessionStatusProjection.isElevatedPermission("권한 우회"))
    }

    /// The composer's permission control is orange with the bypass on and not with Accept edits,
    /// in both appearances. Review images: `.build/claude-bypass-qa/`.
    func testTheComposerDrawsTheBypassInOrange() throws {
        let directory = try WindowlessRender.directory("claude-bypass-qa")
        var orange: [String: Int] = [:]
        for mode in ["acceptEdits", "bypassPermissions"] {
            let captures = try WindowlessRender.hostedInBothAppearances("composer-\(mode)", in: directory,
                                                                        size: NSSize(width: 760, height: 150)) {
                PromptComposer(harness: .claudeCode, composerDraft: Fixtures.draft("Fix it"),
                    providerSession: Fixtures.session(.claudeCode), providerCapabilities: Self.liveCapabilities(mode: mode),
                    providerUsage: Fixtures.providerUsage, isProviderAttached: true, isRunning: false,
                    actions: Fixtures.claudeActions)
                    .environment(\.colorScheme, $0.colorScheme)
                    .frame(width: 760, height: 150, alignment: .bottom)
                    .background(ParityTheme.canvas)
            }
            for (appearance, capture) in zip(WindowlessRender.Appearance.allCases, captures) {
                orange["\(mode)-\(appearance.suffix)"] = Self.orangePixels(in: capture.bitmap)
            }
        }
        for appearance in WindowlessRender.Appearance.allCases {
            XCTAssertEqual(orange["acceptEdits-\(appearance.suffix)"], 0, appearance.suffix)
            XCTAssertGreaterThan(orange["bypassPermissions-\(appearance.suffix)"] ?? 0, 20, appearance.suffix)
        }
    }

    // MARK: - Harness settings sheet

    func testTheHarnessSettingsSheetAsksBeforeTheBypassToo() throws {
        let content = HarnessSettingsSheetProjection.providerContent(Self.liveCapabilities(mode: "manual"), canBranch: false)
        let control = try XCTUnwrap(content.controls.first { $0.id == "option.permissionMode" })
        guard case let .selector(_, choices) = control.kind else { return XCTFail("The mode is a selector") }
        XCTAssertEqual(choices.map(\.id), ClaudePermissionMode.selectable)
        XCTAssertEqual(choices.last?.confirmation,
                       ComposerSessionOptionsProjection.claudePermissionConfirmations["bypassPermissions"])
        XCTAssertTrue(choices.dropLast().allSatisfy { $0.confirmation == nil })
        let model = try XCTUnwrap(content.controls.first { $0.id == "option.model" })
        guard case let .selector(_, models) = model.kind else { return XCTFail("The model is a selector") }
        XCTAssertTrue(models.allSatisfy { $0.confirmation == nil })
    }

    // MARK: - The CLI's announcement

    /// The mode the CLI reports back, in its handshake or its announcement, is the selector's own
    /// value, so a session switched to the bypass shows it and keeps it.
    func testTheAnnouncedBypassRoundTripsToTheSelector() async throws {
        XCTAssertEqual(ClaudeProtocol.initialPermissionMode(in: .object([
            "current_permission_mode": .string("bypassPermissions")
        ])), "bypassPermissions")
        XCTAssertEqual(ClaudeProtocol.announcedPermissionMode(in: Self.announcement("bypassPermissions")),
                       "bypassPermissions")

        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let started = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(started.selectors.first { $0.id == "permissionMode" }?.currentValue, "manual")

        await transport.emit(Self.announcement("bypassPermissions"))
        let deadline = ContinuousClock.now + testWaitLimit
        var mode: String?
        while ContinuousClock.now < deadline {
            mode = try await adapter.providerCapabilities(for: handle).selectors
                .first { $0.id == "permissionMode" }?.currentValue
            if mode == "bypassPermissions" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(mode, "bypassPermissions")
        let state = try await adapter.providerCapabilities(for: handle)
        let selector = try XCTUnwrap(state.selectors.first { $0.id == "permissionMode" })
        XCTAssertEqual(ProviderCapabilityAccessibility.selectedChoiceName(for: selector), L10n.string("Bypass permissions"))
        XCTAssertFalse(state.notes.contains { $0.localizedCaseInsensitiveContains("bypass") },
                       "The old never-offered note is gone")

        // Leaving it is the same mode change, back to Manual.
        _ = try await adapter.setProviderOption(id: "permissionMode", value: "manual", in: handle)
        let requests = await transport.requestedValues
        XCTAssertEqual(requests.last { $0["request"]?["subtype"]?.stringValue == "set_permission_mode" }?["request"]?["mode"],
                       .string("manual"))
        await adapter.close(handle)
    }

    // MARK: - Helpers

    private static func liveCapabilities(mode: String) -> ProviderCapabilityState {
        var state = Fixtures.claudeLiveCapabilities
        if let index = state.selectors.firstIndex(where: { $0.id == "permissionMode" }) {
            state.selectors[index].currentValue = mode
        }
        return state
    }

    private static func announcement(_ mode: String) -> JSONValue {
        .object([
            "type": .string("system"), "subtype": .string("status"), "status": .null,
            "permissionMode": .string(mode), "uuid": .string(UUID().uuidString.lowercased()),
            "session_id": .string("claude-session")
        ])
    }

    /// Orange pixels, the elevated control's tint: red well above blue and above green. The rest
    /// of the composer is drawn in grays.
    private static func orangePixels(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                if red > 0.6, red - blue > 0.4, red - green > 0.15 { count += 1 }
            }
        }
        return count
    }
}
