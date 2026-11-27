import SwiftUI

/// Over a page the agent holds (`BrowserHostPaneController.isAgentHolding`): an accent aura inside the page's edges and,
/// at the bottom, a small pill that says the agent is using the tab, with Take control. Only the pill takes the pointer;
/// the page under it keeps the person's input out by itself, so a press there still focuses the pane and the panel.
struct BrowserAgentHoldOverlay: View {
    /// Counts the presses and keys the page kept out: the edge and the pill answer each with a brief flash.
    let heldPresses: Int
    let takeControl: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShown = false
    @State private var isAnswering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            BrowserAgentHoldEdge(isAnswering: isAnswering, moves: !reduceMotion)
                .allowsHitTesting(false)
            pill
                .padding(.horizontal, ParitySpace.s12)
                .padding(.bottom, ParitySpace.s16)
        }
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) { isShown = true }
        }
        .task(id: heldPresses) {
            // Back to 0 when the panel shows another held tab: a flash cut short there must not stay on.
            guard heldPresses > 0 else { isAnswering = false; return }
            withAnimation(ParityMotion.easeOut(reduceMotion: reduceMotion)) { isAnswering = true }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion, duration: 0.35)) { isAnswering = false }
        }
    }

    private var pill: some View {
        let dark = colorScheme == .dark
        let shape = Capsule(style: .continuous)
        return ViewThatFits(in: .horizontal) {
            pillContent(showsText: true)
            pillContent(showsText: false)
        }
        .padding(.leading, ParitySpace.s8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            shape.fill(ParityTheme.elevated)
                .shadow(color: .black.opacity(dark ? 0.30 : 0.06), radius: 2, y: 1)
                .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 14, y: 6)
                .shadow(color: ParityTheme.accent.opacity(isAnswering ? 0.7 : dark ? 0.4 : 0.3),
                        radius: isAnswering ? 20 : 12)
        }
        .overlay {
            shape.fill(ParityTheme.accentSoftFill).opacity(isAnswering ? 1 : 0).allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(ParityTheme.accent.opacity(isAnswering ? 1 : dark ? 0.7 : 0.55),
                               lineWidth: isAnswering ? 2 : 1.25)
                .allowsHitTesting(false)
        }
        .scaleEffect(isAnswering && !reduceMotion ? 1.04 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("The agent is using this tab"))
    }

    private func pillContent(showsText: Bool) -> some View {
        HStack(spacing: ParitySpace.s8) {
            Image(systemName: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(ParityTheme.accent)
                .frame(width: 24, height: 24)
                .background(ParityTheme.accent.opacity(colorScheme == .dark ? 0.2 : 0.12), in: Circle())
                .accessibilityHidden(true)
            if showsText {
                Text(L10n.string("The agent is using this tab"))
                    .font(.callout.weight(.medium))
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

/// The aura inside the held page's edges: a wide soft glow, a tighter one and a crisp accent edge, all inside the
/// page's bounds. While `moves`, the glow breathes and a lighter band travels around the edge; both run as render
/// animations of this view's own layers, so neither the pane nor this view's body is asked again each frame. A held
/// press brings the glow up to full strength and widens the edge for a moment.
private struct BrowserAgentHoldEdge: View {
    let isAnswering: Bool
    let moves: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isBreathing = false
    @State private var isSweeping = false

    var body: some View {
        let dark = colorScheme == .dark
        let accent = ParityTheme.accent
        ZStack {
            // At rest the glow is at full strength, and the breath dims it: when `moves` goes off, the target changes
            // back to 1 with no animation, which ends the repeating one.
            aura(dark: dark)
                .animation(moves ? .easeInOut(duration: 2.2).repeatForever(autoreverses: true) : nil) {
                    $0.opacity(moves && isBreathing ? 0.6 : 1)
                }
            if isAnswering {
                aura(dark: dark).transition(.opacity)
            }
            sweep(accent: accent, dark: dark)
                .mask { Rectangle().strokeBorder(lineWidth: isAnswering ? 4 : 2.5) }
        }
        .clipped()
        .onAppear {
            isBreathing = moves
            isSweeping = moves
        }
        .onChange(of: moves) { _, moves in
            isBreathing = moves
            isSweeping = moves
        }
    }

    /// The glow, drawn once into its own layer: what animates over it is that layer's opacity, not the blur.
    private func aura(dark: Bool) -> some View {
        let accent = ParityTheme.accent
        return ZStack {
            Rectangle().stroke(accent.opacity(dark ? 0.55 : 0.4), lineWidth: 36).blur(radius: 16)
            Rectangle().stroke(accent.opacity(dark ? 0.6 : 0.5), lineWidth: 14).blur(radius: 4)
        }
        .drawingGroup()
    }

    /// An accent edge with a lighter band in it, turning once every eight seconds while `moves`.
    private func sweep(accent: Color, dark: Bool) -> some View {
        let light = accent.mix(with: .white, by: dark ? 0.55 : 0.4)
        return GeometryReader { proxy in
            // The page's diagonal and a point more, so the circle's antialiased rim never reaches a corner.
            let side = (proxy.size.width * proxy.size.width + proxy.size.height * proxy.size.height).squareRoot() + 2
            Circle()
                .fill(AngularGradient(colors: [accent, accent, light, accent, accent], center: .center))
                .frame(width: side, height: side)
                .animation(moves ? .linear(duration: 8).repeatForever(autoreverses: false) : nil) {
                    $0.rotationEffect(.degrees(moves && isSweeping ? 360 : 0))
                }
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}
