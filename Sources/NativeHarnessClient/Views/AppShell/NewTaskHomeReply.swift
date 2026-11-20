import SwiftUI

/// What the home needs from the window to answer a task in its composer's place
/// ("the reply composer"): the task's own conversation and composer, drawn as a side-panel tab draws them, so
/// its request cards, queue, steering and draft are the ones its own view has.
struct NewTaskHomeReplyServices {
    /// The task's conversation and composer (`MainWindow.taskContent`, conversation only), with the
    /// composer's Escape and Tab and every send or answer there passed to the home (`hooks`).
    var content: (SessionRecord, NewTaskHomeReplyHooks) -> AnyView
    /// The task shows in another pane of the window, where its draft and reading place already are:
    /// choosing it goes there instead.
    var isShownElsewhere: (UUID) -> Bool = { _ in false }
    /// Gives the task's composer the keyboard.
    var focus: (UUID) -> Void = { _ in }
}

/// What the task's composer and request cards tell the home while they answer in its place.
struct NewTaskHomeReplyHooks {
    /// Escape in the composer: back to the new task's composer. Nothing in the task stops.
    var leave: () -> Void = {}
    /// Tab in the composer with no typed list open: the home's lines, at the task's own; true when
    /// they took the keyboard.
    var enterLists: () -> Bool = { false }
    /// The person sent a message or answered the last request the task waited on.
    var replied: () -> Void = {}
}

extension ComposerActions {
    /// The task's composer in the home's reply: each send also tells the home, and Escape and Tab
    /// belong to the home.
    func replying(_ hooks: NewTaskHomeReplyHooks) -> ComposerActions {
        var actions = self
        let send = self.send
        actions.send = { input in
            send(input)
            hooks.replied()
        }
        actions.submitCodex = submitCodex.map { submit in
            { draft, action in
                submit(draft, action)
                hooks.replied()
            }
        }
        actions.submitFollowUp = submitFollowUp.map { submit in
            { input, action in
                submit(input, action)
                hooks.replied()
            }
        }
        actions.escape = hooks.leave
        actions.tab = hooks.enterLists
        return actions
    }
}

extension ConversationActions {
    /// The task's request cards in the home's reply: an answer also tells the home, unless the task
    /// still waits on another of its requests (`waitsBeyond`, read as the answer goes).
    func replying(_ hooks: NewTaskHomeReplyHooks, waitsBeyond: @escaping (String) -> Bool) -> ConversationActions {
        var actions = self
        func answering(_ requestID: String, _ answer: () -> Void) {
            let waitsOn = waitsBeyond(requestID)
            answer()
            if !waitsOn { hooks.replied() }
        }
        let decide = self.decide
        actions.decide = { id, decision in answering(id) { decide(id, decision) } }
        actions.chooseOption = chooseOption.map { choose in
            { id, option in answering(id) { choose(id, option) } }
        }
        actions.answer = answer.map { answer in
            { id, value in answering(id) { answer(id, value) } }
        }
        let respond = respondToCodexRequest
        actions.respondToCodexRequest = { id, response in answering(id) { respond(id, response) } }
        actions.answerQuestion = answerQuestion.map { answer in
            { text in
                answer(text)
                hooks.replied()
            }
        }
        actions.answerQuestionWhileWorking = answerQuestionWhileWorking.map { answer in
            { text in
                answer(text)
                hooks.replied()
            }
        }
        return actions
    }
}

/// Over the task's conversation in the composer's place, the Codex app's conversation preview in
/// Mission Control (`LighthousePreview`): which task it is, where it is and how it is, "Open task"
/// (the preview's "Open conversation", in the word a side-panel task tab uses) and "Close preview",
/// which gives the new task its composer back, as Escape in the composer does.
struct NewTaskHomeReplyHeader: View {
    let session: SessionRecord
    /// The project, or "Chats", it is listed under.
    let place: String
    /// Its state in the sidebar's words, while it needs the person.
    let status: String?
    let onOpen: () -> Void
    let onClose: () -> Void
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 11 * interfaceScale, weight: .semibold))
                .foregroundStyle(ParityTheme.accent)
                .accessibilityHidden(true)
            HarnessIdentityIcon(harness: session.harness, size: 14 * interfaceScale)
                .accessibilityHidden(true)
            Text(session.title)
                .font(.system(size: 14 * interfaceScale, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(([place] + (status.map { [$0] } ?? [])).joined(separator: " · "))
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ParityIconButton(systemName: "arrow.up.forward.square", help: L10n.string("Open task"), action: onOpen)
            ParityIconButton(systemName: "xmark", help: L10n.string("Close preview"), action: onClose)
        }
        .padding(.leading, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Conversation preview"))
    }
}
