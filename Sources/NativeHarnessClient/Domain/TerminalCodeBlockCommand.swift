import Foundation

/// What a code block in an answer runs in the task's terminal ("Run in terminal" beside "Copy code"), as
/// the Claude app's code blocks offer it: nil for a block that is not a command.
///
/// - A block in a shell language (`sh`, `bash`, `zsh`, `shell`, `shellscript`, `terminal`) runs whole, its
///   trailing blank lines left out.
/// - A session block (`console`, `shell-session`), or a shell block whose first line starts with the `$ `
///   prompt, runs the lines after `$ ` without it, with the lines a command continues onto (after a line ending
///   in `\`, or a `> ` continuation prompt), and leaves out the output lines between; with no `$ ` line there is
///   nothing to run.
/// - A block without a language, or `text`, runs only when every line reads as a command, by the Claude app's
///   test: no `|`, `&`, `;`, `<`, `>`, `(`, `)`, backquote, `$` or backslash, and a first word (after `sudo` and
///   `NAME=value` settings) that is a common command line tool or starts with `./`.
/// - A block holding an invisible formatting or control character (a zero-width space, a direction override)
///   runs nothing, as the Claude app leaves such a block without the button: what runs would not be what reads.
enum TerminalCodeBlockCommand {
    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell", "shellscript", "terminal"]
    static let sessionLanguages: Set<String> = ["console", "shell-session"]
    static let plainLanguages: Set<String> = ["", "text", "plaintext", "txt"]

    /// The Claude app's list of the tools a block without a language starts with.
    static let commonTools: Set<String> = [
        "aws", "brew", "bun", "bunx", "cargo", "cd", "chmod", "claude", "cp", "curl", "deno", "docker", "gcloud",
        "gh", "git", "grep", "kubectl", "ls", "mkdir", "mv", "node", "npm", "npx", "pip", "pip3", "pnpm", "python",
        "python3", "rg", "rm", "sed", "ssh", "tar", "uv", "wget", "yarn"
    ]

    static func command(language: String?, code: String) -> String? {
        // The info string's first word: "bash title=x" is bash.
        let language = (language ?? "").split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard !hasHiddenCharacters(code) else { return nil }
        let lines = code.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let firstLine = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let command: String?
        if sessionLanguages.contains(language) || firstLine.hasPrefix("$ ") {
            guard shellLanguages.contains(language) || sessionLanguages.contains(language)
                    || plainLanguages.contains(language) else { return nil }
            let commands = promptedCommands(lines)
            if plainLanguages.contains(language), !commands.allSatisfy(readsAsCommand) { return nil }
            command = commands.isEmpty ? nil : commands.joined(separator: "\n")
        } else if shellLanguages.contains(language) {
            command = lines.joined(separator: "\n")
        } else if plainLanguages.contains(language) {
            let commands = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            command = !commands.isEmpty && commands.allSatisfy(readsAsCommand) ? commands.joined(separator: "\n") : nil
        } else {
            command = nil
        }
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The lines after `$ `, and the lines they continue onto; the output between them is left out.
    private static func promptedCommands(_ lines: [String]) -> [String] {
        var commands: [String] = []
        // The command so far ends in `\`: the next line goes on with it.
        var continues = false
        for line in lines {
            if line.hasPrefix("$ ") {
                commands.append(String(line.dropFirst(2)))
            } else if let last = commands.last, continues || (line.hasPrefix("> ") && isOpen(last)) {
                commands[commands.count - 1] = last + "\n" + (line.hasPrefix("> ") ? String(line.dropFirst(2)) : line)
            } else {
                continues = false
                continue
            }
            continues = commands[commands.count - 1].hasSuffix("\\")
        }
        return commands
    }

    /// A command a `> ` prompt continues: an unclosed quote.
    private static func isOpen(_ command: String) -> Bool {
        command.filter { $0 == "'" }.count % 2 == 1 || command.filter { $0 == "\"" }.count % 2 == 1
    }

    /// The Claude app's test of a line in a block without a language.
    static func readsAsCommand(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.contains(where: { "|&;<>()`$\\".contains($0) }) else { return false }
        var words = line.split(separator: " ").map(String.init)
        if words.first == "sudo" { words.removeFirst() }
        while let word = words.first, let equals = word.firstIndex(of: "="), equals != word.startIndex,
              word[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            words.removeFirst()
        }
        guard let tool = words.first else { return false }
        return tool.hasPrefix("./") || commonTools.contains(tool)
    }

    private static func hasHiddenCharacters(_ code: String) -> Bool {
        code.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { return false }
            switch scalar.properties.generalCategory {
            case .format, .control, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: return true
            default: return false
            }
        }
    }
}
