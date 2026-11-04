import AppKit
import SwiftUI
import YardletRemote

/// The session rail of a host's task, drawn by the local rail (`SessionRailView`) from what the host says of the task:
/// where it runs (its project and harness; the folder is the host's, so it is named and not opened here), its settings
/// as the host's composer reads them (§15.23), chosen here through the host, and the files its Outputs card lists
/// (§15.22). A file opens once read from the host: a click in this Mac's Quick Look, its menu in its own app or in
/// Finder, each on the copy. The shown task reads its remaining facts from the host (§15.34),
/// through the same local projections; older hosts leave those cards out.
struct RemoteTaskRail: View {
    /// The host's task as the sidebar reads it (`RemoteSidebarMirror`).
    let session: SessionRecord
    let projectName: String
    let options: ComposerSessionOptions?
    let outputs: [RemoteOutput]
    var hostName: String? = nil
    var facts: RemoteRailFacts? = nil
    var hostActions = SessionRailActions()
    let preferences: SessionRailPreferenceStore
    @Binding var folds: SessionRailFolds
    let choose: (ComposerSessionChoice) -> Void
    let prepareSettings: () async -> Void
    let open: (URL) -> Void
    let openInItsApp: (URL) -> Void
    let revealInFinder: (URL) -> Void

    var body: some View {
        SessionRailView(content: content, folds: $folds, preferences: preferences, actions: actions)
            // A click on an output opens it as the conversation's links open the host's files.
            .environment(\.openURL, OpenURLAction { url in
                open(url)
                return .handled
            })
    }

    var content: SessionRailContent {
        RemoteRailProjection.content(session: session, projectName: projectName, options: options,
                                     outputs: outputs, hostName: hostName, facts: facts)
    }

    private var actions: SessionRailActions {
        var actions = hostActions
        actions.onChoose = choose
        actions.onPrepareSettings = prepareSettings
        actions.openURL = { url in
            if url.isFileURL { openInItsApp(url) } else { hostActions.openURL(url) }
        }
        actions.revealInFinder = revealInFinder
        return actions
    }

    /// The host's outputs as the card's rows: each at its path on the host, which the card shows as its help.
    nonisolated static func rows(_ outputs: [RemoteOutput]) -> [SessionRailContent.Output] {
        RemoteRailProjection.outputRows(outputs)
    }
}

/// Where a host's file opens once read: this Mac's Quick Look, its own app, or Finder.
@MainActor
enum RemoteFileOpening {
    case viewer
    case itsApp
    case finder

    /// Why a file could not be opened, in the person's words.
    static func message(_ failure: RemoteHostFiles.Failure, host: String) -> String {
        switch failure {
        case .notServed: L10n.format("%@ opens only what the task made and the files in its folders.", host)
        case .tooLarge: L10n.format("The file is too large to open from %@.", host)
        case let .unavailable(error): RemoteHostModel.message(for: error, host: host)
        }
    }
}
