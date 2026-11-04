import Foundation
import Observation

/// What a composer's editor edits: the text, the inputs that travel with it, the notice shown
/// beside them, and the selection a remounted editor restores. The task composer's draft
/// (`TaskComposerDraft`) and the new-task composer's (`NewTaskDraft`) both adopt it, so
/// `ComposerEditor` edits either one the same way.
///
/// Bash mode belongs to the task composer alone. A draft without it keeps the defaults below,
/// which never enter it.
@MainActor
protocol ComposerDraftEditing: AnyObject, Observable {
    var text: String { get set }
    /// Attachments, mentions and skills, in the order they were added.
    var attachments: [CodexUserInput] { get set }
    var hostMentions: [WorkspaceFileMatch] { get set }
    /// Why the last edit or send left the draft as it is, shown beside the text.
    var notice: String? { get set }
    /// The selection to restore, while the text it was measured in is unchanged.
    var selection: Range<String.Index>? { get }
    /// Keeps `range` while `value` is still the draft's text.
    func rememberSelection(_ range: NSRange, in value: String)

    var isBashMode: Bool { get }
    /// A `!` typed into the empty draft turns bash mode on instead of staying in the text.
    @discardableResult func enterBashModeIfTyped(after previousText: String) -> Bool
    @discardableResult func leaveBashMode() -> Bool
}

/// The caret after a chosen file replaced its typed `@word`: where the word was, or nil when the
/// text no longer held that word.
struct ComposerMentionEdit: Equatable, Sendable {
    var caret: Int?
}

extension ComposerDraftEditing {
    var isBashMode: Bool { false }
    @discardableResult func enterBashModeIfTyped(after previousText: String) -> Bool { false }
    @discardableResult func leaveBashMode() -> Bool { false }

    /// A chosen command replaces the typed `/word`, or leads the text, and the caret follows it.
    /// Nothing is sent.
    func insertCommand(_ command: ProviderComposerCommand) {
        text = ComposerCommands.inserting(command, in: text)
        rememberSelection(NSRange(location: text.utf16.count, length: 0), in: text)
    }

    /// The chip at `index` leaves the draft. An index that is already gone does nothing.
    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    /// An attached image's marked-up copy takes its place; the original file stays where it was.
    func replaceAttachment(at index: Int, withMarkedUp copy: URL) {
        guard attachments.indices.contains(index), case .localImage = attachments[index],
              let marked = CodexUserInput.localAttachment(for: copy) else { return }
        attachments[index] = marked
    }

    /// The file a typed `@word` named joins the draft exactly as the `@` button adds it, once,
    /// and the word leaves the text so the reference is not sent twice. Nil when the file cannot
    /// be mentioned, in which case nothing changes.
    func insertMention(_ match: WorkspaceFileMatch, replacing token: ComposerMentionToken) -> ComposerMentionEdit? {
        guard let mention = CodexUserInput.localMention(for: match.url) else { return nil }
        let edited = ComposerMentions.removing(token, from: text)
        if let edited { text = edited.text }
        if !attachments.contains(mention) { attachments.append(mention) }
        return ComposerMentionEdit(caret: edited?.caret)
    }

    /// Pasted or dropped files join as the inputs the pickers would have made (media the harness
    /// carries as attachments, anything else as mentions), each once. A file the harness cannot
    /// take is reported in the notice.
    func attachFiles(_ urls: [URL], policy: HarnessComposerInputPolicy) {
        let result = ComposerAttachmentIntake.inputs(forFiles: urls, policy: policy)
        let added = result.inputs.filter { !attachments.contains($0) }
        attachments += added
        if let notice = result.notice { self.notice = notice }
    }
}

extension TaskComposerDraft: ComposerDraftEditing {}

extension NewTaskDraft: ComposerDraftEditing {}
