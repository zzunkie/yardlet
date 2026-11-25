import SwiftUI

/// Over a page the agent holds (`BrowserHostPaneController.isAgentHolding`): a soft accent glow at the page's edges and,
/// at the bottom, a small pill that says the agent is using the tab, with Take control. Only the pill takes the pointer;
/// the page under it keeps the person's input out by itself, so a press there still focuses the pane and the panel.
struct BrowserAgentHoldOverlay: View {
    /// Counts the presses and keys the page kept out: the pill answers each with a brief highlight.
    let heldPresses: Int
    let takeControl: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShown = false
    @State private var isAnswering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            glow.allowsHitTesting(false)
            pill
                .padding(.horizontal, ParitySpace.s12)
                .padding(.bottom, ParitySpace.s16)
        }
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) { isShown = true }
        }
        .task(id: heldPresses) {
            guard heldPresses > 0 else { return }
            withAnimation(ParityMotion.easeOut(reduceMotion: reduceMotion)) { isAnswering = true }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) { isAnswering = false }
        }
    }

    /// A 1.5 pt accent edge with a light inner glow, inside the page's bounds so nothing outside it changes.
    private var glow: some View {
        let dark = colorScheme == .dark
        return ZStack {
            Rectangle()
                .strokeBorder(ParityTheme.accent.opacity(dark ? 0.24 : 0.16), lineWidth: 6)
                .blur(radius: 6)
            Rectangle()
                .strokeBorder(ParityTheme.accent.opacity(dark ? 0.75 : 0.6), lineWidth: 1.5)
        }
        .clipped()
    }

    private var pill: some View {
        let dark = colorScheme == .dark
        let shape = Capsule(style: .continuous)
        return ViewThatFits(in: .horizontal) {
            pillContent(showsText: true)
            pillContent(showsText: false)
        }
        .padding(.leading, ParitySpace.s12)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            shape.fill(ParityTheme.elevated)
                .shadow(color: .black.opacity(dark ? 0.30 : 0.06), radius: 2, y: 1)
                .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 14, y: 6)
        }
        .overlay {
            shape.fill(ParityTheme.accentSoftFill).opacity(isAnswering ? 1 : 0).allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(isAnswering ? ParityTheme.accent.opacity(0.7)
                               : dark ? ParityTheme.strongSeparator : ParityTheme.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("The agent is using this tab"))
    }

    private func pillContent(showsText: Bool) -> some View {
        HStack(spacing: ParitySpace.s8) {
            Image(systemName: "sparkles")
                .font(.callout)
                .foregroundStyle(ParityTheme.accent)
                .accessibilityHidden(true)
            if showsText {
                Text(L10n.string("The agent is using this tab"))
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(L10n.string("Take control")) { takeControl() }
                .controlSize(.small)
                .parityProminentButton()
                .parityPointer()
                .help(L10n.string("Use this page yourself. The agent is told you are using it."))
        }
        .fixedSize()
    }
}
