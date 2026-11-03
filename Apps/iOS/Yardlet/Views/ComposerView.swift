import PhotosUI
import SwiftUI
import UIKit
import YardletRemote

/// The message box under a conversation: a message or photos to the task, sent into a running turn or queued after
/// it (§15.14, §15.15), Stop while it runs, the queue's own actions, and the task's model and permission mode
/// (§15.23). What is typed stays as the task's draft until it is sent.
struct ComposerView: View {
    let session: HostSession
    let taskID: String
    let conversation: ConversationState
    let openSettings: () -> Void
    @State private var draft = ""
    @State private var images: [PickedImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var followUp: RemoteFollowUpMode?
    @State private var isSending = false

    private var task: RemoteTask? { session.task(taskID) }
    private var isRunning: Bool { task?.running == true }
    private var canSend: Bool {
        session.isConnected && !isSending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }
    private var draftKey: String { "draft.\(session.id).\(taskID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !conversation.queued.isEmpty { queue }
            if session.taskControls, let settings = session.taskSettings[taskID], !settings.isEmpty {
                settingsRow(settings)
            }
            if !images.isEmpty { imageRow }
            HStack(alignment: .bottom, spacing: 8) {
                if task?.acceptsImages == true {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: RemoteProtocol.maxImages - images.count,
                                 matching: .images) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                    .accessibilityLabel("Add Photos")
                    .disabled(images.count >= RemoteProtocol.maxImages)
                }
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
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRunning && draft.isEmpty && images.isEmpty {
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

    private var imageRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
                  let image = PickedImage(data: data) else { continue }
            images.append(image)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = isRunning ? (followUp ?? session.followUp) : nil
        let attached = images.map { RemoteImage(type: "image/jpeg", data: $0.jpeg) }
        isSending = true
        Task {
            let sent = await session.perform(.sendMessage(taskID: taskID, text: text, images: attached, followUp: mode))
            if sent {
                draft = ""
                images = []
            }
            isSending = false
        }
    }
}

/// A photo to send: a JPEG within the Mac's size limit (§15.14), and a small preview.
struct PickedImage: Identifiable {
    let id = UUID()
    let jpeg: Data
    let preview: UIImage

    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = Self.scaled(image, longestSide: 2048)
        var quality: CGFloat = 0.8
        var jpeg = scaled.jpegData(compressionQuality: quality)
        while let current = jpeg, current.count > RemoteProtocol.maxImageBytes, quality > 0.3 {
            quality -= 0.15
            jpeg = scaled.jpegData(compressionQuality: quality)
        }
        guard let jpeg, jpeg.count <= RemoteProtocol.maxImageBytes else { return nil }
        self.jpeg = jpeg
        preview = Self.scaled(image, longestSide: 200)
    }

    private static func scaled(_ image: UIImage, longestSide: CGFloat) -> UIImage {
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
