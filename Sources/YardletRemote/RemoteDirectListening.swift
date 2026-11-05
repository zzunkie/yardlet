import Foundation

/// A host's listener for the direct paths (§11.1, §11.3), which its remote starts while it is on: on the Mac
/// `RemoteSecureListener`. A platform without one yet serves the relay alone.
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
