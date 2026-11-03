import QuickLook
import SwiftUI
import YardletRemote

/// The local Review surface with host-backed reads. Only the task ID crosses the window boundary;
/// its host folders are requested when the panel opens, never inferred from a sidebar placeholder.
struct RemoteReviewPane: View {
    let model: RemoteHostModel
    let taskID: String
    @Binding var review: DiffReviewPreferences
    var onClose: () -> Void = {}
    @State private var context: RemoteReviewResult?
    @State private var contextOwner: String?
    @State private var contextError: String?
    @State private var preview: URL?
    @Environment(\.openURL) private var openURL

    private var ownerKey: String { model.id + ":" + taskID }
    private var reader: RemoteGitDiffReading { .init(model: model, taskID: taskID) }
    private struct LoadKey: Equatable {
        let hostID: String
        let taskID: String
        let connected: Bool
        let offered: Bool
    }

    var body: some View {
        Group {
            if !model.offersReview {
                WorkSurfaceEmptyState(title: L10n.string("Review"),
                                      message: L10n.string("Update Yardlet on the host to use this panel."))
            } else if contextOwner == ownerKey, let workspace = context?.workspace, !workspace.isEmpty {
                DiffPane(workspaceURL: URL(filePath: workspace),
                         additionalRootURLs: (context?.additionalRoots ?? []).map { URL(filePath: $0) },
                         review: $review, reading: reader, onClose: onClose)
                    .id(model.id + ":" + taskID)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.isFileURL else {
                            openURL(url)
                            return .handled
                        }
                        Task {
                            switch await model.files.copy(taskID: taskID, path: url.path) {
                            case let .success(copy): preview = copy
                            case let .failure(error): model.commandError = RemoteFileOpening.message(error, host: model.name)
                            }
                        }
                        return .handled
                    })
                    .quickLookPreview($preview)
            } else if let contextError {
                VStack {
                    WorkSurfaceEmptyState(title: L10n.string("Diff unavailable"), message: contextError)
                    Button(L10n.string("Refresh")) { Task { await loadContext() } }
                        .padding(.bottom, 12)
                }
            } else {
                ProgressView(L10n.string("Loading diff…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(hostID: model.id, taskID: taskID, connected: model.isConnected, offered: model.offersReview)) {
            await loadContext()
        }
    }

    private func loadContext() async {
        context = nil
        contextOwner = nil
        contextError = nil
        guard model.offersReview else { return }
        do {
            let result = try await reader.context()
            try Task.checkCancellation()
            guard result.workspace?.isEmpty == false else { throw RemoteError(.unavailable) }
            contextOwner = ownerKey
            context = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            contextError = error.localizedDescription
        }
    }
}
