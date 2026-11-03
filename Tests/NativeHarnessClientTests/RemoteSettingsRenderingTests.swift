import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// Settings › Remote drawn offscreen (never shown) in both appearances into `.build/remote-qa`:
///
/// - `remote-off-*.png`: the switch off, nothing else.
/// - `remote-pairing-*.png`: on, kept awake on power, reachable on the same Wi-Fi, Tailscale and the Yardlet
///   server, a pairing open with its QR code, its link to copy and time left, and two paired devices: a phone
///   connected now and a Mac last seen yesterday.
/// - `remote-link-*.png`: a phone asking to link through the account, with its number.
/// - `remote-paired-*.png`: after the pairing and the link, with the paired phone named.
///
/// Nothing listens: the service reads fixture interfaces and its listener and relay states are set by
/// the test. Its preferences live in a throwaway suite and its keys in memory.
@MainActor
final class RemoteSettingsRenderingTests: XCTestCase {
    private var onPower = true

    func testTheRemoteSectionDrawsOffPairingAndPaired() async throws {
        let directory = try WindowlessRender.directory("remote-qa")
        let size = NSSize(width: 820, height: 820)
        let (service, identity) = try await makeService()

        try render("remote-off", service: service, in: directory, size: size)
        let offElements = elements(service, size: size)
        XCTAssertTrue(offElements.contains { $0.label == L10n.string("Allow remote connections") }, offElements.description)
        XCTAssertFalse(offElements.contains { $0.label == L10n.string("Pair a device") })
        XCTAssertFalse(offElements.contains { $0.label == L10n.string("Keep this Mac awake on power") })

        // Kept awake only while the remote is on, the setting is on and the Mac is on power.
        service.setKeepsAwakeOnPower(true)
        XCTAssertFalse(service.isKeepingAwake)
        onPower = false
        service.setEnabled(true)
        XCTAssertFalse(service.isKeepingAwake)
        onPower = true
        service.setKeepsAwakeOnPower(false)
        service.setKeepsAwakeOnPower(true)
        XCTAssertTrue(service.isKeepingAwake)
        service.secureState = .ready(port: RemoteProtocol.securePort)
        service.relayState = .connected
        XCTAssertEqual(service.reach, .init(direct: true, tailscale: true, relay: .connected, directFailure: nil))

        // One phone connected now, on the same network: its first message makes it the device's connection.
        let ticket = await service.server.openPairing()
        let phone = try await PipePhone.connect(
            server: service.server, macStatic: identity.noise, phoneKey: .generate(),
            hello: RemoteHandshakeHello(name: "Pixel 9", pair: RemoteEncoding.base64url(ticket.secret)),
            targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertEqual(phone.reply.ok, true)
        _ = try await phone.request(#"{"id":"p","type":"ping"}"#)
        try await waitUntil { service.devices.count == 2 && service.connectedPaths.values.contains(.local) }

        await service.startPairing()
        try await waitUntil { service.directHosts.count == 4 }
        XCTAssertEqual(service.directHosts, ["192.168.0.12:47616", "100.101.102.103:47616", "macbook.tail1234.ts.net:47616",
                                             "[fd7a:115c:a1e0::1234]:47616"])
        await service.startPairing()
        let url = try XCTUnwrap(service.pairing?.url)
        let parsed = try XCTUnwrap(RemoteSecurePairingURL.parse(url))
        XCTAssertEqual(parsed.macKey, identity.noise.publicKey)
        XCTAssertEqual(parsed.hosts, service.directHosts)
        XCTAssertNil(parsed.relayURL, "No relay client runs here, so the QR names no relay")
        XCTAssertNotNil(RemotePairingQRCode.image(for: url.absoluteString))
        try render("remote-pairing", service: service, in: directory, size: size)
        let pairingElements = elements(service, size: size)
        XCTAssertTrue(pairingElements.contains { $0.label == L10n.string("Pairing QR code") }, pairingElements.description)
        XCTAssertTrue(pairingElements.contains { $0.label == L10n.format("Remove %@", "Pixel 9") })
        XCTAssertTrue(pairingElements.contains { $0.label == L10n.string("Copy link") }, pairingElements.description)
        XCTAssertTrue(pairingElements.contains { $0.label == L10n.string("Keep this Mac awake on power") })

        // A phone pairs with the QR's secret: the pairing closes and the new phone is named.
        let tablet = try await PipePhone.connect(
            server: service.server, macStatic: identity.noise, phoneKey: .generate(),
            hello: RemoteHandshakeHello(name: "Galaxy Tab", pair: RemoteEncoding.base64url(parsed.secret)),
            targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertEqual(tablet.reply.paired, true)
        try await waitUntil { service.pairing == nil && service.pairedDeviceName == "Galaxy Tab" }

        // A phone signed in to the account asks to link; the Mac shows its number.
        await service.server.setAcceptsLinks(true)
        let (linking, code, _) = try await PipePhone.link(server: service.server, macStatic: identity.noise, name: "Pixel 10")
        try await waitUntil { service.linkRequest?.code == code }
        try render("remote-link", service: service, in: directory, size: size)
        await service.answerLink(approve: true)
        _ = try await linking.event(.linked)
        try await waitUntil { service.linkRequest == nil && service.devices.count == 4 }
        XCTAssertEqual(service.devices.map(\.name), ["MacBook Air", "Pixel 9", "Galaxy Tab", "Pixel 10"])
        try render("remote-paired", service: service, in: directory, size: size)

        service.setEnabled(false)
        XCTAssertFalse(service.isKeepingAwake)
        try await phone.waitUntilClosed(.unavailable)
    }

    func testDevicePermissionsDrawInBothAppearances() async throws {
        let (service, _) = try await makeService()
        await service.reloadDevices()
        let device = try XCTUnwrap(service.devices.first)
        XCTAssertNil(device.permissions)
        let directory = try WindowlessRender.directory("remote-qa")
        let size = NSSize(width: 820, height: 820)
        try render("remote-permissions-off", service: service, in: directory, size: size)
        await service.setPermission(.terminal, allowed: true, for: device)
        XCTAssertNil(service.permissionError)
        XCTAssertEqual(service.devices.first?.permissions?.terminal, true)
        try render("remote-permissions-terminal", service: service, in: directory, size: size)
        let labels = elements(service, size: size).map(\.label)
        XCTAssertTrue(labels.contains(L10n.format("%@ for %@", L10n.string("Terminal"), device.name)))
    }

    // MARK: - Helpers

    private func makeService() async throws -> (RemoteControlService, RemoteIdentity) {
        let suite = testDefaultsSuite("RemoteSettingsRenderingTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let store = RemoteDeviceStore(fileURL: nil)
        // Yardlet on a laptop paired before, last seen yesterday.
        _ = await store.addSecure(name: "MacBook Air", publicKey: Data(repeating: 3, count: 32), platform: "macos",
                                  now: Date().addingTimeInterval(-86_400))
        let identity = RemoteIdentity.generate()
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: store, audit: nil, identityStore: RemoteMemoryIdentityStore(identity),
            defaults: defaults, environment: [:],
            interfaces: {
                [RemoteInterfaceAddress(interface: "en0", address: "192.168.0.12", family: .ipv4),
                 RemoteInterfaceAddress(interface: "utun4", address: "100.101.102.103", family: .ipv4),
                 RemoteInterfaceAddress(interface: "utun4", address: "fd7a:115c:a1e0::1234", family: .ipv6)]
            },
            resolveName: { _ in "macbook.tail1234.ts.net" },
            listens: false, isOnPower: { [unowned self] in onPower }, macName: "MacBook Pro", appVersion: "test")
        await service.start()
        XCTAssertFalse(service.isEnabled)
        return (service, identity)
    }

    private func settings(_ service: RemoteControlService) -> some View {
        SettingsCenterView(initialSection: SettingsSection.remote.rawValue,
                           notificationCenter: MenuBarQuietNotificationCenter(), remote: service)
    }

    private func render(_ name: String, service: RemoteControlService, in directory: URL, size: NSSize) throws {
        let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
            settings(service).environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
    }

    private func elements(_ service: RemoteControlService, size: NSSize) -> [WindowlessRender.AccessibilityElement] {
        let host = WindowlessRender.Host(settings(service), size: size)
        defer { host.close() }
        host.settle()
        return host.accessibilityElements()
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
