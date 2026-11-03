import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class NativeHarnessClientAppTests: XCTestCase {
    func testQuitWarningCancelLeavesActiveWorkUntouched() {
        let session = activeSession()
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(),
            restoresIndexOnLaunch: false
        )
        let delegate = NativeHarnessClientAppDelegate()
        delegate.model = model
        delegate.terminationPrompt = { _ in false }
        let resource = TestNativeSurfaceResource()
        NativeSurfaceResourceRegistry.shared.register(resource)
        defer { NativeSurfaceResourceRegistry.shared.stopAll() }

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(model.activeLocalSessions.map(\.id), [session.id])
        XCTAssertEqual(resource.stopCount, 0)
    }

    func testQuitWarningConfirmationRunsModelShutdown() async throws {
        let session = activeSession()
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(),
            initialCodexPresentation: [session.id: .empty],
            restoresIndexOnLaunch: false
        )
        let delegate = NativeHarnessClientAppDelegate()
        delegate.model = model
        delegate.terminationPrompt = { _ in true }

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        try await waitUntil { model.codexPresentationBySessionID.isEmpty }
        XCTAssertTrue(model.codexPresentationBySessionID.isEmpty)
    }

    func testConfirmedQuitStopsMountedNativeSurfaceResources() async throws {
        let session = activeSession()
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(),
            initialCodexPresentation: [session.id: .empty],
            restoresIndexOnLaunch: false
        )
        let resource = TestNativeSurfaceResource()
        NativeSurfaceResourceRegistry.shared.register(resource)
        defer { NativeSurfaceResourceRegistry.shared.stopAll() }

        let delegate = NativeHarnessClientAppDelegate()
        delegate.model = model
        delegate.terminationPrompt = { _ in true }

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        try await waitUntil { resource.stopCount != 0 }
        XCTAssertEqual(resource.stopCount, 1)
        // The resources stop before the model shuts down, which clears the presentations in its own time.
        try await waitUntil { model.codexPresentationBySessionID.isEmpty }
    }

    func testWillTerminateStopsMountedNativeSurfaceResources() {
        let delegate = NativeHarnessClientAppDelegate()
        let resource = TestNativeSurfaceResource()
        NativeSurfaceResourceRegistry.shared.register(resource)
        defer { NativeSurfaceResourceRegistry.shared.stopAll() }

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(resource.stopCount, 1)
    }

    func testWillTerminateStopsInteractiveAccountConsole() async throws {
        let controller = AccountLoginController()
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "sleep 120 & wait"],
                initialInput: nil
            )
        )
        let terminal = attachLoginTerminal(to: controller)
        defer { _ = terminal }
        try await waitUntil { controller.isRunning }
        XCTAssertTrue(controller.isRunning)

        let processID = try XCTUnwrap(controller.processIdentifier)
        var descendants: [pid_t] = []
        try await waitUntil {
            descendants = NativeProcessTree.descendantProcessIDs(of: processID)
            return !descendants.isEmpty
        }
        XCTAssertFalse(descendants.isEmpty)

        let delegate = NativeHarnessClientAppDelegate()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertFalse(controller.isRunning)
        try await waitUntil { !descendants.contains(where: { Darwin.kill($0, 0) == 0 }) }
        XCTAssertTrue(descendants.allSatisfy { Darwin.kill($0, 0) == -1 })
    }

    func testInteractiveAccountConsoleSendsInitialInputThroughPTY() async throws {
        let controller = AccountLoginController()
        defer { controller.stop() }
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'YARDLET_LOGIN_PROMPT\\n'; "
                        + "IFS= read -r answer; "
                        + "printf 'YARDLET_LOGIN_INPUT_OK\\n'"
                ],
                initialInput: "\r",
                initialInputTrigger: "YARDLET_LOGIN_PROMPT",
                usesPseudoTerminal: true
            )
        )
        // As the Account Center starts a sign-in: with the CLI details hidden. The CLI still gets a
        // screen its picker fits in; `agy` 1.4 draws its login method prompt on the tenth row, and
        // nothing at all in a terminal one row tall.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            AccountLoginConsoleTerminal(controller: controller, isVisible: false)
            Spacer(minLength: 0)
        })
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let terminal = try XCTUnwrap(window.contentView.flatMap(loginTerminal(in:)))
        XCTAssertGreaterThanOrEqual(terminal.getTerminal().rows, 10)

        try await waitUntil { controller.output.contains("YARDLET_LOGIN_INPUT_OK") }

        XCTAssertTrue(controller.output.contains("YARDLET_LOGIN_PROMPT"), controller.output)
        XCTAssertTrue(controller.output.contains("YARDLET_LOGIN_INPUT_OK"), controller.output)
    }

    func testInteractiveAccountConsoleSendsManualInputThroughPTY() async throws {
        let controller = AccountLoginController()
        defer { controller.stop() }
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'YARDLET_AUTH_CODE_PROMPT\\n'; "
                        + "IFS= read -r answer; "
                        + "if [ \"$answer\" = 'yardlet-one-time-code' ]; then "
                        + "printf 'YARDLET_MANUAL_INPUT_OK\\n'; fi"
                ],
                initialInput: nil,
                usesPseudoTerminal: true
            )
        )
        let terminal = attachLoginTerminal(to: controller)
        defer { _ = terminal }

        try await waitUntil { controller.output.contains("YARDLET_AUTH_CODE_PROMPT") }
        XCTAssertTrue(controller.output.contains("YARDLET_AUTH_CODE_PROMPT"), controller.output)
        XCTAssertTrue(controller.submitInput("  yardlet-one-time-code\n"))

        try await waitUntil { controller.output.contains("YARDLET_MANUAL_INPUT_OK") }
        XCTAssertTrue(controller.output.contains("YARDLET_MANUAL_INPUT_OK"), controller.output)
        XCTAssertFalse(controller.submitInput("   \n"))
    }

    func testGuidedAccountConnectionProjectsBrowserAndVerificationCode() async throws {
        let controller = AccountLoginController()
        defer { controller.stop() }
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'Open https://auth.example.test/device\\n'; "
                        + "printf 'Verification code: ABCD-EFGH\\n'; /bin/sleep 120"
                ],
                initialInput: nil
            )
        )
        let terminal = attachLoginTerminal(to: controller)
        defer { _ = terminal }

        try await waitUntil { controller.detectedURL != nil && controller.detectedCode != nil }

        XCTAssertEqual(controller.phase, .browserHandoff)
        XCTAssertEqual(controller.detectedURL?.absoluteString, "https://auth.example.test/device")
        XCTAssertEqual(controller.detectedCode, "ABCD-EFGH")
    }

    func testRuntimeOwnedPickerProjectsInputRequiredBeforeTerminalAttach() {
        let controller = AccountLoginController()
        defer { controller.stop() }
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/true"),
                arguments: [],
                initialInput: nil,
                interaction: .terminalRequired
            )
        )

        XCTAssertEqual(controller.phase, .inputRequired)
    }

    func testUnexpectedRuntimePickerEscapesGuidedPreparingState() async throws {
        let controller = AccountLoginController()
        defer { controller.stop() }
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'Login method\\n● Browser\\n○ API Key\\n'; /bin/sleep 120"
                ],
                initialInput: nil
            )
        )
        let terminal = attachLoginTerminal(to: controller)
        defer { _ = terminal }

        try await waitUntil { controller.phase != .preparing }

        XCTAssertEqual(controller.phase, .inputRequired)
    }

    func testInteractiveAccountConsoleCancelDrainsPseudoTerminalProcessTree() async throws {
        let controller = AccountLoginController()
        defer { controller.stop() }
        controller.start(
            AccountInteractiveCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' INT; /bin/sh -c 'trap \"\" INT; sleep 120' & wait"
                ],
                initialInput: nil,
                usesPseudoTerminal: true
            )
        )
        let terminal = attachLoginTerminal(to: controller)
        defer { _ = terminal }

        try await waitUntil { controller.isRunning }
        XCTAssertTrue(controller.isRunning)
        let processID = try XCTUnwrap(controller.processIdentifier)

        var descendants: [pid_t] = []
        try await waitUntil {
            descendants = NativeProcessTree.descendantProcessIDs(of: processID)
            return !descendants.isEmpty
        }
        XCTAssertFalse(descendants.isEmpty)

        controller.cancel()
        XCTAssertFalse(controller.isRunning)
        try await waitUntil { !([processID] + descendants).contains(where: { Darwin.kill($0, 0) == 0 }) }
        XCTAssertTrue(([processID] + descendants).allSatisfy { Darwin.kill($0, 0) == -1 })
    }

    private func loginTerminal(in view: NSView) -> AccountLoginTerminalView? {
        view as? AccountLoginTerminalView ?? view.subviews.lazy.compactMap(loginTerminal(in:)).first
    }

    private func attachLoginTerminal(
        to controller: AccountLoginController
    ) -> LocalProcessTerminalView {
        let view = AccountLoginTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 200)
        )
        controller.attach(view)
        return view
    }

    private func activeSession() -> SessionRecord {
        SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/quit-warning"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Active Codex task",
            status: .running
        )
    }

    @MainActor
    private final class TestNativeSurfaceResource: NativeSurfaceResource {
        private(set) var stopCount = 0

        func stop() {
            stopCount += 1
        }

        func terminateForApplicationShutdown() {
            stop()
        }
    }
}
