import Foundation
import YardletRemote
import YardletRemoteFixtureSupport

/// "Try without a Mac": the fixture Mac the protocol's tests use (docs/REMOTE_PROTOCOL.md §17), served inside the
/// app on loopback and reached through the same connection, pairing and screens as a real Mac. Its tasks, answers
/// and files are the fixture's; nothing leaves the phone, and nothing of it is kept once the demo ends.
actor DemoMac {
    struct Failure: Error {}

    private var server: RemoteServer?
    private var listener: RemoteSecureListener?
    private var folder: URL?

    /// Starts the fixture Mac and returns its pairing link.
    func start() async throws -> RemoteSecurePairingURL {
        let identity = RemoteIdentity.generate()
        let folder = FileManager.default.temporaryDirectory.appending(path: "demo-mac-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let bridge = RemoteFixtureBridge(filesFolder: folder.appending(path: "files", directoryHint: .isDirectory))
        var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Demo Mac", appVersion: "demo"),
                                                       macKey: identity.noise.publicKey)
        configuration.uploadDirectory = folder.appending(path: "uploads", directoryHint: .isDirectory)
        let server = RemoteServer(configuration: configuration, bridge: bridge, devices: RemoteDeviceStore(fileURL: nil))
        await server.start()
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        _ = await server.openPairing(secret: secret, lifetime: 24 * 3600, isSingleUse: false)
        self.server = server

        let listener = RemoteSecureListener(server: server, staticKey: identity.noise, port: 0, advertisement: nil,
                                            loopbackOnly: true)
        let (states, continuation) = AsyncStream<RemoteSecureListener.State>.makeStream()
        listener.onStateChange = { continuation.yield($0) }
        listener.start()
        self.listener = listener
        for await state in states {
            switch state {
            case let .ready(port):
                let host = "127.0.0.1:\(port)"
                await server.setDirectory(direct: [host], relay: nil)
                return RemoteSecurePairingURL(macKey: identity.noise.publicKey, secret: secret, name: "Demo Mac",
                                              hosts: [host])
            case .failed:
                throw Failure()
            default:
                continue
            }
        }
        throw Failure()
    }

    func stop() {
        listener?.stop()
        listener = nil
        server = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}
