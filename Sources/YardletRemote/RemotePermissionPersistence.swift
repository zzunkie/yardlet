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
    case save
    case register(RemoteDevice)
    case remove(String)
}

struct RemotePermissionWriteResult: Sendable {
    var succeeded: Bool
    var device: RemoteDevice?
    var recovery: RemotePermissionRecoveryState
}

/// Server-owned desired configuration. Persistence reads the latest complete value, not a queued
/// grant/deny command. The lock protects only copying/replacing this map, never disk work.
/// The serial writer reconciles newer denials after each write.
final class RemotePermissionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var permissions: [String: RemoteDevicePermissions] = [:]

    func replace(_ value: [String: RemoteDevicePermissions]) {
        lock.lock()
        defer { lock.unlock() }
        permissions = value
    }

    func read() -> [String: RemoteDevicePermissions] {
        lock.lock()
        defer { lock.unlock() }
        return permissions
    }
}
