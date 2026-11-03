import SwiftUI

struct OriginalConversationMenuItem: View {
    let canOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(L10n.string("Open original conversation"), action: onOpen).disabled(!canOpen)
    }
}

@MainActor
struct ConversationRewindActions {
    let beginCodexEdit: (CodexTurnState) -> Void
    let beginClaudeEdit: (String) -> Void
    let cancelEdit: () -> Void
    let loadFilePoints: @MainActor () async throws -> [ClaudeConversationPoint]
    let previewFiles: @MainActor (String) async throws -> FileRewindPreview
    let restoreFiles: @MainActor (FileRewindPreview) async throws -> HarnessFileRewindResult
}

struct ConversationEditBanner: View {
    /// The provider has not taken the edit yet, so it can still be cancelled.
    let canCancel: Bool
    let onCancel: () -> Void
    var body: some View {
        HStack {
            Label(L10n.string("Editing message"), systemImage: "pencil")
            Spacer()
            if canCancel {
                Button(L10n.string("Cancel edit"), action: onCancel).buttonStyle(.plain)
            } else {
                Text(L10n.string("Conversation changed. Send the edited message to continue."))
                    .foregroundStyle(.secondary)
            }
        }.font(.caption).padding(.horizontal, ParityTheme.conversationInset).padding(.vertical, 6)
    }
}

struct ClaudeFileRewindSheet: View {
    let actions: ConversationRewindActions
    @Environment(\.dismiss) private var dismiss
    @State private var points: [ClaudeConversationPoint] = []
    @State private var selectedPointID = ""
    @State private var preview: FileRewindPreview?
    @State private var result: HarnessFileRewindResult?
    @State private var error: String?
    @State private var busy = false
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Restore files")).font(.headline)
            if points.isEmpty {
                Text(error ?? L10n.string("No saved conversation checkpoints are available."))
                    .foregroundStyle(.secondary)
            } else {
                Picker(L10n.string("Conversation checkpoint"), selection: $selectedPointID) {
                    ForEach(points.reversed()) { point in
                        Text(point.text.isEmpty ? L10n.string("Attached context") : String(Self.summary(point.text).prefix(100)))
                            .tag(point.id)
                    }
                }
                .disabled(busy)
                Button(L10n.string("Preview file changes")) { Task { await loadPreview() } }
                    .disabled(busy || selectedPointID.isEmpty)
            }
            if let preview {
                if let result, result.canRewind, result.inFlight != true {
                    Text(L10n.string("Files restored.")).font(.callout)
                }
                ScrollView {
                    FileRewindPreviewContent(result: result ?? preview.result)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                if result == nil, preview.result.canRewind, preview.result.filesChanged != nil {
                    Button(L10n.string("Restore these files"), role: .destructive) { Task { await restore(preview) } }
                        .disabled(busy)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button(L10n.string("Close")) { dismiss() }.disabled(busy) }
        }
        .padding(20).frame(width: 480)
        .onChange(of: selectedPointID) { _, _ in
            generation = UUID(); preview = nil; result = nil; error = nil
        }
        .task {
            do {
                points = try await actions.loadFilePoints()
                selectedPointID = points.last?.id ?? ""
            } catch { self.error = error.localizedDescription }
        }
    }

    /// A checkpoint's message as the conversation reads it: a shell command's summary, or what
    /// another task sent, under its sender, as the composer's queue shows it.
    private static func summary(_ text: String) -> String {
        if let message = TaskMessage.parse(text) {
            return L10n.format("%@: %@", ConversationSentMessage.senderLabel(message), message.body)
        }
        return ClaudeBashMessage.summary(of: text) ?? text
    }

    private func loadPreview() async {
        guard !busy else { return }
        busy = true; error = nil; result = nil
        let request = generation
        defer { busy = false }
        do {
            let value = try await actions.previewFiles(selectedPointID)
            guard request == generation else { return }
            preview = value
        } catch { if request == generation { self.error = error.localizedDescription } }
    }

    private func restore(_ value: FileRewindPreview) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { result = try await actions.restoreFiles(value) }
        catch { self.error = error.localizedDescription; preview = nil }
    }
}

struct FileRewindPreviewContent: View {
    let result: HarnessFileRewindResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = result.error { Text(error).foregroundStyle(.secondary) }
            if let files = result.filesChanged {
                if files.isEmpty { Text(L10n.string("No file changes.")) }
                ForEach(files, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).lineLimit(2) }
            }
            if let insertions = result.insertions, let deletions = result.deletions {
                Text("+\(insertions) / −\(deletions)").font(.caption)
            }
            if let skipped = result.skippedLinks, skipped > 0 {
                Text(L10n.format("Skipped links: %d", skipped)).font(.caption).foregroundStyle(.secondary)
            }
            if result.inFlight == true { Text(L10n.string("File restore is still running.")).foregroundStyle(.secondary) }
        }
    }
}
