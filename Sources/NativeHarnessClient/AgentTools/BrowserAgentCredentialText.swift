import Foundation

/// Text shaped like a key or token a service issues, wherever a browser tool reads it: a field that is not a password
/// field (a read-only box showing a bot token), a page's text, an address, a script's result. Its secret part becomes
/// `[hidden credential]`, and the prefix that names its kind stays, as `VaultSetupText` keeps a setup address. The shapes
/// are the prefixes services give their keys so that secret scanning finds them, with lengths ordinary words do not
/// reach; a secret without such a prefix (a signing secret in hex, an AWS secret key) is not found. On unless the person
/// turned it off in Settings (`VaultCenter.hidesCredentials`).
enum CredentialText {
    static let marker = "[hidden credential]"

    private struct Shape {
        /// Text every match holds, looked for before the expression runs.
        var anchors: [String]
        var pattern: NSRegularExpression
        var template = "$1" + CredentialText.marker

        init(_ anchors: [String], _ pattern: String, template: String? = nil) {
            self.anchors = anchors
            self.pattern = try! NSRegularExpression(pattern: pattern)
            if let template { self.template = template }
        }
    }

    private static let shapes: [Shape] = [
        // Slack bot, user, legacy, refresh and rotating tokens, and app-level tokens.
        Shape(["xox"], #"\b(xox[abposre](?:\.xox[abposr])?-)(?=[A-Za-z0-9-]*[0-9])[A-Za-z0-9-]{10,}"#),
        Shape(["xapp-"], #"\b(xapp-)[A-Za-z0-9-]{10,}"#),
        // Slack webhook and workflow addresses, also percent-encoded inside another address.
        Shape(["hooks.slack.com"], #"(hooks\.slack\.com(?:/|%2[Ff])(?:services|workflows|triggers)(?:/|%2[Ff]))"#
            + #"[A-Za-z0-9]+(?:(?:/|%2[Ff])[A-Za-z0-9]+)*"#),
        // GitHub personal, OAuth, user-to-server, server-to-server and refresh tokens, and fine-grained tokens.
        Shape(["gh"], #"\b(gh[pousr]_)[A-Za-z0-9]{30,}"#),
        Shape(["github_pat_"], #"\b(github_pat_)[A-Za-z0-9_]{30,}"#),
        // OpenAI (`sk-`, `sk-proj-`, `sk-svcacct-`) and Anthropic (`sk-ant-api03-`, `sk-ant-oat01-`) keys.
        Shape(["sk-"], #"\b(sk-(?:ant-[a-z]+[0-9]*-|proj-|svcacct-|admin-)?)(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{32,}"#),
        // Stripe secret and restricted keys, and webhook signing secrets.
        Shape(["k_live_", "k_test_"], #"\b([sr]k_(?:live|test)_)[A-Za-z0-9]{16,}"#),
        Shape(["whsec_"], #"\b(whsec_)[A-Za-z0-9+/=]{16,}"#),
        // AWS access key IDs, long-term and temporary.
        Shape(["AKIA", "ASIA"], #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        // Google API keys.
        Shape(["AIza"], #"\b(AIza)[0-9A-Za-z_-]{35}"#),
        // PEM and OpenSSH private keys and PGP private key blocks; one a cut left without its end, to the end of its body.
        Shape(["PRIVATE KEY"], #"(-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----)"#
            + #"(?:[\s\S]*?(-----END \2-----)|[A-Za-z0-9+/=\s\\]*)"#, template: "$1" + marker + "$3"),
    ]

    static func scrub(_ text: String) -> String {
        var text = text
        for shape in shapes where shape.anchors.contains(where: { text.contains($0) }) {
            text = shape.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                          withTemplate: shape.template)
        }
        return text
    }
}
