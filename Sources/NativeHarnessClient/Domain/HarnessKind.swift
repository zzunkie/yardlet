import Foundation

struct HarnessKind: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    static let codex = HarnessKind(rawValue: "codex")
    static let claudeCode = HarnessKind(rawValue: "claude-code")
    static let museCode = HarnessKind(rawValue: "muse-code")
    static let openCode = HarnessKind(rawValue: "opencode")
    static let cursorAgent = HarnessKind(rawValue: "cursor-agent")
    static let antigravityCLI = HarnessKind(rawValue: "antigravity-cli")
    static let kimiCode = HarnessKind(rawValue: "kimi-code")
    static let grokBuild = HarnessKind(rawValue: "grok-build")
    static let hermes = HarnessKind(rawValue: "hermes-agent")
    static let pi = HarnessKind(rawValue: "pi")

    var displayName: String {
        HarnessCatalog.descriptor(for: self)?.displayName ?? rawValue
    }

    var symbolName: String {
        HarnessCatalog.descriptor(for: self)?.symbolName ?? "puzzlepiece.extension"
    }
}

enum HarnessTransportKind: String, Codable, Hashable, Sendable {
    case codexAppServer
    case claudeStreamJSON
    case msp
    case acp
    case piRPC
    case cursorStreamJSON
}

struct HarnessDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: HarnessKind
    let displayName: String
    let shortName: String
    let symbolName: String
    let transport: HarnessTransportKind
    let executableName: String
    let launchArguments: [String]
    let relativeExecutablePaths: [String]
    let websiteURL: URL
    let repositoryURL: URL?
    let isLegacy: Bool

    init(
        id: HarnessKind,
        displayName: String,
        shortName: String,
        symbolName: String,
        transport: HarnessTransportKind,
        executableName: String,
        launchArguments: [String],
        relativeExecutablePaths: [String],
        websiteURL: URL,
        repositoryURL: URL? = nil,
        isLegacy: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.symbolName = symbolName
        self.transport = transport
        self.executableName = executableName
        self.launchArguments = launchArguments
        self.relativeExecutablePaths = relativeExecutablePaths
        self.websiteURL = websiteURL
        self.repositoryURL = repositoryURL
        self.isLegacy = isLegacy
    }
}

enum HarnessCatalog {
    static let builtIns: [HarnessDescriptor] = [
        HarnessDescriptor(
            id: .codex,
            displayName: "Codex",
            shortName: "Codex",
            symbolName: "terminal",
            transport: .codexAppServer,
            executableName: "codex",
            launchArguments: ["app-server", "--stdio"],
            relativeExecutablePaths: [".local/bin/codex"],
            websiteURL: URL(string: "https://openai.com/codex/")!
        ),
        HarnessDescriptor(
            id: .claudeCode,
            displayName: "Claude Code",
            shortName: "Claude",
            symbolName: "sparkles",
            transport: .claudeStreamJSON,
            executableName: "claude",
            launchArguments: [],
            relativeExecutablePaths: [".local/bin/claude"],
            websiteURL: URL(string: "https://www.anthropic.com/claude-code")!
        ),
        HarnessDescriptor(
            id: .museCode,
            displayName: "Muse Code",
            shortName: "Muse",
            symbolName: "infinity",
            transport: .msp,
            executableName: "muse",
            launchArguments: ["serve"],
            relativeExecutablePaths: [".local/bin/muse"],
            websiteURL: URL(
                string: "https://developer.meta.com/ai/resources/blog/build-with-muse-code/"
            )!,
            repositoryURL: URL(string: "https://github.com/meta-models/muse-code-sdk")!
        ),
        HarnessDescriptor(
            id: .openCode,
            displayName: "OpenCode",
            shortName: "OpenCode",
            symbolName: "chevron.left.forwardslash.chevron.right",
            transport: .acp,
            executableName: "opencode",
            launchArguments: ["acp"],
            relativeExecutablePaths: [".opencode/bin/opencode", ".local/bin/opencode"],
            websiteURL: URL(string: "https://opencode.ai/")!
        ),
        HarnessDescriptor(
            id: .cursorAgent,
            displayName: "Cursor Agent",
            shortName: "Cursor",
            symbolName: "cursorarrow.motionlines",
            transport: .cursorStreamJSON,
            executableName: "cursor-agent",
            launchArguments: ["--print", "--output-format", "stream-json"],
            relativeExecutablePaths: [".local/bin/cursor-agent"],
            websiteURL: URL(string: "https://cursor.com/cli")!
        ),
        HarnessDescriptor(
            id: .antigravityCLI,
            displayName: "Antigravity CLI",
            shortName: "Antigravity",
            symbolName: "arrow.up.and.down.and.arrow.left.and.right",
            transport: .acp,
            executableName: "agy",
            launchArguments: ["acp"],
            relativeExecutablePaths: [".local/bin/agy"],
            websiteURL: URL(string: "https://antigravity.google/docs/cli/getting-started")!
        ),
        HarnessDescriptor(
            id: .kimiCode,
            displayName: "Kimi Code",
            shortName: "Kimi",
            symbolName: "moon.stars",
            transport: .acp,
            executableName: "kimi",
            launchArguments: ["acp"],
            relativeExecutablePaths: [".kimi-code/bin/kimi", ".local/bin/kimi"],
            websiteURL: URL(string: "https://www.kimi.com/code/docs/en/")!
        ),
        HarnessDescriptor(
            id: .grokBuild,
            displayName: "Grok Build",
            shortName: "Grok",
            symbolName: "bolt",
            transport: .acp,
            executableName: "grok",
            launchArguments: ["agent", "stdio"],
            relativeExecutablePaths: [".local/bin/grok"],
            websiteURL: URL(string: "https://github.com/xai-org/grok-build")!
        ),
        HarnessDescriptor(
            id: .hermes,
            displayName: "Hermes Agent",
            shortName: "Hermes",
            symbolName: "wand.and.stars",
            transport: .acp,
            executableName: "hermes",
            launchArguments: ["acp"],
            relativeExecutablePaths: [".local/bin/hermes", ".hermes/hermes-agent/venv/bin/hermes"],
            websiteURL: URL(string: "https://hermes-agent.nousresearch.com/")!,
            repositoryURL: URL(string: "https://github.com/NousResearch/hermes-agent")!
        ),
        HarnessDescriptor(
            id: .pi,
            displayName: "Pi",
            shortName: "Pi",
            symbolName: "number",
            transport: .piRPC,
            executableName: "pi",
            launchArguments: ["--mode", "rpc"],
            relativeExecutablePaths: [".local/bin/pi", ".bun/bin/pi"],
            websiteURL: URL(string: "https://pi.dev/")!
        )
    ]

    /// Harnesses that were built in and have been removed. Their saved tasks still load under
    /// their identifiers; Yardlet's own settings for them (the chosen runtime, saved accounts,
    /// remembered account readings, CLI update records and Yardlet's copies of earlier versions)
    /// are dropped when those stores load. The harnesses' own files are untouched.
    static let retired: Set<HarnessKind> = [
        HarnessKind(rawValue: "gemini-cli"),
        HarnessKind(rawValue: "gajae-code"),
        HarnessKind(rawValue: "deep-agents-code"),
        HarnessKind(rawValue: "oh-my-pi")
    ]

    private static let descriptorsByID = Dictionary(
        uniqueKeysWithValues: builtIns.map { ($0.id, $0) }
    )

    static func descriptor(for id: HarnessKind) -> HarnessDescriptor? {
        descriptorsByID[id]
    }
}
