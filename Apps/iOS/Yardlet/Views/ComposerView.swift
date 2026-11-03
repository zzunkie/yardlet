import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YardletRemote

/// The message box under a conversation: a message with photos (from the library or the camera) or files to the
/// task, sent into a running turn or queued after it (§15.14, §15.15, §15.20), Stop while it runs, the queue's own
/// actions, and the task's model and permission mode (§15.23). What is typed stays as the task's draft until it is
/// sent.
struct ComposerView: View {
    let session: HostSession
    let taskID: String
    let conversation: ConversationState
    let openSettings: () -> Void
    @State private var draft = ""
    @State private var images: [PickedImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var files: [AttachedFile] = []
    @State private var followUp: RemoteFollowUpMode?
    @State private var isSending = false
    @State private var isPickingPhotos = false
    @State private var isTakingPhoto = false
    @State private var isPickingFiles = false

    private var task: RemoteTask? { session.task(taskID) }
    private var isRunning: Bool { task?.running == true }
    private var canSend: Bool {
        session.isConnected && !isSending && !files.contains { $0.state == .uploading }
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty)
    }
    private var acceptsImages: Bool { task?.acceptsImages == true }
    private var acceptsFiles: Bool { task?.acceptsFiles == true }
    private var draftKey: String { "draft.\(session.id).\(taskID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !conversation.queued.isEmpty { queue }
            if session.taskControls, let settings = session.taskSettings[taskID], !settings.isEmpty {
                settingsRow(settings)
            }
            if !images.isEmpty || !files.isEmpty { attachmentRow }
            HStack(alignment: .bottom, spacing: 8) {
                if acceptsImages || acceptsFiles { attachMenu }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(isRunning ? "Message to the running task" : "Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.leading, 14)
                        .padding(.vertical, 9)
                    if isRunning && task?.steers == true && !draft.isEmpty { followUpMenu }
                    actionButton
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .onAppear { draft = UserDefaults.standard.string(forKey: draftKey) ?? "" }
        .onChange(of: draft) { _, text in
            if text.isEmpty { UserDefaults.standard.removeObject(forKey: draftKey) } else {
                UserDefaults.standard.set(text, forKey: draftKey)
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await addImages(items) }
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $pickerItems,
                      maxSelectionCount: max(1, RemoteProtocol.maxImages - images.count), matching: .images)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { for url in urls { attach(url) } }
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
                .disabled(files.count >= 20)
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .accessibilityLabel("Attach")
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRunning && draft.isEmpty && images.isEmpty && files.isEmpty {
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .padding(.bottom, 9)
    }

    private var queue: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conversation.queued, id: \.id) { item in
                    Menu {
                        ForEach(item.options ?? [], id: \.self) { option in
                            if let action = RemoteQueuedAction(rawValue: option) {
                                Button(role: action == .remove ? .destructive : nil) {
                                    session.send(.actOnQueued(taskID: taskID, itemID: item.id, action: action))
                                } label: {
                                    switch action {
                                    case .sendNow: Label("Send Now", systemImage: "arrow.up")
                                    case .stopAndSend: Label("Stop and Send", systemImage: "stop")
                                    case .remove: Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.queueFailed == true ? "exclamationmark.circle" : "clock")
                                .foregroundStyle(item.queueFailed == true ? Color.red : Color.secondary)
                            Text(item.text ?? "").lineLimit(1)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 240)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private func settingsRow(_ settings: [RemoteSetting]) -> some View {
        Button(action: openSettings) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text(TaskSettingsView.summary(settings)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(settings.contains { $0.elevated == true } ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    Button {
                        if file.state == .failed { upload(file.id) }
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
                        .background(Color(.secondarySystemBackground), in: Capsule())
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

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = isRunning ? (followUp ?? session.followUp) : nil
        let attached = images.map { RemoteImage(type: "image/jpeg", data: $0.jpeg) }
        let uploads = files.compactMap { $0.state == .ready ? $0.uploadID : nil }
        isSending = true
        Task {
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

    /// A file goes up as soon as it is chosen (§15.20); the message then names it.
    private func attach(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let file = AttachedFile(url: url, name: url.lastPathComponent, mediaType: type)
        files.append(file)
        upload(file.id)
    }

    private func upload(_ id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].state = .uploading
        let file = files[index]
        files[index].upload = Task {
            let uploadID = await session.upload(file.url, mediaType: file.mediaType)
            guard !Task.isCancelled, let index = files.firstIndex(where: { $0.id == id }) else { return }
            files[index].uploadID = uploadID
            files[index].state = uploadID == nil ? .failed : .ready
        }
    }

    /// Takes a file off the message, stopping its upload between parts.
    private func remove(_ id: UUID) {
        files.first { $0.id == id }?.upload?.cancel()
        files.removeAll { $0.id == id }
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
    /// The upload under way, cancelled when the file is taken off the message.
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
