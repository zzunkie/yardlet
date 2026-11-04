import Foundation

extension RemoteSubtaskTranscript {
    /// Normal pages keep whole turns, including a latest turn larger than the soft page limits.
    /// Only the hard wire budget trims items, retaining recent content and marking omissions.
    /// Four KiB remain for the response envelope and request identity.
    public static func window(_ conversation: RemoteConversation, omittedItemText: String,
                              maximumPayloadBytes: Int = RemoteProtocol.maxServerMessageBytes - 4096) -> Self {
        var window = RemoteConversationWindow()
        let page = window.open(conversation)
        let result = Self(items: page.items, truncated: page.hasOlder || conversation.hasEarlier)
        let encoder = JSONEncoder()
        let limit = min(max(4096, maximumPayloadBytes), RemoteProtocol.maxServerMessageBytes - 4096)
        if let encoded = try? encoder.encode(result), encoded.count <= limit { return result }

        var kept: [RemoteItem] = []
        var bytes = (try? encoder.encode(Self(items: [], truncated: true)).count) ?? 64
        for (index, original) in page.items.enumerated().reversed() {
            var item = original
            var size = (try? encoder.encode(item).count) ?? Int.max
            if size > limit - 128 {
                // A single item cannot fit, even alone. Keep a visible omission in its position,
                // rather than returning an empty panel or repeatedly sending an oversized response.
                item = RemoteItem(id: "subtask:omitted:\(index)", turnId: String(original.turnId.prefix(64)), kind: .notice)
                item.text = String(omittedItemText.prefix(128))
                size = (try? encoder.encode(item).count) ?? 2048
            }
            guard size < limit - bytes else { break }
            kept.append(item)
            bytes += size + 1 // The comma between encoded array members, conservatively including the first.
        }
        return Self(items: kept.reversed(), truncated: true)
    }
}
