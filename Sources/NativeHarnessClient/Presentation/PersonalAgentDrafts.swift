import Foundation
import Observation

/// A file waiting in a dot's draft: a private copy of what the person chose, so the original is
/// never read again, moved or changed, and where its upload to the dot's room stands.
struct PersonalAgentDraftFile: Identifiable, Equatable {
    enum State: Equatable {
        case queued, uploading
        case uploaded(PersonalAgentUploadedFile)
        case failed(PersonalAgentFailure)
    }
    let id: UUID
    let name: String
    let mimeType: String
    let sizeBytes: Int
    /// The copy in the draft's own folder.
    let copy: URL
    var state: State

    /// The name the message shows: a converted photo is sent under its new name.
    var shownName: String { uploaded?.name ?? name }
    var uploaded: PersonalAgentUploadedFile? { if case let .uploaded(file) = state { file } else { nil } }
    var isInProgress: Bool { state == .queued || state == .uploading }
    var failure: PersonalAgentFailure? { if case let .failed(value) = state { value } else { nil } }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// A file the person chose or dropped, with the type the system declares for it, if any.
struct PersonalAgentFileSource: Sendable {
    let url: URL
    var declaredType: String?
}

@MainActor @Observable
final class PersonalAgentDraft {
    let editor = TaskComposerDraft()
    private(set) var pending: PersonalAgentSubmission?
    private(set) var storageFailed = false
    private(set) var files: [PersonalAgentDraftFile] = []
    var isSending = false
    /// Chosen files are being copied in; Send waits until they are part of the draft.
    private(set) var isAddingFiles = false
    /// Send was pressed while files were uploading: this draft goes once they finish.
    var waitsForUploads = false
    var failure: PersonalAgentFailure?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var unreadable = false
    @ObservationIgnored private var settled: [CheckedContinuation<Void, Never>] = []
    /// Copies of files taken out of the draft, deleted by the first save that no longer names them.
    @ObservationIgnored private var discarded: [URL] = []
    /// One change saved once at its end, so no record of its halfway state is written.
    @ObservationIgnored private var holdsSaves = false
    /// Where the copies live: beside the draft file, or a private temporary folder for a draft not saved.
    @ObservationIgnored private lazy var filesDirectory: URL = file.map {
        URL(filePath: $0.deletingPathExtension().path(percentEncoded: false) + "-files", directoryHint: .isDirectory)
    } ?? FileManager.default.temporaryDirectory.appending(path: "Yardlet Dot Files", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    var needsRecovery: Bool { unreadable }

    /// Version 1 has no files. A draft without any is still written as version 1, which earlier
    /// builds read; one with files is version 2.
    private struct Record: Codable {
        var version = 1
        let text: String
        let pending: PersonalAgentSubmission?
        var files: [SavedFile]?
    }

    private struct SavedFile: Codable {
        let id: UUID
        let name: String
        let mimeType: String
        let sizeBytes: Int
        let copyName: String
        let uploaded: PersonalAgentUploadedFile?
    }

    init(file: URL? = nil) {
        self.file = file
        if let file {
            var readable = true
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                guard record.version == 1 || record.version == 2 else { throw CocoaError(.coderReadCorrupt) }
                editor.text = record.text
                pending = record.pending
                // An upload the app quit during did not finish; it waits for the person to retry it.
                files = (record.files ?? []).map { saved in
                    // Only a name this draft writes, so a damaged record cannot point outside its folder.
                    let copyName = Self.isCopyName(saved.copyName) ? saved.copyName : "file"
                    return .init(id: saved.id, name: saved.name, mimeType: saved.mimeType, sizeBytes: saved.sizeBytes,
                          copy: filesDirectory.appending(path: saved.id.uuidString).appending(path: copyName),
                          state: saved.uploaded.map { .uploaded($0) } ?? .failed(.uploadInterrupted))
                }
                if pending != nil { failure = .deliveryUnknown }
            } catch CocoaError.fileReadNoSuchFile { }
            catch { unreadable = true; storageFailed = true; readable = false }
            if readable { reconcileCopies() }
        }
        editor.onChange = { [weak self] in
            guard let self, !self.holdsSaves else { return }
            _ = self.save()
        }
    }

    var hasUploadsInProgress: Bool { isAddingFiles || files.contains(where: \.isInProgress) }
    var hasFailedUploads: Bool { files.contains { $0.failure != nil } }

    func file(_ id: UUID) -> PersonalAgentDraftFile? { files.first { $0.id == id } }

    /// Copies the chosen files into the draft's folder, as many as fit in a message and each of a size
    /// the provider takes. The person's own files are only read. Returns the files added, queued.
    func addFiles(_ sources: [PersonalAgentFileSource]) async -> [UUID] {
        await add(sources.map { .file($0) })
    }

    /// A pasted picture, saved as a file of its own. `encode` makes its bytes off the main thread,
    /// while the draft already counts as taking files in, so a Send meanwhile waits for it.
    func addImage(name: String, mimeType: String, encode: @escaping @Sendable () -> Data?) async -> [UUID] {
        await add([.data(encode, name: name, mimeType: mimeType)])
    }

    private enum Incoming: Sendable {
        case file(PersonalAgentFileSource)
        case data(@Sendable () -> Data?, name: String, mimeType: String)
    }

    private func add(_ incoming: [Incoming]) async -> [UUID] {
        guard pending == nil, !isSending, !isAddingFiles, !unreadable else { return [] }
        let room = PersonalAgentFileRules.maximumCount - files.count
        var refused = incoming.count > room
        let directory = filesDirectory
        isAddingFiles = true
        let copies = await Task.detached(priority: .userInitiated) {
            incoming.prefix(max(0, room)).map { Self.copy($0, into: directory) }
        }.value
        isAddingFiles = false
        defer { resumeIfSettled() }
        var added: [UUID] = []
        for copy in copies {
            guard let copy else { refused = true; continue }
            // A draft that started sending, or filled up, meanwhile does not take it; only this copy goes.
            guard pending == nil, !isSending, !unreadable, files.count < PersonalAgentFileRules.maximumCount else {
                try? FileManager.default.removeItem(at: copy.copy.deletingLastPathComponent())
                refused = true
                continue
            }
            files.append(copy)
            added.append(copy.id)
        }
        if refused { editor.notice = PersonalAgentFailure.attachmentLimit.message }
        // A file the saved draft does not name yet is not uploaded. Its copy and the note beside it
        // stay, and the next start takes it back into the draft.
        if !added.isEmpty, !save() {
            for id in added { if let index = files.firstIndex(where: { $0.id == id }) { files[index].state = .failed(.draftStorage) } }
            return []
        }
        return added
    }

    /// One private copy: a regular file of 1 byte to 20 MiB, or nil.
    nonisolated private static func copy(_ incoming: Incoming, into directory: URL) -> PersonalAgentDraftFile? {
        let manager = FileManager.default
        let id = UUID()
        let name: String, declared: String?
        var bytes = Data()
        switch incoming {
        case let .file(source):
            let values = try? source.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, PersonalAgentFileRules.accepts(size: size)
            else { return nil }
            name = PersonalAgentFileRules.displayName(source.url.lastPathComponent)
            declared = source.declaredType
        case let .data(encode, value, type):
            guard let data = encode(), PersonalAgentFileRules.accepts(size: data.count) else { return nil }
            name = PersonalAgentFileRules.displayName(value)
            declared = type
            bytes = data
        }
        let ext = (name as NSString).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12)
        let copyName = ext.isEmpty ? "file" : "file." + ext
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        let target = folder.appending(path: copyName)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
            switch incoming {
            case let .file(source): try manager.copyItem(at: source.url, to: target)
            case .data: try bytes.write(to: target, options: .withoutOverwriting)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path(percentEncoded: false))
            // The size of what was copied, which the original may have changed since it was measured.
            guard let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  PersonalAgentFileRules.accepts(size: size) else { throw CocoaError(.fileReadTooLarge) }
            let mimeType = PersonalAgentFileRules.mimeType(name: name, declared: declared)
            // What the copy is, beside it, so a copy the draft could not save yet is not lost on restart.
            let note = folder.appending(path: noteName)
            try JSONEncoder().encode(SavedFile(id: id, name: name, mimeType: mimeType, sizeBytes: size,
                                               copyName: copyName, uploaded: nil)).write(to: note, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path(percentEncoded: false))
            return .init(id: id, name: name, mimeType: mimeType, sizeBytes: size, copy: target, state: .queued)
        } catch {
            try? manager.removeItem(at: folder)
            return nil
        }
    }

    nonisolated private static let noteName = "about.json"
    nonisolated private static let discardedSuffix = ".discarded"

    nonisolated static func isCopyName(_ name: String) -> Bool {
        guard name.hasPrefix("file") else { return false }
        let rest = name.dropFirst(4)
        guard let dot = rest.first else { return true }
        let ext = rest.dropFirst()
        return dot == "." && (1...12).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Where a file's upload stands. A file removed meanwhile stays removed. An accepted file counts
    /// as uploaded only once its ID is saved with the draft; until then it can be retried, not sent.
    func setState(_ id: UUID, _ state: PersonalAgentDraftFile.State) {
        guard let index = files.firstIndex(where: { $0.id == id }), files[index].state != state else { return }
        files[index].state = state
        if case .uploaded = state, !save() { files[index].state = .failed(.draftStorage) }
        resumeIfSettled()
    }

    /// Takes the file out of the draft, and deletes its copy once the draft is saved without it.
    /// Nothing is deleted on the provider.
    func removeFile(_ id: UUID) {
        guard pending == nil, !isSending, let file = file(id) else { return }
        drop([file])
        resumeIfSettled()
    }

    /// Takes files out of the draft. Each copy is first marked as discarded, and deleted by the first
    /// save that no longer names it. Until then the mark stays: a start after a failed save keeps the
    /// copy the saved draft still names, and a start after a later successful save deletes it. A copy
    /// that cannot be marked loses the note that would bring it back instead; one that can do neither
    /// stays in the draft. Only these files' copies are touched.
    private func drop(_ gone: [PersonalAgentDraftFile]) {
        guard !gone.isEmpty else { return }
        let manager = FileManager.default
        var dropped = Set<UUID>()
        for file in gone {
            let folder = file.copy.deletingLastPathComponent()
            let aside = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + Self.discardedSuffix)
            if (try? manager.moveItem(at: folder, to: aside)) != nil {
                discarded.append(aside)
            } else if !manager.fileExists(atPath: folder.path(percentEncoded: false))
                        || (try? manager.removeItem(at: folder.appending(path: Self.noteName))) != nil {
                discarded.append(folder)
            } else { continue }
            dropped.insert(file.id)
        }
        files.removeAll { dropped.contains($0.id) }
        _ = save()
    }

    /// Returns once no file is queued or uploading.
    func uploadsSettled() async {
        guard hasUploadsInProgress else { return }
        await withCheckedContinuation { settled.append($0) }
        if hasUploadsInProgress { await uploadsSettled() }
    }

    private func resumeIfSettled() {
        guard !hasUploadsInProgress, !settled.isEmpty else { return }
        let waiting = settled
        settled = []
        waiting.forEach { $0.resume() }
    }

    /// After a readable start, the saved draft decides: a copy it names stays (and one set aside for a
    /// removal that was never saved comes back), a copy set aside for a saved removal is deleted, and a
    /// copy it does not name yet, because saving failed after the copy was made, joins the draft again
    /// to retry. Nothing else in the folder is touched.
    private func reconcileCopies() {
        let manager = FileManager.default
        let listed = Set(files.map(\.id))
        let entries = (try? manager.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? []
        var restored = false
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name.hasSuffix(Self.discardedSuffix), let id = UUID(uuidString: String(name.dropLast(Self.discardedSuffix.count))) {
                if listed.contains(id) {
                    try? manager.moveItem(at: entry, to: filesDirectory.appending(path: id.uuidString, directoryHint: .isDirectory))
                } else {
                    try? manager.removeItem(at: entry)
                }
                continue
            }
            guard let id = UUID(uuidString: name), !listed.contains(id), files.count < PersonalAgentFileRules.maximumCount,
                  let note = try? JSONDecoder().decode(SavedFile.self, from: Data(contentsOf: entry.appending(path: Self.noteName))),
                  note.id == id, Self.isCopyName(note.copyName),
                  manager.fileExists(atPath: entry.appending(path: note.copyName).path(percentEncoded: false)) else { continue }
            files.append(.init(id: id, name: note.name, mimeType: note.mimeType, sizeBytes: note.sizeBytes,
                               copy: entry.appending(path: note.copyName), state: .failed(.uploadInterrupted)))
            restored = true
        }
        if restored { _ = save() }
    }

    /// Persist the request identity before any network write. A restarted app
    /// reconciles or retries this same request, never silently creates another.
    ///
    /// `intended` is the text and files as they were when Send was pressed, kept while their uploads
    /// finished; the message is those, or nothing if one of the files is gone or did not upload.
    func prepare(_ intended: Intended? = nil) -> PersonalAgentSubmission? {
        guard !isSending, !unreadable else { return nil }
        let wasPending = pending != nil
        if pending == nil {
            let intended = intended ?? self.intended
            // Only files the room accepted go; a file still uploading or failed stops the send.
            let chosen = intended.files.map { id in files.first { $0.id == id }?.uploaded }
            guard !chosen.contains(where: { $0 == nil }) else { return nil }
            let submission = PersonalAgentSubmission(text: intended.text, attachments: chosen.compactMap { $0 })
            guard !submission.isEmpty else { return nil }
            pending = submission
        }
        guard save() else {
            if !wasPending { pending = nil }
            return nil
        }
        return pending
    }

    /// What Send takes: the words and the files in the draft at that moment.
    struct Intended: Equatable {
        let text: String
        let files: [UUID]
    }

    var intended: Intended { .init(text: editor.text, files: files.map(\.id)) }

    func accepted(_ requestID: String) {
        guard let submission = pending, submission.requestID == requestID else { return }
        pending = nil
        failure = nil
        // The words, the request and the sent files leave together, in one saved record.
        holdsSaves = true
        if editor.text == submission.text { editor.text = "" }
        holdsSaves = false
        let sent = Set(submission.attachments.map(\.fileID))
        let gone = files.filter { $0.uploaded.map { sent.contains($0.fileID) } == true }
        if gone.isEmpty { _ = save() } else { drop(gone) }
    }

    func failed(_ failure: PersonalAgentFailure, retry: Bool) {
        self.failure = failure
        // These responses explicitly reject this attempt; its text is editable.
        // A rejection of a retry says nothing about the earlier uncertain send.
        if !retry, failure == .sendRejected || failure == .verificationRequired || failure == .attachmentsNotAllowed {
            pending = nil
        }
        _ = save()
    }

    /// Only the person's explicit confirmation abandons delivery tracking.
    /// The text stays, and nothing is sent by returning to the editor.
    @discardableResult
    func resumeEditing() -> Bool {
        guard !isSending, !unreadable else { return false }
        let previous = pending
        pending = nil
        guard save() else { pending = previous; return false }
        failure = nil
        return true
    }

    /// Keep the original unreadable bytes before saving a new editable draft.
    /// A backup failure leaves the original and the blocked state untouched.
    @discardableResult
    func recoverStorage() -> Bool {
        guard !isSending, unreadable, let file else { return false }
        do {
            let backup = file.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: file, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            unreadable = false
            guard save() else { unreadable = true; return false }
            failure = nil
            return true
        } catch { storageFailed = true; return false }
    }

    @discardableResult
    func save() -> Bool {
        guard !unreadable else { storageFailed = true; return false }
        guard let file else {
            discarded.forEach { try? FileManager.default.removeItem(at: $0) }
            discarded = []
            storageFailed = false
            return true
        }
        do {
            let manager = FileManager.default
            let directory = file.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let saved = files.map { file in
                SavedFile(id: file.id, name: file.name, mimeType: file.mimeType, sizeBytes: file.sizeBytes,
                          copyName: file.copy.lastPathComponent, uploaded: file.uploaded)
            }
            let attached = !saved.isEmpty || pending?.attachments.isEmpty == false
            let record = Record(version: attached ? 2 : 1, text: editor.text, pending: pending, files: attached ? saved : nil)
            try JSONEncoder().encode(record).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageFailed = false
            let kept = Set(files.map { $0.copy.deletingLastPathComponent().lastPathComponent })
            for folder in discarded where !kept.contains(folder.lastPathComponent) { try? manager.removeItem(at: folder) }
            discarded = []
            return true
        } catch { storageFailed = true; return false }
    }
}

/// One draft per complete account/home/room binding, shared between windows.
/// This directory holds only input the person wrote here, never provider history.
@MainActor
final class PersonalAgentDrafts {
    private let fileURL: ([String]) -> URL?
    private var values: [String: PersonalAgentDraft] = [:]

    init(fileURL: @escaping ([String]) -> URL? = { _ in nil }) { self.fileURL = fileURL }

    func draft(source: String, identity: PersonalAgentIdentity) -> PersonalAgentDraft {
        let binding = [source, identity.accountID, identity.userID, identity.agentID, identity.roomID]
        let key = String(decoding: try! JSONEncoder().encode(binding), as: UTF8.self)
        if let draft = values[key] { return draft }
        let draft = PersonalAgentDraft(file: fileURL(binding))
        values[key] = draft
        return draft
    }

    #if DEBUG
    /// The drafts opened so far, for a rendered window to fill.
    var opened: [PersonalAgentDraft] { Array(values.values) }
    #endif
}
