import Foundation
import Observation

/// Unsent input belongs to a task, not to the lifetime of its mounted composer.
/// The app's draft coordinator owns persistence; navigation never submits input.
@MainActor
@Observable
final class TaskComposerDraft {
    var text = "" {
        didSet {
            if !text.utf16.elementsEqual(oldValue.utf16) { savedSelection = nil }
            guard text != oldValue else { return }
            // Typing lets the suggested next message go, as does taking it into the text.
            if !text.isEmpty { nextMessageSuggestion = nil }
            onChange?()
        }
    }
    /// Host references for a remote composer, never client files to upload.
    var hostMentions: [WorkspaceFileMatch] = []
    var attachments: [CodexUserInput] = [] { didSet { if attachments != oldValue { onChange?() } } }
    var notice: String?
    var editState: ConversationEditState? { didSet { if editState != oldValue { onChange?() } } }
    /// A Claude composer whose text runs as a shell command (bash mode). Typing `!` into the empty
    /// composer turns it on; Backspace in the empty composer, Escape, or running the command
    /// turns it off, as in the Claude app.
    var isBashMode = false { didSet { if isBashMode != oldValue { onChange?() } } }
    /// Comments made on the task's diff, waiting for the next message as the Codex app's do
    /// (`diff_comments`). They go with that message and leave the draft with it.
    var diffComments: [DiffComment] = [] { didSet { if diffComments != oldValue { onChange?() } } }
    /// Elements picked in the task's browser, waiting for the next message as the Codex app's browser
    /// comments do (`BrowserCommentPrompt`). They go with that message, after the diff comments, and
    /// leave the draft with it.
    var browserComments: [BrowserComment] = [] { didSet { if browserComments != oldValue { onChange?() } } }
    /// What the harness predicted the person sends next when its last turn ended (Claude Code's
    /// `prompt_suggestion`). Shown above the composer while the text is empty; typing, sending, the
    /// next turn or taking it into the text lets it go. It lives only here: never in the persisted
    /// draft, and never sent unless the person takes it into the text and sends that.
    var nextMessageSuggestion: String?
    @ObservationIgnored var onChange: (() -> Void)?
    // Selection survives a mounted composer, but is not part of the persisted draft or submission.
    @ObservationIgnored private var savedSelection: NSRange?

    var selection: Range<String.Index>? {
        savedSelection.flatMap { Range($0, in: text) }
    }

    func rememberSelection(_ range: NSRange, in value: String) {
        guard value.utf16.elementsEqual(text.utf16), Range(range, in: text) != nil else { return }
        savedSelection = range
    }

    var snapshot: TaskDraftSnapshot {
        TaskDraftSnapshot(text: text, attachments: attachments, editState: editState, isBashMode: isBashMode ? true : nil,
                          diffComments: diffComments.isEmpty ? nil : diffComments,
                          browserComments: browserComments.isEmpty ? nil : browserComments)
    }

    func apply(_ snapshot: TaskDraftSnapshot) {
        savedSelection = nil
        text = snapshot.text
        attachments = snapshot.attachments
        editState = snapshot.editState
        isBashMode = snapshot.isBashMode == true
        diffComments = snapshot.diffComments ?? []
        browserComments = snapshot.browserComments ?? []
        notice = nil
    }

    /// The Claude app's composer takes a `!` typed into it while empty as the switch to bash mode
    /// and keeps the `!` out of the text. Not while a message is being edited.
    @discardableResult
    func enterBashModeIfTyped(after previousText: String) -> Bool {
        guard !isBashMode, previousText.isEmpty, text == "!", editState == nil else { return false }
        text = ""
        isBashMode = true
        return true
    }

    /// Backspace in the empty composer, or Escape, returns it to chat.
    @discardableResult
    func leaveBashMode() -> Bool {
        guard isBashMode else { return false }
        isBashMode = false
        return true
    }

    /// Whether the next message carries the diff and browser comments. An edit, a slash command and a
    /// shell command go alone, and the comments wait for the message after them.
    var sendsComments: Bool {
        guard !diffComments.isEmpty || !browserComments.isEmpty, editState == nil, !isBashMode else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    /// The suggested next message the composer shows now: with "Next message suggestions" on, no
    /// turn running, nothing typed, and neither bash mode nor an edit of an earlier message.
    func shownNextMessageSuggestion(isEnabled: Bool, isRunning: Bool) -> String? {
        guard isEnabled, !isRunning, text.isEmpty, !isBashMode, editState == nil else { return nil }
        return nextMessageSuggestion
    }

    /// Tab or a click on the suggestion: its words become the text, where the person edits or sends
    /// them. Nothing is sent. Nil when no suggestion shows.
    @discardableResult
    func takeNextMessageSuggestion(isEnabled: Bool, isRunning: Bool) -> String? {
        guard let suggestion = shownNextMessageSuggestion(isEnabled: isEnabled, isRunning: isRunning) else { return nil }
        text = suggestion
        return suggestion
    }

    /// Nothing typed or attached; diff comments may still wait.
    var isMessageEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// The message as it is sent: the text, after the diff and browser comments it carries
    /// (`DiffCommentPrompt`), then the attachments, then the browser comments' captures.
    var submission: CodexComposerDraft {
        var inputs = attachments
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sendsComments else {
            if !trimmed.isEmpty { inputs.insert(.text(trimmed), at: 0) }
            return CodexComposerDraft(inputs: inputs)
        }
        // Every harness sends a message's images in order after its text, so a capture is named by its place.
        var numbers: [Int?] = []
        var next = CodexComposerDraft(inputs: attachments).imageURLs.count + 1
        for comment in browserComments {
            guard let image = comment.image.flatMap(CodexUserInput.localAttachment(for:)) else {
                numbers.append(nil)
                continue
            }
            inputs.append(image)
            numbers.append(next)
            next += 1
        }
        inputs.insert(.text(DiffCommentPrompt.message(comments: diffComments, browserComments: browserComments,
                                                      browserImageNumbers: numbers, request: trimmed)), at: 0)
        return CodexComposerDraft(inputs: inputs)
    }

    /// Empties the draft once its message is on its way. Comments the message carried leave with it;
    /// ones it did not carry (an edit, a command) stay for the next message.
    func clear() {
        if sendsComments {
            diffComments = []
            browserComments = []
        }
        savedSelection = nil
        text = ""
        attachments = []
        editState = nil
        isBashMode = false
        notice = nil
        nextMessageSuggestion = nil
    }

    func restore(_ draft: CodexComposerDraft) {
        savedSelection = nil
        isBashMode = false
        text = draft.text
        attachments = draft.inputs.filter {
            if case .text = $0 { return false }
            return true
        }
        notice = nil
    }

    /// A message that was not sent comes back to the composer: its request as the text, and the
    /// comments it carried waiting again, each browser comment with its capture.
    func restoreUnsent(_ draft: CodexComposerDraft) {
        guard let index = draft.inputs.firstIndex(where: { if case .text = $0 { true } else { false } }),
              case let .text(value, _) = draft.inputs[index],
              let sent = DiffCommentPrompt.parse(value, images: draft.imageURLs) else {
            restore(draft)
            return
        }
        var request = draft
        if sent.request.isEmpty { request.inputs.remove(at: index) } else { request.inputs[index] = .text(sent.request) }
        let captures = Set(sent.browserComments.compactMap { $0.image?.standardizedFileURL })
        request.inputs.removeAll { input in CodexComposerDraft.imageURL(of: input).map(captures.contains) ?? false }
        restore(request)
        keepComments(sent.comments, sent.browserComments)
    }

    /// The comments a message that was not sent carried wait again, after any already waiting and
    /// without repeating one; `images` are the message's, which hold the browser comments' captures.
    func keepDiffComments(sentIn text: String, images: [URL] = []) {
        guard let sent = DiffCommentPrompt.parse(text, images: images) else { return }
        keepComments(sent.comments, sent.browserComments)
    }

    /// A browser comment's marked-up capture takes the capture's place.
    func replaceCapture(of comment: BrowserComment.ID, with copy: URL) {
        guard let index = browserComments.firstIndex(where: { $0.id == comment }) else { return }
        browserComments[index].image = copy
    }

    private func keepComments(_ comments: [DiffComment], _ browser: [BrowserComment]) {
        let missing = comments.filter { comment in !diffComments.contains { $0.hasSameContent(as: comment) } }
        if !missing.isEmpty { diffComments += missing }
        let missingBrowser = browser.filter { comment in !browserComments.contains { $0.hasSameContent(as: comment) } }
        if !missingBrowser.isEmpty { browserComments += missingBrowser }
    }
}

@MainActor
final class TaskComposerDraftStore {
    private var drafts: [UUID: TaskComposerDraft] = [:]
    var onChange: ((UUID) -> Void)?

    var snapshot: [UUID: TaskDraftSnapshot] {
        drafts.mapValues(\.snapshot).filter { !$0.value.isEmpty }
    }

    /// The task's draft if it has one; never makes one.
    func existingDraft(for sessionID: UUID) -> TaskComposerDraft? {
        drafts[sessionID]
    }

    func draft(for sessionID: UUID) -> TaskComposerDraft {
        if let draft = drafts[sessionID] { return draft }
        let draft = TaskComposerDraft()
        draft.onChange = { [weak self] in self?.onChange?(sessionID) }
        drafts[sessionID] = draft
        return draft
    }

    func retainSessions(_ sessionIDs: Set<UUID>) {
        for id in Array(drafts.keys) where !sessionIDs.contains(id) { remove(for: id) }
    }

    func remove(for sessionID: UUID) {
        drafts.removeValue(forKey: sessionID)?.onChange = nil
        onChange?(sessionID)
    }

    func apply(_ snapshots: [UUID: TaskDraftSnapshot], excluding editedIDs: Set<UUID>) {
        for (id, snapshot) in snapshots where !editedIDs.contains(id) {
            let draft = draft(for: id)
            let callback = draft.onChange
            draft.onChange = nil
            draft.apply(snapshot)
            draft.onChange = callback
        }
    }
}
