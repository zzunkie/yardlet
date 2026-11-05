import Foundation

/// npm's command shims on Windows. `npm install -g` writes a `.cmd` file for each program a package has
/// (npm's cmd-shim), which runs Node.js on the package's script under `node_modules`. `CreateProcessW`
/// starts a batch file through `cmd.exe`, which reads the arguments by its own rules rather than the ones
/// Foundation's `Process` quotes them for (the "BatBadBut" family), so Yardlet never starts a batch file
/// itself: for npm's shim it starts what the shim would, Node.js on the script with the same arguments, and
/// it refuses any other batch file. The Windows layer asks before every process it starts
/// (Platform/Windows/NativeProcessTree.swift); elsewhere there are no batch files.
enum NPMCommandShim {
    /// What a shim starts.
    struct Target: Equatable {
        /// Node.js's arguments before the script, from the script's `#!` line.
        var nodeArguments: [String]
        /// The script, relative to the shim's folder, in its components.
        var script: [String]
        /// The shim starts the script itself, a package's program without a `#!` line, not Node.js on it.
        var startsScriptItself: Bool
    }

    /// How to start `executable` with `arguments`: nil when it is not a batch file, which starts as it is.
    /// For npm's shim, Node.js (the one beside the shim, as the shim prefers, else the first in `searchPath`)
    /// on the shim's script, with `arguments` after it. Any other batch file is refused.
    static func launch(
        _ executable: URL,
        arguments: [String],
        searchPath: String,
        lookup: ExecutableLookup = .current,
        fileManager: FileManager = .default
    ) throws -> (executable: URL, arguments: [String])? {
        guard lookup.isBatchFile(executable) else { return nil }
        let name = executable.lastPathComponent
        // cmd-shim's files are a few hundred bytes.
        guard let data = fileManager.contents(atPath: executable.path(percentEncoded: false)), data.count <= 64 * 1024,
              let target = parse(String(decoding: data, as: UTF8.self)) else {
            throw NPMCommandShimError.notAShim(name)
        }
        let programs = lookup.programsOnly
        let folder = executable.deletingLastPathComponent()
        let script = target.script.reduce(folder) { $0.appending(path: $1) }.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard script.pathComponents.contains(where: { $0.lowercased() == "node_modules" }),
              fileManager.fileExists(atPath: script.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NPMCommandShimError.notAShim(name)
        }
        if target.startsScriptItself {
            guard programs.program(at: script, fileManager: fileManager) == script else {
                throw NPMCommandShimError.notAShim(name)
            }
            return (script, arguments)
        }
        guard let node = programs.program(at: folder.appending(path: "node"), fileManager: fileManager)
            ?? programs.find("node", inSearchPath: searchPath, fileManager: fileManager) else {
            throw NPMCommandShimError.nodeNotFound(name)
        }
        return (node, target.nodeArguments + [lookup.nativePath(script)] + arguments)
    }

    /// What the shim `text` starts, or nil when it is not one of cmd-shim's: its last line ending in `%*`
    /// starts Node.js (`node`, `node.exe` beside the shim, or `%_prog%` set only to those) on a script
    /// beside the shim (`"%dp0%\…"`, older shims `"%~dp0\…"`), or starts that script itself. A shim that
    /// also sets a variable for the script (`#!/usr/bin/env -S NAME=value node`) is not one Yardlet starts.
    static func parse(_ text: String) -> Target? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where line.uppercased().hasPrefix("@SET ") {
            let name = line.dropFirst(5).prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
            guard name.uppercased() == "PATHEXT" else { return nil }
        }
        guard let line = lines.last(where: { $0.hasSuffix("%*") }) else { return nil }
        // cmd-shim's line runs its command after `endLocal & … &`.
        let command = line.split(separator: "&", omittingEmptySubsequences: false).last.map(String.init) ?? line
        var tokens = Self.tokens(of: command)
        guard tokens.count >= 2, tokens.removeLast() == "%*", let script = scriptComponents(tokens.removeLast()) else {
            return nil
        }
        guard !tokens.isEmpty else {
            return Target(nodeArguments: [], script: script, startsScriptItself: true)
        }
        let program = tokens.removeFirst()
        guard startsNode(program, in: lines), tokens.allSatisfy(isPlain) else { return nil }
        return Target(nodeArguments: tokens, script: script, startsScriptItself: false)
    }

    /// The words of a command, quotes taken off; a leading `@` only keeps cmd from echoing it.
    private static func tokens(of command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var started = false
        for character in command {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if character.isWhitespace, !quoted {
                if started { tokens.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { tokens.append(current) }
        if let first = tokens.first, first.hasPrefix("@") { tokens[0] = String(first.dropFirst()) }
        return tokens.filter { !$0.isEmpty }
    }

    /// The components of a script the shim names beside itself, or nil for anything else.
    private static func scriptComponents(_ token: String) -> [String]? {
        let lowered = token.lowercased()
        guard let prefix = ["%dp0%\\", "%~dp0\\"].first(where: { lowered.hasPrefix($0) }) else { return nil }
        let relative = token.dropFirst(prefix.count)
        guard !relative.contains(where: { "%!\"^&|<>".contains($0) }) else { return nil }
        let components = relative.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
            .filter { $0 != "." }
        return components.isEmpty ? nil : components
    }

    /// Whether `program` is Node.js: `node`, the `node.exe` beside the shim, or `%_prog%` where the shim
    /// sets `_prog` to nothing else.
    private static func startsNode(_ program: String, in lines: [String]) -> Bool {
        let nodeNames: Set<String> = ["node", "%dp0%\\node.exe", "%~dp0\\node.exe"]
        guard program.lowercased() == "%_prog%" else { return nodeNames.contains(program.lowercased()) }
        let assigned = lines.compactMap { line -> String? in
            guard let range = line.range(of: "SET \"_prog=", options: .caseInsensitive) else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "\"" }).lowercased()
        }
        return !assigned.isEmpty && assigned.allSatisfy(nodeNames.contains)
    }

    /// A word that means the same to `cmd.exe` and to Node.js: nothing `cmd.exe` would expand or split.
    private static func isPlain(_ word: String) -> Bool {
        !word.isEmpty && !word.contains { "%!\"^&|<>()".contains($0) || $0.isWhitespace }
    }
}

enum NPMCommandShimError: LocalizedError, Equatable {
    /// The batch file is not one of npm's shims.
    case notAShim(String)
    /// The shim's Node.js is neither beside it nor in `Path`.
    case nodeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAShim(let name):
            return L10n.format("%@ is a batch file. Yardlet starts a batch file only when it is npm's launcher for a Node.js program.", name)
        case .nodeNotFound(let name):
            return L10n.format("Node.js, which %@ runs on, was not found in Path.", name)
        }
    }
}
