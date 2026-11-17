import Foundation
import Observation

/// Each task's unsent words, the message it edits, its find and where the person was reading, kept on this computer
/// (a host's own drafts stay there). The words outlast the window in the host's cache folder (`drafts.json`, 0600),
/// which goes with the host; the rest lasts while the window is open, as the local window keeps it.
@MainActor
@Observable
final class RemoteComposerDrafts {
    @ObservationIgnored private var drafts: [String: TaskComposerDraft] = [:]
    @ObservationIgnored private var finds: [String: ConversationFindModel] = [:]
    @ObservationIgnored private var readings: [String: TranscriptReadingPosition] = [:]
    @ObservationIgnored private var renders: [String: ConversationRenderState] = [:]
    /// Where the words are kept: the host's cache folder, nil where nothing is kept (tests).
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var savedWords: [String: String] = [:]
    private static let newTaskKey = "new-task"
    @ObservationIgnored let newTask = TaskComposerDraft()
    var edits: [String: RemoteMessageEdit] = [:]
    /// The project New task in a project chose, for the new task screen to start in.
    var newTaskProjectID: String?

    func draft(for taskID: String) -> TaskComposerDraft {
        if let draft = drafts[taskID] { return draft }
        let draft = TaskComposerDraft()
        drafts[taskID] = draft
        return draft
    }

    /// The task's find, kept while the window is open as the local task keeps its own.
    func find(for taskID: String) -> ConversationFindModel {
        if let find = finds[taskID] { return find }
        let find = ConversationFindModel()
        finds[taskID] = find
        return find
    }

    /// Where the person was reading the task's conversation, so going back to it comes back there.
    func readingPosition(for taskID: String) -> TranscriptReadingPosition {
        if let reading = readings[taskID] { return reading }
        let reading = TranscriptReadingPosition()
        readings[taskID] = reading
        return reading
    }

    /// The task's drawn conversation, kept so going back to it does not lay it out again.
    func renderState(for taskID: String) -> ConversationRenderState {
        if let render = renders[taskID] { return render }
        let render = ConversationRenderState()
        renders[taskID] = render
        return render
    }

    /// Reads the words kept in `folder`, once, into the drafts that are still empty.
    func restore(from folder: URL?) {
        guard file == nil, let folder else { return }
        file = folder.appending(path: "drafts.json")
        guard let data = try? Data(contentsOf: file!),
              let words = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        savedWords = words
        for (key, text) in words {
            let draft = key == Self.newTaskKey ? newTask : draft(for: key)
            if draft.text.isEmpty { draft.text = text }
        }
    }

    /// Keeps the drafts' words, when they changed since they were last kept.
    func save() {
        guard let file else { return }
        var words: [String: String] = [:]
        for (key, draft) in drafts {
            let text = RemoteComposerMentionIndex.message(draft.text, mentions: draft.hostMentions)
            if !text.isEmpty { words[key] = text }
        }
        let newText = RemoteComposerMentionIndex.message(newTask.text, mentions: newTask.hostMentions)
        if !newText.isEmpty { words[Self.newTaskKey] = newText }
        guard words != savedWords else { return }
        savedWords = words
        guard let data = try? JSONEncoder().encode(words) else { return }
        try? StateFile.write(data, to: file, isPrivate: true)
    }
}

/// A host turn's message put back in the composer to edit (its Edit message, §15.23), with what the composer held
/// before, which comes back when the edit is cancelled.
struct RemoteMessageEdit: Equatable {
    let turnID: String
    let previousText: String
    let previousAttachments: [CodexUserInput]
}
