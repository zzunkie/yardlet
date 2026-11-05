import Foundation

/// How a host's window says the host is reached now, on the Mac and on Windows.
enum RemoteConnectionText {
    /// The window's subtitle: how the host is reached now.
    static func line(_ connection: RemoteHostModel.Connection) -> String {
        switch connection {
        case let .connected(.direct(address)):
            if isTailscale(address) { return L10n.string("Connected over Tailscale") }
            return L10n.string("Connected on the same network")
        case .connected(.relay): return L10n.string("Connected through the Yardlet server")
        case .connecting: return L10n.string("Connecting…")
        case .unreachable: return L10n.string("Reconnecting…")
        case .removed: return L10n.string("Not paired")
        case .stopped: return ""
        }
    }

    /// Tailscale's addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) and MagicDNS names.
    static func isTailscale(_ address: String) -> Bool {
        let host = address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" })
            : String(address.split(separator: ":").first ?? "")
        if host.hasSuffix(".ts.net") || host.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}
