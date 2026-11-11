import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YardletRemote

/// The composer of a host's task: the app's own editor (`ComposerEditor`) with what the host takes from
/// another device (docs/REMOTE_PROTOCOL.md §15.14, §15.15, §15.20): words, pictures and files, and while a
/// turn runs the local composer's own rules and words for where a message goes (`FollowUpPolicy`), with
/// the host's follow-up setting in place of this Mac's, its queue's rows above the text, and Stop. From a host
/// that offers them (§15.23) its bottom row draws the task's own settings with the local controls
/// (`ComposerSessionControls`), "+" and a typed `/` list the slash commands that may run from here, and an
/// edited message goes as the host's edit. The context ring reads the same host facts as the session rail;
/// while the host cannot be reached, sending waits and the words stay.
struct RemoteComposer: View {
    let model: RemoteHostModel
    let taskID: String
    @Bindable var draft: TaskComposerDraft
    /// Messages waiting in the task's queue on the host.
    var queued: [RemoteItem] = []
    /// A turn's message being edited, sent as its edit.
    @Binding var editing: RemoteMessageEdit?
    @FocusState private var isFocused: Bool
    @State private var isSending = false
    @State private var showsFollowUpMenu = false
    @State private var menu: Menu?
    @State private var commands: [RemoteComposerCommand]?
    @State private var commandSearch = ""
    private var composerState: RemoteComposerState? { model.composerStates[taskID] }
    @State private var mentionIndex = RemoteComposerMentionIndex()
    @State private var queuedEdit: (id: String, text: String, attachments: [CodexUserInput], mentions: [WorkspaceFileMatch])?

    enum Menu {
        case attachments
        case commands
        case connectors
    }

    private var task: RemoteTask? { model.task(taskID) }
    private var isRunning: Bool { task?.running == true }

    private var hasMessage: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty || !draft.hostMentions.isEmpty
    }

    private var canSend: Bool { model.isConnected && !isSending && hasMessage }

    /// The harness's way with a message sent while a turn runs, as the local composer reads it: Codex adds it
    /// to the running task, Claude Code delivers it at its next step, any other harness when the turn ends.
    private var policy: FollowUpPolicy {
        guard task?.steers == true, let task, let policy = FollowUpPolicy(harness: HarnessKind(rawValue: task.harness))
        else { return .afterTurn }
        return policy
    }

    /// What Return does while a turn runs: the host's setting (§15.15), as this Mac's setting does locally.
    private var preferred: FollowUpMode { model.followUp == .queue ? .queue : .steer }

    /// Where Return sends while a turn runs; a harness that cannot steer queues.
    private var returnMode: FollowUpMode { policy.steers ? preferred : .queue }

    /// The task's settings as the local bottom row reads them, from a host that sent them.
    private var options: ComposerSessionOptions? {
        model.railComposerOptions(taskID)
    }

    /// The host's files for an @ mention, when it offers them.
    private var mentionSearch: (@MainActor (String) async -> WorkspaceFileSearchResult)? {
        guard model.offersWorkspaceFiles else { return nil }
        return { await mentionIndex.search($0, model: model, taskID: taskID) }
    }

    var body: some View {
        ComposerEditor(
            draft: draft, placeholder: placeholder,
            accessibilityHint: isRunning ? policy.returnHint(preferred: preferred) : L10n.string("Press Return to send"),
            metrics: .task(), input: nil, onExternalInput: acceptsAttachments ? { receive($0) } : nil, mentionRoots: [],
            mentionSearch: mentionSearch,
            onInsertMention: { RemoteComposerMentionIndex.insert($0, replacing: $1, into: draft) },
            commands: editorCommands, isCommandMenuOpen: menu == .commands, isMenuOpen: showsFollowUpMenu || menu != nil,
            showsChips: !draft.hostMentions.isEmpty,
            isFocused: $isFocused,
            onSubmit: { send(isRunning ? returnMode : nil) },
            onAlternateSubmit: isRunning && policy.steers ? { send(preferred.other) } : nil,
            takeSuggestion: takeSuggestion,
            suggestion: !isRunning && draft.text.isEmpty ? draft.nextMessageSuggestion : nil,
            // Escape stops the running turn, as the local composer's does.
            onEscape: { if isRunning, model.isConnected { model.send(.stopTurn(taskID: taskID)) } },
            onCommandQueryChange: { old, query in
                // Opening the typed list reads the commands again, as the local list reads what it shows.
                if old == nil, query != nil { Task { await readCommands() } }
            }
        ) {
            if queuedEdit != nil {
                HStack {
                    Text(L10n.string("Edit message"))
                    Spacer()
                    Button(L10n.string("Cancel")) { cancelQueueEdit() }.buttonStyle(.borderless)
                }.font(.caption).padding(.horizontal, 15).padding(.top, 9)
            }
            if composerState?.queuePaused == true {
                ComposerQueuePausedRow { act("resume") }
            }
            if !queued.isEmpty {
                VStack(spacing: 4) {
                    ForEach(queued, id: \.id) { item in queueRow(item) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
        } chips: {
            RemoteComposerMentionChips(draft: draft)
        } footer: {
            // The local composer's bottom row: what goes into the message and the task's settings, then the model
            // menu and Send pinned at the end.
            AnyLayout(ControlRowLayout(pinsTrailingActions: true)) {
                inputControls
                actionControls
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 10).padding(.trailing, 9).padding(.bottom, 9)
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .task(id: "\(taskID)|\(model.isConnected)|\(model.taskControls)") {
            await readCommands()
            _ = await model.readComposerState(taskID)
        }
        .task(id: "\(taskID)|\(isRunning)|\(queued.map(\.id).joined(separator: ","))") {
            _ = await model.readComposerState(taskID)
        }
        .onChange(of: composerState?.nextMessageSuggestion, initial: true) { _, suggestion in
            draft.nextMessageSuggestion = draft.text.isEmpty ? suggestion : nil
        }
        // What the host's composer says about the task's last message or command (`keepUnsent`, a command that
        // failed), under the text as the local composer's notice, until the host's goes or this composer's own replaces it.
        .onChange(of: composerState?.notice, initial: true) { previous, notice in
            if let notice { draft.notice = notice } else if draft.notice == previous { draft.notice = nil }
        }
        .onChange(of: isRunning) { _, running in
            if running { draft.nextMessageSuggestion = nil }
        }
        .onChange(of: editing) { _, edit in
            if edit != nil { isFocused = true }
        }
    }

    private var placeholder: String {
        guard model.isConnected else { return L10n.format("Waiting for %@…", model.name) }
        if isRunning { return policy.runningPlaceholder(preferred: preferred) }
        return L10n.format("Ask %@…", task?.harnessName ?? model.name)
    }

    private var acceptsAttachments: Bool { task?.acceptsImages == true || task?.acceptsFiles == true }

    @ViewBuilder private var inputControls: some View {
        plusButton
        if let options {
            ComposerSessionControls(
                options: options, placement: .leading, isDisabled: !model.isConnected, registersTaskFocus: false,
                onChoose: choose, onPrepare: prepareSettings,
                onTurnOffPlanMode: options.mode == .planIndicator ? { run("plan-mode", arguments: nil) } : nil)
        }
    }

    private var actionControls: some View {
        HStack(spacing: 7) {
            if let options {
                ComposerSessionControls(options: options, placement: .trailing, isDisabled: !model.isConnected,
                                        registersTaskFocus: false, onChoose: choose, onPrepare: prepareSettings,
                                        compact: model.railCompact(taskID))
            }
            if isSending { ProgressView().controlSize(.small) }
            if isRunning {
                followUpButton
                stopButton
            } else {
                ParityIconButton(systemName: "arrow.up", help: L10n.string("Send"), isProminent: true) { send(nil) }
                    .accessibilityLabel(L10n.string("Send message"))
                    .disabled(!canSend)
            }
        }
    }

    // MARK: - Settings (§15.23)

    /// A menu's choice; one the host's menu asks about first was asked about here too (`ComposerPermissionControl`).
    private func choose(_ choice: ComposerSessionChoice) {
        model.chooseTaskSetting(taskID, choice)
    }

    private func prepareSettings() async {
        await model.readTaskSettings(taskID, prepare: true)
    }

    // MARK: - "+" and slash commands (§15.23)

    /// The local composer's "+": files and photos where the task takes them, and the slash commands that may run from
    /// here. From a host that offers no commands it opens the file panel at once, as before.
    private var plusButton: some View {
        let hasMenu = !(commands ?? []).isEmpty || composerState?.connectorList != nil
        return Button {
            if hasMenu { menu = .attachments } else { chooseFiles() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(!acceptsAttachments && !hasMenu)
        .accessibilityLabel(hasMenu ? L10n.string("Add files and more") : L10n.string("Add files or photos"))
        .help(hasMenu ? L10n.string("Add files and more") : L10n.string("Add files or photos"))
        .popover(isPresented: Binding(get: { menu != nil }, set: { if !$0 { menu = nil } })) {
            switch menu {
            case .connectors?:
                if let list = composerState?.connectorList {
                    ComposerConnectorsMenu(list: list, onManage: nil,
                        onSwitch: { id, enabled in act("connector", itemID: id.uuidString, value: enabled ? "on" : "off") },
                        onBack: { menu = .attachments }, onDismiss: { menu = nil })
                }
            case .commands?:
                commandsPage
            default:
                ComposerMenuList(
                    entries: ComposerPlusMenu.entries(
                        carriesImages: task?.acceptsImages == true, connectors: composerState?.connectorList,
                        actions: ComposerPlusMenu.Actions(
                            addFiles: acceptsAttachments ? {
                                menu = nil
                                chooseFiles()
                            } : nil,
                            addFolder: nil,
                            openCommands: {
                                commandSearch = ""
                                menu = .commands
                                Task { await readCommands() }
                            },
                            openConnectors: composerState?.connectorList == nil ? nil : { menu = .connectors })),
                    onDismiss: { menu = nil })
            }
        }
    }

    /// "+" → "Slash commands": the search and the list, with the way back.
    private var commandsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComposerMenuBackHeader(title: L10n.string("Slash commands")) { menu = .attachments }
            TextField(L10n.string("Search commands"), text: $commandSearch)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let command = ComposerCommands.matching(listedCommands, query: commandSearch).first { chooseCommand(command) }
                }
                .padding(.horizontal, 3)
            ComposerCommandPicker(commands: listedCommands, query: commandSearch, isLoading: commands == nil,
                                  onSelect: chooseCommand)
        }
        .padding(5)
        .frame(width: 340)
        .onExitCommand { menu = nil }
    }

    /// The host's commands as the local list draws them.
    private var listedCommands: [ProviderComposerCommand] {
        (commands ?? []).map { command in
            ProviderComposerCommand(name: command.name, description: command.description ?? "",
                                    argumentHint: command.argumentHint ?? "", builtin: true, title: command.title,
                                    group: command.group)
        }
    }

    private var editorCommands: ComposerEditorCommands? {
        guard !(commands ?? []).isEmpty else { return nil }
        return ComposerEditorCommands(commands: listedCommands, choose: chooseCommand)
    }

    private func readCommands() async {
        guard let read = await model.composerCommands(taskID) else { return }
        commands = read
    }

    /// As the local list does: a command that runs at once takes the typed `/name` out of the draft and runs (the Codex
    /// app's); any other is typed into the draft, and runs when sent.
    private func chooseCommand(_ command: ProviderComposerCommand) {
        menu = nil
        guard let remote = commands?.first(where: { $0.name == command.name }) else { return }
        guard remote.runs == true else {
            ComposerFieldEditor.insert(command, into: draft, isFocused: $isFocused)
            return
        }
        if ComposerCommands.query(in: draft.text) != nil { draft.text = "" }
        isFocused = true
        run(remote.name, arguments: nil)
    }

    private func run(_ name: String, arguments: String?) {
        isSending = true
        Task {
            defer { isSending = false }
            _ = await model.runComposerCommand(taskID, name: name, arguments: arguments)
        }
    }

    /// The draft's first word names one of the host's commands: its name and the words after it.
    private func typedCommand(_ text: String) -> (name: String, arguments: String?)? {
        guard text.hasPrefix("/"), let commands else { return nil }
        let first = text.prefix { !$0.isWhitespace }
        let name = String(first.dropFirst())
        guard commands.contains(where: { $0.name == name }) else { return nil }
        let rest = text.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, rest.isEmpty ? nil : rest)
    }

    // MARK: - While a turn runs

    /// The local composer's queue-or-steer menu: each row says where the message goes and its key.
    private var followUpButton: some View {
        Button { showsFollowUpMenu = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "text.append")
                if !queued.isEmpty {
                    Text("\(queued.count)").font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(ParityTheme.subtleFill, in: Circle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel(L10n.string("Queue or steer"))
        .accessibilityHint(policy.returnHint(preferred: preferred))
        .help(policy.runningPlaceholder(preferred: preferred))
        .popover(isPresented: $showsFollowUpMenu) {
            VStack(alignment: .leading, spacing: 4) {
                if model.composerExtensions, !queued.isEmpty {
                    Button(composerState?.queuePaused == true ? L10n.string("Resume") : L10n.string("Pause")) {
                        showsFollowUpMenu = false
                        act(composerState?.queuePaused == true ? "resume" : "pause")
                    }.buttonStyle(.borderless)
                }
                Button {
                    showsFollowUpMenu = false
                    send(.queue)
                } label: {
                    ComposerFollowUpMenuRow(title: FollowUpPolicy.afterTurnPhrase, systemImage: "text.append",
                                            isAlternate: returnMode != .queue)
                }
                .buttonStyle(.borderless)
                .parityPointer()
                if let steer = policy.steerPhrase {
                    Button {
                        showsFollowUpMenu = false
                        send(.steer)
                    } label: {
                        ComposerFollowUpMenuRow(title: steer, systemImage: "arrow.turn.up.right", isAlternate: returnMode != .steer)
                    }
                    .buttonStyle(.borderless)
                    .parityPointer()
                }
            }
            .padding(8)
            .frame(minWidth: 150, alignment: .leading)
        }
    }

    private var stopButton: some View {
        Button { model.send(.stopTurn(taskID: taskID)) } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.red, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(!model.isConnected)
        .accessibilityLabel(L10n.string("Stop"))
        .help(L10n.string("Stop"))
    }

    /// One queued message, as the local composer's row: what it says, where it goes, and the actions the
    /// host offers for it (§15.15).
    private func queueRow(_ item: RemoteItem) -> some View {
        let failed = item.queueFailed == true
        let offered = item.options ?? []
        let extended = model.composerExtensions
        let index = queued.firstIndex(where: { $0.id == item.id }) ?? 0
        let send = offered.contains("sendNow") ? policy.sendLabel.map {
            ComposerQueueChip.Send(label: $0, icon: "arrow.turn.up.right", help: policy.sendHelp ?? $0)
        } : nil
        let chip = ComposerQueueChip(icon: failed ? "exclamationmark.circle" : "clock",
            status: failed ? L10n.string("Failed") : policy.pendingHelp, help: policy.pendingHelp,
            send: send, stopAndSend: offered.contains("stopAndSend") ? policy.stopAndSendLabel : nil,
            removeLabel: policy.removeLabel, canMoveUp: extended && offered.contains("moveUp") && index > 0,
            canMoveDown: extended && offered.contains("moveDown") && index + 1 < queued.count)
        return ComposerQueueRow(title: item.text ?? "", failed: failed, fromTask: false, chip: chip,
            moveUp: { act("moveUp", itemID: item.id) }, moveDown: { act("moveDown", itemID: item.id) },
            retry: extended ? { act("retry", itemID: item.id) } : nil,
            sendNow: offered.contains("sendNow") ? { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .sendNow)) } : nil,
            stopAndSend: offered.contains("stopAndSend") ? { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .stopAndSend)) } : nil,
            edit: extended && offered.contains("edit") ? { beginQueueEdit(item) } : nil,
            remove: offered.contains("remove") ? { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .remove)) } : nil)
        .disabled(!model.isConnected)
    }

    private func beginQueueEdit(_ item: RemoteItem) {
        guard queuedEdit == nil else { return }
        queuedEdit = (item.id, draft.text, draft.attachments, draft.hostMentions)
        draft.text = item.text ?? ""
        draft.attachments = []
        draft.hostMentions = []
        isFocused = true
    }

    private func cancelQueueEdit() {
        guard let edit = queuedEdit else { return }
        draft.text = edit.text
        draft.attachments = edit.attachments
        draft.hostMentions = edit.mentions
        queuedEdit = nil
    }

    private func act(_ action: String, itemID: String? = nil, value: String? = nil) {
        Task {
            if let state = await model.actOnComposer(taskID, action: action, itemID: itemID, value: value) {
                model.composerStates[taskID] = state
            }
        }
    }

    private func takeSuggestion() -> Bool {
        guard !isRunning, draft.text.isEmpty, let suggestion = draft.nextMessageSuggestion,
              !suggestion.isEmpty else { return false }
        draft.text = suggestion
        return true
    }

    // MARK: - Attachments

    private func receive(_ input: ComposerExternalInput) {
        switch input {
        case let .files(urls):
            for url in urls { RemoteAttachments.add(url, to: draft) }
        case let .image(data, type):
            guard let png = ComposerExternalInput.pngData(data, type: type), let url = RemoteAttachments.write(png) else { return }
            draft.attachments.append(.localImage(url))
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { RemoteAttachments.add(url, to: draft) }
    }

    // MARK: - Sending

    /// Sends the draft; while a turn runs, queued or steered as `mode` says.
    private func send(_ mode: FollowUpMode?) {
        guard canSend else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let queuedEdit {
            guard !text.isEmpty, draft.attachments.isEmpty else { return }
            isSending = true
            Task {
                defer { isSending = false }
                guard let state = await model.actOnComposer(taskID, action: "edit", itemID: queuedEdit.id, value: RemoteComposerMentionIndex.message(text, mentions: draft.hostMentions)) else {
                    draft.notice = model.commandError
                    return
                }
                model.composerStates[taskID] = state
                cancelQueueEdit()
            }
            return
        }
        if let editing { return sendEdit(editing, text: text) }
        // A typed command runs as the host's composer runs it once sent.
        if draft.attachments.isEmpty, draft.hostMentions.isEmpty, let command = typedCommand(text) {
            isSending = true
            Task {
                defer { isSending = false }
                guard await model.runComposerCommand(taskID, name: command.name, arguments: command.arguments) else {
                    draft.notice = model.commandError
                    return
                }
                if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
                draft.notice = nil
            }
            return
        }
        let attachments = draft.attachments
        let hostMentions = draft.hostMentions
        let message = RemoteComposerMentionIndex.message(text, mentions: hostMentions)
        let followUp = mode.flatMap { RemoteFollowUpMode(rawValue: $0.rawValue) }
        isSending = true
        Task {
            defer { isSending = false }
            guard let parts = await RemoteAttachments.prepare(attachments, for: model, acceptsImages: task?.acceptsImages == true,
                                                             acceptsFiles: task?.acceptsFiles == true) else { return }
            let sent = await model.perform(.sendMessage(taskID: taskID, text: message, images: parts.images, followUp: followUp,
                                                        files: parts.files))
            guard sent else {
                draft.notice = model.commandError
                return
            }
            // What was sent leaves the draft; anything typed meanwhile stays.
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
            draft.attachments.removeAll { attachments.contains($0) }
            draft.hostMentions.removeAll { hostMentions.contains($0) }
            draft.notice = nil
            RemoteAttachments.discard(attachments)
        }
    }

    /// The edited message, as the host's composer sends an edit; it leaves the draft once the host took it, as the
    /// local composer's edit does.
    private func sendEdit(_ edit: RemoteMessageEdit, text: String) {
        let mentions = draft.hostMentions
        let message = RemoteComposerMentionIndex.message(text, mentions: mentions)
        guard !message.isEmpty else { return }
        isSending = true
        Task {
            defer { isSending = false }
            guard await model.editMessage(taskID, turnID: edit.turnID, text: message) else {
                draft.notice = model.commandError
                return
            }
            if editing == edit { editing = nil }
            draft.hostMentions.removeAll { mentions.contains($0) }
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
            draft.notice = nil
        }
    }
}

/// A host turn's message put back in the composer to edit (its Edit message, §15.23), with what the composer held
/// before, which comes back when the edit is cancelled.
struct RemoteMessageEdit: Equatable {
    let turnID: String
    let previousText: String
    let previousAttachments: [CodexUserInput]
}

/// Pictures and files on their way to a host: a picture the harness takes as one goes as an image (§15.14),
/// anything else up in parts as a file (§15.20). A pasted picture waits in a private temporary folder until
/// it is sent or removed.
@MainActor
enum RemoteAttachments {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg"]

    static func add(_ url: URL, to draft: TaskComposerDraft) {
        let input: CodexUserInput = imageTypes.contains(url.pathExtension.lowercased())
            ? .localImage(url) : .mention(name: url.lastPathComponent, path: url)
        if !draft.attachments.contains(input) { draft.attachments.append(input) }
    }

    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "yardlet-remote-attachments", directoryHint: .isDirectory)
    }

    static func write(_ png: Data) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: "Image \(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url, options: [.atomic])) != nil else { return nil }
        return url
    }

    /// Pasted pictures of a sent message are let go.
    static func discard(_ attachments: [CodexUserInput]) {
        for case let .localImage(url, _) in attachments where url.path.hasPrefix(folder.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The images and the uploaded files' IDs a message carries; nil when one could not go (the model
    /// says why).
    @MainActor
    static func prepare(_ attachments: [CodexUserInput], for model: RemoteHostModel, acceptsImages: Bool,
                        acceptsFiles: Bool) async -> (images: [RemoteImage], files: [String])? {
        var images: [RemoteImage] = []
        var files: [String] = []
        for attachment in attachments {
            let url: URL
            switch attachment {
            case let .localImage(path, _), let .image(path, _), let .mention(_, path): url = path
            default: continue
            }
            if acceptsImages, images.count < RemoteProtocol.maxImages, imageTypes.contains(url.pathExtension.lowercased()),
               let data = try? Data(contentsOf: url), data.count <= RemoteProtocol.maxImageBytes {
                let type = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                images.append(RemoteImage(type: type, data: data))
                continue
            }
            guard acceptsFiles else {
                model.commandError = L10n.string("This task takes no files.")
                return nil
            }
            guard files.count < RemoteProtocol.maxFiles else { break }
            let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard let id = await model.upload(url, mediaType: mediaType) else { return nil }
            files.append(id)
        }
        return (images, files)
    }
}
