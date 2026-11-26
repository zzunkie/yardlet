import Foundation

/// Names the packaged mark for each built-in harness. Each platform layer loads the image
/// from its own resources; a harness without a mark falls back to its catalog symbol.
enum HarnessLogoAsset {
    static let subdirectory = "HarnessLogos"

    static func name(for harness: HarnessKind) -> String? {
        switch harness {
        case .codex: "codex"
        case .claudeCode: "claude-code"
        case .museCode: "muse-code"
        case .openCode: "opencode"
        case .cursorAgent: "cursor-agent"
        case .antigravityCLI: "antigravity-cli"
        case .kimiCode: "kimi-code"
        case .grokBuild: "grok-build"
        case .hermes: "hermes-agent"
        case .kiroCLI: "kiro-cli"
        case .pi: "pi"
        default: nil
        }
    }

    /// The mark the harness's own app shows in dark mode, where the light one would stand out as a bright
    /// tile. A harness without one keeps its single mark in both appearances.
    static func darkName(for harness: HarnessKind) -> String? {
        switch harness {
        case .codex: "codex-dark"
        default: nil
        }
    }
}
