import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YardletRemote

/// The composer of a host's task: the app's own editor (`ComposerEditor`) with what the host takes from
/// another device (docs/REMOTE_PROTOCOL.md §15.14, §15.15, §15.20): words, pictures and files, sent as a
/// steer or a queued message while a turn runs, and Stop. The host's own composer keeps what only it
/// offers (the model and permission menus, slash commands, connectors), so those are not here; while the
/// host cannot be reached, sending waits and the words stay.
struct RemoteComposer: View {
    let model: RemoteHostModel
    let taskID: String
    @Bindable var draft: TaskComposerDraft
    @FocusState private var isFocused: Bool
    @State private var isSending = false

    private var task: RemoteTask? { model.task(taskID) }
    private var isRunning: Bool { task?.running == true }

    private var hasMessage: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }

    private var canSend: Bool { model.isConnected && !isSending && hasMessage }

    /// What Return does while a turn runs: the host's setting (§15.15).
    private var returnSteers: Bool { (model.followUp ?? .queue) == .steer && task?.steers == true }

    var body: some View {
        ComposerEditor(
            draft: draft, placeholder: placeholder,
            accessibilityHint: L10n.string("Press Return to send"), metrics: .task(),
            input: nil, onExternalInput: acceptsAttachments ? { receive($0) } : nil, mentionRoots: [], commands: nil,
            isCommandMenuOpen: false, isMenuOpen: false, isFocused: $isFocused,
            onSubmit: { send(followUp: nil) },
            onAlternateSubmit: isRunning && task?.steers == true ? { send(followUp: returnSteers ? .queue : .steer) } : nil
        ) {
            EmptyView()
        } chips: {
            EmptyView()
        } footer: {
            HStack(spacing: 6) {
                ParityIconButton(systemName: "plus", help: L10n.string("Add files or photos"), action: chooseFiles)
                    .accessibilityLabel(L10n.string("Add files or photos"))
                    .disabled(!acceptsAttachments)
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                if isRunning {
                    ParityIconButton(systemName: "stop.fill", help: L10n.string("Stop")) {
                        model.send(.stopTurn(taskID: taskID))
                    }
                    .accessibilityLabel(L10n.string("Stop"))
                    .disabled(!model.isConnected)
                }
                ParityIconButton(systemName: "arrow.up", help: L10n.string("Send"), isProminent: true) { send(followUp: nil) }
                    .accessibilityLabel(L10n.string("Send message"))
                    .disabled(!canSend)
            }
            .padding(.leading, 10).padding(.trailing, 9).padding(.bottom, 9)
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    private var placeholder: String {
        guard model.isConnected else { return L10n.format("Waiting for %@…", model.name) }
        if isRunning, task?.steers == true {
            return returnSteers ? L10n.string("Send into this turn, or ⌘Return to queue it")
                                : L10n.string("Queue for when this turn ends, or ⌘Return to send it now")
        }
        return L10n.format("Message %@ on %@", task?.harnessName ?? L10n.string("the agent"), model.name)
    }

    private var acceptsAttachments: Bool { task?.acceptsImages == true || task?.acceptsFiles == true }

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

    private func send(followUp: RemoteFollowUpMode?) {
        guard canSend else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draft.attachments
        isSending = true
        Task {
            defer { isSending = false }
            guard let parts = await RemoteAttachments.prepare(attachments, for: model, acceptsImages: task?.acceptsImages == true,
                                                             acceptsFiles: task?.acceptsFiles == true) else { return }
            let sent = await model.perform(.sendMessage(taskID: taskID, text: text, images: parts.images, followUp: followUp,
                                                        files: parts.files))
            guard sent else { return }
            // What was sent leaves the draft; anything typed meanwhile stays.
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
            draft.attachments.removeAll { attachments.contains($0) }
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
