import Foundation
import Observation
import UWP
import WinUI

/// A task that needs the person, answered in New task's composer's place, as the Mac's home answers it
/// (`NewTaskHomeReplyHeader`, `NewTaskHomeReplyServices`): a line naming the task (the reply arrow, its harness's
/// mark, its title, where it is listed and how it is, Open task and Close preview), then its own conversation
/// (`ConversationTimeline`) and composer (`TaskComposer`), read and answered as the window's own are. Its saved
/// conversation is read as the Mac reads it for the reply, without resuming anything
/// (`AppModel.prefetchSavedConversation`). A message sent from its composer, or an answer to the last request the
/// task waits on, tells the home (`onReplied`), which goes on to the next task that needs the person; Escape in its
/// composer and Close preview give the new task its composer back, and nothing in the task stops.
@MainActor
final class NewTaskHomeReplyPane {
    let view = Grid()
    var onOpen: (SessionRecord.ID) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// The person sent a message, or answered the last request the task waited on.
    var onReplied: () -> Void = {}
    private(set) var sessionID: SessionRecord.ID?

    private let model: AppModel
    private let log: QAEventLog
    private let header = Grid()
    private let body = Grid()
    private let timeline = ConversationTimeline()
    private let composer: TaskComposer
    private let presentation: (SessionRecord) -> ConversationPresentation?
    private let answer: (ConversationRequest, ConversationRequestResponse, SessionRecord) -> Void
    private var generation = 0
    private var shownHeader: Header?
    /// Where the task is listed, read when it is shown.
    private var place = ""

    private struct Header: Equatable {
        var title: String
        var harness: HarnessKind
        var status: String?
    }

    init(model: AppModel, log: QAEventLog, signIn: HarnessSignIn,
         presentation: @escaping (SessionRecord) -> ConversationPresentation?,
         answer: @escaping (ConversationRequest, ConversationRequestResponse, SessionRecord) -> Void) {
        self.model = model
        self.log = log
        self.presentation = presentation
        self.answer = answer
        composer = TaskComposer(model: model, log: log, answersInHome: true)
        timeline.signIn = signIn
        make()
    }

    /// The window "+"'s dialogs belong to.
    var windowHandle: () -> UInt64 {
        get { composer.windowHandle }
        set { composer.windowHandle = newValue }
    }

    private func make() {
        SidebarStyle.columns(view, [SidebarStyle.star])
        for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto)] {
            let row = RowDefinition()
            row.height = height
            view.rowDefinitions.append(row)
        }
        view.rowSpacing = 4
        header.columnSpacing = 8
        header.padding = Thickness(left: 10, top: 0, right: 0, bottom: 0)
        view.children.append(header)

        for height in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 0, gridUnitType: .auto)] {
            let row = RowDefinition()
            row.height = height
            body.rowDefinitions.append(row)
        }
        body.children.append(timeline.view)
        try? Grid.setRow(composer.noticeView, 1)
        body.children.append(composer.noticeView)
        try? Grid.setRow(composer.view, 2)
        body.children.append(composer.view)
        try? Grid.setRow(body, 1)
        view.children.append(body)

        timeline.respond = { [weak self] request, response in self?.respond(request, response) }
        composer.onSent = { [weak self] in self?.onReplied() }
        composer.onEscape = { [weak self] in self?.onClose() }
    }

    /// How tall the conversation and the composer stand (`NewTaskHomeLayout.replyHeight`).
    func setHeight(_ height: Double) {
        if body.height != height { body.height = height }
    }

    func focus() {
        composer.focus()
    }

    /// Answers `id` here, or with nil, no task: the following ends.
    func show(_ id: SessionRecord.ID?) {
        guard id != sessionID else { return }
        sessionID = id
        generation += 1
        shownHeader = nil
        composer.show(id)
        guard let id, let session = model.store.sessions.first(where: { $0.id == id }) else {
            timeline.show(nil, conversationID: nil)
            return
        }
        place = model.taskPlaceNames()(session)
        log.write("home reply: \(session.title)")
        model.prefetchSavedConversation(of: id)
        follow()
    }

    /// The task's line and conversation, followed through Observation while it is answered here.
    private func follow() {
        guard let id = sessionID else { return }
        let current = generation
        let (session, conversation, status) = withObservationTracking {
            let session = model.store.sessions.first { $0.id == id }
            return (session, session.flatMap(presentation), session.flatMap { session in
                SidebarTaskIndicatorProjection.status(
                    of: session, detail: model.taskAttentionDetails[session.id],
                    isShellBusy: model.shellBusySessionIDs.contains(session.id))
            })
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.follow()
            }
        }
        guard let session else { return }
        let line = Header(title: session.title, harness: session.harness, status: status?.accessibilityName)
        if line != shownHeader {
            shownHeader = line
            drawHeader(line)
        }
        timeline.workspaceURL = session.workspaceURL
        timeline.show(conversation, conversationID: session.id.uuidString)
    }

    /// An answer from a request's card, carried out as the window's own card does; it tells the home unless the task
    /// still waits on another of its requests.
    private func respond(_ request: ConversationRequest, _ response: ConversationRequestResponse) {
        guard let id = sessionID, let session = model.store.sessions.first(where: { $0.id == id }) else { return }
        let waitsOn = (model.railChildWait(session)?.requests ?? []).contains { $0.id != request.id }
        answer(request, response, session)
        if !waitsOn { onReplied() }
    }

    /// Which task it is, where it is and how it is, with Open task and Close preview at its end.
    private func drawHeader(_ line: Header) {
        header.children.clear()
        header.columnDefinitions.clear()
        SidebarStyle.columns(header, [SidebarStyle.auto, SidebarStyle.auto, SidebarStyle.auto, SidebarStyle.star,
                                      SidebarStyle.auto, SidebarStyle.auto])
        header.children.append(ComposerParts.glyph(Self.replyGlyph, size: 11, color: WindowsTheme.accent))
        if let icon = HarnessIcon.element(for: line.harness, size: 14) {
            icon.verticalAlignment = .center
            try? Grid.setColumn(icon, 1)
            header.children.append(icon)
        }
        let title = ComposerParts.label(line.title, size: 14, color: WindowsTheme.text, weight: 600)
        title.maxWidth = 360
        try? Grid.setColumn(title, 2)
        header.children.append(title)
        let facts = ComposerParts.label(([place] + (line.status.map { [$0] } ?? [])).joined(separator: " · "),
                                        size: 12, weight: 400)
        try? Grid.setColumn(facts, 3)
        header.children.append(facts)
        let open = ComposerParts.iconButton(Self.openGlyph, name: L10n.string("Open task"), size: 12,
                                            foreground: WindowsTheme.secondaryText, fill: nil, radius: 6)
        open.click.addHandler { [weak self] _, _ in
            guard let self, let id = self.sessionID else { return }
            self.onOpen(id)
        }
        try? Grid.setColumn(open, 4)
        header.children.append(open)
        let close = ComposerParts.iconButton(ComposerParts.Glyph.remove, name: L10n.string("Close preview"), size: 11,
                                             foreground: WindowsTheme.secondaryText, fill: nil, radius: 6)
        close.click.addHandler { [weak self] _, _ in self?.onClose() }
        try? Grid.setColumn(close, 5)
        header.children.append(close)
        try? AutomationProperties.setName(header, L10n.string("Conversation preview"))
    }

    private static let replyGlyph = "\u{E97A}"
    private static let openGlyph = "\u{E8A7}"
}
