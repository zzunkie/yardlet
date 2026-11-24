import Foundation
import SwiftUI

/// The one look of a conversation, the same for every harness (D12, plan M12f). Its spacing and the
/// sent bubble's shape are Claude Code's (2026-10-15 user decision):
/// three quarters of a 20 pt line between turns (`--chat-turn-gap`), half a line inside one
/// (`--chat-item-gap`), a bubble no wider than 472 pt (`min(85%, 29.5rem)`). The "Show more" length
/// is the Codex timeline's. The sent message is set in the conversation font, which follows the
/// interface size setting (`ParityTheme.conversationFont(scale:)`).
enum ConversationLayout {
    /// Between turns.
    static let turnSpacing: CGFloat = 15
    /// Between the parts of one turn.
    static let itemSpacing: CGFloat = 10
    /// Taken from the space above and below the fold of the calls between two of the provider's
    /// messages, which then sits half a part's space from each (`ConversationWorkStretch.opensWithAnswer`).
    static let foldBetweenMessagesInset: CGFloat = -itemSpacing / 2
    static let topPadding: CGFloat = 24
    static let bottomPadding: CGFloat = 28
    /// The least space before a sent message's bubble.
    static let sentMessageLeadingSpace: CGFloat = 96
    /// The widest a sent message's bubble grows.
    static let sentBubbleMaximumWidth: CGFloat = 472
    /// The sent bubble's corner and inside (`--cds-message-bubble-radius`, `-pad-x`, `-pad-y`).
    static let sentBubbleCornerRadius: CGFloat = 10
    static let sentBubblePadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    /// The characters of a message shown before "Show more".
    static let messageCharacterLimit = 5_000
}

/// Where a conversation sits, which decides what it paints and where assistive apps read it. It is
/// the surface's business, not the harness's.
enum ConversationPlacement: Equatable, Sendable {
    /// A task's own conversation: it paints the window's canvas behind itself and reads as the task's
    /// main content, ahead of the composer.
    case task
    /// A conversation inside another surface (a subtask's side panel, a reading fixture): it takes
    /// that surface's background and reads in layout order, after the panel's header.
    case panel

    var paintsCanvas: Bool { self == .task }
    var accessibilitySortPriority: Double { self == .task ? ParityAccessibility.mainContent : 0 }
}
