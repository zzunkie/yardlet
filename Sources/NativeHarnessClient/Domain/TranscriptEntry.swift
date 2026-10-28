import Foundation

enum TranscriptActivityState: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case stopped
}

enum TranscriptPermissionState: String, Codable, Equatable, Sendable {
    case pending
    case allowed
    case denied
    case expired
}

/// An image sent with a request, which the conversation previews beside the request's text.
struct TranscriptImageAttachment: Codable, Equatable, Sendable {
    /// A local file or an inline `data:` image. A remote URL is kept but never fetched.
    let url: URL?
    /// The file name; nil for an inline image, which has none.
    let name: String?

    init(url: URL?, name: String?) {
        self.url = url
        self.name = name
    }

    /// A pasted image has no name of its own (Yardlet named its file), so it reads as "Image" like
    /// an inline one.
    init(url: URL) {
        self.url = url
        name = url.scheme == "data" || ComposerAttachmentIntake.isPastedImage(url)
            ? nil : (url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
    }

    private enum CodingKeys: String, CodingKey { case url, name }

    /// The reading cache is rewritten whenever the transcript is published. Inline image bytes stay
    /// in the provider's history and the live entry rather than being re-encoded there each time,
    /// so a restored inline image shows as its name until the history is read again.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let url, url.scheme != "data" { try container.encode(url, forKey: .url) }
        try container.encodeIfPresent(name, forKey: .name)
    }
}

enum TranscriptEntryContent: Codable, Equatable, Sendable {
    /// `images` is nil for a request without images, which keeps the saved shape of older entries.
    case user(text: String, images: [TranscriptImageAttachment]? = nil)
    case assistant(text: String, isStreaming: Bool)
    /// The provider's own thinking. It is kept apart from the answer and stays collapsed.
    case reasoning(text: String, isStreaming: Bool)
    case activity(HarnessActivity, state: TranscriptActivityState)
    case permission(PermissionRequest, state: TranscriptPermissionState)
    case plan(String)
    /// `transient` as the provider's error event carried it (`HarnessEventPayload.error`); nil keeps
    /// the saved shape of older entries.
    case error(message: String, recoverable: Bool, transient: Bool? = nil)
    /// A marker where the provider summarized earlier conversation.
    case compaction(HarnessContextCompaction)
    /// A turn a plan limit stopped, in place of a generic error.
    case usageLimit(HarnessRateLimit)
}

/// Who sent a request other than the person, as the provider recorded it.
enum TranscriptRequestOrigin: String, Codable, Equatable, Sendable {
    /// The provider's own schedule sent it in the person's place: Claude Code's `turnOrigin`
    /// "scheduled", a `CronCreate` job or a `/loop` wakeup the CLI fired, or a Claude app scheduled
    /// task (`ClaudeScheduledPrompt`).
    case scheduled
    /// The provider started the turn with a command it queued itself, whose saved record Yardlet has
    /// not read yet (`HarnessEventPayload.providerStartedTurn`): the entry opens the turn and shows
    /// nothing until it is read.
    case provider
}

struct TranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var content: TranscriptEntryContent
    /// A message the provider read into the turn that was running (Claude Code reads a follow-up at
    /// the turn's next step), which the conversation shows in that turn where it was read rather
    /// than as a turn of its own (D13). Nil for everything else, and left out of the saved shape
    /// then, so older readers and older entries agree.
    var joinsRunningTurn: Bool?
    /// A request someone other than the person sent (`TranscriptRequestOrigin`): it opens its turn
    /// as a request does, drawn as what sent it rather than as the person's message, and is no
    /// message to edit or restore files to. Nil for the person's own and everything else, and left
    /// out of the saved shape then.
    var origin: TranscriptRequestOrigin?
    /// Thinking that is what the model wrote between its tool calls rather than its reasoning: a note
    /// longer than a sentence or two, which Claude Opus 5.5, Sonnet 5.5 and Fable 5.1 send back as a
    /// progress-update thinking block whose signature names it narration, its text a summary of the
    /// note (`ClaudeProgressUpdate`). The conversation reads it as the model's words. Nil for
    /// everything else, and left out of the saved shape then.
    var isProgressUpdate: Bool?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        content: TranscriptEntryContent,
        joinsRunningTurn: Bool? = nil,
        origin: TranscriptRequestOrigin? = nil,
        isProgressUpdate: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.content = content
        self.joinsRunningTurn = joinsRunningTurn
        self.origin = origin
        self.isProgressUpdate = isProgressUpdate
    }
}
