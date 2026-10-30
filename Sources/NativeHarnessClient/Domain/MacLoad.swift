import Foundation

#if canImport(Darwin)
typealias SystemThermalState = ProcessInfo.ThermalState
#else
/// How hot the computer runs, in the steps macOS reports; Foundation elsewhere does not report it.
enum SystemThermalState: Int, Sendable {
    case nominal, fair, serious, critical
}
#endif

/// This Mac's size and how busy it is now, as the session tools' admission reads it
/// (`SessionToolPolicy.admitted`).
struct MacLoad: Equatable, Sendable {
    enum MemoryPressure: Int, Comparable, Sendable {
        case normal = 1, warning = 2, critical = 4

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The cores macOS runs threads on, performance and efficiency alike (`activeProcessorCount`, Node's
    /// `os.availableParallelism`).
    var cores: Int
    var physicalMemory: UInt64
    /// The kernel's one-minute load average: the threads running or ready to run.
    var loadAverage: Double
    var memoryPressure: MemoryPressure
    var thermalState: SystemThermalState
}

/// Where admission reads the Mac's load; tests give their own.
protocol MacLoadReading: Sendable {
    func read() -> MacLoad
}

struct LiveMacLoadReader: MacLoadReading {
    func read() -> MacLoad { MacConditionReader.load() }
}
