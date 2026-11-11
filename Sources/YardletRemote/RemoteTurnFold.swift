/// How a client draws one turn's items while the turn's work folds (the header's `foldsWork`), as the Mac draws it
/// (docs/REMOTE_PROTOCOL.md §6): the work (`inWork`) before the first message sent into the turn that stays in view
/// folds under the turn header, and the work after each such message, up to the next, folds on a line of its own
/// drawn right under the message, which opens only that work. One fold above the person's message read as if the
/// message came after all the work.
public enum RemoteTurnFold {
    public enum Row: Equatable, Sendable {
        case item(RemoteItem)
        /// The fold of the work after the message with this ID.
        case fold(after: String)

        public var id: String {
            switch self {
            case let .item(item): item.id
            case let .fold(message): "fold:" + message
            }
        }
    }

    /// The rows of a turn whose items are `items`, in order. `folds`: the turn's work is folded (its header folds it
    /// and the person did not open it). `opened`: the messages whose folded work the person opened.
    public static func rows(_ items: [RemoteItem], folds: Bool, opened: Set<String> = []) -> [Row] {
        guard folds else { return items.map(Row.item) }
        var hidesWork: Set<String> = []
        var message: String?
        var pastHeader = false
        for item in items {
            if item.kind == .turn { pastHeader = true }
            if pastHeader, partsFold(item) { message = item.id }
            if item.inWork == true, let message { hidesWork.insert(message) }
        }
        var rows: [Row] = []
        message = nil
        pastHeader = false
        for item in items {
            if item.kind == .turn { pastHeader = true }
            if pastHeader, partsFold(item) {
                message = item.id
                rows.append(.item(item))
                if hidesWork.contains(item.id) { rows.append(.fold(after: item.id)) }
            } else if item.inWork != true || message.map(opened.contains) == true {
                rows.append(.item(item))
            }
        }
        return rows
    }

    /// A message sent into the turn that stays in view while its work folds.
    private static func partsFold(_ item: RemoteItem) -> Bool {
        item.kind == .user && item.inWork != true
    }
}
