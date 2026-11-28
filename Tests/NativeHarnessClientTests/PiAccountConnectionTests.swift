import AppKit
import Darwin
import Foundation
@preconcurrency import SwiftTerm
import XCTest
@testable import NativeHarnessClient

@MainActor
final class PiAccountConnectionTests: XCTestCase {
    func testPiConsoleTitleIncludesTheHarnessOnlyOnce() {
        var connection = ProviderConnection(id: "pi-test", name: "Pi", harness: .pi,
            providerID: "openai-codex", homePath: nil, credentialSelector: nil)
        XCTAssertEqual(connection.consoleTitle, "Pi")
        connection.name = "Work"
        XCTAssertEqual(connection.consoleTitle, "Work · Pi")
    }

    func testFailedPiProbeKeepsTheChosenProviderIdentity() async throws {
        let fixture = try PiAccountFixture()
        defer { fixture.remove() }
        try fixture.setProbe("invalid json", exitCode: 2)
        let connection = ProviderConnection(id: "anthropic", name: "Anthropic", harness: .pi,
            providerID: "anthropic", homePath: fixture.root.path, credentialSelector: nil)
        let result = await HarnessAccountBroker(connection: connection).snapshot(
            for: HarnessCatalog.descriptor(for: .pi)!, executableURL: fixture.executable)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.detail, L10n.string("Account status could not be confirmed."))
        XCTAssertEqual(result.providerID, "anthropic")
        XCTAssertFalse(result.canLogout)
    }

    func testPiProbeDistinguishesMissingCredentialsFromInvalidOrUnrecognizedState() async throws {
        let fixture = try PiAccountFixture()
        defer { fixture.remove() }
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .pi))
        let broker = HarnessAccountBroker(connection: ProviderConnection(id: "pi-test", name: "Test", harness: .pi, providerID: "openai-codex", homePath: nil, credentialSelector: nil))
        let cases: [(String, Int, AccountAuthState)] = [
            (#"{"status":"ready","provider":"openai-codex","authType":"oauth"}"#, 0, .signedIn),
            (#"{"status":"not_ready","provider":"openai-codex","reason":"credentials_not_configured"}"#, 1, .signedOut),
            (#"{"status":"invalid","provider":"openai-codex","reason":"invalid_state"}"#, 2, .unknown),
            (#"{"status":"not_ready","provider":"openai-codex","reason":"provider_not_found"}"#, 1, .unknown),
            (#"{"status":"ready","provider":"another-provider"}"#, 0, .unknown),
            (#"{"status":"ready","provider":"openai-codex"}"#, 2, .unknown),
            (#"{}"#, 0, .unknown),
            ("invalid json", 2, .unknown)
        ]
        for (output, exitCode, expected) in cases {
            try fixture.setProbe(output, exitCode: exitCode)
            let snapshot = await broker.snapshot(for: descriptor, executableURL: fixture.executable)
            XCTAssertEqual(snapshot.state, expected, output)
            if expected == .signedIn || expected == .signedOut {
                XCTAssertTrue(snapshot.detail.contains(ProviderConnection.providerDisplayName("openai-codex")))
            }
            XCTAssertEqual(snapshot.id, "pi:openai-codex", output)
            XCTAssertEqual(snapshot.canLogout, expected == .signedIn, output)
        }
        let unavailable = await broker.snapshot(for: descriptor, executableURL: nil)
        XCTAssertEqual(unavailable.id, "pi:openai-codex")
        XCTAssertEqual(unavailable.state, .unavailable)
    }

    func testPiLoginFinishesFromReadOnlyProbeWhileInteractiveRuntimeStaysOpen() async throws {
        let fixture = try PiAccountFixture()
        defer { fixture.remove() }
        let selections = try fixture.selections()
        let store = ProviderConnectionStore()
        let model = AccountCenterModel(connections: store)
        defer { model.closeConsole() }
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .pi))
        await model.login(descriptor: descriptor, connection: ProviderConnection(id: "pi-test", name: "Test", harness: .pi, providerID: "openai-codex", homePath: nil, credentialSelector: nil), runtimeSelections: selections)
        let terminal = attach(model.loginController)
        defer { _ = terminal }
        try await waitUntil { fixture.loginStarted }
        XCTAssertEqual(model.loginController.phase, .browserHandoff)
        let pid = try XCTUnwrap(model.loginController.processIdentifier)

        try fixture.setProbe(#"{"status":"invalid","provider":"openai-codex","reason":"invalid_state"}"#, exitCode: 2)
        try await waitUntil { store.defaultSnapshots[.pi]?.state == .unknown }
        XCTAssertTrue(model.loginController.isRunning)

        try fixture.setProbe(#"{"status":"ready","provider":"openai-codex","authType":"oauth"}"#, exitCode: 0)
        try await waitUntil { model.loginController.phase == .completed }
        XCTAssertFalse(model.loginController.isRunning)
        XCTAssertEqual(store.defaultSnapshots[.pi]?.state, .signedIn)
        XCTAssertNil(model.loginController.detectedURL)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        let commands = try String(contentsOf: fixture.root.appending(path: "probe-arguments"), encoding: .utf8)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.split(separator: "\n").allSatisfy {
            $0 == "auth check --provider openai-codex --json --no-refresh"
        })
    }

    func testClosingPiLoginRejectsLateProbeAndDoesNotCompleteNewConsole() async throws {
        let fixture = try PiAccountFixture()
        defer { fixture.remove() }
        let selections = try fixture.selections()
        let gate = PiProbeGate()
        let store = ProviderConnectionStore(defaultLoader: { descriptor, _ in
            await gate.load(descriptor)
        })
        let model = AccountCenterModel(connections: store)
        defer { model.closeConsole() }
        await model.login(descriptor: HarnessCatalog.descriptor(for: .pi)!, connection: ProviderConnection(id: "pi-test", name: "Test", harness: .pi, providerID: "openai-codex", homePath: nil, credentialSelector: nil), runtimeSelections: selections)
        let terminal = attach(model.loginController)
        defer { _ = terminal }
        try await waitUntil { await gate.isWaiting }
        let isWaiting = await gate.isWaiting
        XCTAssertTrue(isWaiting)
        model.closeConsole()
        model.seedConnectionFlow(harness: .grokBuild, command: AccountInteractiveCommand(
            executableURL: URL(filePath: "/usr/bin/true"), arguments: [], initialInput: nil
        ))
        await gate.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.activeHarness, .grokBuild)
        XCTAssertEqual(model.loginController.phase, .preparing)
        XCTAssertNil(store.defaultSnapshots[.pi])
    }

    func testSlowInitialRefreshDoesNotOverwriteVerifiedPiConnection() async throws {
        let fixture = try PiAccountFixture()
        defer { fixture.remove() }
        let selections = try fixture.selections()
        let gate = PiProbeGate(firstState: .signedOut)
        let store = ProviderConnectionStore(defaultLoader: { descriptor, _ in
            await gate.load(descriptor)
        })
        let model = AccountCenterModel(connections: store)
        defer { model.closeConsole() }
        let refresh = Task { await store.check(savedOf: [], policy: .refresh, runtimeSelections: selections) }
        try await waitUntil { await gate.isWaiting }
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .pi))
        await model.login(descriptor: descriptor, connection: ProviderConnection(id: "pi-test", name: "Test", harness: .pi, providerID: "openai-codex", homePath: nil, credentialSelector: nil), runtimeSelections: selections)
        let terminal = attach(model.loginController)
        defer { _ = terminal }
        try await waitUntil { model.loginController.phase == .completed }
        await gate.release()
        await refresh.value
        XCTAssertEqual(store.defaultSnapshots[.pi]?.state, .signedIn)
        XCTAssertTrue(store.checkingKeys.isEmpty)
    }

    func testRefreshDuringPiProbeDoesNotAbandonLoginCompletion() async throws {
        let fixture = try PiAccountFixture()
        defer { fixture.remove() }
        let selections = try fixture.selections()
        let gate = PiProbeGate(firstState: .signedOut)
        let store = ProviderConnectionStore(defaultLoader: { descriptor, _ in
            await gate.load(descriptor)
        })
        let model = AccountCenterModel(connections: store)
        defer { model.closeConsole() }
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .pi))
        await model.login(descriptor: descriptor, connection: ProviderConnection(id: "pi-test", name: "Test", harness: .pi, providerID: "openai-codex", homePath: nil, credentialSelector: nil), runtimeSelections: selections)
        let terminal = attach(model.loginController)
        defer { _ = terminal }
        try await waitUntil { await gate.isWaiting }
        await store.check(savedOf: [], policy: .refresh, runtimeSelections: selections)
        await gate.release()
        try await waitUntil { model.loginController.phase == .completed }
        XCTAssertEqual(store.defaultSnapshots[.pi]?.state, .signedIn)
    }


    func testSuccessfulLogoutExitImmediatelyStartsTheNextLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\nexec /bin/sleep 120\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .claudeCode))
        let runtime = RuntimeSelectionStore(defaults: SuggestionVolatileDefaults(), discoversRuntimes: false,
                                            loadsPersistedSelections: false)
        runtime.select(cli, for: .claudeCode)
        let model = AccountCenterModel(connections: ProviderConnectionStore())
        defer { model.closeConsole() }
        await model.logout(descriptor: descriptor, signsInAfter: true, runtimeSelections: runtime)
        let controller = model.loginController
        let signOutID = controller.commandID
        let terminal = attach(controller)
        XCTAssertEqual(controller.operation, .disconnect)
        controller.processTerminated(source: terminal, exitCode: 0)
        XCTAssertNotEqual(controller.commandID, signOutID)
        XCTAssertEqual(controller.operation, .connect)
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(model.showsLoginDetails)
    }

    private func attach(_ controller: AccountLoginController) -> LocalProcessTerminalView {
        let view = AccountLoginTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 200)
        )
        controller.attach(view)
        return view
    }
}

private struct PiAccountFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var executable: URL { root.appending(path: "pi") }
    var loginStarted: Bool { FileManager.default.fileExists(atPath: root.appending(path: "login-started").path) }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        fixture_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ "$1" = "auth" ]; then
            printf '%s\\n' "$*" >> "$fixture_root/probe-arguments"
            cat "$fixture_root/state.json"
            exit "$(cat "$fixture_root/exit-code")"
        fi
        printf 'Open https://auth.example.test/device\\n'
        IFS= read -r input
        [ "$input" = '/login openai-codex' ] || exit 3
        touch "$fixture_root/login-started"
        /bin/sleep 120 & wait
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try setProbe(#"{"status":"not_ready","provider":"openai-codex","reason":"credentials_not_configured"}"#, exitCode: 1)
    }

    func setProbe(_ text: String, exitCode: Int) throws {
        try Data(text.utf8).write(to: root.appending(path: "state.json"), options: .atomic)
        try Data(String(exitCode).utf8).write(to: root.appending(path: "exit-code"), options: .atomic)
    }

    @MainActor func selections() throws -> RuntimeSelectionStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("PiAccountConnectionTests")))
        let store = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        store.select(executable, for: .pi)
        return store
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor PiProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var requests = 0
    private let firstState: AccountAuthState
    var isWaiting: Bool { continuation != nil }

    init(firstState: AccountAuthState = .signedIn) { self.firstState = firstState }

    func load(_ descriptor: HarnessDescriptor) async -> HarnessAccountSnapshot {
        guard descriptor.id == .pi else { return .unavailable(for: descriptor) }
        requests += 1
        let state = requests == 1 ? firstState : .signedIn
        if requests == 1 { await withCheckedContinuation { continuation = $0 } }
        return HarnessAccountSnapshot(
            id: "pi:openai-codex", harness: .pi, providerID: "openai-codex", state: state,
            accountLabel: nil, detail: "Ready", credentialOwner: "Pi", checkedAt: Date(),
            usage: [], canLogin: state != .signedIn, canLogout: state == .signedIn
        )
    }

    func release() { continuation?.resume(); continuation = nil }
}
