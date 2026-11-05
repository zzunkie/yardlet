#if canImport(Darwin)
import Darwin
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// An address one of the Mac's interfaces holds.
public struct RemoteInterfaceAddress: Equatable, Hashable, Sendable {
    public enum Family: Sendable {
        case ipv4
        case ipv6
    }

    public var interface: String
    public var address: String
    public var family: Family

    public init(interface: String, address: String, family: Family) {
        self.interface = interface
        self.address = address
        self.family = family
    }
}

/// Which of the Mac's addresses a phone is told about (§11.4, §13.3).
public enum RemoteAddressSelection {
    /// An address Tailscale assigns: IPv4 `100.64.0.0/10` (CGNAT) or IPv6 `fd7a:115c:a1e0::/48`.
    public static func isTailscale(_ address: String) -> Bool {
        if let ipv4 = bytes(of: address, family: AF_INET, count: 4) {
            return ipv4[0] == 100 && ipv4[1] & 0xC0 == 64
        }
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        if let ipv6 = bytes(of: bare, family: AF_INET6, count: 16) {
            return ipv6.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        }
        return false
    }

    /// A private IPv4 address of the same network (RFC 1918), which v2 names to phones as a direct path.
    public static func isPrivateLAN(_ address: String) -> Bool {
        guard let ipv4 = bytes(of: address, family: AF_INET, count: 4) else { return false }
        return ipv4[0] == 10 || ipv4[0] == 172 && ipv4[1] & 0xF0 == 16 || ipv4[0] == 192 && ipv4[1] == 168
    }

    /// An address in network order, as `inet_pton` reads it; nil when it is not one of `family`.
    private static func bytes(of address: String, family: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let read = bytes.withUnsafeMutableBytes { inet_pton(family, address, $0.baseAddress) }
        return read == 1 ? bytes : nil
    }

    #if canImport(Darwin)

    /// Every IPv4 and IPv6 address of the Mac's interfaces that are up (`getifaddrs`). Reads only.
    public static func systemInterfaces() -> [RemoteInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }
        var result: [RemoteInterfaceAddress] = []
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr else { continue }
            let family: RemoteInterfaceAddress.Family
            switch Int32(address.pointee.sa_family) {
            case AF_INET: family = .ipv4
            case AF_INET6: family = .ipv6
            default: continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == .ipv4 ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(RemoteInterfaceAddress(interface: String(cString: entry.ifa_name), address: text, family: family))
        }
        return result
    }

    /// The Mac's MagicDNS name, when the system resolver names its Tailscale IPv4 address with one
    /// (`*.ts.net`). A reverse lookup only; it blocks, so call it off the main thread.
    public static func magicDNSName(for ipv4: String) -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ipv4, &address.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        var name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasSuffix(".") { name.removeLast() }
        return name.lowercased().hasSuffix(".ts.net") ? name : nil
    }
    #endif
}
