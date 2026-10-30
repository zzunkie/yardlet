import CryptoKit
import Darwin
import Foundation

/// The input-request journal in private files, one per provider request, shared by every window,
/// process and account home of the current OS user. Each operation holds an exclusive lock on the
/// folder for its read, check and write only, never across a network request, and writes through a
/// synced temporary file renamed into place, so a claim is made at most once and survives a crash.
final class DotsResponseJournalFiles: DotsResponseJournal, @unchecked Sendable {
    static let live = DotsResponseJournalFiles(directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: YardletProduct.storageDirectoryName).appending(path: "personal-agent-responses"))

    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func record(for key: DotsResponseKey) throws -> DotsResponseRecord? {
        try locked { try read(key) }
    }

    func claim(_ key: DotsResponseKey) throws -> Bool {
        try locked {
            guard try read(key) == nil else { return false }
            try store(.init(acknowledgement: nil), for: key)
            return true
        }
    }

    func release(_ key: DotsResponseKey) throws {
        try locked {
            guard try read(key) == .claimed else { throw DotsResponseJournalFailure.missingClaim }
            guard unlink(file(key).path) == 0 else { throw DotsResponseJournalFailure.unreadable }
            try syncDirectory()
        }
    }

    func acknowledge(_ key: DotsResponseKey, _ acknowledgement: DotsResponseAcknowledgement) throws {
        try locked {
            guard let record = try read(key) else { throw DotsResponseJournalFailure.missingClaim }
            if case .claimed = record { try store(.init(acknowledgement: acknowledgement), for: key) }
        }
    }

    // MARK: - Files

    private func file(_ key: DotsResponseKey) -> URL {
        let name = SHA256.hash(data: Data(key.serialized.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }

    private func read(_ key: DotsResponseKey) throws -> DotsResponseRecord? {
        let data: Data
        do { data = try Data(contentsOf: file(key)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        // A record that cannot be read blocks the request rather than reopening it.
        guard let stored = try? JSONDecoder().decode(DotsResponseRecord.Stored.self, from: data),
              let record = DotsResponseRecord(stored) else { throw DotsResponseJournalFailure.unreadable }
        return record
    }

    private func store(_ stored: DotsResponseRecord.Stored, for key: DotsResponseKey) throws {
        let data = try JSONEncoder().encode(stored)
        let target = file(key)
        let temporary = directory.appending(path: "." + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw DotsResponseJournalFailure.unreadable }
        var failed = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } != data.count
        failed = fcntl(descriptor, F_FULLFSYNC) != 0 && fsync(descriptor) != 0 || failed
        close(descriptor)
        guard !failed, rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            throw DotsResponseJournalFailure.unreadable
        }
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw DotsResponseJournalFailure.unreadable }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }

    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw DotsResponseJournalFailure.unreadable }
        let descriptor = open(directory.appending(path: ".lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw DotsResponseJournalFailure.unreadable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw DotsResponseJournalFailure.unreadable }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
