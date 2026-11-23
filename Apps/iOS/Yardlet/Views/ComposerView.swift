import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YardletRemote

/// The message box under a conversation: a message with photos (from the library or the camera) or files to the
/// task, sent into a running turn or queued after it (§15.14, §15.15, §15.20), Stop while it runs, the queue's own
/// actions, and the task's model and permission mode, slash commands and Edit Message (§15.23). What is typed stays as
/// the task's draft until it is sent.
struct ComposerView: View {
    let session: HostSession
    let taskID: String
    let conversation: ConversationState
    /// A turn's message being edited: its words are in the field, and sending them goes as the turn's edit (§15.23).
    @Binding var editing: MessageEdit?
    let openSettings: () -> Void
    /// Opens a task a command started: a new chat, a fork.
    let openTask: (String) -> Void
    @State private var draft = ""
    /// What the field held before an edit began, which comes back once it ends, as on the Mac.
    @State private var draftBeforeEdit: String?
    /// The slash commands the Mac lists for the task (§15.23); nil until read.
    @State private var commands: [RemoteComposerCommand]?
    @FocusState private var isFieldFocused: Bool
    @State private var images: [PickedImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var files: [AttachedFile] = []
    @State private var followUp: RemoteFollowUpMode?
    @State private var isSending = false
    @State private var isPickingPhotos = false
    @State private var isTakingPhoto = false
    @State private var isPickingFiles = false
    /// A queued message whose words are being changed (§15.33 `edit`), and its new words.
    @State private var editingQueued: RemoteItem?
    @State private var queuedText = ""

    private var task: RemoteTask? { session.task(taskID) }
    private var isRunning: Bool { task?.running == true }
    private var canSend: Bool {
        if editing != nil { return session.isConnected && !isSending && !trimmedDraft.isEmpty }
        return session.isConnected && !isSending && !files.contains { $0.state == .uploading }
            && (!trimmedDraft.isEmpty || !images.isEmpty || !files.isEmpty)
    }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The Mac takes slash commands from the phone now (§15.23).
    private var controlsUp: Bool { session.taskControls && session.isConnected }
    /// The commands a typed `/` names, while it is one word; none while a message is edited.
    private var slashMatches: [RemoteComposerCommand] {
        guard editing == nil, controlsUp, let query = SlashCommands.query(draft), let commands else { return [] }
        return SlashCommands.matching(commands, query: query)
    }
    /// "+" lists the slash commands too, where the Mac lists any.
    private var offersCommands: Bool { controlsUp && commands?.isEmpty == false }
    private var acceptsImages: Bool { task?.acceptsImages == true }
    private var acceptsFiles: Bool { task?.acceptsFiles == true }
    private var draftKey: String { "draft.\(session.id).\(taskID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !conversation.queued.isEmpty { queue }
            if session.taskControls, let settings = session.taskSettings[taskID], !settings.isEmpty {
                settingsRow(settings)
            }
            // An edit carries only words; the message's pictures stay with it on the Mac, and the draft's wait (§15.23).
            if editing == nil && (!images.isEmpty || !files.isEmpty) { attachmentRow }
            if editing != nil {
                EditingBar { editing = nil }
            } else if !slashMatches.isEmpty {
                SlashList(commands: slashMatches, choose: choose)
                    .disabled(isSending)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if editing == nil && (acceptsImages || acceptsFiles || offersCommands) { attachMenu }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(isRunning ? "Message to the running task" : "Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($isFieldFocused)
                        .padding(.leading, 14)
                        .padding(.vertical, 9)
                    if editing == nil && isRunning && task?.steers == true && !draft.isEmpty { followUpMenu }
                    actionButton
                }
                .background(YardletPalette.surfaceContainer,
                            in: RoundedRectangle(cornerRadius: YardletMetrics.radiusComposer, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YardletMetrics.radiusComposer, style: .continuous)
                        .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(YardletPalette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5)
        }
        .onAppear { draft = UserDefaults.standard.string(forKey: draftKey) ?? "" }
        .onChange(of: draft) { _, text in
            // The words being edited are the turn's, not the draft, which stays as it was.
            guard editing == nil else { return }
            if text.isEmpty { UserDefaults.standard.removeObject(forKey: draftKey) } else {
                UserDefaults.standard.set(text, forKey: draftKey)
            }
        }
        .onChange(of: editing) { _, edit in
            if let edit {
                if draftBeforeEdit == nil { draftBeforeEdit = draft }
                draft = edit.text
                isFieldFocused = true
            } else if let before = draftBeforeEdit {
                draftBeforeEdit = nil
                draft = before
            }
        }
        // §15.23: the slash commands, read when the conversation opens or connects (they decide whether "+" lists
        // them) and each time a typed `/` opens the list, as the Mac's list reads what it shows.
        .task(id: controlsUp) {
            if controlsUp { commands = await session.composerCommands(taskID) ?? commands }
        }
        .onChange(of: SlashCommands.query(draft) != nil) { _, typing in
            guard typing, controlsUp else { return }
            Task { commands = await session.composerCommands(taskID) ?? commands }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await addImages(items) }
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $pickerItems,
                      maxSelectionCount: max(1, RemoteProtocol.maxImages - images.count), matching: .images)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { attach(urls) }
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in
                Task {
                    if let picked = await PickedImage.make(from: image), images.count < RemoteProtocol.maxImages {
                        images.append(picked)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Photos, the camera and files, as the task's harness takes them.
    private var attachMenu: some View {
        Menu {
            if acceptsImages {
                Button {
                    isPickingPhotos = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                .disabled(images.count >= RemoteProtocol.maxImages)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        isTakingPhoto = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .disabled(images.count >= RemoteProtocol.maxImages)
                }
            }
            if acceptsFiles {
                Button {
                    isPickingFiles = true
                } label: {
                    Label("Choose Files", systemImage: "doc")
                }
                .disabled(files.count >= RemoteProtocol.maxFiles)
            }
            if offersCommands, let commands {
                Menu {
                    ForEach(Array(SlashCommands.groups(commands).enumerated()), id: \.offset) { _, group in
                        if let heading = group.heading {
                            Section(heading) { commandButtons(group.commands) }
                        } else {
                            Section { commandButtons(group.commands) }
                        }
                    }
                } label: {
                    Label("Slash Commands", systemImage: "slash.circle")
                }
                .disabled(isSending)
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurface)
                .frame(width: 36, height: 36)
                .background(YardletPalette.surfaceContainer, in: Circle())
                .overlay(Circle().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
        }
        .accessibilityLabel(acceptsImages || acceptsFiles ? Text("Attach") : Text("Slash Commands"))
    }

    private func commandButtons(_ commands: [RemoteComposerCommand]) -> some View {
        ForEach(commands, id: \.name) { command in
            Button {
                choose(command)
            } label: {
                Text(command.title ?? "/\(command.name)")
                if let description = command.description, !description.isEmpty { Text(description) }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if editing == nil && isRunning && draft.isEmpty && images.isEmpty && files.isEmpty {
            Button {
                session.send(.stopTurn(taskID: taskID))
            } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 30))
            }
            .accessibilityLabel("Stop")
            .padding(3)
            .disabled(!session.isConnected)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .accessibilityLabel("Send")
            .padding(3)
            .disabled(!canSend)
        }
    }

    /// Into the running turn now, or after it ends: the Mac's own setting first (§15.15).
    private var followUpMenu: some View {
        let mode = followUp ?? session.followUp ?? .queue
        return Menu {
            Picker("When to Send", selection: Binding(get: { mode }, set: { followUp = $0 })) {
                Text("Send Now (Steer)").tag(RemoteFollowUpMode.steer)
                Text("After This Turn (Queue)").tag(RemoteFollowUpMode.queue)
            }
        } label: {
            Text(mode == .steer ? "Steer" : "Queue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(YardletPalette.surfaceContainerHigh, in: Capsule())
        }
        .padding(.bottom, 9)
    }

    /// The messages queued behind the running turn, with the actions the Mac offers for each (§15.15, §15.33), and the
    /// Mac's line when the person paused the queue by stopping a turn.
    private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.composerStates[taskID]?.queuePaused == true {
                HStack(alignment: .firstTextBaseline) {
                    Label("Queue paused because you interrupted", systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Resume") { Task { await session.composerAction(taskID, action: "resume") } }
                        .font(.footnote.weight(.semibold))
                        .disabled(!session.isConnected)
                }
                .padding(.horizontal, 4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(conversation.queued, id: \.id) { item in
                        Menu {
                            queueActions(item)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.queueFailed == true ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(item.queueFailed == true ? YardletPalette.error : YardletPalette.onSurfaceVariant)
                                Text(item.text ?? "").lineLimit(1)
                            }
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: 240)
                            .background(YardletPalette.surfaceContainer, in: Capsule())
                            .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5))
                        }
                        .foregroundStyle(YardletPalette.onSurface)
                        .accessibilityHint(Text("Queued message actions"))
                    }
                }
            }
        }
        .alert("Edit Message", isPresented: Binding(get: { editingQueued != nil }, set: { if !$0 { editingQueued = nil } }),
               presenting: editingQueued) { item in
            TextField("Message", text: $queuedText)
            Button("Save") {
                let text = queuedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                Task { await session.composerAction(taskID, action: "edit", itemID: item.id, value: text) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The Mac's queue chip in its order: Retry (a message that failed to send) or Send Now, Stop and Send, Edit
    /// Message, Move Up, Move Down, Remove. Retry, the moves and editing go through `composerAction` (§15.33).
    @ViewBuilder
    private func queueActions(_ item: RemoteItem) -> some View {
        let options = Set(item.options ?? [])
        if options.contains("retry") {
            Button {
                Task { await session.composerAction(taskID, action: "retry", itemID: item.id) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        } else if options.contains(RemoteQueuedAction.sendNow.rawValue) {
            Button {
                session.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .sendNow))
            } label: {
                Label("Send Now", systemImage: "arrow.up")
            }
        }
        if options.contains(RemoteQueuedAction.stopAndSend.rawValue) {
            Button {
                session.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .stopAndSend))
            } label: {
                Label("Stop and Send", systemImage: "stop")
            }
        }
        if options.contains("edit") {
            Button {
                queuedText = item.text ?? ""
                editingQueued = item
            } label: {
                Label("Edit Message", systemImage: "pencil")
            }
        }
        if options.contains("moveUp") {
            Button {
                Task { await session.composerAction(taskID, action: "moveUp", itemID: item.id) }
            } label: {
                Label("Move Up", systemImage: "arrow.up.to.line")
            }
        }
        if options.contains("moveDown") {
            Button {
                Task { await session.composerAction(taskID, action: "moveDown", itemID: item.id) }
            } label: {
                Label("Move Down", systemImage: "arrow.down.to.line")
            }
        }
        if options.contains(RemoteQueuedAction.remove.rawValue) {
            Button(role: .destructive) {
                session.send(.actOnQueued(taskID: taskID, itemID: item.id, action: .remove))
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func settingsRow(_ settings: [RemoteSetting]) -> some View {
        HStack(spacing: 10) {
            // Codex's Plan indicator, while Plan mode is on: tapping it turns Plan mode off, as on the Mac (§15.23).
            if let plan = settings.first(where: { $0.role == "plan" }) {
                Button {
                    run("plan-mode")
                } label: {
                    HStack(spacing: 4) {
                        Text(plan.name).lineLimit(1)
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(YardletPalette.onSurface)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!controlsUp || isSending)
                .accessibilityLabel("Turn Off Plan Mode")
            }
            Button(action: openSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text(TaskSettingsView.summary(settings)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.footnote)
                .foregroundStyle(settings.contains { $0.elevated == true } ? YardletPalette.Status.limit : YardletPalette.onSurfaceVariant)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    Button {
                        if file.state == .failed { retry(file.id) }
                    } label: {
                        HStack(spacing: 6) {
                            switch file.state {
                            case .uploading: ProgressView().controlSize(.mini)
                            case .ready: Image(systemName: "doc").foregroundStyle(.secondary)
                            case .failed: Image(systemName: "arrow.clockwise").foregroundStyle(.red)
                            }
                            Text(file.name).lineLimit(1)
                            Button {
                                remove(file.id)
                            } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Remove File")
                        }
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .frame(maxWidth: 220)
                        .background(YardletPalette.surfaceContainer, in: Capsule())
                        .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(file.state == .failed ? Text("Not sent. Tap to try again.") : Text(verbatim: ""))
                }
                ForEach(images) { image in
                    Image(uiImage: image.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                images.removeAll { $0.id == image.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(3)
                            .accessibilityLabel("Remove Photo")
                        }
                }
            }
        }
    }

    private func addImages(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard images.count < RemoteProtocol.maxImages,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let image = await PickedImage.make(from: data), images.count < RemoteProtocol.maxImages else { continue }
            images.append(image)
        }
    }

    /// Sends the message; a draft whose first word names one of the Mac's slash commands runs it as the Mac's composer
    /// does once sent, and an edit goes as the turn's Edit Message (§15.23).
    private func send() {
        let text = trimmedDraft
        if let editing { return sendEdit(editing, text: text) }
        let mode = isRunning ? (followUp ?? session.followUp) : nil
        let attached = images.map { RemoteImage(type: "image/jpeg", data: $0.jpeg) }
        let uploads = files.compactMap { $0.state == .ready ? $0.uploadID : nil }
        isSending = true
        Task {
            if controlsUp, attached.isEmpty, uploads.isEmpty, text.hasPrefix("/") {
                if commands == nil { commands = await session.composerCommands(taskID) }
                if let (command, arguments) = SlashCommands.typed(text, in: commands ?? []) {
                    let run = await session.runComposerCommand(taskID, name: command.name, arguments: arguments)
                    if run.ok, trimmedDraft == text { draft = "" }
                    if let started = run.started { openTask(started) }
                    isSending = false
                    return
                }
            }
            let sent = await session.perform(.sendMessage(taskID: taskID, text: text, images: attached, followUp: mode,
                                                          files: uploads))
            if sent {
                draft = ""
                images = []
                files = []
            }
            isSending = false
        }
    }

    /// Edit Message and Send: the turn is replaced by the edited message. A refusal keeps the edit, so no words are lost.
    private func sendEdit(_ edit: MessageEdit, text: String) {
        guard !text.isEmpty else { return }
        isSending = true
        Task {
            if await session.editMessage(taskID, turnID: edit.turnID, text: text), editing == edit { editing = nil }
            isSending = false
        }
    }

    /// As the Mac's list: a command that runs at once (the Codex app's) takes a typed `/name` out of the draft and runs;
    /// any other is typed into the draft as `/name `, and runs when sent.
    private func choose(_ command: RemoteComposerCommand) {
        let typing = SlashCommands.query(draft) != nil
        guard command.runs == true else {
            draft = "/\(command.name) " + (typing ? "" : String(draft.drop(while: \.isWhitespace)))
            isFieldFocused = true
            return
        }
        if typing { draft = "" }
        run(command.name)
    }

    private func run(_ command: String) {
        guard !isSending else { return }
        isSending = true
        Task {
            let run = await session.runComposerCommand(taskID, name: command)
            if let started = run.started { openTask(started) }
            isSending = false
        }
    }

    /// Chosen files go up as soon as they are chosen (§15.20), as many as a message names; the message then names them.
    private func attach(_ urls: [URL]) {
        for url in urls.prefix(RemoteProtocol.maxFiles - files.count) {
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append(AttachedFile(url: url, name: url.lastPathComponent, mediaType: type))
        }
        uploadNext()
    }

    private func retry(_ id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].state = .uploading
        uploadNext()
    }

    /// Sends the next file waiting, one at a time: the Mac holds only a few unfinished uploads from a phone and makes
    /// room for another by dropping the one that went longest without a part, which could be one still going up.
    private func uploadNext() {
        guard !files.contains(where: { $0.upload != nil }),
              let index = files.firstIndex(where: { $0.state == .uploading }) else { return }
        let file = files[index]
        files[index].upload = Task {
            let uploadID = await session.upload(file.url, mediaType: file.mediaType)
            guard !Task.isCancelled, let index = files.firstIndex(where: { $0.id == file.id }) else { return }
            files[index].uploadID = uploadID
            files[index].state = uploadID == nil ? .failed : .ready
            files[index].upload = nil
            uploadNext()
        }
    }

    /// Takes a file off the message, stopping its upload between parts.
    private func remove(_ id: UUID) {
        files.first { $0.id == id }?.upload?.cancel()
        files.removeAll { $0.id == id }
        uploadNext()
    }
}

/// A file chosen for the next message, sent up in parts before it (§15.20).
struct AttachedFile: Identifiable {
    enum State { case uploading, ready, failed }

    let id = UUID()
    let url: URL
    let name: String
    let mediaType: String
    var uploadID: String?
    var state = State.uploading
    /// The upload under way, cancelled when the file is taken off the message; nil while the file waits its turn.
    var upload: Task<Void, Never>?
}

/// The camera, for a photo to send.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A photo to send: a JPEG within the Mac's size limit (§15.14), and a small preview. Decoding, scaling and
/// compressing a photo takes a while, so it is made off the main actor; a photo from the camera comes as the image the
/// camera took, not encoded and read again.
struct PickedImage: Identifiable, Sendable {
    let id = UUID()
    let jpeg: Data
    let preview: UIImage

    @concurrent
    static func make(from data: Data) async -> PickedImage? {
        guard let image = UIImage(data: data) else { return nil }
        return encode(image)
    }

    @concurrent
    static func make(from image: UIImage) async -> PickedImage? {
        encode(image)
    }

    private nonisolated static func encode(_ image: UIImage) -> PickedImage? {
        let resized = scaled(image, longestSide: 2048)
        var quality: CGFloat = 0.8
        var jpeg = resized.jpegData(compressionQuality: quality)
        while let current = jpeg, current.count > RemoteProtocol.maxImageBytes, quality > 0.3 {
            quality -= 0.15
            jpeg = resized.jpegData(compressionQuality: quality)
        }
        guard let jpeg, jpeg.count <= RemoteProtocol.maxImageBytes else { return nil }
        return PickedImage(jpeg: jpeg, preview: scaled(image, longestSide: 200))
    }

    private nonisolated static func scaled(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, longestSide / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
