import Foundation

/// A device Yardlet started, and the boot it started, which is the only boot Yardlet ever stops.
struct SimulatorBootRecordEntry: Codable, Equatable, Sendable {
    var device: SimulatorDeviceIdentity
    var boot: SimulatorBootIdentity
    var bootedAt: Date
}

/// A device Yardlet made as a separate copy of another for a task while another task used the original, and deletes
/// once no task attaches it.
struct SimulatorCopyRecordEntry: Codable, Equatable, Sendable {
    var device: SimulatorDeviceIdentity
    var source: SimulatorDeviceIdentity
    var madeAt: Date
}

/// Where the devices Yardlet started, and the copies it made, are written down, so a Yardlet that ended without
/// stopping them stops them, and deletes the copies, at its next start.
protocol SimulatorBootRecordStore: Sendable {
    func load() -> [SimulatorBootRecordEntry]
    /// Writes the entries; with none, and no copy, leaves nothing behind.
    func save(_ entries: [SimulatorBootRecordEntry])
    func loadCopies() -> [SimulatorCopyRecordEntry]
    /// Writes the copies; with none, and no started device, leaves nothing behind.
    func saveCopies(_ copies: [SimulatorCopyRecordEntry])
}

/// The record as a small JSON file, removed when it holds no device.
struct SimulatorBootRecordFile: SimulatorBootRecordStore {
    let url: URL

    private struct Contents: Codable {
        var devices: [SimulatorBootRecordEntry]
        var copies: [SimulatorCopyRecordEntry]?
    }

    func load() -> [SimulatorBootRecordEntry] { contents().devices }

    func loadCopies() -> [SimulatorCopyRecordEntry] { contents().copies ?? [] }

    func save(_ entries: [SimulatorBootRecordEntry]) {
        var contents = contents()
        contents.devices = entries
        write(contents)
    }

    func saveCopies(_ copies: [SimulatorCopyRecordEntry]) {
        var contents = contents()
        contents.copies = copies.isEmpty ? nil : copies
        write(contents)
    }

    private func contents() -> Contents {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder.simulatorRecord.decode(Contents.self, from: data)
        else { return Contents(devices: []) }
        return contents
    }

    private func write(_ contents: Contents) {
        guard !contents.devices.isEmpty || !(contents.copies ?? []).isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.simulatorRecord.encode(contents) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {}
    }
}

/// The record kept in memory: tests, and a model whose platform starts no device.
final class InMemorySimulatorBootRecord: SimulatorBootRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SimulatorBootRecordEntry]
    private var copies: [SimulatorCopyRecordEntry]

    init(_ entries: [SimulatorBootRecordEntry] = [], copies: [SimulatorCopyRecordEntry] = []) {
        self.entries = entries
        self.copies = copies
    }

    func load() -> [SimulatorBootRecordEntry] { lock.withLock { entries } }
    func save(_ entries: [SimulatorBootRecordEntry]) { lock.withLock { self.entries = entries } }
    func loadCopies() -> [SimulatorCopyRecordEntry] { lock.withLock { copies } }
    func saveCopies(_ copies: [SimulatorCopyRecordEntry]) { lock.withLock { self.copies = copies } }
}

private extension JSONEncoder {
    static var simulatorRecord: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var simulatorRecord: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
