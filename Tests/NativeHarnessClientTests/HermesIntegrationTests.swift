import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class HermesIntegrationTests: XCTestCase {
    func testHermesUsesOfficialACPAndRuntimeOwnedProviderSetup() async throws {
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .hermes))
        XCTAssertEqual(descriptor.transport, .acp)
        XCTAssertEqual(descriptor.executableName, "hermes")
        XCTAssertEqual(descriptor.launchArguments, ["acp"])
        XCTAssertTrue(descriptor.relativeExecutablePaths.contains(".local/bin/hermes"))
        let executable = URL(filePath: "/tmp/hermes")
        let adapter = await HarnessRegistry().adapter(for: .hermes, executableURL: executable)
        let routed = try XCTUnwrap(adapter as? YHPProviderCompatibilityAdapter)
        XCTAssertEqual(routed.protocolManifest.adapterID, "com.yardlet.compat.acp.hermes-agent")

        let broker = HarnessAccountBroker()
        let command = await broker.loginCommand(for: .hermes, executableURL: executable)
        XCTAssertEqual(command?.arguments, ["acp", "--setup"])
        XCTAssertNil(command?.initialInput)
        XCTAssertEqual(command?.interaction, .terminalRequired)
        let logout = await broker.logoutCommand(for: .hermes, executableURL: executable)
        XCTAssertNil(logout)
        XCTAssertEqual(AccountConnectionPresentation.connectAction(for: .hermes), L10n.string("Connect provider"))
        XCTAssertEqual(AccountConnectionPresentation.providerTitle(for: .hermes), L10n.string("Hermes provider setup"))
    }

    func testHermesDoesNotExecuteImportChecksOrMutatingAuthCommandsAsAccountEvidence() async throws {
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .hermes))
        // An installed runtime with no safe aggregate account query is unknown.
        // Even an unlaunchable URL must not trigger auth status/pool healing or
        // turn an ACP import check's success into a connected account.
        let snapshot = await HarnessAccountBroker().snapshot(
            for: descriptor, executableURL: URL(filePath: "/missing/hermes")
        )
        XCTAssertEqual(snapshot.harness, .hermes)
        XCTAssertEqual(snapshot.state, .unknown)
        XCTAssertTrue(snapshot.canLogin)
        XCTAssertFalse(snapshot.canLogout)
        XCTAssertEqual(snapshot.detail, L10n.string("Account status could not be confirmed."))
        let missing = await HarnessAccountBroker().snapshot(for: descriptor, executableURL: nil)
        XCTAssertEqual(missing.state, .unavailable)
    }
}
