import Foundation

/// What macOS says about this Mac, for the new-task screen's notice line (`NewTaskHomeNotice`): the home
/// folder's disk below `NewTaskHomeNotice.lowDiskBytes`, the kernel's memory pressure at warning or
/// worse, the thermal state serious or worse. Read off the main actor; nothing is written.
enum MacConditionReader {
    static func notices(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [NewTaskHomeNotice] {
        await Task.detached(priority: .utility) {
            var notices: [NewTaskHomeNotice] = []
            if let available = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, available < NewTaskHomeNotice.lowDiskBytes {
                notices.append(.lowDisk(availableBytes: available))
            }
            if memoryPressure() >= .warning { notices.append(.memoryPressure) }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical { notices.append(.thermal) }
            return notices
        }.value
    }

    /// The kernel's memory pressure (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4
    /// critical); normal where it cannot be read.
    static func memoryPressure() -> MacLoad.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }

    /// The Mac's size and how busy it is at this moment: the kernel's own figures, read once, with no
    /// sampling of its own.
    static func load() -> MacLoad {
        let info = ProcessInfo.processInfo
        var averages = [Double](repeating: 0, count: 1)
        let loadAverage = getloadavg(&averages, 1) == 1 ? averages[0] : 0
        return MacLoad(cores: info.activeProcessorCount, physicalMemory: info.physicalMemory, loadAverage: loadAverage,
                       memoryPressure: memoryPressure(), thermalState: info.thermalState)
    }
}

