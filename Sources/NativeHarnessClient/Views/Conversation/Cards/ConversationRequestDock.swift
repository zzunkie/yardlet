import SwiftUI

/// The requests a task waits on, docked right above its composer as the Claude app docks its approval
/// and question cards: the oldest one whole, the ones after it as up to two edges behind it, and the
/// composer still free to type in. Only a task's own conversation docks them (`ConversationPlacement.task`);
/// its turns keep the progress line that says what waits, and an answered request stays in its turn as
/// the line it leaves.
struct ConversationRequestDock: View {
    let requests: [ConversationRequest]
    let actions: ConversationActions
    /// The most the dock takes of its conversation's height; a taller card scrolls inside it.
    let maximumHeight: CGFloat

    /// The edges behind the front card, as the Claude app stacks up to two.
    static let maximumEdges = 2
    /// The share of the conversation's height the dock takes at most, as the Claude app's card does of
    /// its window (`max-h-[60vh]`).
    static let heightShare: CGFloat = 0.6
    /// How far each edge shows above the one in front of it.
    static let edgeStep: CGFloat = 6

    @State private var cardHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let front = requests.first {
            let edges = min(requests.count - 1, Self.maximumEdges)
            // The composer's keys answer the oldest request a notification could answer
            // (`ComposerApprovalKey`); the front card names them when it is that one.
            let keyed = requests.first { NotificationApprovalProjection.pendingRequest(for: $0) != nil }?.id
            ScrollView {
                ConversationRequestCard(request: front, actions: actions, answeredByComposerKeys: front.id == keyed)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            // A card taller than the dock opens at its answers, the part it waits on; what it asks
            // scrolls back into view above them.
            .defaultScrollAnchor(.bottom)
            .frame(height: min(max(cardHeight, 1), maximumHeight))
            // The panel's edge stays put while a taller card scrolls under it.
            .clipShape(RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
            .overlay {
                if cardHeight > maximumHeight {
                    RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius)
                        .stroke(ParityTheme.strongSeparator)
                }
            }
            // Raised off the conversation as the composer under it is (`PromptComposer`): the shadow is drawn from a
            // plain shape behind the panel, as `floatingSurface()` draws its own, so the scrolling card is not
            // composited offscreen for it.
            .background {
                RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius)
                    .fill(ParityTheme.elevated)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.06), radius: 12, y: 4)
            }
            .background(alignment: .top) { edgesBehind(edges) }
            // A card of its own for each request: the next one does not take the answered one's input.
            .id(front.id)
            .transition(.opacity)
            .animation(ParityMotion.easeOut(reduceMotion: reduceMotion), value: front.id)
            .padding(.top, CGFloat(edges) * Self.edgeStep)
            .conversationColumn()
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
        }
    }

    /// The requests after the front one, as edges of the same panel showing above it, each a little
    /// narrower and fainter than the one in front.
    private func edgesBehind(_ count: Int) -> some View {
        ZStack(alignment: .top) {
            ForEach((1...max(count, 1)).reversed(), id: \.self) { depth in
                if depth <= count {
                    ConversationRequestPanel()
                        .frame(height: 40)
                        .scaleEffect(x: 1 - 0.03 * CGFloat(depth), y: 1, anchor: .top)
                        .offset(y: -Self.edgeStep * CGFloat(depth))
                        .opacity(1 - 0.25 * Double(depth))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
