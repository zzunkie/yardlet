import Foundation

/// A provider-owned resume boundary. The child's saved account/scope still selects the storage;
/// this metadata never carries paths, credentials, or a substitute text prompt.
struct HarnessSessionForkSource: Codable, Hashable, Sendable {
    let providerSessionID: String
    let throughMessageID: String
}

/// A deferred native fork is launch input for a provider whose CLI persists the new session only
/// after its first input. Configure it before resume; a nil source resumes the child's own ID.
protocol HarnessSessionForkConfiguring: Actor {
    func setSessionForkSource(_ source: HarnessSessionForkSource?, for localSessionID: UUID) async throws
}

/// An explicitly planned empty native conversation, used when editing the first message. A
/// missing saved history never implicitly opts an ordinary resume into starting over.
protocol HarnessNewSessionConfiguring: Actor {
    func setNewSessionID(_ providerSessionID: String?, for localSessionID: UUID) async throws
}

/// How an adapter makes a second conversation from a task's own, without Yardlet replaying the
/// conversation as text. The child always keeps the source's account, storage scope and runtime.
enum HarnessSessionBranchMethod: Equatable, Sendable {
    /// Yardlet reads the boundary from the provider's saved conversation and the adapter forks it
    /// at the child's first launch (`HarnessSessionForkConfiguring`). The source is neither
    /// attached nor probed. Only the whole saved conversation is a boundary.
    case savedConversation
    /// The attached provider forks the session itself, through a completed turn when asked
    /// (`CodexCapabilityProviding.fork`).
    case attachedSession
}

/// Optional native-branch surface (B12). AppModel reads it from the adapter a task runs on, not
/// from the harness name. An adapter that does not conform, or answers `nil`, has no native fork:
/// its side chat starts from a reading snapshot, and its task offers no fork.
protocol HarnessSessionBranching: Actor {
    nonisolated var sessionBranchMethod: HarnessSessionBranchMethod? { get }
}

/// Where `AppModel.branch` opens the new conversation: its own task in the sidebar, which is
/// selected, or the parent's side chat in the side panel.
enum BranchPlacement: Sendable {
    case sidebar
    /// Its own task in the sidebar, left unselected: one another device made, which the window here
    /// does not switch to (docs/REMOTE_PROTOCOL.md §15.23).
    case sidebarInBackground
    case sidePanel
}

/// How much of the source conversation a branch carries.
enum BranchPoint: Hashable, Sendable {
    /// Nothing: a blank task in the source's project, account, storage scope and runtime
    /// (Codex New chat, Claude `/clear`).
    case start
    /// The conversation through one completed turn.
    case turn(String)
    /// The whole conversation.
    case latest
}
