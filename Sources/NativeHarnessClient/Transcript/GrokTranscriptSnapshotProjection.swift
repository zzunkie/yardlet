import Foundation

/// Repairs the transcript shape produced by Grok Build versions that omitted assistant message
/// IDs from ACP chunks. Grok's provider-owned history is read-only evidence; this projection only
/// rewrites Yardlet's detached snapshot, and only when every user and assistant byte matches.
enum GrokTranscriptSnapshotProjection {
    private struct AssistantSegment {
        let text: String
        let toolCallIDs: [String]
    }

    private struct Turn {
        let userText: String
        var assistantSegments: [AssistantSegment]
    }

    static func repairedEntries(
        providerSessionID: String,
        existing: [TranscriptEntry],
        grokSessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".grok/sessions")
    ) -> [TranscriptEntry]? {
        guard let historyURL = uniqueHistoryURL(
            providerSessionID: providerSessionID,
            grokSessionsRoot: grokSessionsRoot
        ), let nativeTurns = nativeTurns(from: historyURL), !nativeTurns.isEmpty else {
            return nil
        }

        let userIndices = existing.indices.filter { index in
            if case .user = existing[index].content { return true }
            return false
        }
        guard userIndices.count == nativeTurns.count, userIndices.first == existing.startIndex else {
            return nil
        }

        var repaired: [TranscriptEntry] = []
        var repairedAtLeastOneTurn = false

        for (turnOffset, nativeTurn) in nativeTurns.enumerated() {
            let start = userIndices[turnOffset]
            let end = turnOffset + 1 < userIndices.count
                ? userIndices[turnOffset + 1]
                : existing.endIndex
            let persistedTurn = Array(existing[start..<end])

            guard case let .user(persistedUserText, _) = persistedTurn[0].content,
                  persistedUserText == nativeTurn.userText else {
                return nil
            }

            let persistedAssistants = persistedTurn.filter { entry in
                if case .assistant = entry.content { return true }
                return false
            }
            let nativeMessages = nativeTurn.assistantSegments.filter { !$0.text.isEmpty }
            guard nativeMessages.count >= 2,
                  persistedAssistants.count == 1,
                  case let .assistant(persistedAssistantText, _) = persistedAssistants[0].content,
                  nativeMessages.map(\.text).joined() == persistedAssistantText else {
                return nil
            }

            let nativeToolCallIDs = Set(
                nativeTurn.assistantSegments.flatMap(\.toolCallIDs)
            )
            let persistedActivityIDs = Set(persistedTurn.compactMap { entry -> String? in
                guard case let .activity(activity, _) = entry.content else { return nil }
                return activity.id
            })
            guard persistedActivityIDs.isSubset(of: nativeToolCallIDs) else { return nil }

            repaired.append(persistedTurn[0])
            repaired.append(contentsOf: projectTurn(
                nativeTurn,
                persistedTurn: persistedTurn,
                combinedAssistant: persistedAssistants[0]
            ))
            repairedAtLeastOneTurn = true
        }

        guard repairedAtLeastOneTurn, repaired != existing else { return nil }
        return repaired
    }

    private static func projectTurn(
        _ nativeTurn: Turn,
        persistedTurn: [TranscriptEntry],
        combinedAssistant: TranscriptEntry
    ) -> [TranscriptEntry] {
        let auxiliaryEntries = persistedTurn.filter { entry in
            switch entry.content {
            case .user, .assistant:
                return false
            default:
                return true
            }
        }

        var entriesByActivityID: [String: [TranscriptEntry]] = [:]
        var currentActivityID: String?
        for entry in auxiliaryEntries {
            if case let .activity(activity, _) = entry.content {
                currentActivityID = activity.id
                entriesByActivityID[activity.id, default: []].append(entry)
            } else if let currentActivityID {
                entriesByActivityID[currentActivityID, default: []].append(entry)
            }
        }

        var projected: [TranscriptEntry] = []
        var consumedEntryIDs = Set<UUID>()
        var assistantOffset = 0

        for segment in nativeTurn.assistantSegments {
            if !segment.text.isEmpty {
                let entry: TranscriptEntry
                if assistantOffset == 0 {
                    entry = TranscriptEntry(
                        id: combinedAssistant.id,
                        createdAt: combinedAssistant.createdAt,
                        content: .assistant(text: segment.text, isStreaming: false)
                    )
                } else {
                    entry = TranscriptEntry(
                        // An answer at no time stays at none rather than a moment past it.
                        createdAt: combinedAssistant.recordedAt.map {
                            $0.addingTimeInterval(Double(assistantOffset) / 1_000_000)
                        } ?? TranscriptEntry.unrecordedTime,
                        content: .assistant(text: segment.text, isStreaming: false)
                    )
                }
                projected.append(entry)
                assistantOffset += 1
            }

            for toolCallID in segment.toolCallIDs {
                for entry in entriesByActivityID[toolCallID, default: []]
                    where consumedEntryIDs.insert(entry.id).inserted {
                    projected.append(entry)
                }
            }
        }

        // Provider and ACP versions can omit a card that exists in the other source. Preserve any
        // Yardlet-owned plan/error/permission card rather than guessing a new provider association.
        projected.append(contentsOf: auxiliaryEntries.filter { entry in
            consumedEntryIDs.insert(entry.id).inserted
        })
        return projected
    }

    private static func uniqueHistoryURL(
        providerSessionID: String,
        grokSessionsRoot: URL
    ) -> URL? {
        guard !providerSessionID.isEmpty,
              providerSessionID != ".",
              providerSessionID != "..",
              !providerSessionID.contains("/") else {
            return nil
        }
        guard let workspaceDirectories = try? FileManager.default.contentsOfDirectory(
            at: grokSessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let candidates = workspaceDirectories.compactMap { workspaceURL -> URL? in
            let historyURL = workspaceURL
                .appending(path: providerSessionID, directoryHint: .isDirectory)
                .appending(path: "chat_history.jsonl")
            return FileManager.default.fileExists(atPath: historyURL.path) ? historyURL : nil
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private static func nativeTurns(from historyURL: URL) -> [Turn]? {
        guard let values = try? historyURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= 32 * 1_024 * 1_024,
              let history = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return nil
        }

        var turns: [Turn] = []
        for line in history.split(whereSeparator: \Character.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case let .object(object) = value,
                  let type = object["type"]?.stringValue else {
                return nil
            }

            switch type {
            case "user":
                guard object["prompt_index"] != nil,
                      let userText = userText(from: object["content"]) else {
                    continue
                }
                turns.append(Turn(userText: userText, assistantSegments: []))

            case "assistant":
                guard !turns.isEmpty,
                      let text = object["content"]?.stringValue else {
                    continue
                }
                turns[turns.count - 1].assistantSegments.append(
                    AssistantSegment(
                        text: text,
                        toolCallIDs: toolCallIDs(from: object["tool_calls"])
                    )
                )

            default:
                continue
            }
        }
        return turns
    }

    private static func userText(from value: JSONValue?) -> String? {
        guard case let .array(items) = value else { return nil }
        let textItems = items.compactMap { item -> String? in
            guard case let .object(object) = item,
                  object["type"]?.stringValue == "text" else {
                return nil
            }
            return object["text"]?.stringValue
        }
        guard textItems.count == 1 else { return nil }

        let wrapped = textItems[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "<user_query>"
        let suffix = "</user_query>"
        guard wrapped.hasPrefix(prefix), wrapped.hasSuffix(suffix) else { return nil }
        return wrapped
            .dropFirst(prefix.count)
            .dropLast(suffix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolCallIDs(from value: JSONValue?) -> [String] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { item in
            guard case let .object(object) = item else { return nil }
            return object["id"]?.stringValue
        }
    }
}
