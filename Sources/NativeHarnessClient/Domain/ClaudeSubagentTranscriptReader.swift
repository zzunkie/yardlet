import Crypto
import Foundation

/// Read-only counterpart of Claude's listSubagents/getSubagentMessages. Resolve beneath the
/// saved parent's config directory; never resume an agent or interpret a task ID as a session.
struct ClaudeSubagentTranscriptReader: Sendable {
    let configDirectory: URL
    var maximumBytes = 8 * 1_048_576
    var maximumEntries = 500

    struct SessionSnapshot: Sendable {
        let forkSource: HarnessSessionForkSource
        let transcript: HarnessSubtaskTranscript
    }

    static func fileFingerprints(_ paths: [String], in session: SessionRecord) throws -> [String: String] {
        guard paths.count <= 256 else { throw HarnessAdapterError.capabilityUnavailable("Too many files to review") }
        let roots = ([session.workspaceURL] + session.additionalRootURLs).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var result: [String: String] = [:]
        for path in paths {
            let url = (path.hasPrefix("/") ? URL(filePath: path)
                : session.workspaceURL.appending(path: path)).standardizedFileURL
            guard let root = roots.first(where: { url.path.hasPrefix($0.path + "/") }) else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("A restore file is outside this project's folders."))
            }
            let components = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
            let files = ScopedFiles(root: root)
            guard files.isRegularFile(components) else {
                let names = try files.names(Array(components.dropLast()), limit: 4_096)
                guard !names.contains(components.last ?? "") else {
                    throw HarnessAdapterError.capabilityUnavailable(L10n.string("A restore file cannot be safely reviewed."))
                }
                result[path] = "missing"
                continue
            }
            guard let value = try files.data(components, maximumBytes: 32 * 1_048_576, tail: false), !value.truncated else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("A restore file cannot be safely reviewed."))
            }
            result[path] = SHA256.hash(data: value.data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    /// Read the main transcript's current chain to pin a native fork. A missing file is different
    /// from a substituted/non-regular file: the latter must never trigger a fresh CLI fork.
    func readSession(sessionID: String, throughMessageID: String? = nil) throws -> SessionSnapshot? {
        guard let (chain, truncated) = try mainChain(sessionID: sessionID) else { return nil }
        let selected = chain.lastIndex { value in
            value["type"]?.stringValue == "assistant" && value["isMeta"]?.boolValue != true
                && value["isSidechain"]?.boolValue != true
                && value["parent_tool_use_id"]?.stringValue?.isEmpty != false
                && value["uuid"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil
                && (throughMessageID == nil || value["uuid"]?.stringValue == throughMessageID)
        }
        guard let selected, let messageID = chain[selected]["uuid"]?.stringValue else { throw sessionUnavailable() }
        return SessionSnapshot(forkSource: .init(providerSessionID: sessionID, throughMessageID: messageID),
            transcript: projectChain(Array(chain.prefix(selected + 1)), sessionID: sessionID, wasTruncated: truncated))
    }

    /// Reading the original branch includes the trailing user/tool/error entries too. A fork
    /// needs an assistant boundary, but opening a saved conversation must not drop its tail.
    ///
    /// The read takes the file's newest `maximumBytes`. When the conversation goes on before them
    /// (`hasEarlierRecords`), the turn they begin inside is left out, so the first turn shown starts
    /// with its request and keeps its ID when a larger read brings in the turns before it. A
    /// compaction does not end the conversation shown: the turns before it follow on above it.
    func readConversation(sessionID: String) throws -> HarnessSubtaskTranscript? {
        guard let read = try mainChainRead(sessionID: sessionID, crossesCompactions: true) else { return nil }
        return projectChain(read.chain, sessionID: sessionID, wasTruncated: read.truncated,
                            startsInsideConversation: read.startsInsideConversation)
    }

    // MARK: - Reading a conversation in parts

    /// The conversation's newest part: the file's newest `bytes`, or further back when they hold no
    /// whole message (one line longer than the budget), and the window the read covered, which a
    /// read further back (`readEarlier`) grows. The conversation shown goes on above a compaction,
    /// as the Claude app shows a saved conversation; a compaction's summary is not shown. Entries
    /// keep the IDs their records give them however the reads are split.
    func readNewest(sessionID: String, bytes: Int) throws -> ClaudeTranscriptRead? {
        guard let path = try transcriptPath(sessionID: sessionID) else { return nil }
        guard let file = projectFiles.openRegularFile(path) else { throw sessionUnavailable() }
        var budget = bytes
        while true {
            let (data, start) = try file.lines(from: max(0, file.size - Int64(budget)), to: file.size)
            let scan = try self.scan(data, at: start, sessionID: sessionID)
            if scan.leaf == nil, start > 0, budget < ClaudeTranscriptTail.placeBytes {
                budget = ClaudeTranscriptTail.budget(after: budget)
                continue
            }
            let walk = try Self.walk(from: scan.leaf, in: scan.records, crossesCompactions: true, failure: unavailable())
            let hasEarlier = start > 0 && walk.missingParent != nil
            let chain = Self.restoringParallelToolResults(walk.chain, records: scan.records).compactMap { scan.values[$0] }
            let projection = projectChainDetailed(chain, sessionID: sessionID, wasTruncated: false,
                                                  startsInsideConversation: hasEarlier,
                                                  limit: TranscriptBuilder.maximumEntryLimit, keepsLeadingPart: true)
            let entries = projection.transcript.entries
            let contextUsage = ClaudeTranscriptContextUsage.latest(in: chain)
            // Only part of the last turn: shown as it is, and read whole once a read reaches its request.
            if hasEarlier, !entries.contains(where: \.opensTurn) {
                return ClaudeTranscriptRead(entries: entries, window: ClaudeTranscriptWindow(
                    sessionID: sessionID, file: file.identity, end: file.size, bytes: budget, start: start,
                    records: scan.records, seamRecord: nil, seamEntry: nil, partialRecord: walk.chain.last,
                    partialEntry: entries.last?.id, hasEarlierRecords: true), contextUsage: contextUsage)
            }
            // Begun inside a turn before the first request read: that turn's end (its last steps and
            // answer, and what Claude answered a notice after it) shows above the request, and a read
            // further back puts the whole turn in its place.
            if let leadingPartEnd = projection.leadingPartEnd {
                return ClaudeTranscriptRead(entries: entries, window: ClaudeTranscriptWindow(
                    sessionID: sessionID, file: file.identity, end: file.size, bytes: budget, start: start,
                    records: scan.records, seamRecord: projection.firstTurnSource,
                    seamEntry: entries.first(where: \.opensTurn)?.id, partialEntry: leadingPartEnd,
                    hasEarlierRecords: true), contextUsage: contextUsage)
            }
            return ClaudeTranscriptRead(entries: entries, window: ClaudeTranscriptWindow(
                sessionID: sessionID, file: file.identity, end: file.size, bytes: budget, start: start,
                records: scan.records, seamRecord: projection.firstSource ?? walk.chain.first,
                seamEntry: entries.first?.id, hasEarlierRecords: hasEarlier), contextUsage: contextUsage)
        }
    }

    /// `window` grown back to the file's newest `bytes` as it was when the newest part was read. Only
    /// the lines before the window are parsed. The chain goes on from the record the entries shown
    /// begin with, through what is now covered, and its projection is what goes before them: the
    /// turn the read begins inside is left out, and nothing is when no turn's request was reached
    /// yet (a turn longer than the step), which a read further back then brings whole. The records
    /// already covered that the projection needs again are read back from the file by offset.
    func readEarlier(_ window: ClaudeTranscriptWindow, bytes: Int) throws -> ClaudeTranscriptRead? {
        var parsed: [String: JSONValue] = [:]
        return try readEarlier(window, bytes: bytes, parsed: &parsed)
    }

    /// The turns before the ones shown, as a request for earlier turns brings them: reads further
    /// back (`ClaudeTranscriptTail.budget(after:)`) until a turn's request arrives or the file's
    /// start. A turn longer than a step takes several; the records each one parsed are kept for the
    /// next, so every byte is parsed once.
    func readEarlierTurns(_ window: ClaudeTranscriptWindow) throws -> ClaudeTranscriptRead? {
        var window = window
        var parsed: [String: JSONValue] = [:]
        while true {
            guard let read = try readEarlier(window, bytes: ClaudeTranscriptTail.budget(after: window.bytes),
                                             parsed: &parsed) else { return nil }
            if !read.entries.isEmpty || !read.window.hasEarlierRecords { return read }
            window = read.window
        }
    }

    /// `parsed`: the values of the chain before the seam that an earlier step of the same request
    /// read, which this one holds again if it reaches no turn.
    private func readEarlier(_ window: ClaudeTranscriptWindow, bytes: Int,
                             parsed: inout [String: JSONValue]) throws -> ClaudeTranscriptRead? {
        // From the record before the seam, or, when the newest read held only part of the last turn,
        // from that read's end, so the turn is projected whole.
        let from: String?
        if let seam = window.seamRecord, let seamRecord = window.records[seam] {
            from = seamRecord.isCompaction ? seamRecord.logicalParent : seamRecord.parent
        } else if let partial = window.partialRecord, window.records[partial] != nil {
            from = partial
        } else {
            return try readNewest(sessionID: window.sessionID, bytes: bytes)
        }
        guard let path = try transcriptPath(sessionID: window.sessionID) else { return nil }
        guard let file = projectFiles.openRegularFile(path) else { throw sessionUnavailable() }
        // Claude appends to its transcript; one replaced since holds other lines at these offsets.
        guard file.identity == window.file, file.size >= window.end else { throw sessionUnavailable() }
        var scan = Scan()
        var start = window.start
        let budgetStart = max(0, window.end - Int64(bytes))
        if budgetStart < window.start {
            let (data, lineStart) = try file.lines(from: budgetStart, to: window.start)
            scan = try self.scan(data, at: lineStart, sessionID: window.sessionID)
            start = lineStart
        }
        let records = window.records.merging(scan.records) { later, _ in later }
        let walk = try Self.walk(from: from, in: records, crossesCompactions: true, stoppingAt: window.seamRecord,
                                 failure: unavailable())
        let hasEarlier = start > 0 && walk.missingParent != nil
        // A seam that is a result for a call before it is already shown.
        let ids = Self.restoringParallelToolResults(walk.chain, records: records, excluding: window.seamRecord)
        let chain = try ids.map { id in
            guard let record = records[id] else { throw sessionUnavailable() }
            // A record keeps the offset it was first indexed at: a line read later is an earlier one.
            if let value = scan.values[id], scan.records[id]?.offset == record.offset { return value }
            if let value = parsed[id] { return value }
            guard let value = try file.line(at: record.offset, length: record.length).flatMap(Self.parseLine) else {
                throw sessionUnavailable()
            }
            return value
        }
        parsed = Dictionary(zip(ids, chain)) { first, _ in first }
        let projection = projectChainDetailed(chain, sessionID: window.sessionID, wasTruncated: false,
                                              startsInsideConversation: hasEarlier,
                                              limit: TranscriptBuilder.maximumEntryLimit)
        let entries = projection.transcript.entries
        // No turn's request yet (a turn longer than the step): nothing changes but what is covered.
        guard !hasEarlier || entries.contains(where: \.opensTurn) else {
            return ClaudeTranscriptRead(entries: [], window: ClaudeTranscriptWindow(
                sessionID: window.sessionID, file: window.file, end: window.end, bytes: bytes, start: start,
                records: records, seamRecord: window.seamRecord, seamEntry: window.seamEntry,
                partialRecord: window.partialRecord, partialEntry: window.partialEntry, hasEarlierRecords: true))
        }
        let seamRecord = entries.isEmpty ? window.seamRecord ?? walk.chain.first : projection.firstSource ?? walk.chain.first
        return ClaudeTranscriptRead(entries: entries, window: ClaudeTranscriptWindow(
            sessionID: window.sessionID, file: window.file, end: window.end, bytes: bytes, start: start,
            records: records, seamRecord: seamRecord, seamEntry: entries.first?.id ?? window.seamEntry,
            hasEarlierRecords: hasEarlier),
            replacesThrough: window.partialEntry)
    }

    /// The conversation as it reads now, from the turns `shown` and the `window` they were read in:
    /// the newest part read again goes in place of the turns shown from its first one on, and the
    /// earlier turns the person brought in stay (following another app's writes, or opening the task
    /// again). When the newest part meets none of them (the window is new, the file was replaced, or
    /// more was written than a read takes), the read starts over from the newest part, going back
    /// as far as `ClaudeTranscriptTail.placeBytes` to hold `place`, the entry the person was reading.
    func refreshConversation(sessionID: String, window: ClaudeTranscriptWindow?, shown: [TranscriptEntry],
                             keeping place: String?) throws -> ClaudeTranscriptRead? {
        guard var read = try readNewest(sessionID: sessionID, bytes: ClaudeTranscriptTail.initialBytes) else { return nil }
        func readFurtherBack() throws -> Bool {
            guard read.window.hasEarlierRecords, read.window.bytes < ClaudeTranscriptTail.placeBytes,
                  let earlier = try readEarlier(read.window, bytes: ClaudeTranscriptTail.budget(after: read.window.bytes))
            else { return false }
            read = ClaudeTranscriptRead(entries: earlier.applied(to: read.entries), window: earlier.window,
                                        contextUsage: read.contextUsage)
            return true
        }
        if let window, window.file == read.window.file, read.window.end >= window.end, read.window.hasEarlierRecords,
           !shown.isEmpty {
            repeat {
                if let spliced = ClaudeTranscriptWindow.splicing(read.entries, into: shown) {
                    return ClaudeTranscriptRead(entries: spliced, window: window, contextUsage: read.contextUsage)
                }
            } while try readFurtherBack()
        }
        while let place, !read.entries.contains(where: { $0.id.uuidString == place }), try readFurtherBack() {}
        return read
    }

    /// The request a turn Claude Code started itself opened with: the `user` record saved under
    /// `uuid` near the transcript's end, read as the saved conversation reads it (a schedule's prompt,
    /// a background task's notice, another session's message), or none when the conversation shows
    /// none for it. Nil while the CLI has not written it, so the caller looks again.
    func request(savedUnder uuid: String, sessionID: String) throws -> [TranscriptEntry]? {
        guard UUID(uuidString: uuid) != nil, let path = try transcriptPath(sessionID: sessionID),
              let loaded = try projectFiles.data(path, maximumBytes: ClaudeTranscriptTail.initialBytes, tail: true)
        else { return nil }
        let data = loaded.data
        guard let found = data.range(of: Data(#""uuid":"\#(uuid)""#.utf8)) else { return nil }
        let start = data[..<found.lowerBound].lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
        let end = data[found.upperBound...].firstIndex(of: 10) ?? data.endIndex
        // A line still being written does not parse yet.
        guard let value = Self.parseLine(Data(data[start..<end])), value["uuid"]?.stringValue == uuid,
              value["type"]?.stringValue == "user",
              (value["sessionId"] ?? value["session_id"])?.stringValue?.lowercased() == sessionID.lowercased()
        else { return nil }
        return requestEntries(value, sessionID: sessionID)
    }

    /// The request a turn Claude Code started itself under no uuid opened with: the newest request
    /// saved near the transcript's end, when it is one Claude Code sent itself (a background task's
    /// notice, which 2.1.299 queues under no uuid, or a schedule's prompt). Nil while the newest is
    /// still a request the person sent, before the CLI has written the one this turn opened with,
    /// so the caller looks again. The CLI writes it as the turn starts, before it asks the model.
    func newestRequestClaudeSent(sessionID: String) throws -> [TranscriptEntry]? {
        guard let path = try transcriptPath(sessionID: sessionID),
              let loaded = try projectFiles.data(path, maximumBytes: ClaudeTranscriptTail.initialBytes, tail: true)
        else { return nil }
        let data = loaded.data
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[..<end].lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
            defer { end = start > data.startIndex ? data.index(before: start) : data.startIndex }
            let line = data[start..<end]
            guard line.range(of: Data(#""type":"user""#.utf8)) != nil, let value = Self.parseLine(Data(line)),
                  value["type"]?.stringValue == "user", value["isSidechain"]?.boolValue != true,
                  (value["sessionId"] ?? value["session_id"])?.stringValue?.lowercased() == sessionID.lowercased()
            else { continue }
            let request = requestEntries(value, sessionID: sessionID)
            guard let opener = request.first else { continue }
            guard case let .user(text, _) = opener.content,
                  opener.origin == .scheduled || ClaudeTaskNotification.parse(text) != nil else { return nil }
            return request
        }
        return nil
    }

    /// One saved `user` record read as the saved conversation reads it: its request, if it is one.
    private func requestEntries(_ value: JSONValue, sessionID: String) -> [TranscriptEntry] {
        projectChainDetailed([value], sessionID: sessionID, wasTruncated: false,
                             startsInsideConversation: false, limit: 8)
            .transcript.entries.filter { if case .user = $0.content { true } else { false } }
    }

    func conversationPoints(sessionID: String) throws -> [ClaudeConversationPoint] {
        guard let (chain, truncated) = try mainChain(sessionID: sessionID) else { return [] }
        var previousAssistant: String?
        var points: [(Int, String, String, String?, Bool, [CodexUserInput]?, String)] = []
        for (index, value) in chain.enumerated() {
            guard value["isMeta"]?.boolValue != true, value["isSidechain"]?.boolValue != true,
                  value["parent_tool_use_id"]?.stringValue?.isEmpty != false, !Self.isClaudesOwnNotice(value),
                  let uuid = value["uuid"]?.stringValue, UUID(uuidString: uuid) != nil else { continue }
            if value["type"]?.stringValue == "assistant" { previousAssistant = uuid; continue }
            guard value["type"]?.stringValue == "user" else { continue }
            let content = value["message"]?["content"]
            let blocks = content?.arrayValue ?? []
            // Tool results and local command echoes are not an editable user request.
            guard content?.stringValue != nil || blocks.contains(where: {
                ["text", "image", "document"].contains($0["type"]?.stringValue ?? "")
            }) else { continue }
            let text = ClaudeHostNotice.stripped(content?.stringValue ?? blocks.compactMap {
                $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
            }.joined(separator: "\n"))
            // The output half of a CLI `!` command belongs to its command, which is the point.
            if ClaudeBashMessage.isOutputOnly(text) { continue }
            var images: [CodexUserInput] = []
            var supported = true
            for block in blocks where block["type"]?.stringValue != "text" {
                guard block["type"]?.stringValue == "image", block["source"]?["type"]?.stringValue == "base64",
                      let mime = block["source"]?["media_type"]?.stringValue,
                      let data = block["source"]?["data"]?.stringValue,
                      let url = InlineImageInput.url(mimeType: mime, base64: data), images.count < 8 else {
                    supported = false; continue
                }
                images.append(.image(url, detail: .auto))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fingerprint = SHA256.hash(data: try encoder.encode(content ?? .null)).map { String(format: "%02x", $0) }.joined()
            points.append((index, uuid, text, previousAssistant,
                blocks.contains { $0["type"]?.stringValue != "text" }, supported ? images : nil, fingerprint))
        }
        return points.suffix(50).map { index, uuid, text, previous, attachments, images, fingerprint in
            ClaudeConversationPoint(id: uuid, text: text, previousAssistantID: previous, hasAttachments: attachments,
                precedingEntries: uuid == points.last?.1
                    ? projectChain(Array(chain.prefix(index)), sessionID: sessionID, wasTruncated: truncated).entries : [],
                imageInputs: images, inputFingerprint: fingerprint)
        }
    }

    private func mainChain(sessionID: String) throws -> ([JSONValue], Bool)? {
        try mainChainRead(sessionID: sessionID).map { ($0.chain, $0.truncated) }
    }

    /// The main transcript's active chain as far as the read reaches. `startsInsideConversation`:
    /// the read began inside the file and the chain's oldest record has a parent before it.
    private struct ChainRead {
        let chain: [JSONValue]
        let truncated: Bool
        let startsInsideConversation: Bool
    }

    /// The main transcript's chain within its newest `maximumBytes`. Fork and edit points stop at a
    /// compaction, where the conversation Claude resumes begins; reading it to show it goes on.
    private func mainChainRead(sessionID: String, crossesCompactions: Bool = false) throws -> ChainRead? {
        guard let path = try transcriptPath(sessionID: sessionID) else { return nil }
        guard let loaded = try projectFiles.data(path, maximumBytes: maximumBytes, tail: true) else {
            throw sessionUnavailable()
        }
        let active = try walkActiveChain(loaded.data, sessionID: sessionID, truncated: loaded.truncated,
                                         crossesCompactions: crossesCompactions, maximumLines: nil)
        return ChainRead(chain: active.chain, truncated: active.wasTruncated,
                         startsInsideConversation: loaded.truncated && active.parentIsBeforeData)
    }

    /// The records Claude Code reads back when it resumes the conversation, for the session jobs it
    /// brings back with them (`ClaudeSessionJobs`): the active chain from its last compaction on, as
    /// `mainChainRead` walks it. None when the newest `maximumBytes` name no session job at all. A
    /// chain that goes on before those bytes is read again from the file's newest `resumedReadLimit`.
    func recordsNamingSessionJobs(sessionID: String) throws -> [JSONValue] {
        guard let path = try transcriptPath(sessionID: sessionID) else { return [] }
        var budget = maximumBytes
        while true {
            guard let loaded = try projectFiles.data(path, maximumBytes: budget, tail: true) else {
                throw sessionUnavailable()
            }
            guard ClaudeSessionJobs.markers.contains(where: { loaded.data.range(of: $0) != nil }) else { return [] }
            let active = try walkActiveChain(loaded.data, sessionID: sessionID, truncated: loaded.truncated,
                                             maximumLines: nil)
            guard loaded.truncated, active.parentIsBeforeData, budget < Self.resumedReadLimit else { return active.chain }
            budget = Self.resumedReadLimit
        }
    }

    /// How far back a read of what Claude Code resumes goes when the conversation since its last
    /// compaction is longer than `maximumBytes`.
    static let resumedReadLimit = 64 * 1_048_576

    /// The conversation's transcript beneath the config's projects, nil when there is none. More than
    /// one, or one that is not a regular file, is refused.
    private func transcriptPath(sessionID: String) throws -> [String]? {
        guard UUID(uuidString: sessionID) != nil else { throw sessionUnavailable() }
        let files = projectFiles
        var candidates: [[String]] = []
        for directory in try files.directories([], limit: 512) {
            let project = [directory]
            for name in try files.names(project, limit: 4_096)
                where name.lowercased() == "\(sessionID.lowercased()).jsonl" {
                let path = project + [name]
                guard files.isRegularFile(path) else { throw sessionUnavailable() }
                candidates.append(path)
            }
        }
        guard candidates.count <= 1 else { throw sessionUnavailable() }
        return candidates.first
    }

    /// Claude keeps every conversation under the config's `projects` folder. An account folder may
    /// share that folder with another config through a link (Session Switch links each account's
    /// `projects` to `~/.claude/projects`). Follow that one top-level link; nothing beneath it.
    private var projectFiles: ScopedFiles {
        ScopedFiles(root: configDirectory.appending(path: "projects", directoryHint: .isDirectory)
            .resolvingSymlinksInPath())
    }

    static func configDirectory(
        connection: ProviderConnection?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspaceURL: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) -> URL {
        let values = environment.merging(connection?.environment ?? [:]) { _, new in new }
        if let path = values["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            return path.hasPrefix("/") ? URL(filePath: path, directoryHint: .isDirectory)
                : workspaceURL.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
        }
        let home = values["HOME"].flatMap {
            $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil
        } ?? homeURL
        return home.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// A saved record's time, with or without milliseconds. The format styles are values, so every
    /// record of a long transcript reads without making a formatter of its own.
    static func timestamp(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }

    func read(parentSessionID: String, reference: HarnessSubtaskReference) throws -> HarnessSubtaskTranscript {
        guard UUID(uuidString: parentSessionID) != nil, reference.hasConversation else { throw unavailable() }
        let files = projectFiles
        let projects = try files.directories([], limit: 512)
        var parents: [[String]] = []
        for project in projects {
            let path = [project, "\(parentSessionID).jsonl"]
            if files.isRegularFile(path) { parents.append([project, parentSessionID]) }
        }
        guard parents.count <= 1 else { throw unavailable() }
        guard let parent = parents.first else { return empty() }

        var pending: [([String], Int)] = [(parent + ["subagents"], 0)]
        var candidates: [[String]] = []
        var visited = 0
        while let (directory, depth) = pending.popLast() {
            visited += 1
            guard visited <= 128, depth <= 8 else { throw unavailable() }
            for name in try files.names(directory, limit: 1_024) {
                let path = directory + [name]
                if files.isDirectory(path) { pending.append((path, depth + 1)); continue }
                guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl"), files.isRegularFile(path) else { continue }
                let agentID = String(name.dropFirst(6).dropLast(6))
                guard Self.safeID(agentID) else { continue }
                let metadataPath = directory + [String(name.dropLast(6)) + ".meta.json"]
                let metadata = try files.data(metadataPath, maximumBytes: 65_536, tail: false)
                    .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.data) }
                let matches: Bool
                if let expected = reference.agentID {
                    matches = Self.safeID(expected) && agentID == expected
                } else if let toolID = reference.toolUseID {
                    // The SDK's sidecar explicitly binds an agent transcript to its tool use.
                    matches = metadata?["toolUseId"]?.stringValue == toolID
                } else {
                    // Only a provider-labelled local agent may use the task ID as a candidate.
                    matches = reference.taskType == "local_agent" && reference.taskID == agentID
                }
                if matches { candidates.append(path) }
            }
        }
        guard candidates.count <= 1 else { throw unavailable() }
        guard let path = candidates.first,
              let loaded = try files.data(path, maximumBytes: maximumBytes, tail: true) else { return empty() }
        return try project(loaded.data, parentSessionID: parentSessionID, truncated: loaded.truncated)
    }

    /// Follow UUID ancestry rather than concatenating abandoned/rewound branches. Partial
    /// writes are skipped and a compact/gapped chain is explicitly reported as truncated.
    func project(_ data: Data, parentSessionID: String, truncated: Bool = false) throws -> HarnessSubtaskTranscript {
        let (chain, wasTruncated) = try activeChain(data, sessionID: parentSessionID, truncated: truncated)
        return projectChain(chain, sessionID: parentSessionID, wasTruncated: wasTruncated)
    }

    private func activeChain(_ data: Data, sessionID: String, truncated: Bool) throws -> ([JSONValue], Bool) {
        let active = try walkActiveChain(data, sessionID: sessionID, truncated: truncated)
        return (active.chain, active.wasTruncated)
    }

    /// `parentIsBeforeData`: the walk stopped at a parent the data does not hold, rather than at the
    /// conversation's first record or a compaction. `maximumLines` bounds a read whose bytes are
    /// not otherwise bounded by the reader's own reads.
    private func walkActiveChain(_ data: Data, sessionID: String, truncated: Bool, crossesCompactions: Bool = false,
                                 maximumLines: Int? = 20_000) throws
        -> (chain: [JSONValue], wasTruncated: Bool, parentIsBeforeData: Bool) {
        let scan = try self.scan(data, at: 0, sessionID: sessionID, maximumLines: maximumLines)
        let walk = try Self.walk(from: scan.leaf, in: scan.records, crossesCompactions: crossesCompactions,
                                 failure: unavailable())
        let chain = Self.restoringParallelToolResults(walk.chain, records: scan.records).compactMap { scan.values[$0] }
        return (chain, truncated || walk.passedCompaction || walk.missingParent != nil, walk.missingParent != nil)
    }

    /// A transcript's lines as records, with their values for a projection.
    private struct Scan {
        var records: [String: ClaudeTranscriptWindow.Record] = [:]
        var values: [String: JSONValue] = [:]
        /// The newest user or assistant record that is not meta: where the conversation's chain ends.
        var leaf: String?
    }

    /// The records of `data`'s lines, whose first starts at `offset` in the file. A partial write
    /// (a line that does not parse) and a line without a record ID are skipped; a message from
    /// another session refuses the transcript. Of two lines with one ID the later is kept.
    private func scan(_ data: Data, at offset: Int64, sessionID: String, maximumLines: Int? = nil) throws -> Scan {
        var scan = Scan()
        var lines = 0
        let session = sessionID.lowercased()
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var lineStart = 0
            while lineStart < buffer.count {
                let lineEnd = memchr(base + lineStart, 10, buffer.count - lineStart)
                    .map { base.distance(to: UnsafeRawPointer($0)) } ?? buffer.count
                defer { lineStart = lineEnd + 1 }
                guard lineEnd > lineStart else { continue }
                lines += 1
                if let maximumLines, lines > maximumLines { throw unavailable() }
                guard let value = Self.parseLine(Data(buffer[lineStart..<lineEnd])),
                      let id = value["uuid"]?.stringValue else { continue }
                let type = value["type"]?.stringValue
                if type == "user" || type == "assistant" {
                    guard let recordSessionID = value["sessionId"]?.stringValue ?? value["session_id"]?.stringValue,
                          recordSessionID.lowercased() == session else { throw unavailable() }
                    if value["isMeta"]?.boolValue != true { scan.leaf = id }
                }
                scan.records[id] = Self.record(value, offset: offset + Int64(lineStart), length: lineEnd - lineStart)
                scan.values[id] = value
            }
        }
        return scan
    }

    /// One saved line. Foundation's JSONSerialization reads it several times faster than decoding
    /// `JSONValue` through Codable, which tries each value as other types first; a line it refuses
    /// is decoded that way. The Foundation objects it makes go with the line rather than waiting for
    /// the thread's autorelease pool, which a read of many megabytes would otherwise fill.
    static func parseLine(_ data: Data) -> JSONValue? {
        let value = autoreleasepool { () -> JSONValue? in
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return nil
            }
            return JSONValue(foundation: object)
        }
        return value ?? (try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    private static func record(_ value: JSONValue, offset: Int64, length: Int) -> ClaudeTranscriptWindow.Record {
        let blocks = value["message"]?["content"]?.arrayValue ?? []
        var toolUses: [String] = []
        var toolResults: [String] = []
        for block in blocks {
            if block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue {
                toolUses.append(id)
            } else if block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue {
                toolResults.append(id)
            }
        }
        return ClaudeTranscriptWindow.Record(
            offset: offset, length: length, parent: value["parentUuid"]?.stringValue,
            logicalParent: value["logicalParentUuid"]?.stringValue, type: value["type"]?.stringValue,
            isMeta: value["isMeta"]?.boolValue == true, isSidechain: value["isSidechain"]?.boolValue == true,
            isCompaction: value["subtype"]?.stringValue == "compact_boundary",
            toolUses: toolUses, toolResults: toolResults,
            isOnlyToolResults: !blocks.isEmpty && toolResults.count == blocks.count)
    }

    /// A walk of the conversation's chain by parent links.
    private struct Walk {
        /// The chain's records, oldest first.
        var chain: [String] = []
        /// The parent the chain goes on to that the records do not hold.
        var missingParent: String?
        var passedCompaction = false
    }

    /// Follows UUID ancestry from `cursor` rather than concatenating abandoned or rewound branches.
    /// A compaction's parent is empty: the conversation Claude resumes starts there. Crossing it
    /// goes on to the record before it (`logicalParentUuid`), the conversation the person had. A
    /// cycle, or a link back to `stoppingAt` (the record a read further back started from), fails.
    private static func walk(from cursor: String?, in records: [String: ClaudeTranscriptWindow.Record],
                             crossesCompactions: Bool, stoppingAt stop: String? = nil,
                             failure: @autoclosure () -> Error) throws -> Walk {
        var walk = Walk()
        var seen: Set<String> = stop.map { [$0] } ?? []
        var cursor = cursor
        while let id = cursor {
            guard seen.insert(id).inserted else { throw failure() }
            guard let record = records[id] else { walk.missingParent = id; break }
            walk.chain.append(id)
            if record.isCompaction {
                walk.passedCompaction = true
                cursor = crossesCompactions ? record.logicalParent : record.parent
            } else {
                cursor = record.parent
            }
        }
        walk.chain.reverse()
        return walk
    }

    /// Claude saves parallel tool calls as one entry each and parents every result on its own
    /// call, while the conversation continues from the last result only. The ancestry walk skips
    /// the other results, which Claude's own loader puts back on resume. Only a saved result for a
    /// call on this chain that the chain leaves unanswered returns, right after that call; a call
    /// with no saved result stays unanswered.
    private static func restoringParallelToolResults(
        _ chain: [String], records: [String: ClaudeTranscriptWindow.Record], excluding excluded: String? = nil
    ) -> [String] {
        var positions: [String: Int] = [:]
        var calls: Set<String> = []
        var answered: Set<String> = []
        for (index, id) in chain.enumerated() {
            positions[id] = index
            guard let record = records[id] else { continue }
            calls.formUnion(record.toolUses)
            answered.formUnion(record.toolResults)
        }
        guard !calls.isEmpty else { return chain }
        // Off the chain, in the order they were saved.
        let candidates = records.filter { id, record in
            positions[id] == nil && id != excluded && record.isOnlyToolResults
                && record.parent.flatMap { positions[$0] } != nil
        }.sorted { $0.value.offset < $1.value.offset }
        var restored: [Int: [String]] = [:]
        for (id, record) in candidates {
            guard record.type == "user", !record.isMeta, !record.isSidechain,
                  let index = record.parent.flatMap({ positions[$0] }),
                  records[chain[index]]?.type == "assistant" else { continue }
            let results = record.toolResults
            guard Set(results).count == results.count,
                  results.allSatisfy({ calls.contains($0) && !answered.contains($0) }) else { continue }
            answered.formUnion(results)
            restored[index, default: []].append(id)
        }
        guard !restored.isEmpty else { return chain }
        return chain.enumerated().flatMap { index, id in [id] + (restored[index] ?? []) }
    }

    private func projectChain(_ chain: [JSONValue], sessionID: String, wasTruncated: Bool,
                              startsInsideConversation: Bool = false) -> HarnessSubtaskTranscript {
        projectChainDetailed(chain, sessionID: sessionID, wasTruncated: wasTruncated,
                             startsInsideConversation: startsInsideConversation, limit: maximumEntries).transcript
    }

    /// A projection of saved records, and the record its first entry came from.
    private struct ChainProjection {
        let transcript: HarnessSubtaskTranscript
        let firstSource: String?
        /// Kept (`keepsLeadingPart`): the last entry of the turn the read began inside, which the
        /// entries begin with, and the record of the first request after it.
        var leadingPartEnd: UUID? = nil
        var firstTurnSource: String? = nil
    }

    /// `keepsLeadingPart`: a read that begins inside a turn keeps that turn's end instead of leaving
    /// it out, so the answer that ended it shows before the next request (the newest read; a read
    /// further back leaves it for the read that reaches its request).
    private func projectChainDetailed(_ chain: [JSONValue], sessionID: String, wasTruncated: Bool,
                                      startsInsideConversation: Bool, limit: Int,
                                      keepsLeadingPart: Bool = false) -> ChainProjection {
        var builder = TranscriptBuilder(limit: limit)
        // The live stream's projection, so a saved Agent call reads as the same card it was.
        var projection = ClaudeSessionProjection()
        var identities: [UUID: (id: UUID, createdAt: Date, source: String)] = [:]
        var count = 0
        /// The entries the builder added since its last entry was `lastID`: it only appends, and
        /// drops its oldest past its limit.
        func added(after lastID: UUID?) -> ArraySlice<TranscriptEntry> {
            guard let lastID, let index = builder.entries.lastIndex(where: { $0.id == lastID }) else {
                return builder.entries[...]
            }
            return builder.entries[(index + 1)...]
        }
        /// Names the entries one saved record added after that record, so a reread keeps them.
        func record(_ added: ArraySlice<TranscriptEntry>, from value: JSONValue) {
            let sourceID = value["uuid"]?.stringValue ?? ""
            // Claude writes millisecond timestamps, which the default formatter options reject.
            let timestamp = value["timestamp"]?.stringValue.flatMap(Self.timestamp)
                ?? Date(timeIntervalSince1970: 0)
            for (index, entry) in added.enumerated() {
                let bytes = Array(SHA256.hash(data: Data("\(sessionID)|\(sourceID)|\(index)".utf8)).prefix(16))
                let stableID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                    bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                identities[entry.id] = (stableID, timestamp, sourceID)
            }
        }
        for value in chain {
            // A message sent while a turn ran is saved as the command Claude read into that turn,
            // not as a user record; it stays in that turn, as the live stream showed it (D13).
            if value["type"]?.stringValue == "attachment", let text = Self.messageReadIntoTurn(value["attachment"]) {
                let lastID = builder.entries.last?.id
                builder.appendUser(text, joinsRunningTurn: true)
                record(added(after: lastID), from: value)
                continue
            }
            // So does a prompt Claude Code's own schedule sent: a `CronCreate` job or `/loop` wakeup
            // the CLI fired, a meta record, or a Claude app scheduled task (`ClaudeScheduledPrompt`).
            if let text = ClaudeScheduledPrompt.text(of: value) {
                count += 1
                let lastID = builder.entries.last?.id
                builder.appendUser(text, origin: .scheduled)
                record(added(after: lastID), from: value)
                continue
            }
            // A background command's or agent's notice opens the turn Claude answered it in, apart from
            // the turn before, whose answer stays its answer (`ClaudeTaskNotification`).
            if let notice = Self.backgroundTaskNotice(value) {
                count += 1
                let lastID = builder.entries.last?.id
                builder.appendUser(notice)
                record(added(after: lastID), from: value)
                continue
            }
            // A compaction reads as the marker the live stream shows. Its summary is the model's next
            // context, not a request the person made; the Claude app leaves it out too.
            let isCompaction = value["type"]?.stringValue == "system"
                && value["subtype"]?.stringValue == "compact_boundary"
            guard value["isMeta"]?.boolValue != true, value["isCompactSummary"]?.boolValue != true,
                  value["isVisibleInTranscriptOnly"]?.boolValue != true, !Self.isClaudesOwnNotice(value),
                  let type = value["type"]?.stringValue, ["user", "assistant"].contains(type) || isCompaction
            else { continue }
            count += 1
            let lastID = builder.entries.last?.id
            if type == "user" {
                let content = value["message"]?["content"]
                // A host app's notices before the person's text are context, not what they wrote.
                let text = ClaudeHostNotice.stripped(content?.stringValue ?? content?.arrayValue?.compactMap {
                    $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
                }.joined(separator: "\n") ?? "")
                // Claude saves an attached image inline; show it with its request as the live send did.
                // One saved another way still shows that an image was sent, and is never fetched.
                let images = (content?.arrayValue ?? []).compactMap { block -> TranscriptImageAttachment? in
                    guard block["type"]?.stringValue == "image" else { return nil }
                    let source = block["source"]
                    guard source?["type"]?.stringValue == "base64", let mimeType = source?["media_type"]?.stringValue,
                          let data = source?["data"]?.stringValue else { return TranscriptImageAttachment(url: nil, name: nil) }
                    return TranscriptImageAttachment(url: InlineImageInput.url(mimeType: mimeType, base64: data), name: nil)
                }
                // The CLI's own `!` saves the command and its output as two records; they read
                // as one command, as the Claude app's single bash message does.
                if images.isEmpty, let last = builder.entries.last, case let .user(previous, nil) = last.content,
                   let joined = ClaudeBashMessage.joining(input: previous, output: text) {
                    builder.replaceUserText(of: last.id, with: joined)
                } else if !text.isEmpty || !images.isEmpty {
                    builder.appendUser(text, images: images)
                }
            }
            // Child framing must remain in this reader, never leak into the parent transcript.
            guard case var .object(object) = value else { continue }
            object["parent_tool_use_id"] = .null
            // The saved log keeps the typed result the stream sends as `tool_use_result`.
            if let typed = object["toolUseResult"] { object["tool_use_result"] = typed }
            // and a compaction's sizes under the stream's names.
            if isCompaction, let saved = object["compactMetadata"] {
                object["compact_metadata"] = .object(["pre_tokens": saved["preTokens"] ?? .null,
                                                      "post_tokens": saved["postTokens"] ?? .null])
            }
            for payload in projection.payloads(from: .object(object)) { builder.apply(payload) }
            record(added(after: lastID), from: value)
        }
        builder.apply(.turnCompleted)
        var entries = builder.entries.suffix(limit).map { entry in
            let identity = identities[entry.id]
            return TranscriptEntry(id: identity?.id ?? entry.id,
                createdAt: identity?.createdAt ?? entry.createdAt, content: entry.content,
                joinsRunningTurn: entry.joinsRunningTurn, origin: entry.origin, isProgressUpdate: entry.isProgressUpdate)
        }
        var sources: [UUID: String] = [:]
        for identity in identities.values { sources[identity.id] = identity.source }
        let hasEarlierRecords = startsInsideConversation && builder.entries.count < limit
        var leadingPartEnd: UUID?
        var firstTurnSource: String?
        // The turn the read began inside reads whole once a larger read reaches its request.
        if hasEarlierRecords, let request = entries.firstIndex(where: \.opensTurn), request > 0 {
            if keepsLeadingPart {
                leadingPartEnd = entries[request - 1].id
                firstTurnSource = sources[entries[request].id]
            } else {
                entries.removeFirst(request)
            }
        }
        return ChainProjection(
            transcript: HarnessSubtaskTranscript(entries: entries,
                isTruncated: wasTruncated || count >= limit || builder.entries.count >= limit,
                hasEarlierRecords: hasEarlierRecords),
            firstSource: entries.first.flatMap { sources[$0.id] },
            leadingPartEnd: leadingPartEnd, firstTurnSource: firstTurnSource)
    }

    /// The text of a `user` record Claude Code wrote to start a turn when a background command or
    /// agent finished (`origin.kind` "task-notification", a `<task-notification>` block): the turn's
    /// opener, drawn as the notice (`ClaudeTaskNotification`), never as the person's message.
    static func backgroundTaskNotice(_ value: JSONValue) -> String? {
        guard value["type"]?.stringValue == "user",
              value["origin"]?["kind"]?.stringValue == "task-notification",
              value["isSidechain"]?.boolValue != true else { return nil }
        let content = value["message"]?["content"]
        let text = content?.stringValue ?? content?.arrayValue?.compactMap {
            $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
        }.joined(separator: "\n")
        guard let text, ClaudeTaskNotification.parse(text) != nil else { return nil }
        return text
    }

    /// A `user` record Claude Code wrote itself to start a turn — the notice that a background
    /// command or agent finished (`origin.kind` "task-notification", its text a
    /// `<task-notification>` block), or a Claude app scheduled task (subkind "scheduled-trigger").
    /// It is not a message the person sent, so it is not a point to rewind or edit to; the
    /// conversation shows it as its turn's notice (`backgroundTaskNotice`) or schedule
    /// (`ClaudeScheduledPrompt`). Other origins — a person, another session's message — read as before.
    static func isClaudesOwnNotice(_ value: JSONValue) -> Bool {
        guard value["type"]?.stringValue == "user" else { return false }
        let origin = value["origin"]?["kind"]?.stringValue
        if origin == "task-notification" { return true }
        // The continuation a host sends after its quit cut a turn off (Yardlet's, and the Claude
        // app's own) is the app speaking, not the person; the answer reads on from the cut turn.
        guard origin == nil || origin == RestartContinuation.claudeOrigin else { return false }
        let content = value["message"]?["content"]
        let text = content?.stringValue ?? content?.arrayValue?.compactMap {
            $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
        }.joined(separator: "\n")
        // The Claude app wakes a parent with its notice alone when a session it started finishes
        // a turn; nothing in it is the person's (an attachment would be).
        if let text, ClaudeHostNotice.isOnlyNotice(text),
           !(content?.arrayValue ?? []).contains(where: { $0["type"]?.stringValue != "text" }) {
            return true
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        // So is the continuation after a lost connection or the Mac's sleep (`TurnCut`); "Try again"
        // only as the host stamped it, since the person may type the same words.
        if trimmed == RestartContinuation.claudeAfterConnection { return origin == RestartContinuation.claudeOrigin }
        return trimmed == RestartContinuation.claudeText || trimmed == RestartContinuation.claudeAfterSleep
            || trimmed.map(interruptionNotes.contains) == true
    }

    /// The note Claude Code saves when a turn stops before it ends, whether the person stopped it or
    /// a quit ended the CLI (the record then says `interruptedByShutdown`). The Claude app 3.1623.3
    /// reads it as the turn's interruption, never as a message the person sent (`aH` in its
    /// conversation reader).
    static let interruptionNotes: Set<String> = ["[Request interrupted by user]",
                                                 "[Request interrupted by user for tool use]"]

    /// The text of a message a person sent while a turn ran, from the `queued_command` record
    /// Claude saves when it reads one into the turn. Commands Claude queued itself (a finished
    /// background task's notice, a bash command) are not messages and return nil.
    static func messageReadIntoTurn(_ attachment: JSONValue?) -> String? {
        guard let attachment, attachment["type"]?.stringValue == "queued_command",
              (attachment["commandMode"]?.stringValue ?? "prompt") == "prompt",
              (attachment["origin"]?["kind"]?.stringValue ?? "human") == "human" else { return nil }
        let prompt = attachment["prompt"]
        let text = prompt?.stringValue ?? prompt?.arrayValue?.compactMap {
            $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil
        }.joined(separator: "\n") ?? ""
        return text.isEmpty ? nil : text
    }

    private func empty() -> HarnessSubtaskTranscript { .init(entries: [], isTruncated: false) }
    private func sessionUnavailable() -> HarnessAdapterError {
        .capabilityUnavailable(L10n.string("The saved conversation cannot be forked."))
    }
    private func unavailable() -> HarnessAdapterError {
        .capabilityUnavailable(L10n.string("The child conversation could not be read."))
    }
    static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

extension ClaudeSubagentTranscriptReader {
    /// The conversation's newest `pr-link` record (`ClaudePullRequestLinkScanner`), read beneath the
    /// config's projects as the conversation itself is read. `previous`, a scan of the same file,
    /// makes the read cover only what Claude appended since; an unchanged file is not read at all.
    /// Nil when the conversation has no transcript. Only the record's fields are kept.
    func pullRequestLinkScan(sessionID: String, previous: ClaudePullRequestLinkScan?) throws -> ClaudePullRequestLinkScan? {
        // Tasks in view are looked at every half minute. While the file the last scan found is
        // still that same file, it is read again without walking every project folder for it.
        let files = projectFiles
        if let previous, let path = previous.path,
           path.last?.lowercased() == "\(sessionID.lowercased()).jsonl",
           let file = files.openRegularFile(path),
           ClaudePullRequestLinkScan.FileIdentity(device: file.identity.device, inode: file.identity.inode) == previous.file {
            return try scanLink(in: file, at: path, previous: previous)
        }
        guard let path = try transcriptPath(sessionID: sessionID),
              let file = files.openRegularFile(path) else { return nil }
        return try scanLink(in: file, at: path, previous: previous)
    }

    private func scanLink(in file: OpenFile, at path: [String],
                          previous: ClaudePullRequestLinkScan?) throws -> ClaudePullRequestLinkScan {
        let identity = ClaudePullRequestLinkScan.FileIdentity(device: file.identity.device, inode: file.identity.inode)
        if let previous, previous.file == identity, previous.scannedThrough == file.size {
            var unchanged = previous
            unchanged.path = path
            return unchanged
        }
        var scan = try ClaudePullRequestLinkScanner.scan(file: identity, size: file.size, previous: previous) { offset, count in
            try autoreleasepool {
                try file.handle.seek(toOffset: UInt64(offset))
                return try file.handle.read(upToCount: count) ?? Data()
            }
        }
        scan.path = path
        return scan
    }
}

extension ClaudeSubagentTranscriptReader {
    /// The files the conversation's calls read and edited (`ClaudeFileTouchScanner`), read on from
    /// `previous`: only what Claude appended since, and nothing when the file has not grown. The file is
    /// found beneath the config's projects as the conversation itself is, at the place `previous` found
    /// it while that is still the same file. Nil when the conversation has no transcript.
    func fileTouchScan(sessionID: String, previous: FileTouches) throws -> FileTouches? {
        let files = projectFiles
        let cursor = previous.claudeScan.flatMap { $0.providerSessionID == sessionID ? $0 : nil }
        var found: (path: [String], file: OpenFile)?
        if let cursor, let path = cursor.path, path.last?.lowercased() == "\(sessionID.lowercased()).jsonl",
           let file = files.openRegularFile(path),
           file.identity.device == cursor.device, file.identity.inode == cursor.inode {
            found = (path, file)
        } else if let path = try transcriptPath(sessionID: sessionID), let file = files.openRegularFile(path) {
            found = (path, file)
        }
        guard let (path, file) = found else { return nil }
        if let cursor, cursor.device == file.identity.device, cursor.inode == file.identity.inode,
           cursor.offset == file.size, cursor.path == path {
            return previous
        }
        var touches = try ClaudeFileTouchScanner.scan(
            providerSessionID: sessionID, device: file.identity.device, inode: file.identity.inode,
            size: file.size, previous: previous
        ) { offset, count in
            try autoreleasepool {
                try file.handle.seek(toOffset: UInt64(offset))
                return try file.handle.read(upToCount: count) ?? Data()
            }
        }
        touches.claudeScan?.path = path
        return touches
    }
}

extension JSONValue {
    /// A value Foundation's JSONSerialization read; nil for a type JSON does not have.
    init?(foundation value: Any) {
        switch value {
        case let string as NSString:
            self = .string(string as String)
        case let dictionary as NSDictionary:
            var object: [String: JSONValue] = Dictionary(minimumCapacity: dictionary.count)
            for (key, element) in dictionary {
                guard let key = key as? String, let element = JSONValue(foundation: element) else { return nil }
                object[key] = element
            }
            self = .object(object)
        case let array as NSArray:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let element = JSONValue(foundation: element) else { return nil }
                values.append(element)
            }
            self = .array(values)
        case let number as NSNumber:
            if number.isJSONBoolean {
                self = .bool(number.boolValue)
            } else if !(number is NSDecimalNumber), !number.isJSONFloat {
                self = .integer(number.int64Value)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            return nil
        }
    }
}
