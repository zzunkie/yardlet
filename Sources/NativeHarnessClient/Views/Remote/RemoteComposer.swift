import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YardletRemote

/// The composer of a host's task: the app's own editor (`ComposerEditor`) with what the host takes from
/// another device (docs/REMOTE_PROTOCOL.md §15.14, §15.15, §15.20): words, pictures and files, and while a
/// turn runs the local composer's own rules and words for where a message goes (`FollowUpPolicy`), with
/// the host's follow-up setting in place of this Mac's, its queue's rows above the text, and Stop. The
/// host's own composer keeps what only it offers (the model and permission menus, slash commands,
/// connectors), so those are not here; while the host cannot be reached, sending waits and the words stay.
struct RemoteComposer: View {
    let model: RemoteHostModel
    let taskID: String
    @Bindable var draft: TaskComposerDraft
    /// Messages waiting in the task's queue on the host.
    var queued: [RemoteItem] = []
    @FocusState private var isFocused: Bool
    @State private var isSending = false
    @State private var showsFollowUpMenu = false

    private var task: RemoteTask? { model.task(taskID) }
    private var isRunning: Bool { task?.running == true }

    private var hasMessage: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
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

    var body: some View {
        ComposerEditor(
            draft: draft, placeholder: placeholder,
            accessibilityHint: isRunning ? policy.returnHint(preferred: preferred) : L10n.string("Press Return to send"),
            metrics: .task(), input: nil, onExternalInput: acceptsAttachments ? { receive($0) } : nil, mentionRoots: [],
            commands: nil, isCommandMenuOpen: false, isMenuOpen: showsFollowUpMenu, isFocused: $isFocused,
            onSubmit: { send(isRunning ? returnMode : nil) },
            onAlternateSubmit: isRunning && policy.steers ? { send(preferred.other) } : nil
        ) {
            if !queued.isEmpty {
                VStack(spacing: 4) {
                    ForEach(queued, id: \.id) { item in queueRow(item) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
        } chips: {
            EmptyView()
        } footer: {
            HStack(spacing: 7) {
                ParityIconButton(systemName: "plus", help: L10n.string("Add files or photos"), action: chooseFiles)
                    .accessibilityLabel(L10n.string("Add files or photos"))
                    .disabled(!acceptsAttachments)
                Spacer()
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
            .padding(.leading, 10).padding(.trailing, 9).padding(.bottom, 9)
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    private var placeholder: String {
        guard model.isConnected else { return L10n.format("Waiting for %@…", model.name) }
        if isRunning { return policy.runningPlaceholder(preferred: preferred) }
        return L10n.format("Ask %@…", task?.harnessName ?? model.name)
    }

    private var acceptsAttachments: Bool { task?.acceptsImages == true || task?.acceptsFiles == true }

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
                .frame(width: 30, height: 30)
                .background(.red, in: Circle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(!model.isConnected)
        .accessibilityLabel(L10n.string("Interrupt"))
        .help(L10n.string("Interrupt"))
    }

    /// One queued message, as the local composer's row: what it says, where it goes, and the actions the
    /// host offers for it (§15.15).
    private func queueRow(_ item: RemoteItem) -> some View {
        let failed = item.queueFailed == true
        let actions = (item.options ?? []).compactMap(RemoteQueuedAction.init(rawValue:))
        let status = failed ? L10n.string("Failed") : policy.pendingHelp
        return HStack(spacing: 6) {
            Image(systemName: failed ? "exclamationmark.circle" : "clock")
                .frame(width: 14)
            Text(item.text ?? "")
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status)
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: 4) {
                if actions.contains(.sendNow), let label = policy.sendLabel {
                    Button { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .sendNow)) } label: {
                        Label(label, systemImage: "arrow.turn.up.right")
                            .labelStyle(.titleAndIcon)
                            .fontWeight(.medium)
                            .fixedSize()
                    }
                    .buttonStyle(.borderless)
                    .parityPointer()
                    .accessibilityLabel(label)
                    .help(policy.sendHelp ?? label)
                }
                if actions.contains(.remove) {
                    Button { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .remove)) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .parityPointer()
                    .accessibilityLabel(policy.removeLabel)
                    .help(policy.removeLabel)
                }
            }
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(failed ? .red : .secondary)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        .help(status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(L10n.string("Queue")), \(status)")
        .accessibilityValue(item.text ?? "")
        .contextMenu {
            if actions.contains(.stopAndSend), let label = policy.stopAndSendLabel {
                Button(label) { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .stopAndSend)) }
            }
            if actions.contains(.remove) {
                Button(policy.removeLabel) { model.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .remove)) }
            }
        }
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
        let attachments = draft.attachments
        let followUp = mode.flatMap { RemoteFollowUpMode(rawValue: $0.rawValue) }
        isSending = true
        Task {
            defer { isSending = false }
            guard let parts = await RemoteAttachments.prepare(attachments, for: model, acceptsImages: task?.acceptsImages == true,
                                                             acceptsFiles: task?.acceptsFiles == true) else { return }
            let sent = await model.perform(.sendMessage(taskID: taskID, text: text, images: parts.images, followUp: followUp,
                                                        files: parts.files))
            guard sent else {
                draft.notice = model.commandError
                return
            }
            // What was sent leaves the draft; anything typed meanwhile stays.
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
            draft.attachments.removeAll { attachments.contains($0) }
            draft.notice = nil
            RemoteAttachments.discard(attachments)
        }
    }
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
