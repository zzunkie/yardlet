import Foundation
import YardletRemote

/// Small previews of the pictures a conversation's messages sent, for a client that draws them as the Mac
/// does (docs/REMOTE_PROTOCOL.md §15.24). Each is made once, away from the main actor, by the platform's
/// `make` (a JPEG of at most `maximumSide` pixels on its long side), and kept while a client follows a
/// conversation. A projection that asks before one is made gets nothing and is told once it is ready, so
/// the turn that holds the picture is projected again; nothing else is.
@MainActor
final class RemoteImagePreviews {
    /// The platform's preview of a local file or an inline `data:` image, or nil when it cannot read one.
    typealias Make = @Sendable (_ url: URL, _ maximumSide: Int) async -> Data?

    /// A turn of a task that asked for a preview.
    struct Asker: Hashable {
        let taskID: UUID
        let turnID: String
    }

    static let maximumSide = 480
    /// Previews kept at most; past it they are let go and made again when asked.
    static let keptCount = 200

    private let make: Make
    private var made: [URL: Data] = [:]
    private var unreadable: Set<URL> = []
    private var waiting: [URL: Set<Asker>] = [:]
    /// Told when previews someone asked for are ready.
    var onReady: (Set<Asker>) -> Void = { _ in }

    init(make: @escaping Make) {
        self.make = make
    }

    /// The picture's preview when it is made; otherwise starts making it and answers nil. A picture on the web
    /// is never fetched.
    func preview(_ url: URL, for asker: Asker) -> Data? {
        guard url.isFileURL || url.scheme == "data", !unreadable.contains(url) else { return nil }
        if let data = made[url] { return data }
        let isNew = waiting[url] == nil
        waiting[url, default: []].insert(asker)
        if isNew {
            let make = self.make
            Task { [weak self] in
                let data = await make(url, Self.maximumSide)
                self?.finish(url, data)
            }
        }
        return nil
    }

    /// Lets every preview go: nobody follows a conversation.
    func removeAll() {
        made = [:]
        unreadable = []
    }

    private func finish(_ url: URL, _ data: Data?) {
        if made.count >= Self.keptCount { made = [:] }
        if let data { made[url] = data } else { unreadable.insert(url) }
        let askers = waiting.removeValue(forKey: url) ?? []
        if data != nil, !askers.isEmpty { onReady(askers) }
    }
}
