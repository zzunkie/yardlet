import Foundation

/// Flattens provider-owned Codex narrative into the shared detached reading surface. The live
/// task keeps using `CodexTaskState`, so no typed turn, cursor, approval, or activity semantics
/// are reconstructed from this lossy snapshot.
///
/// Entry IDs are name-based UUIDs of the thread, turn and item they come from, so every checkpoint
/// of the same thread names the same entry the same way (plan A3.5). The entry that opens a turn —
/// its first message with text or images — is named by the turn alone (`turnEntryID`), so a reading
/// place saved on a Codex turn can be found in the snapshot, and one saved on the snapshot can be
/// found in the thread once it attaches (`ConversationAnchorResolver`). The stored format is
/// unchanged: still `[TranscriptEntry]`.
enum CodexTranscriptSnapshotProjection {
    static let limit = 500

    /// The namespace of the snapshot's entry IDs. Never change it: saved reading places name entries
    /// by these IDs.
    private static let namespace = UUID(uuidString: "2BE580BD-82A6-4829-ABA1-E8C2A03B77FF")!

    /// The entry that opens `turnID`: its first message with text or images.
    static func turnEntryID(threadID: String, turnID: String) -> UUID {
        NameBasedUUID.make(namespace: namespace, name: [threadID, turnID].joined(separator: "\n"))
    }

    /// Any other entry an item of the turn becomes; `occurrence` tells apart items that share an ID
    /// within one turn.
    static func itemEntryID(threadID: String, turnID: String, itemID: String, occurrence: Int = 0) -> UUID {
        let item = occurrence == 0 ? itemID : "\(itemID)#\(occurrence)"
        return NameBasedUUID.make(namespace: namespace, name: [threadID, turnID, "item", item].joined(separator: "\n"))
    }

    /// The entry the turn's error becomes.
    static func errorEntryID(threadID: String, turnID: String) -> UUID {
        NameBasedUUID.make(namespace: namespace, name: [threadID, turnID, "error"].joined(separator: "\n"))
    }

    /// The newest `limit` entries, oldest first. A streaming task checkpoints this every second,
    /// so it walks back from the newest turn and stops once it has them.
    static func entries(from state: CodexTaskState) -> [TranscriptEntry] {
        guard let thread = state.thread else { return [] }
        var newestFirst: [TranscriptEntry] = []

        walk: for turn in thread.turns.reversed() {
            if let error = turn.error?.stringValue,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newestFirst.append(
                    TranscriptEntry(
                        id: errorEntryID(threadID: thread.id, turnID: turn.id),
                        createdAt: turn.completedAt ?? turn.startedAt ?? TranscriptEntry.unrecordedTime,
                        content: .error(message: error, recoverable: false)
                    )
                )
            }

            let names = EntryNames(turn: turn, threadID: thread.id)
            let firstRequestIndex = turn.items.firstIndex {
                if case .userMessage = $0.content { true } else { false }
            }
            let lastMessageIndex = turn.items.lastIndex {
                if case .agentMessage = $0.content { true } else { false }
            }
            for (index, item) in turn.items.enumerated().reversed() {
                guard newestFirst.count < limit else { break walk }
                // When the provider says the item was made: a request when it was sent, which the one
                // that opens the turn was when the turn started, and a message when it was written,
                // which the turn's last message was when the turn ended. An item no time names is
                // left without one.
                let madeAt: Date? = switch item.content {
                case .agentMessage:
                    item.completedAt ?? item.startedAt ?? (index == lastMessageIndex ? turn.completedAt : nil)
                default:
                    item.startedAt ?? item.completedAt ?? (index == firstRequestIndex ? turn.startedAt : nil)
                }
                let createdAt = madeAt ?? TranscriptEntry.unrecordedTime

                switch item.content {
                case let .userMessage(message):
                    let sent = message.sentContent
                    let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !sent.images.isEmpty else { continue }
                    newestFirst.append(TranscriptEntry(id: names.id(at: index), createdAt: createdAt, content: .user(
                        text: text, images: sent.images.isEmpty ? nil : sent.images
                    )))

                case let .agentMessage(message):
                    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    newestFirst.append(
                        TranscriptEntry(
                            id: names.id(at: index),
                            createdAt: createdAt,
                            content: .assistant(text: text, isStreaming: false)
                        )
                    )

                case let .plan(text):
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    newestFirst.append(TranscriptEntry(id: names.id(at: index), createdAt: createdAt, content: .plan(text)))

                default:
                    continue
                }
            }
            if newestFirst.count >= limit { break }
        }

        return Array(newestFirst.prefix(limit).reversed())
    }

    /// The IDs a turn's entries get, made only for the items that become entries.
    private struct EntryNames {
        let turn: CodexTurnState
        let threadID: String
        let opening: Int?
        /// Items share an ID within the turn; their entries are told apart by occurrence.
        let repeatsIDs: Bool

        init(turn: CodexTurnState, threadID: String) {
            self.turn = turn
            self.threadID = threadID
            repeatsIDs = Set(turn.items.map(\.id)).count != turn.items.count
            opening = turn.items.firstIndex { item in
                guard case let .userMessage(message) = item.content else { return false }
                let sent = message.sentContent
                return !sent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sent.images.isEmpty
            }
        }

        func id(at index: Int) -> UUID {
            if index == opening { return turnEntryID(threadID: threadID, turnID: turn.id) }
            let itemID = turn.items[index].id
            let occurrence = repeatsIDs ? turn.items[..<index].lazy.filter { $0.id == itemID }.count : 0
            return itemEntryID(threadID: threadID, turnID: turn.id, itemID: itemID, occurrence: occurrence)
        }
    }
}
