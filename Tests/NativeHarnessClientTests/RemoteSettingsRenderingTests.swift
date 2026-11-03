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
        XCTAssertEqual(device.permissions, RemoteDevicePermissions())
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

    func testPermissionDenialStaysOffWhenSavingFailsAndCanRetry() async throws {
        let fixture = try DeviceStoreWriteFailure()
        defer { fixture.cleanUp() }
        let store = RemoteDeviceStore(fileURL: fixture.file)
        let (service, _) = try await makeService(store: store)
        await service.reloadDevices()
        let device = try XCTUnwrap(service.devices.first)
        let first = PermissionEvents()
        let second = PermissionEvents()
        _ = await service.server.addPermissionsChangedHandler { first.append($0, $1) }
        _ = await service.server.addPermissionsChangedHandler { second.append($0, $1) }
        await service.setPermission(.terminal, allowed: true, for: device)
        await service.setPermission(.fileWrites, allowed: true, for: device)
        try fixture.block()
        await service.setPermission(.terminal, allowed: false, for: device)
        XCTAssertNotNil(service.permissionError)
        XCTAssertTrue(service.canRetryPermissionChange)
        XCTAssertEqual(service.devices.first?.permissions?.terminal, false)
        await service.setPermission(.fileWrites, allowed: false, for: device)
        XCTAssertEqual(service.unsavedDeniedPermissions.count, 2)
        await service.setPermission(.settings, allowed: true, for: device)
        XCTAssertEqual(service.unsavedDeniedPermissions.count, 2, "A later failed grant must not replace unsaved denials")
        XCTAssertTrue(service.canRetryPermissionChange)
        XCTAssertEqual(first.values.last?.permissions.terminal, false)
        XCTAssertEqual(first.values, second.values)
        try render("remote-permissions-save-failed", service: service,
                   in: WindowlessRender.directory("remote-qa"), size: NSSize(width: 820, height: 820))
        try fixture.restore()
        let beforeRetry = await RemoteDeviceStore(fileURL: fixture.file).device(device.id)
        XCTAssertEqual(beforeRetry?.permissions?.terminal, true, "The warning must remain until the denied value is saved")
        await service.retryPermissionChange()
        XCTAssertNil(service.permissionError)
        XCTAssertFalse(service.canRetryPermissionChange)
        let afterRetry = await RemoteDeviceStore(fileURL: fixture.file).device(device.id)
        XCTAssertEqual(afterRetry?.permissions, RemoteDevicePermissions(), "Retry saves only denials; it cannot retry the failed grant")
        XCTAssertTrue(service.unsavedDeniedPermissions.isEmpty)
    }

    func testPendingGrantCanBeTurnedOffBeforeItEverReachesDisk() async throws {
        let fixture = try DeviceStoreWriteFailure()
        defer { fixture.cleanUp() }
        let gate = PermissionPersistenceGate()
        let store = RemoteDeviceStore(fileURL: fixture.file, beforePermissionWrite: { await gate.waitIfArmed() })
        let (service, _) = try await makeService(store: store)
        await service.reloadDevices()
        let device = try XCTUnwrap(service.devices.first)
        let events = PermissionEvents()
        _ = await service.server.addPermissionsChangedHandler { events.append($0, $1) }
        await gate.arm()
        let grant = Task { await service.setPermission(.terminal, allowed: true, for: device) }
        try await waitUntil { await gate.isWaiting }
        XCTAssertEqual(service.pendingPermissionValues[.init(deviceID: device.id, permission: .terminal)], true)
        try render("remote-permissions-saving", service: service,
                   in: WindowlessRender.directory("remote-qa"), size: NSSize(width: 820, height: 820))
        let denial = Task { await service.setPermission(.terminal, allowed: false, for: device) }
        try await waitUntil { !events.values.isEmpty }
        // Hold the SECOND write too: inspecting the first completed write must already show OFF.
        await gate.arm()
        await gate.release()
        await grant.value
        try await waitUntil { await gate.isWaiting }
        let intermediate = await RemoteDeviceStore(fileURL: fixture.file).device(device.id)
        XCTAssertEqual(intermediate?.permissions?.terminal, false)
        XCTAssertEqual(service.pendingPermissionValues[.init(deviceID: device.id, permission: .terminal)], false)
        await gate.release()
        await denial.value
        XCTAssertNil(service.permissionError)
        let saved = await RemoteDeviceStore(fileURL: fixture.file).device(device.id)
        XCTAssertEqual(saved?.permissions?.terminal, false)
    }

    func testReenablingRemoteRestoresPermissionEnforcement() async throws {
        let (service, _) = try await makeService()
        await service.reloadDevices()
        let device = try XCTUnwrap(service.devices.first)
        await service.setPermission(.terminal, allowed: true, for: device)
        service.setEnabled(true)
        let phone = TestChannel()
        guard case let .accepted(id, _) = await service.server.acceptHandshake(
            RemoteHandshakeHello(name: "Mac"), publicKey: Data(repeating: 3, count: 32), channel: phone, path: .local)
        else { return XCTFail("Expected paired device") }
        await service.server.receive(Data(#"{"id":"proof","type":"ping"}"#.utf8), on: id)
        _ = try await phone.response("proof")
        service.setEnabled(false)
        try await phone.waitUntilClosed(.unavailable)
        service.setEnabled(true)
        let returning = TestChannel()
        guard case let .accepted(newID, _) = await service.server.acceptHandshake(
            RemoteHandshakeHello(name: "Mac"), publicKey: Data(repeating: 3, count: 32), channel: returning, path: .local)
        else { return XCTFail("Expected paired device after enabling") }
        await service.server.receive(Data(#"{"id":"proof","type":"ping"}"#.utf8), on: newID)
        _ = try await returning.response("proof")
        try await waitUntil { await service.server.permissionError(.terminal, on: newID) == nil }
        let files = await service.server.permissionError(.fileWrites, on: newID)
        XCTAssertEqual(files?.code, .notAllowed)
        await service.shutdown()
    }

    func testOtherWritesPreserveFailedDenials() async throws {
        for metadataOnly in [true, false] {
            let fixture = try DeviceStoreWriteFailure()
            defer { fixture.cleanUp() }
            let store = RemoteDeviceStore(fileURL: fixture.file)
            let (service, _) = try await makeService(store: store)
            await service.reloadDevices()
            let device = try XCTUnwrap(service.devices.first)
            await service.setPermission(.terminal, allowed: true, for: device)
            try fixture.block()
            await service.setPermission(.terminal, allowed: false, for: device)
            let logical = await store.device(device.id)
            XCTAssertEqual(logical?.permissions?.terminal, false)
            try fixture.restore()
            if metadataOnly {
                _ = await store.authenticate(publicKey: Data(repeating: 3, count: 32), name: "Renamed Mac")
            } else {
                await service.setPermission(.settings, allowed: true, for: device)
            }
            let restarted = await RemoteDeviceStore(fileURL: fixture.file).device(device.id)
            XCTAssertEqual(restarted?.permissions?.terminal, false)
            XCTAssertEqual(restarted?.permissions?.settings, !metadataOnly)
        }
    }

    func testDurableDenialRecoveryExplainsThatRestartRemainsSafe() async throws {
        let fixture = try DeviceStoreWriteFailure()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.file.path)
            fixture.cleanUp()
        }
        let store = RemoteDeviceStore(fileURL: fixture.file)
        let (service, _) = try await makeService(store: store)
        await service.reloadDevices()
        let device = try XCTUnwrap(service.devices.first)
        await service.setPermission(.terminal, allowed: true, for: device)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.file.path)
        await service.setPermission(.terminal, allowed: false, for: device)
        XCTAssertFalse(service.unsavedDeniedPermissions.isEmpty)
        XCTAssertTrue(service.unsafeDeniedPermissions.isEmpty)
        XCTAssertEqual(service.devices.first?.permissions?.terminal, false)
        XCTAssertEqual(service.permissionError, L10n.string("Permission stays off after restarting. Retry saving the settings."))
        try render("remote-permissions-recovery-saved", service: service,
                   in: WindowlessRender.directory("remote-qa"), size: NSSize(width: 820, height: 820))
    }

    func testFailedRemovalRetainsThePairedDeviceAndReportsFailure() async throws {
        let fixture = try DeviceStoreWriteFailure()
        defer { fixture.cleanUp() }
        let store = RemoteDeviceStore(fileURL: fixture.file)
        let audit = RemoteAuditLog(fileURL: fixture.root.appendingPathComponent("audit.log"))
        let (service, identity) = try await makeService(store: store, audit: audit)
        let key = RemoteKeyPair.generate()
        let ticket = await service.server.openPairing()
        let phone = try await PipePhone.connect(server: service.server, macStatic: identity.noise, phoneKey: key,
            hello: RemoteHandshakeHello(name: "Test phone", pair: RemoteEncoding.base64url(ticket.secret)),
            targetKey: identity.noise.publicKey, expectsReply: true)
        let deviceID = try XCTUnwrap(phone.reply.deviceId)
        await service.reloadDevices()
        let device = try XCTUnwrap(service.devices.first(where: { $0.id == deviceID }))
        await service.setPermission(.terminal, allowed: true, for: device)
        try fixture.block()
        await service.remove(device)
        XCTAssertNotNil(service.removalError)
        XCTAssertTrue(service.devices.contains { $0.id == deviceID })
        try await phone.waitUntilClosed(.unavailable)
        // The unsuccessful attempt must not leave a permanent in-memory revocation behind.
        let reconnected = try await PipePhone.connect(server: service.server, macStatic: identity.noise, phoneKey: key,
            hello: RemoteHandshakeHello(name: "Test phone"), targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertTrue(reconnected.reply.ok)
        let failed = try await reconnected.request(#"{"id":"forget","type":"forgetDevice"}"#)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.error?.code, .internal)
        try await reconnected.waitUntilClosed(.unavailable)
        try render("remote-removal-failed", service: service,
                   in: WindowlessRender.directory("remote-qa"), size: NSSize(width: 820, height: 820))
        try fixture.restore()
        let restarted = await RemoteDeviceStore(fileURL: fixture.file).device(deviceID)
        XCTAssertNotNil(restarted)
        XCTAssertEqual(restarted?.permissions?.terminal, true)
        XCTAssertNotNil(service.removalError, "A retained pairing must never have been reported as removed")
        await service.remove(device)
        XCTAssertNil(service.removalError)
        let removed = await RemoteDeviceStore(fileURL: fixture.file).device(deviceID)
        XCTAssertNil(removed)
        XCTAssertEqual(audit.entries().filter { $0.type == "revoke" }.map(\.result), ["failed", "failed", "ok"])
    }

    // MARK: - Helpers

    private func makeService(store supplied: RemoteDeviceStore? = nil, audit: RemoteAuditLog? = nil) async throws -> (RemoteControlService, RemoteIdentity) {
        let suite = testDefaultsSuite("RemoteSettingsRenderingTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let store = supplied ?? RemoteDeviceStore(fileURL: nil)
        // Yardlet on a laptop paired before, last seen yesterday.
        _ = await store.addSecure(name: "MacBook Air", publicKey: Data(repeating: 3, count: 32), platform: "macos",
                                  now: Date().addingTimeInterval(-86_400))
        let identity = RemoteIdentity.generate()
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: store, audit: audit, identityStore: RemoteMemoryIdentityStore(identity),
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


}

/// A deterministic persistence failure without depending on the test runner's filesystem privileges.
private struct DeviceStoreWriteFailure {
    let root: URL
    let directory: URL
    let displaced: URL
    var file: URL { directory.appendingPathComponent("devices.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-store-" + UUID().uuidString)
        directory = root.appendingPathComponent("data")
        displaced = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func block() throws {
        try FileManager.default.moveItem(at: directory, to: displaced)
        try Data().write(to: directory)
    }
    func restore() throws {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: displaced, to: directory)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
