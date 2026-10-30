import Foundation

enum BrowserPreviewAddressError: Error, Equatable {
    case empty
    case unsupportedScheme
    case missingHost
    case containsCredentials
    case insecureRemoteHTTP
}

struct BrowserPreviewAddress {
    static func resolve(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BrowserPreviewAddressError.empty }

        let candidate: String
        if value.contains("://") {
            candidate = value
        } else if looksLocal(value) {
            candidate = "http://\(value)"
        } else if value.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
            options: .regularExpression
        ) != nil {
            candidate = value
        } else {
            candidate = "https://\(value)"
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            throw BrowserPreviewAddressError.unsupportedScheme
        }
        guard components.host != nil else {
            throw BrowserPreviewAddressError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw BrowserPreviewAddressError.containsCredentials
        }
        if scheme == "http", !isLoopbackHost(components.host) {
            throw BrowserPreviewAddressError.insecureRemoteHTTP
        }
        guard let url = components.url else {
            throw BrowserPreviewAddressError.missingHost
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil
        else { return false }
        return scheme == "https" || isLoopbackHost(components.host)
    }

    private static func looksLocal(_ value: String) -> Bool {
        let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let hostWithoutPort: String?
        if host.hasPrefix("["), let closingBracket = host.firstIndex(of: "]") {
            hostWithoutPort = String(host[host.index(after: host.startIndex)..<closingBracket])
        } else {
            hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        return isLoopbackHost(hostWithoutPort)
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
                && UInt8($0) != nil
        }
    }
}

struct BrowserPreviewPreferences: Codable, Equatable {
    /// The page shown last, which a build before side-panel browser tabs opens.
    var address = ""
    /// The pages of the task's browser tabs and which was in front, kept when it has several, for a
    /// build before side-panel browser tabs.
    var tabs: [String]?
    var selectedTab: Int?
    /// Each of the side panel's browser tabs, in the panel's order (2026-10-23).
    var pages: [BrowserTabPage]?
    /// The pages the task's tabs showed, which the launcher and a new tab's start page offer again (2026-10-29).
    var visited: [BrowserVisitedPage]?
}
