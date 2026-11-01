import Foundation

/// Whether a harness can carry composer image input, and on whose authority.
enum HarnessImageInputSupport: Equatable, Sendable {
    /// The transport always carries image input for this family.
    case always
    /// The agent answers for itself during its own handshake. The control stays available and
    /// the adapter refuses the turn when the agent did not advertise room for an image.
    case negotiated
    /// The protocol has nowhere to put an image.
    case unavailable
}

/// Composer attachment and mention availability per harness. `+` and `@` are not Codex controls:
/// they belong to every harness whose protocol carries the input, and are hidden — not silently
/// ignored — where it does not.
struct HarnessComposerInputPolicy: Equatable, Sendable {
    let harness: HarnessKind
    let imageSupport: HarnessImageInputSupport
    /// What this session's agent answered during its own handshake, for a negotiated family.
    /// `nil` means it has not answered yet, and for every other family it means nothing at all.
    let negotiatedImageInput: Bool?

    init(harness: HarnessKind, negotiatedImageInput: Bool? = nil) {
        self.harness = harness
        self.negotiatedImageInput = negotiatedImageInput
        if harness == .codex {
            imageSupport = .always
            return
        }
        switch HarnessCatalog.descriptor(for: harness)?.transport {
        case .claudeStreamJSON, .piRPC, .msp:
            imageSupport = .always
        case .acp:
            imageSupport = .negotiated
        case .cursorStreamJSON, .codexAppServer, nil:
            imageSupport = .unavailable
        }
    }

    /// Whether a turn from this composer can actually carry an image. A negotiated family is
    /// offered until its agent answers, because the answer belongs to the agent and guessing it
    /// early would hide a control that works; once the agent has said no, it is no longer offered.
    var carriesImages: Bool {
        switch imageSupport {
        case .always: true
        case .unavailable: false
        case .negotiated: negotiatedImageInput ?? true
        }
    }

    /// `+` is shown exactly when the turn can carry the attachment it would add.
    var showsAttachmentControl: Bool { carriesImages }

    /// `@` is shown wherever the harness has an attachment surface at all. A mention loses
    /// nothing on the wire — it travels as a path line inside the prompt — so a negotiated no
    /// takes the attachment control without taking this one.
    var showsMentionControl: Bool { imageSupport != .unavailable }

    /// Only Codex has an audio input envelope, so only its picker may accept audio.
    var acceptsAudioAttachments: Bool { harness == .codex }

    /// The notice for a draft this harness cannot carry. Shown on a refused send, and as soon as
    /// a negotiation settles against an attachment the composer is already holding.
    var attachmentRefusalNotice: String {
        L10n.format(
            "%@ cannot send this attachment. Remove it to send the message.",
            harness.displayName
        )
    }

    /// What the composer does with a draft on this harness. Anything the harness cannot carry —
    /// a restored image on a harness with no image input, an image an agent declined during its
    /// handshake, or an input with no neutral representation at all — is reported instead of
    /// being quietly stripped from the turn. A mention is not refused: it is preserved in the
    /// prompt as its own path line.
    func submission(for draft: CodexComposerDraft) -> HarnessComposerSubmission {
        let projection = HarnessUserInput.projecting(draft)
        let losesImages = !projection.input.images.isEmpty && !carriesImages
        guard projection.carriesEverything, !losesImages else {
            return .refuse(attachmentRefusalNotice)
        }
        return .send(projection.input)
    }
}

enum HarnessComposerSubmission: Equatable, Sendable {
    case send(HarnessUserInput)
    /// The localized notice the composer shows while keeping the draft intact.
    case refuse(String)
}
