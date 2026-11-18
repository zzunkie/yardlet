import Foundation

/// A device Yardlet started, and the boot it started, which is the only boot Yardlet ever stops.
struct SimulatorBootRecordEntry: Codable, Equatable, Sendable {
    var device: SimulatorDeviceIdentity
    var boot: SimulatorBootIdentity
    var bootedAt: Date
}

/// Where the devices Yardlet started are written down, so a Yardlet that ended without stopping them stops them at
/// its next start.
protocol SimulatorBootRecordStore: Sendable {
    func load() -> [SimulatorBootRecordEntry]
    /// Writes the entries; with none, leaves nothing behind.
    func save(_ entries: [SimulatorBootRecordEntry])
}

/// The record as a small JSON file, removed when it holds no device.
struct SimulatorBootRecordFile: SimulatorBootRecordStore {
    let url: URL

    private struct Contents: Codable {
        var devices: [SimulatorBootRecordEntry]
    }

    func load() -> [SimulatorBootRecordEntry] {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder.simulatorRecord.decode(Contents.self, from: data) else { return [] }
        return contents.devices
    }

    func save(_ entries: [SimulatorBootRecordEntry]) {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.simulatorRecord.encode(Contents(devices: entries)) else { return }
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

    init(_ entries: [SimulatorBootRecordEntry] = []) { self.entries = entries }

    func load() -> [SimulatorBootRecordEntry] { lock.withLock { entries } }
    func save(_ entries: [SimulatorBootRecordEntry]) { lock.withLock { self.entries = entries } }
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
