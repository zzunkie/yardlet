import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class HarnessCatalogTests: XCTestCase {
    func testBuiltInCatalogHasTenUniqueOpenIdentifiers() throws {
        let descriptors = HarnessCatalog.builtIns

        XCTAssertEqual(descriptors.count, 10)
        XCTAssertEqual(Set(descriptors.map(\.id)).count, descriptors.count)
        XCTAssertEqual(
            Set(descriptors.map(\.id)),
            Set([
                .codex, .claudeCode, .museCode, .openCode,
                .cursorAgent, .antigravityCLI,
                .kimiCode, .grokBuild, .hermes, .pi
            ])
        )
        XCTAssertEqual(
            descriptors.filter { $0.transport == .msp }.map(\.id),
            [.museCode]
        )
        XCTAssertEqual(
            descriptors.filter { $0.transport == .acp }.map(\.id),
            [.openCode, .antigravityCLI, .kimiCode, .grokBuild, .hermes]
        )
        XCTAssertEqual(
            descriptors.filter { $0.transport == .piRPC }.map(\.id),
            [.pi]
        )
        XCTAssertTrue(descriptors.filter(\.isLegacy).isEmpty)
        XCTAssertEqual(
            descriptors.filter { $0.transport == .cursorStreamJSON }.map(\.id),
            [.cursorAgent]
        )
    }

    func testRemovedHarnessIdentifiersStillDecodeWithoutRestoringRuntimeSupport() async throws {
        let names = ["gemini-cli", "gajae-code", "deep-agents-code", "oh-my-pi"]
        XCTAssertEqual(HarnessCatalog.retired, Set(names.map(HarnessKind.init(rawValue:))))
        for name in names {
            let retired = try JSONDecoder().decode(HarnessKind.self, from: Data("\"\(name)\"".utf8))
            XCTAssertEqual(retired.rawValue, name)
            XCTAssertEqual(retired.displayName, name)
            XCTAssertNil(HarnessCatalog.descriptor(for: retired))
            XCTAssertNil(HarnessLogoAsset.name(for: retired))
            let adapter = await HarnessRegistry().adapter(for: retired, executableURL: URL(filePath: "/tmp/\(name)"))
            XCTAssertTrue(adapter is UnsupportedHarnessAdapter, name)
            do {
                _ = try await adapter.probeRuntime()
                XCTFail(name)
            } catch let HarnessAdapterError.capabilityUnavailable(message) {
                XCTAssertEqual(message, L10n.format("Yardlet no longer supports %@.", name), "Removed, not unfinished")
            }
            let command = await HarnessAccountBroker().loginCommand(for: retired, executableURL: URL(filePath: "/tmp/\(name)"))
            XCTAssertNil(command, name)
        }
    }

    func testMuseCodeUsesOfficialMSPEntrypointAndProductLinks() throws {
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .museCode))

        XCTAssertEqual(descriptor.id.rawValue, "muse-code")
        XCTAssertEqual(descriptor.transport, .msp)
        XCTAssertEqual(descriptor.executableName, "muse")
        XCTAssertEqual(descriptor.launchArguments, ["serve"])
        XCTAssertEqual(descriptor.relativeExecutablePaths, [".local/bin/muse"])
        XCTAssertEqual(
            descriptor.websiteURL.absoluteString,
            "https://developer.meta.com/ai/resources/blog/build-with-muse-code/"
        )
        XCTAssertEqual(
            descriptor.repositoryURL?.absoluteString,
            "https://github.com/meta-models/muse-code-sdk"
        )
        XCTAssertFalse(descriptor.isLegacy)
    }

    func testMuseCodeUsesYHPV1MSPProductRouteByDefault() async {
        let registry = HarnessRegistry()
        let adapter = await registry.adapter(
            for: .museCode,
            executableURL: URL(filePath: "/tmp/muse")
        )

        guard let routed = adapter as? YHPProviderCompatibilityAdapter else {
            return XCTFail("Muse Code must use the product-default YHP provider route")
        }
        XCTAssertEqual(routed.protocolManifest.harness, .museCode)
        XCTAssertEqual(routed.protocolManifest.protocolVersions, [.v1])
        XCTAssertEqual(
            routed.protocolManifest.adapterID,
            "com.yardlet.compat.msp.muse-code"
        )
        XCTAssertTrue(routed.protocolManifest.extensionNamespaces.contains("yardlet.provider"))
    }

    func testStructuredHeadlessHarnessesUseYHPV1ProviderRouteByDefault() async {
        let registry = HarnessRegistry()

        for kind in [HarnessKind.cursorAgent, .antigravityCLI] {
            let adapter = await registry.adapter(
                for: kind,
                executableURL: URL(filePath: "/tmp/\(kind.rawValue)")
            )
            guard let routed = adapter as? YHPProviderCompatibilityAdapter else {
                XCTFail("\(kind.displayName) must use the product-default YHP provider route")
                continue
            }
            XCTAssertEqual(routed.protocolManifest.harness, kind)
            XCTAssertEqual(routed.protocolManifest.protocolVersions, [.v1])
            XCTAssertTrue(
                routed.protocolManifest.extensionNamespaces.contains("yardlet.provider")
            )
        }
    }

    func testUnknownHarnessIdentifierUsesSingleStringCodableShape() throws {
        let unknown = HarnessKind(rawValue: "future-agent")
        let data = try JSONEncoder().encode(unknown)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""future-agent""#)
        XCTAssertEqual(try JSONDecoder().decode(HarnessKind.self, from: data), unknown)
        XCTAssertEqual(unknown.displayName, "future-agent")
    }

    func testEveryBuiltInHarnessHasAReadableBundledLogo() throws {
        for descriptor in HarnessCatalog.builtIns {
            XCTAssertNotNil(HarnessLogoAsset.name(for: descriptor.id), descriptor.displayName)
            let image = try XCTUnwrap(
                HarnessLogoCatalog.image(for: descriptor.id),
                "Missing bundled logo for \(descriptor.displayName)"
            )
            let pixelsWide = image.representations.map(\.pixelsWide).max() ?? 0
            let pixelsHigh = image.representations.map(\.pixelsHigh).max() ?? 0
            XCTAssertGreaterThanOrEqual(pixelsWide, 128, descriptor.displayName)
            XCTAssertGreaterThanOrEqual(pixelsHigh, 128, descriptor.displayName)
        }
    }
}
