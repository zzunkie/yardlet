import SwiftUI

/// The exact content used by the native link buttons. Kept independently renderable because
/// ImageRenderer does not render AppKit's link-button backing view.
struct HarnessSubtaskActionLabel: View {
    let title: String
    let systemName: String
    var body: some View {
        Label(L10n.string(title), systemImage: systemName).font(.caption)
    }
}

/// The same task-owned panel chrome as Changes/Files. It has no composer: an agent's log does
/// not establish an independently writable chat or transfer ownership of the agent loop.
struct HarnessSubtaskPane: View {
    let activity: HarnessActivity
    let session: SessionRecord
    let readingPosition: TranscriptReadingPosition
    /// What the child conversation offers; by default nothing beyond reading it.
    var actions = ConversationActions()
    let load: @MainActor @Sendable () async throws -> HarnessSubtaskTranscript
    let onClose: () -> Void
    @State private var snapshot: HarnessSubtaskTranscript?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = UUID()

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(title: activity.title, systemName: "person.2",
                              workspaceURL: session.workspaceURL, onClose: onClose) {
                ParityIconButton(systemName: "arrow.clockwise", help: L10n.string("Refresh")) {
                    Task { await refresh() }
                }
                .disabled(loading)
            }
            if let error {
                WorkSurfaceEmptyState(title: L10n.string("Child conversation unavailable"),
                                      message: error, systemName: "text.bubble")
            } else if let snapshot, !snapshot.entries.isEmpty {
                if snapshot.isTruncated {
                    Text(L10n.string("Showing recent conversation"))
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                TranscriptConversationView(harness: session.harness, entries: snapshot.entries,
                    readingPosition: readingPosition, actions: actions)
                    .environment(\.transcriptWorkspaceURL, session.workspaceURL)
            } else if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkSurfaceEmptyState(title: L10n.string("No child conversation yet"), systemName: "text.bubble")
            }
        }
        .task(id: activity.subtask) { await refresh() }
    }

    private func refresh() async {
        let token = UUID()
        generation = token
        loading = true
        error = nil
        do {
            let value = try await load()
            guard token == generation, !Task.isCancelled else { return }
            snapshot = value
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}
