import Foundation

/// Why a task's runtime is taken off it (`AppModel.detachRuntime(of:reason:)`). The words are what
/// the coordination log records.
enum RuntimeDetachReason: String, Sendable, CaseIterable {
    /// The task is archived, deleted or discarded.
    case taskRemoved = "task-removed"
    /// The task moves to another account, whose login its next runtime starts under.
    case accountChange = "account-change"
    /// The task starts again for a context limit its running CLI cannot take.
    case contextLimit = "context-limit"
    /// Nothing needs the runtime and the memory saver lets it go.
    case memorySaver = "memory-saver"
    /// The task came on screen and starts again with next-message suggestions it started without.
    case nextMessageSuggestions = "next-message-suggestions"
    /// The harness's CLI changed under it, so its next message starts the CLI that is there now.
    case cliChanged = "cli-changed"
    /// Its login was signed in after its CLI found none.
    case signIn = "sign-in"
    /// Its event stream ended: the process exited or the connection closed.
    case streamEnded = "stream-ended"
    /// An edited message continues in a new conversation of the provider's.
    case conversationEdit = "conversation-edit"

    /// Whether the task goes on with the conversation the runtime ran in. A removed task takes its
    /// conversation along and an edit puts another in its place, so nothing in it is ended for them.
    var keepsConversation: Bool {
        switch self {
        case .taskRemoved, .conversationEdit: false
        case .accountChange, .contextLimit, .memorySaver, .nextMessageSuggestions, .cliChanged, .signIn, .streamEnded: true
        }
    }
}
