import Foundation

/// Reading a sign-in command's terminal output, the same on every platform: the device code it
/// shows, whether it waits for a choice, and its text without terminal escapes.
extension AccountLoginController {
    nonisolated static func firstDeviceCode(in value: String) -> String? {
        let normalized = stripANSI(value)
        let pattern = #"(?i)(?:device\s+code|verification\s+code|code|코드)[^A-Z0-9]{0,24}([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in expression.matches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        ) {
            guard let range = Range(match.range(at: 1), in: normalized) else { continue }
            let candidate = String(normalized[range]).uppercased()
            if candidate != "HTTP", candidate != "HTTPS" { return candidate }
        }
        return nil
    }

    nonisolated static func outputRequiresInput(_ value: String) -> Bool {
        let normalized = stripANSI(value).lowercased()
        if normalized.contains("●"), normalized.contains("○") { return true }
        return [
            "select login method",
            "select authentication method",
            "login method",
            "choose a provider",
            "select a provider",
            "select provider",
            "enter api key"
        ].contains { normalized.contains($0) }
    }

    nonisolated static func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07]*(?:\\x07|\\x1B\\\\))",
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "\r", with: "")
    }
}
