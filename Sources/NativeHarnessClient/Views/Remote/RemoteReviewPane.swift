import QuickLook
import SwiftUI

/// The local Review surface with host-backed reads. The window owns its per-task preferences.
struct RemoteReviewPane: View {
    let model: RemoteHostModel
    let taskID: String
    let workspaceURL: URL
    var additionalRootURLs: [URL] = []
    @Binding var review: DiffReviewPreferences
    var onClose: () -> Void = {}
    @State private var preview: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if model.offersReview {
            DiffPane(workspaceURL: workspaceURL, additionalRootURLs: additionalRootURLs, review: $review,
                     reading: RemoteGitDiffReading(model: model, taskID: taskID, workspaceURL: workspaceURL),
                     onClose: onClose)
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
        } else {
            WorkSurfaceEmptyState(title: L10n.string("Review"),
                                  message: L10n.string("Update Yardlet on the host to use this panel."))
        }
    }
}
