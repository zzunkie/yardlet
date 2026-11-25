import Foundation

/// A web site as the agent's navigations are allowed by it: scheme, host and port together, so allowing
/// `http://localhost:3000` allows no other port of the Mac, and `https://docs.stripe.com` no other host
/// (docs/AGENT_BROWSER_TOOLS.md, "Where the browser goes").
struct BrowserSite: Hashable, Sendable {
    let scheme: String
    /// In lower case, an IPv6 address without its brackets.
    let host: String
    let port: Int

    init?(_ address: String) {
        // Chromium reads an address by the WHATWG URL rules and Foundation by RFC 3986, which disagree on a backslash
        // (`http://a.test\@localhost:3000` goes to a.test), on a user name, on control characters, which Chromium drops,
        // and on escapes and other characters in a host. An address whose authority holds any of these, or that does not
        // start `scheme://`, names no site here: it is asked about each time and can be allowed for no task.
        guard let colon = address.firstIndex(of: ":"), address[colon...].hasPrefix("://"),
              !address.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let authority = address[address.index(colon, offsetBy: 3)...].prefix { !"/?#".contains($0) }
        guard !authority.isEmpty, authority.unicodeScalars.allSatisfy({ $0.isASCII && !"\\@%".unicodeScalars.contains($0) })
        else { return nil }
        guard let components = URLComponents(string: address),
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        self.scheme = scheme
        self.host = host
        port = components.port ?? Self.defaultPort(scheme)
    }

    /// As an address field writes it: the port only where it is not the scheme's own.
    var text: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(name)" + (port == Self.defaultPort(scheme) ? "" : ":\(port)")
    }

    /// `localhost`, `127.0.0.1` or `::1`: a server on this Mac, which a task may open freely where it listens itself.
    var isLoopbackName: Bool { ["localhost", "127.0.0.1", "::1"].contains(host) }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }
}

/// Where a `browser_navigate` goes, as Yardlet's approvals weigh it.
enum BrowserNavigationTarget: Hashable, Sendable {
    /// `about:blank`, which shows nothing and sends nothing.
    case blank
    /// A `file:` address, weighed by the task's folders (`BrowserAgentTools.allowFile`).
    case file
    /// A web site, which the person may allow for the task.
    case site(BrowserSite)
    /// Any other address (`data:`, another `about:` page): asked about each time, since it names no site to allow.
    case other(String)

    init(_ address: String) {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        switch BrowserURLPolicy.scheme(of: value) {
        case "about" where value.lowercased() == "about:blank": self = .blank
        case "file": self = .file
        case "http", "https": self = BrowserSite(value).map(Self.site) ?? .other(value)
        default: self = .other(value)
        }
    }

    /// What a batch's card lets through for its own run (`BrowserNavigationPass`): the site, or the whole address.
    var passKey: String {
        switch self {
        case .blank: "about:blank"
        case .file: "file:"
        case let .site(site): site.text
        case let .other(address): address
        }
    }

    /// How a card names it: the site, or the address cut short (a `data:` address can be long).
    var cardText: String {
        switch self {
        case let .site(site): site.text
        case let .other(address): address.count > 120 ? String(address.prefix(120)) + "…" : address
        case .blank, .file: passKey
        }
    }
}

/// The addresses the person allowed on a `browser_batch`'s card, which its own navigations go to without another
/// card while it runs. A navigation that ends somewhere else, a redirect, is weighed again.
enum BrowserNavigationPass {
    @TaskLocal static var allowed: Set<String> = []
}

/// The answers a navigation's card offers: Deny, Allow once, and for a web site, Allow it in this task.
enum BrowserNavigationAnswer: Equatable, Sendable {
    case denied
    case once
    case site

    static let denyID = "deny"
    static let onceID = "allow-once"
    static let siteID = "allow-site-in-task"

    /// The card's answers. The site's answer names it; the narrowest allow is the card's main one.
    static func actions(site: String?) -> [PermissionRequestAction] {
        var actions = [
            PermissionRequestAction(id: denyID, text: LocalizedText("Deny"), decision: .deny, kind: "reject_once"),
            PermissionRequestAction(id: onceID, text: LocalizedText("Allow once"), decision: .allow, kind: "allow_once")
        ]
        if let site {
            actions.append(PermissionRequestAction(id: siteID, text: LocalizedText("Allow %@ in this task", .verbatim(site)),
                                                   decision: .allow, kind: "allow_session"))
        }
        return actions
    }

    init(actionID: String?) {
        switch actionID {
        case Self.siteID?: self = .site
        case Self.onceID?: self = .once
        default: self = .denied
        }
    }
}
