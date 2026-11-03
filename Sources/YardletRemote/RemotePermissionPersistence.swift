import Foundation

public struct RemotePermissionKey: Hashable, Codable, Sendable {
    public var deviceID: String
    public var permission: RemoteDevicePermission

    public init(deviceID: String, permission: RemoteDevicePermission) {
        self.deviceID = deviceID
        self.permission = permission
    }
}

/// Recovery facts, not live authorization. Only RemoteServer decides whether an operation is allowed.
public struct RemotePermissionRecoveryState: Equatable, Sendable {
    public var unsavedDeniedPermissions: Set<RemotePermissionKey>
    public var unsafeDeniedPermissions: Set<RemotePermissionKey>

    public init(unsavedDeniedPermissions: Set<RemotePermissionKey> = [],
                unsafeDeniedPermissions: Set<RemotePermissionKey> = []) {
        self.unsavedDeniedPermissions = unsavedDeniedPermissions
        self.unsafeDeniedPermissions = unsafeDeniedPermissions
    }
}

struct RemotePermissionBootstrap: Sendable {
    var devices: [RemoteDevice]
    var recovery: RemotePermissionRecoveryState
}

enum RemotePermissionWrite: Sendable {
    case grant(RemotePermissionKey)
    case deny(Set<RemotePermissionKey>)
    case register(RemoteDevice)
    case remove(String)
}

struct RemotePermissionWriteResult: Sendable {
    var succeeded: Bool
    var device: RemoteDevice?
    var recovery: RemotePermissionRecoveryState
}
