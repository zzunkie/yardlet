import AppKit

/// Kept behind the session's capability check, including when a remote-created shell is shown locally.
@MainActor
struct TerminalClipboard {
    var read: () -> Data?
    var write: (Data) -> Void
    static var system: Self {
        Self(read: { NSPasteboard.general.string(forType: .string)?.data(using: .utf8) }, write: { data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([text as NSString])
        })
    }
}
