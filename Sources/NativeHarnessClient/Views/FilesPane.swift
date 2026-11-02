import SwiftUI

struct FilesPane: View {
    let workspaceURL: URL
    @Bindable var state: WorkspaceFilesState
    let onClose: () -> Void
    @FocusState private var isSearchFocused: Bool
    @State private var confirmsDiscard = false
    /// The tasks that edited or read the open file.
    @State private var fileTasks = FileTasks()
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: state.preferences.selectedPath.map { URL(filePath: $0).lastPathComponent } ?? L10n.string("Files"),
                systemName: state.preferences.selectedPath == nil ? "folder" : "doc.text",
                workspaceURL: state.preferences.selectedPath.map(fileURL) ?? workspaceURL,
                onClose: {
                    if state.preferences.selectedPath != nil || state.fileError != nil { showPicker() }
                    else { onClose() }
                }
            ) {
                if state.isDirty {
                    Button(L10n.string("Save")) { Task { await state.save(in: workspaceURL) } }.disabled(state.isSaving)
                    ParityIconButton(systemName: "arrow.uturn.backward", help: L10n.string("Discard changes")) { confirmsDiscard = true }
                        .disabled(state.isSaving)
                }
                if state.preferences.selectedPath != nil || state.fileError != nil {
                    ParityIconButton(systemName: "folder", help: L10n.string("Files"), action: showPicker)
                }
                ParityIconButton(systemName: "arrow.clockwise", help: L10n.string("Refresh")) {
                    if let path = state.preferences.selectedPath {
                        if state.isDirty { confirmsDiscard = true }
                        else { state.open(WorkspaceFileLocation(relativePath: path), in: workspaceURL, refresh: true) }
                    } else { Task { await state.loadIndex(in: workspaceURL, force: true) } }
                }
                .disabled(state.isLoading || state.isIndexing)
            }
            fileContent
        }
        .background(ParityTheme.canvas)
        .confirmationDialog(L10n.string("Discard unsaved changes?"), isPresented: $confirmsDiscard) {
            Button(L10n.string("Discard changes"), role: .destructive) { state.discard(in: workspaceURL) }
        }
        .task {
            state.restore(in: workspaceURL)
            await state.loadIndex(in: workspaceURL)
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        if let error = state.saveError {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(10)
        }
        if let error = state.fileError {
            WorkSurfaceEmptyState(title: L10n.string("File unavailable"), message: error, systemName: "doc.badge.ellipsis") {
                // A file the panel cannot show (an image, a folder, an app) is still a click away.
                if let path = state.preferences.selectedPath {
                    FileElsewhereButtons(url: fileURL(path)).controlSize(.small)
                }
            }
        } else if let media = state.media {
            VStack(spacing: 0) {
                if !fileTasks.isEmpty {
                    FileTasksLine(tasks: fileTasks).padding(.horizontal, 10).padding(.vertical, 7)
                    Divider()
                }
                WorkspaceFileMediaView(media: media)
            }
            .loadsFileTasks(for: media.url, into: $fileTasks)
        } else if let document = state.document {
            VStack(spacing: 0) {
                FileNotice(document: document, url: fileURL(document.path))
                if !fileTasks.isEmpty {
                    FileTasksLine(tasks: fileTasks).padding(.horizontal, 10).padding(.vertical, 7)
                    Divider()
                }
                WorkspaceFileReader(document: document,
                    bookmark: state.preferences.bookmarks[document.path] ?? .init(),
                    location: state.requestedLocation, navigationID: state.navigationID,
                    fontSize: 12 * interfaceScale, focus: keyboardFocus,
                    onBookmark: { state.preferences.bookmarks[document.path] = $0 },
                    onNavigated: { state.didNavigate($0) }, onEdit: document.isEditable ? { state.edit($0) } : nil,
                    isSaving: state.isSaving)
            }
            .loadsFileTasks(for: fileURL(document.path), into: $fileTasks)
        } else if state.isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { filePicker }
    }

    private var filePicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("Find files"), text: $state.preferences.query)
                    .textFieldStyle(.plain).focused($isSearchFocused)
                    .onSubmit { if let path = state.matches.first { open(path) } }
            }
            .padding(12)
            Divider()
            if let error = state.indexError {
                WorkSurfaceEmptyState(title: L10n.string("Files unavailable"), message: error, systemName: "folder")
            } else if state.isIndexing && state.index.paths.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.matches.isEmpty {
                WorkSurfaceEmptyState(title: L10n.string("No files found"), systemName: "folder")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.matches, id: \.self) { path in
                            Button { open(path) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(filePath: path).lastPathComponent).foregroundStyle(.primary)
                                        Text(path).font(.caption).foregroundStyle(.secondary)
                                    }.lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless).parityPointer().help(path)
                            .accessibilityLabel(path)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if state.index.isLimited {
                Text(L10n.string("File list is limited"))
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .taskFocus(.files, isFocused: $isSearchFocused)
    }

    /// A path the panel holds: relative to the task's folder, or absolute for a file outside it.
    private func fileURL(_ path: String) -> URL {
        WorkspaceFileLocation.url(for: path, in: workspaceURL)
    }

    private func open(_ path: String) {
        state.open(WorkspaceFileLocation(relativePath: path), in: workspaceURL)
        keyboardFocus?.move(to: .files)
    }

    private func showPicker() {
        state.showPicker()
        keyboardFocus?.move(to: .files)
    }
}

/// One line over a file the panel does not show as usual: past 2 MB without colors or editing, past
/// 20 MB only its beginning, outside the task's folder or not UTF-8 read-only, with the file's own app
/// and Finder for the rest.
private struct FileNotice: View {
    let document: WorkspaceFileDocument
    let url: URL

    var body: some View {
        let isOutside = WorkspaceFileLocation(relativePath: document.path).isOutsideWorkspace
        if document.isPartial || !document.isEditable {
            HStack(spacing: 10) {
                Text(L10n.string(document.isPartial ? "Large file: only its beginning is shown"
                                 : isOutside ? "Outside the task's folder: not editable here"
                                 : document.isLossy ? "Not UTF-8: what doesn't decode shows as �, not editable here"
                                 : "Large file: shown without syntax highlighting or editing"))
                    .lineLimit(1).truncationMode(.tail)
                    .help(isOutside ? document.path : "")
                Spacer(minLength: 0)
                if document.isPartial || isOutside || document.isLossy { FileElsewhereButtons(url: url) }
            }
            .buttonStyle(.borderless)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ParityTheme.subtleFill)
        }
    }
}

/// The file in its own app and in Finder, for what the panel does not do. A program is only shown in
/// Finder: its own app would run it.
struct FileElsewhereButtons: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            if !Self.runs(url) {
                Button(L10n.string("Open in its app")) { NSWorkspace.shared.open(url) }
            }
            Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    static func runs(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && (isDirectory.boolValue ? NSWorkspace.shared.isFilePackage(atPath: path) : FileManager.default.isExecutableFile(atPath: path))
    }
}
