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
}
