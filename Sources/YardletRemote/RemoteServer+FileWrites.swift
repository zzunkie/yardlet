import Foundation

extension RemoteServer {
    /// Registered in the same actor turn as the current permission check, with no await between them.
    func fileWritePermit(on connectionID: UUID, requestID: UUID) -> RemoteFileWritePermit? {
        guard permissionError(.fileWrites, on: connectionID) == nil else { return nil }
        let permit = RemoteFileWritePermit()
        fileWritePermits[connectionID, default: [:]][requestID] = permit
        return permit
    }

    func revokeFileWrites(on connectionID: UUID) {
        for permit in fileWritePermits.removeValue(forKey: connectionID)?.values ?? [:].values { permit.revoke() }
    }

    func revokeFileWrites(deviceID: String) {
        for (id, connection) in connections where connection.deviceID == deviceID { revokeFileWrites(on: id) }
    }
}
