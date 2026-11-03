import AppKit
import SwiftUI
import YardletRemote

/// The session rail of a host's task: its Outputs card, as the local rail draws it (`SessionRailOutputsCard`
/// in a `SessionRailCard`), with the files the host's Outputs card lists (docs/REMOTE_PROTOCOL.md §15.22).
/// A file opens once read from the host: a click in this Mac's Quick Look, its menu in its own app or in
/// Finder, each on the copy. The rail's other cards read the host's task as it stands there and stay on the
/// host.
struct RemoteTaskRail: View {
    let outputs: [RemoteOutput]
    let open: (URL) -> Void
    let openInItsApp: (URL) -> Void
    let revealInFinder: (URL) -> Void
    @State private var isFolded = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: SessionRailPlacement.cardSpacing) {
                SessionRailCard(kind: .outputs, rollup: String(outputs.count), meter: nil, isFolded: isFolded,
                                onToggle: { isFolded.toggle() }, menu: { EmptyView() }) {
                    SessionRailOutputsCard(outputs: Self.rows(outputs), actions: actions)
                }
            }
            .frame(width: SessionRailPlacement.width - 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .padding(.leading, 4)
            .padding(.trailing, 12)
        }
        .scrollIndicators(.automatic)
        .frame(width: SessionRailPlacement.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ParityTheme.canvas)
        // A click on a row opens it as the conversation's links open the host's files.
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Session details"))
    }

    private var actions: SessionRailActions {
        var actions = SessionRailActions()
        actions.openURL = openInItsApp
        actions.revealInFinder = revealInFinder
        return actions
    }

    /// The host's outputs as the card's rows: each at its path on the host, which the card shows as its help.
    static func rows(_ outputs: [RemoteOutput]) -> [SessionRailContent.Output] {
        outputs.map { output in
            SessionRailContent.Output(url: URL(filePath: output.path),
                                      writtenAt: output.writtenAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
        }
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
