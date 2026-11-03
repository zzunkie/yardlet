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
/// grant/deny command. The short configuration transaction and publishing a new intent are mutually
/// exclusive, so a superseded snapshot cannot replace the files or clear a newer denial fence.
final class RemotePermissionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var permissions: [String: RemoteDevicePermissions] = [:]

    func replace(_ value: [String: RemoteDevicePermissions]) {
        lock.lock()
        defer { lock.unlock() }
        permissions = value
    }

    func withValue<T>(_ body: ([String: RemoteDevicePermissions]) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(permissions)
    }
}
