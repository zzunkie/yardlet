import AppKit
import SwiftUI

/// What a link in a conversation names, which decides where a click opens it and what its menu offers.
enum ConversationLinkKind: Equatable {
    /// Another task (`TaskLink`), which a click opens in the window.
    case task(TaskLink)
    /// A web page, which a click opens in the task's own browser panel, as the Codex app opens one in its
    /// browser (decision of 2026-10-22: the Yardlet browser is the default).
    case web
    /// A file or folder, which a click opens in the task's files or Finder.
    case file
    /// An anchor to a place in the message, such as a heading: nothing outside the message.
    case place
    /// Mail and other apps' links, which go where the system sends them.
    case other

    init(_ url: URL) {
        if let link = TaskLink(url) {
            self = .task(link)
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            self = .web
        } else if url.scheme == nil, url.path(percentEncoded: false).isEmpty {
            self = .place
        } else if url.isFileURL || url.scheme == nil || RemoteConversationFileLink.path(url) != nil {
            self = .file
        } else {
            self = .other
        }
    }
}

/// Where the menu of a link to another task opens it besides where a click does: a new tab, a pane beside
/// the task in a split view, or the side panel, as a sidebar row's menu opens a task.
enum TaskLinkPlace: Equatable {
    case newTab
    case splitView
    case sidePanel
}

/// The places a conversation's links open in that the window and the task's area provide: a task in a new
/// tab, a split view or the side panel (the window), and a web page in the task's browser panel (the task's
/// area). A conversation shown where they are not, as a personal agent's, has none, and its links' menus
/// offer only what does not need them. Equal while the same places are there, so the window's redraws leave
/// the conversation's texts that read them alone, as the sidebar's row actions do.
struct ConversationLinkPlaces: Equatable {
    var task: (@MainActor (TaskLink, URL, TaskLinkPlace) -> Void)?
    var browserPanel: (@MainActor (URL) -> Void)?
    /// Opens a file of the computer the conversation ran on, read from there first: another Mac's task
    /// (docs/REMOTE_PROTOCOL.md §15.22). Nil where the files are this Mac's, or where they cannot be read.
    var fileElsewhere: (@MainActor (URL) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.task == nil) == (rhs.task == nil) && (lhs.browserPanel == nil) == (rhs.browserPanel == nil)
            && (lhs.fileElsewhere == nil) == (rhs.fileElsewhere == nil)
    }
}

private struct ConversationLinkPlacesKey: EnvironmentKey {
    static let defaultValue = ConversationLinkPlaces()
}

extension EnvironmentValues {
    var conversationLinkPlaces: ConversationLinkPlaces {
        get { self[ConversationLinkPlacesKey.self] }
        set { self[ConversationLinkPlacesKey.self] = newValue }
    }
}

/// A link's items in a conversation's menus, by what it names, for a message's text and for the cards that
/// name a task or a file alike. A task offers what its sidebar row's menu offers (open, in a new tab, in a
/// split view, in the side panel); a web page, the task's browser panel and the default browser; a file, the
/// task's files, its own app and Finder (for a file on another computer, `transcriptOpensLocalFiles`, only its
/// path, and opening it where that computer's files can be read). Each ends with its copy. An anchor to a place in the message offers nothing.
/// Yardlet's windows share one selection, so a task has no "Open in New Window".
enum ConversationLinkMenu {
    enum Item: Hashable {
        /// As a click on the link opens it.
        case open
        case openInNewTab
        case openInSplitView
        case openInSidePanel
        case openInDefaultBrowser
        case openInItsApp
        case revealInFinder
        case copyLink
        case copyPath
    }

    /// The items for `url`, in groups with a separator between them.
    static func items(for url: URL, opensLocalFiles: Bool, places: ConversationLinkPlaces) -> [[Item]] {
        switch ConversationLinkKind(url) {
        case .task:
            let beside: [Item] = places.task == nil ? [] : [.openInNewTab, .openInSplitView, .openInSidePanel]
            return [[.open] + beside, [.copyLink]]
        case .web:
            return [(places.browserPanel == nil ? [] : [.open]) + [.openInDefaultBrowser], [.copyLink]]
        case .file:
            // A file on another computer is named, and opened only where it can be read from there.
            guard opensLocalFiles, RemoteConversationFileLink.path(url) == nil else {
                return places.fileElsewhere == nil ? [[.copyPath]] : [[.open], [.copyPath]]
            }
            // A program or a package is only shown in Finder: its own app would run it.
            let itsApp: [Item] = FileElsewhereButtons.runs(url) ? [] : [.openInItsApp]
            return [[.open] + itsApp + [.revealInFinder], [.copyPath]]
        case .place:
            return []
        case .other:
            return [[.copyLink]]
        }
    }

    static func title(_ item: Item, for url: URL) -> String {
        switch item {
        case .open:
            switch ConversationLinkKind(url) {
            case .task: L10n.string("Open task")
            case .web: L10n.string("Open in the browser panel")
            default: L10n.string("Open file")
            }
        case .openInNewTab: L10n.string("Open in New Tab")
        case .openInSplitView: L10n.string("Open in Split View")
        case .openInSidePanel: L10n.string("Open in Side Panel")
        case .openInDefaultBrowser: L10n.string("Open in default browser")
        case .openInItsApp: L10n.string("Open in its app")
        case .revealInFinder: L10n.string("Reveal in Finder")
        case .copyLink: L10n.string("Copy link")
        case .copyPath: L10n.string("Copy path")
        }
    }

    /// Does `item` for `url`; `open` is what a click on it does, and `text` the words it is written with.
    @MainActor
    static func perform(_ item: Item, url: URL, text: String?, places: ConversationLinkPlaces, open: (URL) -> Void) {
        // A host file never reaches a local-file action, even when drawn outside a remote environment.
        if RemoteConversationFileLink.path(url) != nil {
            if item == .open { places.fileElsewhere?(url) }
            if item == .copyPath { TranscriptClipboard.copy(copiedPath(url)) }
            return
        }
        switch item {
        case .open:
            if ConversationLinkKind(url) == .web, let browserPanel = places.browserPanel { browserPanel(url) } else { open(url) }
        case .openInNewTab: place(url, .newTab, places)
        case .openInSplitView: place(url, .splitView, places)
        case .openInSidePanel: place(url, .sidePanel, places)
        case .openInDefaultBrowser: OutsideBrowser.open(url)
        case .openInItsApp: NSWorkspace.shared.open(url)
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyLink: TranscriptClipboard.copy(copiedLink(url, text: text))
        case .copyPath: TranscriptClipboard.copy(copiedPath(url))
        }
    }

    static func copiedPath(_ url: URL) -> String {
        RemoteConversationFileLink.path(url) ?? url.path(percentEncoded: false)
    }

    /// A link as it is copied: an anchor to a task names it only inside a conversation, so it is copied as
    /// the Markdown it was written in, which an agent reads where it is pasted; any other link as its address.
    static func copiedLink(_ url: URL, text: String?) -> String {
        guard url.scheme == nil, case .task = ConversationLinkKind(url), let text, !text.isEmpty else { return url.absoluteString }
        let escaped = text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString))"
    }

    @MainActor
    private static func place(_ url: URL, _ place: TaskLinkPlace, _ places: ConversationLinkPlaces) {
        guard let link = TaskLink(url), let task = places.task else { return }
        task(link, url, place)
    }
}

extension View {
    /// The link menu of a card's control that names `url`, as a message's text offers it for its links.
    /// `open` is what the control's click does, when it is not the conversation's `openURL`.
    func conversationLinkMenu(_ url: URL?, text: String? = nil, open: (@MainActor () -> Void)? = nil) -> some View {
        modifier(ConversationLinkMenuModifier(url: url, text: text, open: open))
    }
}

private struct ConversationLinkMenuModifier: ViewModifier {
    let url: URL?
    let text: String?
    let open: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        if let url {
            content.contextMenu { ConversationLinkMenuItems(url: url, text: text, open: open) }
        } else {
            content
        }
    }
}

/// The menu's items, read only as the menu opens: SwiftUI draws a context menu's views then, so a card's
/// redraw reads neither the environment nor whether the file is a program.
private struct ConversationLinkMenuItems: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.conversationLinkPlaces) private var places
    @Environment(\.transcriptOpensLocalFiles) private var opensLocalFiles
    let url: URL
    let text: String?
    let open: (@MainActor () -> Void)?

    var body: some View {
        let groups = ConversationLinkMenu.items(for: url, opensLocalFiles: opensLocalFiles, places: places)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.self) { item in
                Button(ConversationLinkMenu.title(item, for: url)) {
                    ConversationLinkMenu.perform(item, url: url, text: text, places: places) { url in
                        if let open { open() } else { openURL(url) }
                    }
                }
            }
        }
    }
}
