import Foundation

/// A host's listener for the direct paths (§11.1, §11.3), which its remote starts while it is on: on the Mac
/// `RemoteSecureListener`, on Windows `RemoteWinsockListener`. A platform without one yet serves the relay alone.
public protocol RemoteDirectListening: AnyObject, Sendable {
    /// Told on the listener's own queue whenever its state changes.
    var onStateChange: (@Sendable (RemoteDirectListenerState) -> Void)? { get set }
    func start()
    func stop()
}

public enum RemoteDirectListenerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(String)
}

/// What a listener advertises on the same network (§11.3): its Bonjour instance name and TXT record.
public struct RemoteDirectAdvertisement: Equatable, Sendable {
    public var name: String
    public var txt: [String: String]

    public init(name: String, txt: [String: String]) {
        self.name = name
        self.txt = txt
    }

    /// What a host with this identity advertises.
    public static func of(_ identity: RemoteIdentity) -> RemoteDirectAdvertisement {
        RemoteDirectAdvertisement(name: "Yardlet-\(identity.discoveryID)", txt: ["v": String(RemoteProtocol.secureVersion),
                                                                                "id": identity.discoveryID])
    }
}
