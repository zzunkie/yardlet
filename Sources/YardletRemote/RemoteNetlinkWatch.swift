#if os(Linux)
import Foundation
import Glibc

/// The kernel's word that an interface or one of its addresses came or went, on Linux: a netlink route socket that
/// joins the link and address groups, read on a thread of its own (`RemoteAddressSelection.watchSystemInterfaces`).
/// Each batch of messages calls back once; what changed is read again with `getifaddrs`, so the messages themselves
/// are not parsed. Stopping wakes the thread through a pipe and waits for it to end.
final class RemoteNetlinkWatch: @unchecked Sendable {
    private let socket: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let changed: @Sendable () -> Void
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    /// `AF_NETLINK`'s route family and the groups it joins (linux/rtnetlink.h): links, IPv4 and IPv6 addresses.
    private static let netlinkRoute: Int32 = 0
    private static let groups: UInt32 = 0x1 | 0x10 | 0x100

    private init(socket: Int32, wakeRead: Int32, wakeWrite: Int32, changed: @escaping @Sendable () -> Void) {
        self.socket = socket
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
        self.changed = changed
    }

    static func start(_ changed: @escaping @Sendable () -> Void) -> RemoteNetlinkWatch? {
        let descriptor = Glibc.socket(AF_NETLINK, Int32(SOCK_RAW.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
                                      | Int32(SOCK_NONBLOCK.rawValue), netlinkRoute)
        guard descriptor >= 0 else { return nil }
        // struct sockaddr_nl: the family, two bytes of padding, the port ID (0: the kernel's choice) and the groups.
        let address = (sa_family_t(AF_NETLINK), UInt16(0), UInt32(0), groups)
        let length = socklen_t(MemoryLayout.size(ofValue: address))
        let bound = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        var pipe: [Int32] = [-1, -1]
        guard bound == 0, Glibc.pipe(&pipe) == 0 else {
            close(descriptor)
            return nil
        }
        for end in pipe {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
        }
        let watch = RemoteNetlinkWatch(socket: descriptor, wakeRead: pipe[0], wakeWrite: pipe[1], changed: changed)
        let thread = Thread { watch.run() }
        thread.name = "Yardlet network watch"
        thread.start()
        return watch
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        var byte: UInt8 = 0
        _ = write(wakeWrite, &byte, 1)
        _ = finished.wait(timeout: .now() + 5)
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !lock.withLock({ stopped }) {
            var polled = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                          pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&polled, nfds_t(polled.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if polled[1].revents != 0 { break }
            guard polled[0].revents != 0 else { continue }
            // Every message waiting, then one callback for them all. An overrun (ENOBUFS) also means something changed.
            var any = false
            while true {
                let count = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
                if count > 0 { any = true; continue }
                if count < 0, errno == ENOBUFS { any = true; continue }
                break
            }
            if any { changed() }
        }
        close(socket)
        close(wakeRead)
        close(wakeWrite)
        finished.signal()
    }
}
#endif
