import Darwin
import Foundation

/// The macOS process table through libproc: `proc_listallpids` for the running processes,
/// `proc_pidinfo(PROC_PIDTBSDINFO)` for each one's parent and start, `proc_pid_rusage` for what
/// a counted process has used, and its sockets for the ports a task's process listens on.
///
/// `proc_pid_rusage` (`RUSAGE_INFO_V2`) is used for usage instead of `PROC_PIDTASKINFO`: besides the
/// process's own user and system time it has the CPU time of the children the process collected
/// (`ri_child_user_time`, `ri_child_system_time`), which keeps commands that start and end between
/// samples in the count, and the memory footprint (`ri_phys_footprint`) that Activity Monitor's
/// Memory column shows, where resident size counts shared pages once per process. Its times are in
/// Mach absolute time units, as `PROC_PIDTASKINFO`'s are (nanoseconds on Intel, 125/3 ns per unit on
/// Apple silicon), converted here with the timebase.
struct LiveProcessTable: ProcessTableReading {
    private let timebaseNumerator: UInt64
    private let timebaseDenominator: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseNumerator = UInt64(max(timebase.numer, 1))
        timebaseDenominator = UInt64(max(timebase.denom, 1))
    }

    func entries() -> [ProcessTableEntry] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        var entries: [ProcessTableEntry] = []
        entries.reserveCapacity(Int(count))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            entries.append(ProcessTableEntry(
                processID: pid,
                parentID: pid_t(bitPattern: info.pbi_ppid),
                startMicroseconds: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
            ))
        }
        return entries
    }

    func usage(of processID: Int32) -> ProcessUsageReading? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessUsageReading(
            cpuNanoseconds: nanoseconds(info.ri_user_time &+ info.ri_system_time),
            endedChildrenCPUNanoseconds: nanoseconds(info.ri_child_user_time &+ info.ri_child_system_time),
            memoryBytes: info.ri_phys_footprint
        )
    }

    /// The process's descriptors (`PROC_PIDLISTFDS`), and for each socket its state
    /// (`PROC_PIDFDSOCKETINFO`): a TCP socket in `LISTEN` bound to a loopback address or to every
    /// address. Two system calls for a process without sockets, one more per socket; the kernel's own
    /// view, so nothing is started (no `lsof`) and no connection is made.
    func listeningPorts(of processID: Int32) -> [Int] {
        let needed = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let read = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard read > 0 else { return [] }
        var ports: [Int] = []
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in descriptors.prefix(Int(read) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            // A descriptor closed meanwhile reads short.
            guard proc_pidfdinfo(processID, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let address = info.psi.soi_proto.pri_tcp.tcpsi_ini
            guard Self.isReachableAsLocalhost(address) else { continue }
            // `insi_lport` is the port in network byte order.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    /// Bound to every address or to a loopback one: 0.0.0.0, 127.0.0.0/8, ::, ::1.
    private static func isReachableAsLocalhost(_ address: in_sockinfo) -> Bool {
        if address.insi_vflag & UInt8(INI_IPV6) != 0 {
            let bytes = withUnsafeBytes(of: address.insi_laddr.ina_6) { Array($0) }
            return bytes.dropLast().allSatisfy { $0 == 0 } && (bytes.last == 0 || bytes.last == 1)
        }
        let host = UInt32(bigEndian: address.insi_laddr.ina_46.i46a_addr4.s_addr)
        return host == 0 || host >> 24 == 127
    }

    /// Reads the process's arguments and environment (`KERN_PROCARGS2`, as `ps -E` does): the
    /// argument count, the executable's path, the arguments, then the environment, each ending in a
    /// NUL. One system call; only a process of the same user can be read.
    func environment(_ names: Set<String>, of processID: Int32) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard !names.isEmpty, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The executable's path and the NULs that pad it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        for _ in 0..<max(argumentCount, 0) {
            while index < size, buffer[index] != 0 { index += 1 }
            index += 1
        }
        var values: [String: String] = [:]
        while index < size, values.count < names.count {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            // An empty string ends the environment.
            guard index > start else { break }
            if let equals = buffer[start..<index].firstIndex(of: UInt8(ascii: "=")) {
                let name = String(decoding: buffer[start..<equals], as: UTF8.self)
                if names.contains(name), values[name] == nil {
                    values[name] = String(decoding: buffer[(equals + 1)..<index], as: UTF8.self)
                }
            }
            index += 1
        }
        return values
    }

    func name(of processID: Int32) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(processID, &name, UInt32(name.count)) > 0 else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func nanoseconds(_ machTime: UInt64) -> UInt64 {
        let (high, low) = machTime.multipliedFullWidth(by: timebaseNumerator)
        guard high < timebaseDenominator else { return .max }
        return timebaseDenominator.dividingFullWidth((high, low)).quotient
    }
}
