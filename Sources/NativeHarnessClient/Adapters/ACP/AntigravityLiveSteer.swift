import Foundation

/// Messages sent into a running Antigravity turn (an experimental setting, off by default).
///
/// `agy acp` takes no message while a prompt runs, but its `PreInvocation` hooks may answer with
/// `injectSteps`, and a `userMessage` step joins the running turn before its next model call: the
/// agent reads it at its next step, and the ACP stream reports it as a `user_message_chunk`.
///
/// The hook comes from an Antigravity plugin Yardlet adds while the setting is on: the folder
/// `~/.gemini/config/plugins/yardlet-live-steer/`, which `agy` reads for every conversation, also
/// outside Yardlet. Turning the setting off removes the folder, and nothing else of the person's
/// Antigravity configuration is written. A plugin keeps the hook out of the conversations themselves:
/// a hook folder passed with `--add-dir` would be recorded in each conversation's workspaces and
/// come back when the conversation continues outside Yardlet.
///
/// The hook (`deliver.sh`) reads the conversation ID from its input and hands over the message file
/// Yardlet left for that conversation (`pending/<conversation>.json`), taking it with one rename so
/// Yardlet and the hook never both have it. With no file it answers `{}` at once, which is all it
/// does for every conversation Yardlet did not write to.
struct AntigravityLiveSteer: Sendable {
    static let preferenceKey = "YardletAntigravityLiveSteer"
    static let pluginName = "yardlet-live-steer"

    /// The hook is a POSIX shell script, run by `sh -c`; Antigravity runs hooks with `cmd /c` on Windows.
    static var isSupported: Bool {
#if os(Windows)
        false
#else
        true
#endif
    }

    static func isEnabled(in defaults: UserDefaults = .yardlet) -> Bool {
        isSupported && defaults.bool(forKey: preferenceKey)
    }

    /// The plugin folder.
    let folder: URL
    /// Whether the setting is on now.
    let isEnabled: @Sendable () -> Bool

    static var live: AntigravityLiveSteer {
        AntigravityLiveSteer(
            folder: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".gemini/config/plugins/\(pluginName)", directoryHint: .isDirectory),
            isEnabled: { Self.isEnabled(in: .yardlet) })
    }

    /// Turns the setting on or off, adding or removing the plugin with it. Answers why nothing changed,
    /// or nil once it went through.
    static func setEnabled(_ isOn: Bool, in defaults: UserDefaults = .yardlet) -> String? {
        guard isSupported else { return nil }
        let plugin = AntigravityLiveSteer(folder: live.folder, isEnabled: { isOn })
        do {
            try plugin.reconcile()
        } catch {
            return error.localizedDescription
        }
        defaults.set(isOn, forKey: preferenceKey)
        return nil
    }

    // MARK: The plugin

    static let manifest = """
    {
      "name": "\(pluginName)",
      "author": "Yardlet"
    }

    """

    static let hooks = """
    {
      "\(pluginName)": {
        "PreInvocation": [
          { "type": "command", "command": "./deliver.sh", "timeout": 5 }
        ]
      }
    }

    """

    static let deliverScript = """
    #!/bin/sh
    # Added by Yardlet while its "Steer Antigravity turns" setting is on; turning it off removes this folder.
    # Hands a message Yardlet left for this conversation to the running turn, or answers {}.
    id=$(sed -n 's/.*"conversationId"[[:space:]]*:[[:space:]]*"\\([0-9A-Za-z-]*\\)".*/\\1/p' | head -n 1)
    file="pending/$id.json"
    if [ -n "$id" ] && [ -f "$file" ] && mv "$file" "$file.$$" 2>/dev/null; then
      cat "$file.$$"
      rm -f "$file.$$"
    else
      echo '{}'
    fi

    """

    private var manifestURL: URL { folder.appending(path: "plugin.json") }
    private var pendingFolder: URL { folder.appending(path: "pending", directoryHint: .isDirectory) }

    /// Whether the folder holds Yardlet's plugin, which is the only folder Yardlet removes.
    var isInstalled: Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return manifest["name"] == Self.pluginName
    }

    /// Writes the plugin, or brings an older copy up to date.
    func install(fileManager: FileManager = .default) throws {
        guard folder.lastPathComponent == Self.pluginName else { return }
        try fileManager.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
        let files = [("plugin.json", Self.manifest), ("hooks.json", Self.hooks), ("deliver.sh", Self.deliverScript)]
        for (name, contents) in files {
            let url = folder.appending(path: name)
            let data = Data(contents.utf8)
            if (try? Data(contentsOf: url)) != data {
                try data.write(to: url, options: .atomic)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "deliver.sh").path(percentEncoded: false))
    }

    /// Removes the plugin folder, with any message still in it, when it is Yardlet's.
    func remove(fileManager: FileManager = .default) throws {
        guard folder.lastPathComponent == Self.pluginName,
              fileManager.fileExists(atPath: folder.path(percentEncoded: false)), isInstalled else { return }
        try fileManager.removeItem(at: folder)
    }

    /// Puts the plugin where the setting says: there while it is on, gone while it is off.
    func reconcile(fileManager: FileManager = .default) throws {
        if isEnabled() { try install(fileManager: fileManager) } else { try remove(fileManager: fileManager) }
    }

    // MARK: Messages

    /// The message file for one conversation; nil for an ID the hook would not read.
    private func pendingURL(_ conversationID: String) -> URL? {
        guard !conversationID.isEmpty,
              conversationID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return pendingFolder.appending(path: "\(conversationID).json")
    }

    /// Leaves these messages for the conversation's next model call, in place of what was there.
    func leave(_ texts: [String], for conversationID: String, fileManager: FileManager = .default) throws {
        guard let url = pendingURL(conversationID) else {
            throw HarnessAdapterError.invalidProviderEvent(L10n.string("Antigravity did not take this message."))
        }
        // Brought back or up to date: another copy of Yardlet with the setting off may have removed it.
        try install(fileManager: fileManager)
        let steps = texts.map { ["userMessage": $0] }
        let data = try JSONSerialization.data(withJSONObject: ["injectSteps": steps], options: [.withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Takes back the messages left for the conversation. Nil when there is no file: the hook took it.
    func takeBack(for conversationID: String, fileManager: FileManager = .default) -> [String]? {
        guard let url = pendingURL(conversationID) else { return nil }
        let claimed = url.appendingPathExtension("yardlet-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: url, to: claimed)
        } catch {
            return nil
        }
        defer { try? fileManager.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["injectSteps"] as? [[String: Any]] else { return [] }
        return steps.compactMap { $0["userMessage"] as? String }
    }
}

/// What one Antigravity task has left for its running turn (`AntigravityLiveSteer`), and what the
/// agent has read of it. The adapter keeps one per task while its prompt runs.
struct AntigravitySteerLedger: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let messageID: String
        let text: String
    }

    /// In the message file, as last written.
    private(set) var waiting: [Entry] = []
    /// Taken by the hook, and not yet seen on the stream.
    private(set) var taken: [Entry] = []
    /// The `user_message_chunk` text read so far of the message being reported.
    private var chunks = ""

    var isEmpty: Bool { waiting.isEmpty && taken.isEmpty }

    /// The file was gone when Yardlet went to change it: the hook took all it held.
    mutating func hookTookWaiting() {
        taken += waiting
        waiting = []
    }

    mutating func add(_ entry: Entry) {
        waiting.append(entry)
    }

    /// Takes one waiting message out. False when it is not waiting (the hook has it, or it is unknown).
    mutating func withdraw(_ messageID: String) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.messageID == messageID }) else { return false }
        waiting.remove(at: index)
        return true
    }

    func holds(_ messageID: String) -> Bool {
        waiting.contains { $0.messageID == messageID } || taken.contains { $0.messageID == messageID }
    }

    /// A `user_message_chunk` on the stream. Returns the ID of the message it completes, if any. A chunk
    /// that begins no message Yardlet left (another hook's) is let go.
    mutating func read(chunk: String) -> String? {
        let candidates = taken + waiting
        guard !candidates.isEmpty else { return nil }
        chunks += chunk
        let seen = chunks.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = candidates.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == seen }) {
            chunks = ""
            if waiting.contains(match) { hookTookWaiting() }
            taken.removeAll { $0 == match }
            return match.messageID
        }
        if !candidates.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(seen) }) {
            chunks = ""
        }
        return nil
    }

    /// The turn ended. `fileHadMessages`: Yardlet took the file back, so what it held reached no model
    /// call. `hookPresent`: the plugin is still there, so a file that is gone was taken by the hook,
    /// not removed with the plugin.
    mutating func settle(fileHadMessages: Bool, hookPresent: Bool) -> (read: [String], returned: [String]) {
        var read = taken.map(\.messageID)
        var returned: [String] = []
        if fileHadMessages || !hookPresent {
            returned = waiting.map(\.messageID)
        } else {
            read += waiting.map(\.messageID)
        }
        self = AntigravitySteerLedger()
        return (read, returned)
    }
}
