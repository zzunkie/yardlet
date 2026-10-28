import Foundation
import YardletAgentTools

/// An icon an MCP server gives for itself in `initialize`'s `serverInfo.icons` (MCP 2025-11-25 `Icon`).
struct MCPServerIcon: Codable, Equatable, Sendable {
    var src: String
    var mimeType: String?
    /// "48x48", "any", …
    var sizes: [String]?
    /// "light" for a light background, "dark" for a dark one; nil for either.
    var theme: String?

    init(src: String, mimeType: String? = nil, sizes: [String]? = nil, theme: String? = nil) {
        self.src = src
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }

    /// The icons in a `serverInfo`, skipping any without a source.
    static func list(in serverInfo: ToolJSON?) -> [MCPServerIcon] {
        (serverInfo?["icons"]?.arrayValue ?? []).compactMap { icon in
            guard let src = icon["src"]?.stringValue?.trimmingCharacters(in: .whitespaces), !src.isEmpty else { return nil }
            let sizes = icon["sizes"]?.arrayValue?.compactMap(\.stringValue) ?? icon["sizes"]?.stringValue.map { [$0] }
            return MCPServerIcon(src: src, mimeType: icon["mimeType"]?.stringValue, sizes: sizes,
                                 theme: icon["theme"]?.stringValue)
        }
    }

    /// Codex's measure: "any" or no sizes is the largest; otherwise the largest width × height.
    var area: Double {
        guard let sizes, !sizes.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "any" }) else {
            return .infinity
        }
        return sizes.compactMap { size -> Double? in
            let parts = size.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
            return width * height
        }.max() ?? 0
    }
}

/// Where a connector's picture comes from, best first, for a light and a dark background.
///
/// The two apps differ (docs/CONNECTORS.md, "Icons"): Codex draws the icons an MCP server declares about
/// itself (`serverInfo.icons`, https or data only, the largest for each theme) and the pictures it
/// carries for its own connectors; the Claude app draws its directory's icon and, for a server
/// without one, the server domain's favicon through a third-party service. Yardlet takes the
/// server's own icons when it gave any, then the directory's icon on the service's own site, and
/// nothing from any other site. The symbol stands in until one loads, or when none does.
struct ConnectorIconSources: Equatable, Sendable {
    var light: [URL]
    var dark: [URL]

    static let none = ConnectorIconSources(light: [], dark: [])

    func urls(dark isDark: Bool) -> [URL] { isDark ? dark : light }

    var isEmpty: Bool { light.isEmpty && dark.isEmpty }

    static func make(serverURL: URL?, serverIcons: [MCPServerIcon]?, preset: ConnectorPreset?) -> ConnectorIconSources {
        let declared = (serverIcons ?? []).compactMap { icon -> (icon: MCPServerIcon, url: URL)? in
            guard let url = URL(string: icon.src),
                  ConnectorIconSite.accepts(url, serverURL: serverURL, preset: preset) else { return nil }
            return (icon, url)
        }
        func best(_ theme: String?) -> URL? {
            declared.filter { $0.icon.theme?.lowercased() == theme }.max { $0.icon.area < $1.icon.area }?.url
        }
        let either = best(nil), light = best("light"), dark = best("dark")
        let directory = preset?.iconURL
        return ConnectorIconSources(light: unique([light, either, dark, directory]),
                                    dark: unique([dark, either, light, directory]))
    }

    /// A directory entry's own icon.
    static func preset(_ id: String?) -> ConnectorIconSources {
        guard let preset = id.flatMap(ConnectorPreset.preset(id:)) else { return .none }
        return make(serverURL: preset.serverURL, serverIcons: nil, preset: preset)
    }

    /// Google, for the one sign-in that serves Gmail, Calendar, and Drive.
    static let google: ConnectorIconSources = {
        let url = URL(string: "https://www.gstatic.com/images/branding/product/2x/googleg_48dp.png")!
        return ConnectorIconSources(light: [url], dark: [url])
    }()

    private static func unique(_ urls: [URL?]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// Whose site an icon address is on: an icon an MCP server declares is drawn only from that
/// server's own site (or the directory's site for the service), never from another one.
enum ConnectorIconSite {
    static func accepts(_ url: URL, serverURL: URL?, preset: ConnectorPreset?) -> Bool {
        if url.scheme?.lowercased() == "data" { return url.absoluteString.lowercased().hasPrefix("data:image/") }
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        let own = [serverURL?.host(), preset?.iconURL?.host()].compactMap { $0?.lowercased() }.map(baseDomain)
        return own.contains(baseDomain(host))
    }

    /// The registrable part of a host, closely enough for this check: its last two labels, three
    /// under a two-letter country code's "co"/"com"/"net"/"org" ("example.co.uk").
    static func baseDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        if labels[labels.count - 1].count == 2, ["co", "com", "net", "org", "ac", "go"].contains(labels[labels.count - 2]) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

extension ConnectorPreset {
    /// Each service's icon on its own site, linked from its own home page, checked 2026-10-22 with an
    /// unauthenticated GET (docs/CONNECTORS.md, "Icons"). Services with only a 16 px icon (monday.com), that
    /// refused the request (Gamma, DeepWiki), or with icons only on another company's host (Jam) keep
    /// their symbol. Google's product icons are on Google's own `gstatic.com`.
    static let iconAddresses: [String: String] = [
        "linear": "https://linear.app/static/apple-touch-icon.png",
        "notion": "https://www.notion.com/front-static/logo-ios.png",
        "slack": "https://slack.com/favicon.ico",
        "gmail": "https://www.gstatic.com/images/branding/product/2x/gmail_2020q4_48dp.png",
        // The Mac's own apps draw from the icons macOS gives them (`ConnectorIconStore`), and App
        // Store Connect's is on Apple's developer site (checked 2026-10-26, 96 px at 2x).
        "apple-calendar": "file:///System/Applications/Calendar.app",
        "apple-reminders": "file:///System/Applications/Reminders.app",
        "apple-contacts": "file:///System/Applications/Contacts.app",
        "xcode": "file:///Applications/Xcode.app",
        "app-store-connect": "https://developer.apple.com/assets/elements/icons/app-store-connect/app-store-connect-96x96_2x.png",
        "google-calendar": "https://www.gstatic.com/images/branding/product/2x/calendar_2020q4_48dp.png",
        "google-drive": "https://www.gstatic.com/images/branding/product/2x/drive_2020q4_48dp.png",
        "github": "https://github.com/fluidicon.png",
        "browserbase": "https://www.browserbase.com/favicon.svg",
        "atlassian": "https://www.atlassian.com/apple-touch-icon.png",
        "sentry": "https://sentry.io/favicon.ico",
        "asana": "https://asana.com/assets/img/brand/asana-logo-favicon.ico",
        "clickup": "https://clickup.com/favicons/apple-touch-icon.png",
        "todoist": "https://www.todoist.com/static/favicon.ico",
        "airtable": "https://www.airtable.com/favicon.ico",
        "miro": "https://miro.com/favicon.ico",
        "dropbox": "https://cfl.dropboxstatic.com/static/metaserver/static/images/favicon.ico",
        "intercom": "https://www.intercom.com/intercom-marketing-site/favicons/favicon.ico",
        "zapier": "https://zapier.com/favicon.ico",
        "granola": "https://www.granola.ai/favicon/apple-touch-icon.png",
        "fireflies": "https://fireflies.ai/apple-touch-icon.png",
        "gitlab": "https://about.gitlab.com/images/ico/favicon-192x192.png",
        "supabase": "https://supabase.com/favicon/apple-icon-180x180.png",
        "neon": "https://neon.com/apple-touch-icon.png",
        "prisma": "https://www.prisma.io/apple-icon.png",
        "netlify": "https://www.netlify.com/favicon/apple-touch-icon.png",
        "cloudflare": "https://www.cloudflare.com/favicon.ico",
        "posthog": "https://posthog.com/icons/icon-192x192.png",
        "semgrep": "https://semgrep.dev/favicon.ico",
        "postman": "https://www.postman.com/_mk-www-next/icons/android-chrome-192x192.png",
        "stripe": "https://stripe.com/favicon.ico",
        "paypal": "https://www.paypal.com/favicon.ico",
        "square": "https://squareup.com/apple-touch-icon.png",
        "mercury": "https://mercury.com/apple-icon.png",
        "webflow": "https://webflow.com/apple-touch-icon.png",
        "wix": "https://www.wix.com/favicon.ico",
        "figma-desktop": "https://static.figma.com/app/icon/2/touch-180.png",
        "tavily": "https://www.tavily.com/apple-icon.png",
        "exa": "https://exa.ai/favicon.ico",
        "huggingface": "https://huggingface.co/favicon.ico",
        "context7": "https://context7.com/favicon.ico",
        "openai-docs": "https://developers.openai.com/favicon.png",
        "microsoft-learn": "https://learn.microsoft.com/apple-touch-icon.png",
        "aws-knowledge": "https://aws.amazon.com/apple-touch-icon.png",
        "cloudflare-docs": "https://developers.cloudflare.com/favicon.png",
        // Checked 2026-10-29 the same way. BrowserStack, BugSnag, Fathom, Mapbox, Port, and Zephyr link
        // icons only on another company's host, Grafana's is 16 px, CircleCI's own is a dark mark that
        // vanishes on a dark background, and Contentful and PandaDoc refused the request, so they keep
        // their symbol.
        "basecamp": "https://basecamp.com/assets/images/general/apple-touch-icon.png",
        "teamwork": "https://www.teamwork.com/favicon.ico",
        "lucid": "https://lucid.co/favicon.ico",
        "deepl": "https://www.deepl.com/apple-icon",
        "mobbin": "https://mobbin.com/mobbin-marketing-pages/images/apple-touch-icon.png",
        "apollo-io": "https://www.apollo.io/apple-icon.png",
        "attio": "https://attio.com/favicon.ico",
        "customer-io": "https://customer.io/apple-touch-icon.png",
        "klaviyo": "https://www.klaviyo.com/icons/icon-192x192.png",
        "mailerlite": "https://www.mailerlite.com/site/themes/new/img/favicons/apple-touch-icon.png",
        "ahrefs": "https://ahrefs.com/apple-touch-icon.png",
        "semrush": "https://www.semrush.com/favicon.ico",
        "similarweb": "https://www.similarweb.com/favicon.ico",
        "amplitude": "https://amplitude.com/nextjs-public/favicon/apple-touch-icon.png",
        "mixpanel": "https://mixpanel.com/favicon.ico",
        "swagger": "https://swagger.io/swagger_fav.png",
        "honeycomb": "https://www.honeycomb.io/favicon.ico",
        "axiom": "https://axiom.co/apple-touch-icon.png",
        "statsig": "https://www.statsig.com/images/favicons/favicon180.png",
        "aiven": "https://aiven.io/favicons/apple-touch-icon.png",
        "upstash": "https://upstash.com/icons/apple-touch-icon.png",
        "algolia": "https://www.algolia.com/favicon.ico",
        "sanity": "https://www.sanity.io/apple-touch-icon.png",
        "workos": "https://workos.com/apple-touch-icon.png",
        "apify": "https://apify.com/apple-icon.png",
        "ramp": "https://ramp.com/apple-touch-icon.png",
        "brex": "https://www.brex.com/apple-touch-icon.png",
        "paddle": "https://www.paddle.com/favicon.ico",
        "beancount-io": "https://beancount.io/img/favicon.png",
        "hostinger": "https://www.hostinger.com/favicon.ico"
    ]

    /// The service's icon on its own site, when the directory has one.
    var iconURL: URL? { Self.iconAddresses[id].flatMap(URL.init(string:)) }

    /// The directory entry a harness's own server stands for, by its address or else by its name.
    static func preset(forServerNamed name: String, url: URL? = nil) -> ConnectorPreset? {
        if let url, let preset = preset(for: url) { return preset }
        return all.first { $0.isNamed(name) }
    }
}

extension ConnectorRecord {
    /// Its server's own icons, then its directory entry's.
    var iconSources: ConnectorIconSources {
        .make(serverURL: localService == nil ? serverURL : nil, serverIcons: serverIcons, preset: preset ?? presetID.flatMap(ConnectorPreset.preset(id:)))
    }
}
