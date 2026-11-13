import Foundation
import Observation

struct FileReadingBookmark: Codable, Equatable {
    var line = 1
    var lineOffset: Double = 0
    var horizontalOffset: Double = 0
}

struct WorkspaceFilePreferences: Codable, Equatable {
    var selectedPath: String?
    var query = ""
    var bookmarks: [String: FileReadingBookmark] = [:]
    var drafts: [String: WorkspaceFileDraft]? = nil
}

struct WorkspaceFileDraft: Codable, Equatable {
    var text: String
    var originalText: String
    var digest: String
    var encoding: WorkspaceFileEncoding
}

@MainActor @Observable
final class WorkspaceFilesState {
    var preferences: WorkspaceFilePreferences { didSet { if preferences != oldValue { onChange?() } } }
    private(set) var resolvedWorkspace: URL?
    private(set) var index = WorkspaceFileIndex(paths: [], isLimited: false)
    private(set) var document: WorkspaceFileDocument?
    /// An image or a PDF the panel shows in place of text.
    private(set) var media: WorkspaceFileMedia?
    private(set) var isIndexing = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var saveError: String?
    private(set) var indexError: String?
    private(set) var fileError: String?
    private(set) var navigationID = UUID()
    private(set) var requestedLocation: WorkspaceFileLocation?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var indexedWorkspace: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var indexID = UUID()

    @ObservationIgnored let provider: any WorkspaceFiles
    var isLocal: Bool { provider.isLocal }

    init(preferences: WorkspaceFilePreferences = .init(), provider: any WorkspaceFiles = LocalWorkspaceFiles()) {
        self.preferences = preferences
        self.provider = provider
    }
    var isDirty: Bool { document.flatMap { preferences.drafts?[$0.path] } != nil }
    var canEdit: Bool { document?.isEditable == true && document?.sourceDigest != nil && !isSaving }

    func edit(_ text: String) {
        guard let document, document.isEditable, let digest = document.sourceDigest else { return }
        var draft = preferences.drafts?[document.path] ?? .init(text: document.text, originalText: document.text, digest: digest, encoding: document.encoding)
        draft.text = text
        var drafts = preferences.drafts ?? [:]
        if text == draft.originalText { drafts.removeValue(forKey: document.path) } else { drafts[document.path] = draft }
        preferences.drafts = drafts.isEmpty ? nil : drafts
        self.document = WorkspaceFileDocument(id: document.id, path: document.path, text: text, sourceDigest: draft.digest,
                                              encoding: draft.encoding, highlight: .later(keeping: document.highlightID))
        saveError = nil
        highlightLater()
    }

    /// Works out the colors of the text once the person has stopped typing, off the main thread,
    /// and keeps them only for that text.
    private func highlightLater() {
        highlightTask?.cancel()
        guard let document else { return }
        let text = document.text, path = document.path, revision = document.revision
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let tokens = await Task.detached(priority: .userInitiated) {
                WorkspaceFileDocument.tokens(in: text, path: path)
            }.value
            guard let self, !Task.isCancelled, let current = self.document, current.revision == revision else { return }
            self.document = current.highlighted(tokens)
        }
    }

    func save(in workspace: URL) async {
        guard !isSaving, let document, let draft = preferences.drafts?[document.path] else { return }
        let path = document.path
        isSaving = true; saveError = nil
        defer { isSaving = false }
        do {
            let result = try await provider.save(path: path, text: draft.text, expectedDigest: draft.digest,
                                                 encoding: draft.encoding, in: workspace)
            var drafts = preferences.drafts ?? [:]
            if drafts[path]?.text == draft.text { drafts.removeValue(forKey: path) }
            else if var newer = drafts[path] { newer.originalText = result.text; newer.digest = result.sourceDigest!; drafts[path] = newer }
            preferences.drafts = drafts.isEmpty ? nil : drafts
            if let current = self.document, current.path == path {
                let text = drafts[path]?.text ?? result.text
                self.document = WorkspaceFileDocument(id: document.id, path: path, text: text, sourceDigest: result.sourceDigest,
                                                      encoding: result.encoding, highlight: .later(keeping: current.highlightID))
                highlightLater()
            }
        } catch { saveError = error.localizedDescription }
    }

    func discard(in workspace: URL) {
        guard let path = document?.path, !isSaving else { return }
        preferences.drafts?.removeValue(forKey: path)
        if preferences.drafts?.isEmpty == true { preferences.drafts = nil }
        saveError = nil
        open(.init(relativePath: path), in: workspace, refresh: true)
    }

    var matches: [String] {
        let words = preferences.query.split(whereSeparator: \.isWhitespace).map(String.init)
        return index.paths.filter { path in words.allSatisfy { path.localizedCaseInsensitiveContains($0) } }
    }

    func loadIndex(in workspace: URL, force: Bool = false) async {
        guard force || indexedWorkspace != workspace else { return }
        let id = UUID()
        indexID = id
        isIndexing = true
        indexError = nil
        do {
            let result = try await provider.index(in: workspace)
            try Task.checkCancellation()
            guard indexID == id else { return }
            index = result
            resolvedWorkspace = result.workspaceURL ?? (isLocal ? workspace : nil)
            indexedWorkspace = result.workspaceURL ?? workspace
        } catch is CancellationError { }
        catch { if indexID == id { indexError = error.localizedDescription } }
        if indexID == id { isIndexing = false }
    }

    /// A file link the person clicked: a file outside the task's folder opens read-only.
    func open(_ url: URL, in workspace: URL) {
        do {
            guard isLocal else {
                open(.init(relativePath: url.isFileURL ? url.path(percentEncoded: false) : url.relativeString), in: workspace)
                return
            }
            open(try WorkspaceFileLocation.opening(url, in: workspace), in: workspace)
        }
        catch {
            loadTask?.cancel()
            loadID = UUID()
            preferences.selectedPath = nil
            requestedLocation = nil
            document = nil
            media = nil
            fileError = error.localizedDescription
            isLoading = false
        }
    }

    func open(_ location: WorkspaceFileLocation, in workspace: URL, refresh: Bool = false) {
        preferences.selectedPath = location.relativePath
        requestedLocation = location
        navigationID = UUID()
        fileError = nil
        if !refresh, document?.path == location.relativePath { return }
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        if refresh || document?.path != location.relativePath { document = nil }
        media = nil
        isLoading = true
        let draft = preferences.drafts?[location.relativePath]
        let provider = provider
        loadTask = Task { [weak self] in
            do {
                let content = try await provider.read(location, in: workspace)
                try Task.checkCancellation()
                var shown: WorkspaceFileDocument?
                if case let .document(file) = content, let draft {
                    shown = await Task.detached(priority: .utility) {
                        WorkspaceFileDocument(path: file.path, text: draft.text, sourceDigest: draft.digest, encoding: draft.encoding)
                    }.value
                }
                guard let self, !Task.isCancelled, self.loadID == id else { return }
                switch content {
                case let .media(media): self.media = media
                case let .document(file):
                    self.document = shown ?? file
                    self.saveError = draft.map { file.sourceDigest != $0.digest } == true
                        ? WorkspaceFileError.changedOnDisk.localizedDescription : nil
                }
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.loadID == id else { return }
                self.fileError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func restore(in workspace: URL) {
        guard document == nil, media == nil, !isLoading, let path = preferences.selectedPath else { return }
        open(WorkspaceFileLocation(relativePath: path), in: workspace)
    }

    func showPicker() {
        loadTask?.cancel()
        loadID = UUID()
        preferences.selectedPath = nil
        document = nil
        media = nil
        fileError = nil
        isLoading = false
    }

    func didNavigate(_ id: UUID) {
        if id == navigationID { requestedLocation = nil }
    }
}
