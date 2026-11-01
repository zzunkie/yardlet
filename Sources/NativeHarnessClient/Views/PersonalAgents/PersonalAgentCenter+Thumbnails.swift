import Foundation

extension PersonalAgentCenter {
    /// This window's thumbnails, made when a picture first asks for one.
    var thumbnails: PersonalAgentThumbnails {
        if let store = thumbnailStore as? PersonalAgentThumbnails { return store }
        let store = PersonalAgentThumbnails()
        thumbnailStore = store
        return store
    }

    /// A picture's thumbnail already in memory, or `.unavailable` while its failure waits for a retry.
    func cachedThumbnail(of attachment: PersonalAgentAttachment, size: TranscriptImageThumbnails.Size,
                         for identity: PersonalAgentIdentity) -> TranscriptImageThumbnails.Preview? {
        guard let file = attachment.fileID else { return .unavailable }
        return thumbnails.cached(PersonalAgentThumbnails.key(room: identity.roomID, file: file), size: size)
    }

    /// Reads and decodes a picture of the shown dot's room for its thumbnail, waiting for a reading
    /// slot first. Nil when the asking row went away before it ended; `.unavailable` when it could not
    /// be read here, which a retry may read again.
    func thumbnail(of attachment: PersonalAgentAttachment, size: TranscriptImageThumbnails.Size,
                   for identity: PersonalAgentIdentity) async -> TranscriptImageThumbnails.Preview? {
        guard attachment.isImage, !attachment.isLoading, let file = attachment.fileID else { return .unavailable }
        let store = thumbnails
        let key = PersonalAgentThumbnails.key(room: identity.roomID, file: file)
        if let cached = store.cached(key, size: size) { return cached }
        guard await store.slot() else { return nil }
        defer { store.release() }
        if let cached = store.cached(key, size: size) { return cached }
        guard !Task.isCancelled else { return nil }
        guard store === thumbnailStore, let agent = selected, agent.id == identity, let client else { return .unavailable }
        let current = generation
        store.noteRead()
        do {
            let data = try await client.image(attachment, for: agent)
            guard !Task.isCancelled else { return nil }
            // What another connection or account read is not shown, nor kept as this one's failure.
            guard store === thumbnailStore, current == generation else { return .unavailable }
            let preview = await store.decode(data, key: key, size: size)
            if case .unavailable = preview { store.fail(key, size: size) }
            return preview
        } catch {
            guard !Task.isCancelled else { return nil }
            guard store === thumbnailStore, current == generation else { return .unavailable }
            store.fail(key, size: size)
            return .unavailable
        }
    }

    /// Lets a picture that could not be read be read again.
    func retryThumbnail(of attachment: PersonalAgentAttachment, size: TranscriptImageThumbnails.Size,
                        for identity: PersonalAgentIdentity) {
        guard let file = attachment.fileID else { return }
        thumbnails.retry(PersonalAgentThumbnails.key(room: identity.roomID, file: file), size: size)
    }
}
