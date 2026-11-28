import Foundation

/// Reading a sign-in command's terminal output, the same on every platform: the device code it
/// shows, whether it waits for a choice, and its text without terminal escapes.
extension AccountLoginController {
    nonisolated private static let deviceCode = try! NSRegularExpression(
        pattern: #"(?i:\bcode\b|코드)[^\r\nA-Za-z0-9]{0,12}([0-9]{3} [0-9]{3}|[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})?)(?![\w-])"#
    )

    nonisolated static func firstDeviceCode(in value: String) -> String? {
        let normalized = stripANSI(value)
        for match in deviceCode.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let range = Range(match.range(at: 1), in: normalized) else { continue }
            let code = normalized[range]
            if code.contains(where: { $0.isNumber || $0 == "-" }) { return String(code) }
        }
        return nil
    }

    nonisolated static func outputRequiresInput(_ value: String, automaticPrompt: String? = nil) -> Bool {
        var normalized = stripANSI(value).lowercased()
        if let automaticPrompt, let prompt = normalized.range(of: automaticPrompt.lowercased(), options: .backwards) {
            // The CLI may keep the answered prompt and its radio choices in scrollback.
            let afterPrompt = normalized[prompt.upperBound...].split(separator: "\n")
            normalized = afterPrompt.drop(while: { line in
                let choice = line.trimmingCharacters(in: .whitespaces)
                return choice.isEmpty || choice.hasPrefix("●") || choice.hasPrefix("○")
            }).joined(separator: "\n")
        }
        // Read the active prompt, ignoring completed questions above it. Clack uses a
        // vertical rail around the choices, then replaces the diamond when answered.
        let rail = CharacterSet(charactersIn: "│┃ \t")
        var hasChoice = false
        for line in normalized.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: rail)
            if text.isEmpty { continue }
            if text.hasPrefix("●") || text.hasPrefix("○") {
                hasChoice = true
                continue
            }
            if text.hasPrefix("◇") || text.hasPrefix("✔") { return false }
            if hasChoice || text.hasPrefix("◆") { return true }
            if text.range(of: #"\[(?:y/n|n/y)\]\s*[:?]?$"#, options: .regularExpression) != nil { return true }
            if text.range(of: #"^enter (?:api key|start url|region)\s*[:?]?\s*$"#, options: .regularExpression) != nil {
                return true
            }
            return [
                "select credential", "select login method", "select authentication method", "login method",
                "choose a provider", "select a provider", "select provider", "press enter"
            ].contains { text.hasPrefix($0) }
        }
        return hasChoice
    }

    nonisolated static func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07]*(?:\\x07|\\x1B\\\\))",
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "\r", with: "")
    }
}
