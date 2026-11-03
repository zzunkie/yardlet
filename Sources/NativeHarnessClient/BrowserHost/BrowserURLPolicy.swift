import Foundation

/// Which URLs the in-window browser may load: http, https, file, about and data. Everything else
/// (javascript:, chrome:, devtools:, custom app schemes, …) is refused, both when typed into the
/// address field and when a page, a redirect or the agent tries to navigate there. The host
/// applies the same list to every navigation it sees.
enum BrowserURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "file", "about", "data"]

    enum AddressError: Error, Equatable {
        case empty
        case blockedScheme(String)
        case invalid
    }

    /// The scheme of `url` in lower case, or nil when it has none.
    static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    static func isAllowed(_ url: String) -> Bool {
        guard let scheme = scheme(of: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Turns address-field input into a URL: explicit allowed schemes pass through, paths become
    /// file URLs, loopback hosts use http and other host names use https.
    static func resolve(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AddressError.empty }
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            let path = value.hasPrefix("~/")
                ? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false) + String(value.dropFirst(1))
                : value
            return URL(filePath: path).absoluteString
        }
        if let scheme = scheme(of: value), !looksLikeHostWithPort(value) {
            guard allowedSchemes.contains(scheme) else { throw AddressError.blockedScheme(scheme) }
            return value
        }
        guard !value.contains(where: \.isWhitespace) else { throw AddressError.invalid }
        let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let candidate = (isLoopback(host) ? "http://" : "https://") + value
        guard let components = URLComponents(string: candidate), components.host?.isEmpty == false else {
            throw AddressError.invalid
        }
        return candidate
    }

    /// Chrome's default search engine, where address-field text that is no address goes.
    static let searchURL = "https://www.google.com/search"

    /// Address-field text as Chrome's omnibox reads it: an address opens as `resolve` makes it, and
    /// anything else (words, a single word that names no host, text after "?") is searched.
    static func addressFieldURL(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AddressError.empty }
        if value.hasPrefix("?") { return try search(String(value.dropFirst())) }
        return looksLikeAddress(value) ? try resolve(value) : try search(value)
    }

    static func search(_ terms: String) throws -> String {
        let query = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw AddressError.empty }
        // "+" too, which a query reads as a space ("c++").
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { throw AddressError.invalid }
        return searchURL + "?q=" + encoded
    }

    /// The search of a results page `search` made, or nil for any other address.
    static func searchTerms(in url: String) -> String? {
        guard url.hasPrefix(searchURL + "?"), let components = URLComponents(string: url),
              let terms = components.queryItems?.first(where: { $0.name == "q" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines), !terms.isEmpty else { return nil }
        return terms
    }

    /// Two addresses of the same page, apart from a fragment and trailing slashes: the one a load error names
    /// and the one the page commits at.
    static func sameAddress(_ first: String?, _ second: String?) -> Bool {
        func normalized(_ address: String?) -> String? {
            guard var address, !address.isEmpty else { return nil }
            if let hash = address.firstIndex(of: "#") { address = String(address[..<hash]) }
            while address.hasSuffix("/") { address.removeLast() }
            return address
        }
        guard let first = normalized(first), let second = normalized(second) else { return false }
        return first == second
    }

    /// A path, a URL with "://", a loopback host, a host with a port, or a dotted host name whose last
    /// label could be a top-level domain. Text with spaces and other single words are search terms.
    static func looksLikeAddress(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.contains("://") { return true }
        if value.contains(where: \.isWhitespace) { return false }
        if scheme(of: value) != nil { return true }
        let host = value.prefix { !"/?#".contains($0) }.lowercased()
        if isLoopback(host) || looksLikeHostWithPort(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last else { return false }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        return last.hasPrefix("xn--") || (last.count >= 2 && last.allSatisfy(\.isLetter))
    }

    /// `localhost:3000` and `example.com:8080/x` parse as a scheme followed by a port.
    private static func looksLikeHostWithPort(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let rest = value[value.index(after: colon)...]
        let port = rest.prefix { $0 != "/" }
        return !port.isEmpty && port.allSatisfy(\.isNumber)
    }

    static func isLoopback(_ hostAndPort: String) -> Bool {
        var host = hostAndPort.lowercased()
        if host == "::1" { return true }
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
            return host == "::1"
        }
        host = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
