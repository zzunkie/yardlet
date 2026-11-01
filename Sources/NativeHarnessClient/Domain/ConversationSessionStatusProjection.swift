import Foundation

enum ConversationSessionControlRole: Int, CaseIterable, Sendable {
    case model
    case reasoning
    case mode
    case permission
}

enum ConversationSessionStatusProjection {
    static func inlineSelectors(
        from state: ProviderCapabilityState?
    ) -> [ProviderCapabilitySelector] {
        var selected: [ConversationSessionControlRole: ProviderCapabilitySelector] = [:]
        for selector in state?.selectors ?? [] {
            guard let role = role(for: selector), selected[role] == nil else { continue }
            selected[role] = selector
        }
        return ConversationSessionControlRole.allCases.compactMap { selected[$0] }
    }

    static func role(
        for selector: ProviderCapabilitySelector
    ) -> ConversationSessionControlRole? {
        let id = selector.id.lowercased()
        let category = selector.category?.lowercased() ?? ""
        if id == "model" || category == "model" { return .model }
        if id == "mode" || id == "sessionmode" || id == "collaborationmode" { return .mode }
        if category == "thought_level" || category == "model_config"
            || id.contains("reason") || id.contains("thinking") || id.contains("thought") {
            return .reasoning
        }
        if id.contains("permission") || id.contains("approval")
            || id.contains("review") || id.contains("sandbox") {
            return .permission
        }
        return nil
    }

    static func pendingPermissionCount(in entries: [TranscriptEntry]) -> Int {
        entries.reduce(into: 0) { count, entry in
            if case .permission(_, .pending) = entry.content { count += 1 }
        }
    }

    static func supportsPermissionRequests(_ harness: HarnessKind) -> Bool {
        switch HarnessCatalog.descriptor(for: harness)?.transport {
        case .codexAppServer, .claudeStreamJSON, .msp, .acp, .piRPC:
            return true
        case .cursorStreamJSON, nil:
            return false
        }
    }

    static func totalUsageTokens(_ usage: HarnessProtocolUsage?) -> UInt64? {
        guard let usage,
              usage.inputTokens != nil || usage.outputTokens != nil else { return nil }
        return addingWithoutOverflow(usage.inputTokens ?? 0, usage.outputTokens ?? 0)
    }

    static func contextFraction(_ usage: HarnessProtocolUsage?) -> Double? {
        guard let used = usage?.contextUsedTokens,
              let window = usage?.contextWindowTokens,
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    static func compactTokenCount(_ value: UInt64) -> String {
        switch value {
        case 0..<1_000:
            return String(value)
        case 1_000..<1_000_000:
            return String(format: value < 10_000 ? "%.1fK" : "%.0fK", Double(value) / 1_000)
        default:
            return String(format: value < 10_000_000 ? "%.1fM" : "%.0fM", Double(value) / 1_000_000)
        }
    }

    /// Providers do not agree on whether reasoning levels are advertised low-to-high or
    /// high-to-low. The shared menu should always present them from lower to higher effort.
    static func orderedReasoningChoices(
        _ choices: [ProviderCapabilityChoice]
    ) -> [ProviderCapabilityChoice] {
        let ranked = choices.enumerated().map { index, choice in
            (index, choice, reasoningRank(choice.value) ?? reasoningRank(choice.name))
        }
        guard ranked.allSatisfy({ $0.2 != nil }) else { return choices }
        return ranked.sorted {
            if $0.2 == $1.2 { return $0.0 < $1.0 }
            return $0.2! < $1.2!
        }.map(\.1)
    }

    static func isElevatedPermission(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("full")
            || normalized.contains("danger")
            || normalized.contains("bypass")
            || normalized.contains("전체")
    }

    private static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private static func reasoningRank(_ rawValue: String) -> Int? {
        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "effort", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return switch normalized {
        case "default": -1
        case "none", "off": 0
        case "minimal": 1
        case "low": 2
        case "medium": 3
        case "high": 4
        case "xhigh", "extra high": 5
        case "max": 6
        case "ultra": 7
        default: nil
        }
    }
}
