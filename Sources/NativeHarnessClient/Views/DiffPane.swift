import AppKit
import SwiftUI

struct DiffPane: View {
    let workspaceURL: URL
    var additionalRootURLs: [URL] = []
    @Binding var review: DiffReviewPreferences
    var codexChanges: [CodexChangeHandoff] = []
    var lastTurn: ReviewLastTurn = .notOffered
    /// The task's diff comments waiting for its next message; nil leaves the diff without comments.
    var comments: Binding<[DiffComment]>? = nil
    var reading: any GitDiffReading = GitDiffService()
    @State private var providerLastTurn: ReviewLastTurn?
    private var effectiveLastTurn: ReviewLastTurn { providerLastTurn ?? lastTurn }
    let onClose: () -> Void

    /// Same bound as the git scopes' output.
    nonisolated static let lastTurnByteLimit = 2 * 1024 * 1024

    @State private var snapshot = DiffSnapshot(lines: [], isTruncated: false)
    @State private var emptyTitle: String?
    /// Repositories among the task's folders; the menu appears only when there are two or more.
    @State private var repositories: [URL] = []
    @State private var commits: [GitCommitSummary] = []
    @State private var errorMessage: String?
    /// Why Stage, Unstage or Discard did not happen, shown above the diff it was asked for.
    @State private var mutationError: String?
    /// No repository holds the task's folder: the Codex app and the Claude app say so quietly, as
    /// they say there are no changes, rather than as a failure.
    @State private var isNotRepository = false
    @State private var isLoading = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var requestID = UUID()
    /// The scope the snapshot shows, so a Last turn update keeps the old diff until the new one parses.
    @State private var shownScope: GitDiffScope?
    @State private var loadedRepository: URL?
    /// The top folder of the loaded repository, which the diff's paths are relative to.
    @State private var loadedRoot: URL?
    /// What the shown git scope compared, which a Markdown file's rendered view reads its file from.
    @State private var shownTarget: GitDiffTarget?
    /// The tasks that edited or read the selected file.
    @State private var fileTasks = FileTasks()
    @State private var isMutating = false
    @State private var discardRequest: GitDiscardRequest?
    @FocusState private var isRefreshFocused: Bool
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: L10n.string("Review"),
                systemName: "plus.rectangle",
                workspaceURL: selectedRepository ?? workspaceURL,
                status: statusText,
                statusTint: statusTint,
                onClose: onClose
            ) {
                Button {
                    reloadTask?.cancel()
                    reloadTask = Task { await reload() }
                } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Refresh"))
                .focused($isRefreshFocused)
                .disabled(isLoading)
                .parityPointer()
            }

            if !isNotRepository || effectiveLastTurn.isOffered { scopeBar }
            Divider()
            if let mutationError {
                Label(mutationError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ParityTheme.subtleFill)
                Divider()
            }

            if !codexChanges.isEmpty {
                CodexChangeContext(changes: codexChanges)
            }

            Group {
                if isLoading && snapshot.isEmpty {
                    ProgressView(L10n.string("Loading diff…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    WorkSurfaceEmptyState(
                        title: L10n.string("Diff unavailable"),
                        message: errorMessage,
                        systemName: "exclamationmark.triangle"
                    )
                } else if isNotRepository, review.scope != .lastTurn {
                    WorkSurfaceEmptyState(
                        title: L10n.string("Changes need a Git repository"),
                        message: L10n.string("None was found for this task, or its folder couldn’t be reached.")
                    )
                } else if snapshot.isEmpty {
                    WorkSurfaceEmptyState(title: emptyTitle ?? review.scope.emptyTitle)
                } else {
                    diffContent
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .sheet(item: $discardRequest) { request in
            GitDiscardReviewSheet(request: request, onCancel: { discardRequest = nil }, onDiscard: {
                discardRequest = nil
                perform(.discard, frozen: request)
            })
        }
        .task(id: LoadKey(
            workspaceURL: workspaceURL,
            additionalRootURLs: additionalRootURLs,
            scope: review.scope,
            commit: review.commit,
            repositoryPath: review.repositoryPath,
            lastTurnRevision: review.scope == .lastTurn ? effectiveLastTurn.diff?.revision ?? "" : nil
        )) {
            reloadTask?.cancel()
            if !(review.scope == .lastTurn && shownScope == .lastTurn) {
                snapshot = DiffSnapshot(lines: [], isTruncated: false)
            }
            await reload()
        }
        .onAppear {
            // A task that no longer offers Last turn opens on the default scope.
            if !reading.isRemote, review.scope == .lastTurn, !effectiveLastTurn.isOffered { review.scope = .unstaged }
        }
        .onDisappear { reloadTask?.cancel() }
        .taskFocus(.diff, isFocused: $isRefreshFocused, enabled: !isLoading)
    }

    /// The repository, scope and commit menus, and what the scope's changes can have done to them.
    private var scopeBar: some View {
        HStack {
            if repositories.count > 1, review.scope != .lastTurn {
                Picker(L10n.string("Repository"), selection: Binding(
                    get: { selectedRepository?.path(percentEncoded: false) ?? "" },
                    set: { review.repositoryPath = $0 }
                )) {
                    ForEach(repositories, id: \.self) { repository in
                        Text(repository.lastPathComponent).tag(repository.path(percentEncoded: false))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help(selectedRepository?.path(percentEncoded: false) ?? "")
            }
            Picker(L10n.string("Review scope"), selection: $review.scope) {
                ForEach(GitDiffScope.offered(includingLastTurn: effectiveLastTurn.isOffered), id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if review.scope == .commit, let commit = selectedCommit {
                Picker(L10n.string("Commit"), selection: Binding(
                    get: { commit.id }, set: { review.commit = $0 }
                )) {
                    ForEach(commits) { item in
                        Text(verbatim: "\(item.shortID)  \(item.subject)  ·  "
                            + item.date.formatted(date: .abbreviated, time: .omitted))
                            .tag(item.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(commit.subject)
            }
            Spacer(minLength: 0)
            if review.scope == .unstaged, mutationIsAvailable {
                Button(L10n.string("Stage all")) { perform(.stage) }
                    .disabled(mutationUnavailableReason != nil).help(mutationUnavailableReason ?? "")
                Button(L10n.string("Discard changes")) {
                    if let loadedRepository { discardRequest = .init(workspaceURL: loadedRepository, snapshot: snapshot) }
                }
                .disabled(mutationUnavailableReason != nil).help(mutationUnavailableReason ?? "")
            } else if review.scope == .staged, mutationIsAvailable {
                Button(L10n.string("Unstage all")) { perform(.unstage) }
                    .disabled(mutationUnavailableReason != nil).help(mutationUnavailableReason ?? "")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private struct LoadKey: Equatable {
        let workspaceURL: URL
        let additionalRootURLs: [URL]
        let scope: GitDiffScope
        let commit: String?
        let repositoryPath: String?
        let lastTurnRevision: String?
    }

    /// The repository shown in the menu, when the task's folders hold more than one.
    private var selectedRepository: URL? {
        guard repositories.count > 1 else { return nil }
        var preferences = review
        return preferences.resolveRepository(among: repositories, workspaceURL: workspaceURL)
    }

    private var selectedCommit: GitCommitSummary? {
        var preferences = review
        return preferences.resolveCommit(among: commits)
    }

    private var selectedFile: DiffFile? {
        snapshot.files.first { $0.path == review.selectedPath } ?? snapshot.files.first
    }

    private var diffContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if proxy.size.width < 620 {
                    HStack(spacing: 8) {
                        Picker(L10n.string("Changed file"), selection: Binding(
                            get: { selectedFile?.path ?? "" }, set: { review.selectedPath = $0 }
                        )) {
                            ForEach(snapshot.files) { file in
                                Text(file.path).tag(file.path)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(selectedFile?.path ?? "")
                        if let file = selectedFile {
                            DiffFileContent.summary(file)
                            if let preview = markdownPreview(for: file) { MarkdownReviewToggle(isOn: preview.isOn) }
                        }
                    }
                    .padding(10)
                    if !fileTasks.isEmpty {
                        FileTasksLine(tasks: fileTasks).padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    Divider()
                }
                HStack(spacing: 0) {
                    if proxy.size.width >= 620 {
                        fileList.frame(width: 200)
                        Divider()
                    }
                    if let file = selectedFile {
                        DiffFileContent(
                            file: file, width: proxy.size.width - (proxy.size.width >= 620 ? 201 : 0),
                            showsHeader: proxy.size.width >= 620,
                            commentRoot: comments == nil ? nil : commentRoot,
                            comments: comments ?? .constant([]),
                            markdownPreview: markdownPreview(for: file),
                            fileTasks: fileTasks
                        )
                        .id(file.path)
                    }
                }
                if snapshot.isTruncated {
                    Label(L10n.string("Preview limited. Some changes are not shown."), systemImage: "scissors")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ParityTheme.subtleFill)
                }
            }
        }
        // Read again with each load, so a refresh also brings the tasks that touched the file since.
        .loadsFileTasks(for: isLoading || reading.isRemote ? nil : selectedFileURL, refresh: requestID.uuidString, into: $fileTasks)
    }

    /// The selected file where it is: in the repository's top folder for the git scopes, in the task's
    /// folder for Last turn (or where the call named it).
    private var selectedFileURL: URL? {
        guard let file = selectedFile else { return nil }
        if file.path.hasPrefix("/") { return URL(filePath: file.path) }
        return (review.scope == .lastTurn ? workspaceURL : loadedRoot ?? workspaceURL).appending(path: file.path)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(snapshot.files) { file in
                    Button { review.selectedPath = file.path } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.path).font(.callout.weight(.medium))
                                .lineLimit(2).truncationMode(.middle)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 8) {
                                Text(file.status).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text("+\(file.additionCount)").foregroundStyle(.green)
                                Text("−\(file.deletionCount)").foregroundStyle(.red)
                            }.font(.caption)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                        .background(selectedFile?.id == file.id ? ParityTheme.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).parityPointer()
                    .accessibilityLabel(file.path)
                    .accessibilityValue("\(file.status), +\(file.additionCount), −\(file.deletionCount)")
                    .accessibilityAddTraits(selectedFile?.id == file.id ? .isSelected : [])
                    .help(file.path)
                }
            }.padding(6)
        }
    }

    /// The folder the shown diff's paths are relative to, which its comments name (`Workspace:`):
    /// the repository's top folder for its scopes, the task's folder for Last turn.
    private var commentRoot: String {
        let root = review.scope == .lastTurn ? workspaceURL : loadedRoot ?? workspaceURL
        let path = root.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// A Markdown file's rendered view (`MarkdownReviewDiff`): its change read against the file the
    /// shown diff left, which the working tree holds for Unstaged and Last turn and the repository
    /// for the other scopes. Nil for any other file.
    private func markdownPreview(for file: DiffFile) -> DiffMarkdownPreview? {
        guard MarkdownReviewDiff.isMarkdown(file.path), !file.isBinary, let scope = shownScope,
              scope == .lastTurn || shownTarget != nil else { return nil }
        let sections = snapshot.files.filter { $0.path == file.path }
        let root = scope == .lastTurn ? workspaceURL : loadedRoot ?? workspaceURL
        let fileURL = file.newPath.map { $0.hasPrefix("/") ? URL(filePath: $0) : root.appending(path: $0) }
        let repository = loadedRepository ?? root
        let target = shownTarget
        return DiffMarkdownPreview(
            isOn: Binding(get: { review.rendersMarkdown == true }, set: { review.rendersMarkdown = $0 ? true : nil }),
            loadID: "\(scope.rawValue)|\(String(describing: target))|\(file.path)|\(sections.hashValue)",
            documentFolder: reading.isRemote ? nil : (fileURL ?? root.appending(path: file.path)).deletingLastPathComponent(),
            load: {
                let new: String?
                if let path = file.newPath {
                    switch target {
                    case nil, .unstaged?:
                        if let fileURL { new = try? await reading.workingText(fileURL) } else { new = nil }
                    case .staged?:
                        new = try? await reading.fileText(workspaceURL: repository, revision: "", path: path)
                    case let .commit(hash)?:
                        new = try? await reading.fileText(workspaceURL: repository, revision: hash, path: path)
                    case .branch?:
                        new = try? await reading.fileText(workspaceURL: repository, revision: "HEAD", path: path)
                    }
                } else {
                    // The change took the whole file out.
                    new = ""
                }
                return await Task.detached(priority: .userInitiated) {
                    MarkdownReviewDiff.outcome(new: new, sections: sections, afterTurn: scope == .lastTurn)
                }.value
            }
        )
    }

    private var statusText: String? {
        if isLoading { return L10n.string("Loading") }
        if errorMessage != nil { return L10n.string("Unavailable") }
        if isNotRepository, review.scope != .lastTurn { return nil }
        if snapshot.isEmpty { return L10n.string("No changes") }
        return L10n.format(
            snapshot.fileCount == 1 ? "%d file · +%d −%d" : "%d files · +%d −%d",
            snapshot.fileCount,
            snapshot.additionCount,
            snapshot.deletionCount
        )
    }

    private var statusTint: Color {
        errorMessage != nil ? .red : .secondary
    }

    private var mutationIsAvailable: Bool {
        !isLoading && !isMutating && !snapshot.isEmpty && !snapshot.isTruncated
            && shownScope == review.scope && loadedRepository != nil
    }

    private var mutationUnavailableReason: String? { reading.mutationUnavailableReason }

    private func perform(_ action: GitMutation, frozen: GitDiscardRequest? = nil) {
        guard mutationUnavailableReason == nil, !isMutating,
              let root = frozen?.workspaceURL ?? loadedRepository else { return }
        let expected = frozen?.snapshot ?? snapshot
        let reading = reading
        isMutating = true
        mutationError = nil
        Task {
            defer { isMutating = false }
            do {
                try await reading.mutate(action, workspaceURL: root, expected: expected)
                await reload()
            } catch { mutationError = error.localizedDescription }
        }
    }

    private func reload() async {
        let ticket = UUID()
        requestID = ticket
        mutationError = nil
        if reading.isRemote {
            isLoading = true
            do {
                let last = try await reading.lastTurn()
                guard requestID == ticket, !Task.isCancelled else { return }
                providerLastTurn = last
                if review.scope == .lastTurn, !effectiveLastTurn.isOffered { review.scope = .unstaged }
            } catch {
                guard requestID == ticket, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
        }
        let scope = review.scope
        if scope == .lastTurn {
            await showLastTurn(ticket: ticket)
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let service = reading
            // A task with one folder never looks further, so its review reads that folder as before.
            let found = additionalRootURLs.isEmpty
                ? []
                : try await service.repositories(containing: [workspaceURL] + additionalRootURLs)
            try Task.checkCancellation()
            guard requestID == ticket else { return }
            // The menus stay usable even when the chosen repository then fails to load.
            repositories = found
            var resolved = review
            let repository = resolved.resolveRepository(among: found, workspaceURL: workspaceURL)
            var title: String?
            var target: GitDiffTarget?
            let result: DiffSnapshot
            switch scope {
            case .unstaged:
                target = .unstaged
                result = try await service.load(workspaceURL: repository, target: .unstaged)
            case .staged:
                target = .staged
                result = try await service.load(workspaceURL: repository, target: .staged)
            case .commit:
                let listed = try await service.recentCommits(workspaceURL: repository, limit: 50)
                try Task.checkCancellation()
                guard requestID == ticket else { return }
                commits = listed
                if let commit = resolved.resolveCommit(among: listed) {
                    target = .commit(commit.id)
                    result = try await service.load(workspaceURL: repository, target: .commit(commit.id))
                } else {
                    result = DiffSnapshot(lines: [], isTruncated: false)
                    title = L10n.string("No commits")
                }
            case .branch:
                switch try await service.baseBranch(workspaceURL: repository) {
                case let .found(base):
                    target = .branch(base: base)
                    result = try await service.load(workspaceURL: repository, target: .branch(base: base))
                case .missing:
                    result = DiffSnapshot(lines: [], isTruncated: false)
                    title = L10n.string("No base branch")
                case .current:
                    result = DiffSnapshot(lines: [], isTruncated: false)
                    title = L10n.string("On the base branch")
                }
            case .lastTurn:
                return  // Read from the provider in showLastTurn, never from git.
            }
            let root = result.isEmpty ? nil : try? await service.repositoryRoot(workspaceURL: repository)
            try Task.checkCancellation()
            guard requestID == ticket, review.scope == scope else { return }
            snapshot = result
            loadedRepository = repository
            loadedRoot = root ?? repository
            shownScope = scope
            shownTarget = target
            emptyTitle = title
            isNotRepository = false
            // A remembered repository or commit that no longer exists is cleared without notice.
            if review.repositoryPath != resolved.repositoryPath { review.repositoryPath = resolved.repositoryPath }
            if scope == .commit, review.commit != resolved.commit { review.commit = resolved.commit }
            if !result.files.contains(where: { $0.path == review.selectedPath }) {
                review.selectedPath = result.files.first?.path
            }
        } catch is CancellationError {
            if requestID == ticket { isLoading = false }
            return
        } catch GitDiffServiceError.notARepository {
            guard requestID == ticket, review.scope == scope else { return }
            snapshot = DiffSnapshot(lines: [], isTruncated: false)
            loadedRepository = nil
            shownScope = scope
            emptyTitle = nil
            isNotRepository = true
        } catch {
            guard requestID == ticket, review.scope == scope else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Last turn reads the provider's diff, not git, so it needs no repository and shows at once.
    private func showLastTurn(ticket: UUID) async {
        let diff = effectiveLastTurn.diff
        let text = diff?.text ?? ""
        let result = await Task.detached(priority: .userInitiated) {
            let parsed = UnifiedDiffParser().parse(text, byteLimit: Self.lastTurnByteLimit)
            return DiffSnapshot(lines: parsed.lines, isTruncated: parsed.isTruncated || diff?.isTruncated == true)
        }.value
        guard requestID == ticket, review.scope == .lastTurn else { return }
        snapshot = result
        shownScope = .lastTurn
        shownTarget = nil
        errorMessage = nil
        isLoading = false
        emptyTitle = diff == nil ? L10n.string("No turns yet") : nil
        if !result.files.contains(where: { $0.path == review.selectedPath }) {
            review.selectedPath = result.files.first?.path
        }
    }
}

private struct CodexChangeContext: View {
    let changes: [CodexChangeHandoff]
    @State private var outcomes: [CodexChangeHandoff.ID: CodexEditorHandoffOutcome] = [:]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) { changeRows }
                    .padding(.vertical, 5)
            }
            .frame(height: min(120, CGFloat(changes.count) * 30))
        } label: {
            HStack(spacing: 6) {
                Label(L10n.string("Codex changes"), systemImage: "link")
                Text("\(changes.count)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
        }
    }

    private var changeRows: some View {
        ForEach(changes) { change in
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    guard let url = change.verifiedURL else { return }
                    outcomes[change.id] = CodexEditorHandoffProjection.outcome(
                        opened: NSWorkspace.shared.open(url)
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: change.isVerified ? "checkmark.shield" : "xmark.shield")
                            .foregroundStyle(change.isVerified ? .green : .red)
                        Text(change.locationLabel)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(change.status)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .disabled(!change.isVerified)
                .accessibilityLabel(change.locationLabel)
                .accessibilityValue(
                    change.isVerified
                        ? L10n.string("Open in editor")
                        : L10n.string("Path is outside the task workspace")
                )
                .help(
                    change.isVerified
                        ? change.verifiedURL?.path(percentEncoded: false) ?? change.relativePath
                        : L10n.string("Path is outside the task workspace")
                )
                outcomeLabel(for: outcomes[change.id])
            }
        }
    }

    @ViewBuilder
    private func outcomeLabel(for outcome: CodexEditorHandoffOutcome?) -> some View {
        if let outcome {
            Label(
                L10n.string(CodexEditorHandoffProjection.messageKey(for: outcome)),
                systemImage: CodexEditorHandoffProjection.symbolName(for: outcome)
            )
            .font(.caption2)
            .foregroundStyle(outcome == .opened ? Color.secondary : Color.red)
            .accessibilityValue(L10n.string(CodexEditorHandoffProjection.messageKey(for: outcome)))
        }
    }
}
