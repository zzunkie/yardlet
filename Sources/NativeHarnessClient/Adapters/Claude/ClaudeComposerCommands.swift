import Foundation

enum ClaudeComposerCommands {
    /// The CLI 2.1.284 probe's terminal-only built-ins. Before the first system/init arrives,
    /// keep these out of a GUI menu; its own terminal_slash_commands becomes authoritative after
    /// that. User/project commands without the builtin marker are not hidden by this fallback.
    private static let bootstrapTerminalCommands: Set<String> = ["doctor", "color", "focus", "reload-plugins"]

    static func decode(_ value: JSONValue?) -> [ProviderComposerCommand] {
        var commands: [ProviderComposerCommand] = []
        for row in value?.arrayValue ?? [] {
            guard let name = row["name"]?.stringValue, ProviderComposerCommand.isValidName(name) else { continue }
            let command = ProviderComposerCommand(
                name: name, description: name == "clear"
                    ? L10n.string("Start a new conversation and keep this chat.")
                    : row["description"]?.stringValue ?? "",
                argumentHint: row["argumentHint"]?.stringValue ?? "",
                aliases: row["aliases"]?.arrayValue?.compactMap(\.stringValue).filter(ProviderComposerCommand.isValidName),
                builtin: row["builtin"]?.boolValue
            )
            if let index = commands.firstIndex(where: { $0.name == name }) {
                // The SDK documents that the built-in wins a same-name collision, independent
                // of row order. An alias never overrides another command's actual name.
                if command.builtin == true && commands[index].builtin != true { commands[index] = command }
            } else {
                commands.append(command)
            }
        }
        return commands
    }

    static func initial(_ response: JSONValue) -> [ProviderComposerCommand] {
        decode(response["commands"]).filter {
            $0.builtin != true || !bootstrapTerminalCommands.contains($0.name)
        }
    }

    static func refreshed(_ current: [ProviderComposerCommand], from frame: JSONValue) -> [ProviderComposerCommand]? {
        guard frame["type"]?.stringValue == "system", frame["subtype"]?.stringValue == "init",
              frame["parent_tool_use_id"]?.stringValue?.isEmpty != false,
              let names = frame["slash_commands"]?.arrayValue else { return nil }
        let terminal = Set(frame["terminal_slash_commands"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var result: [ProviderComposerCommand] = []
        for name in names.compactMap(\.stringValue) {
            guard ProviderComposerCommand.isValidName(name), !terminal.contains(name),
                  !result.contains(where: { $0.name == name }) else { continue }
            result.append(current.first { $0.name == name }
                ?? ProviderComposerCommand(name: name, description: name == "clear"
                    ? L10n.string("Start a new conversation and keep this chat.") : "", argumentHint: ""))
        }
        return result
    }

    /// Claude Code manages plugins with `/plugin` (alias `/plugins`) in its terminal interface only. The
    /// session Yardlet runs neither lists it nor runs it: 2.1.327 answers "/plugin isn't available in this
    /// environment" without a model turn. While the CLI lists no command of that name, the task composer
    /// offers it as the harness settings sheet's Plugins section, where the account's plugins are turned
    /// on and off (docs/PROVIDER_CONNECTIONS.md, "Skill and plugin switches").
    static func pluginManager(given commands: [ProviderComposerCommand]) -> ProviderComposerCommand? {
        let names: Set<String> = ["plugin", "plugins"]
        guard !commands.contains(where: { names.contains($0.name) || ($0.aliases ?? []).contains(where: names.contains) })
        else { return nil }
        return ProviderComposerCommand(name: "plugin", description: L10n.string("Turn plugins on and off in harness settings"),
                                       argumentHint: "", aliases: ["plugins"])
    }

    static func validateSubmission(_ text: String, commands: [ProviderComposerCommand] = []) throws {
        guard !isSessionReset(text, commands: commands) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Start a new conversation from this chat.")
            )
        }
    }

    static func isResetCandidate(_ text: String) -> Bool {
        let first = text.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace })
        return ["/clear", "/reset", "/new"].contains(String(first))
    }

    static func isSessionReset(_ text: String, commands: [ProviderComposerCommand]) -> Bool {
        let first = text.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace })
        let name = first.first == "/" ? String(first.dropFirst()) : ""
        let isResetAlias = ["reset", "new"].contains(name)
            && !commands.contains { $0.name == name && $0.builtin != true }
        return name == "clear" || isResetAlias
    }
}
