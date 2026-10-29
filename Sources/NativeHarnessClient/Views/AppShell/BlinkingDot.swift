import AppKit
import SwiftUI

/// A dot that fades to 30% and back every 1.2 s, as the Claude app's working status dot does
/// (`dframe-dot-blink`). Core Animation runs the fade on the dot's own layer. Run by SwiftUI
/// (`phaseAnimator`), every frame of the fade updated the window's view graph and laid out and drew
/// the whole window again, for as long as any task ran.
struct BlinkingDot: NSViewRepresentable {
    let color: Color
    let diameter: CGFloat

    func makeNSView(context: Context) -> BlinkingDotView {
        BlinkingDotView()
    }

    /// The color as SwiftUI would fill it here; the window's appearance changing updates it.
    func updateNSView(_ view: BlinkingDotView, context: Context) {
        view.color = color.resolve(in: context.environment).cgColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BlinkingDotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

/// The round layer `BlinkingDot` fades. Clicks go to the row around it.
final class BlinkingDotView: NSView {
    private static let fadeKey = "Yardlet.blink"

    var color: CGColor? {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Full to 30% in 0.6 s and back, easing in and out, for as long as the layer lives; a layer that
    /// comes to a window without it gets it again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer, layer.animation(forKey: Self.fadeKey) == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.3
        fade.duration = 0.6
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: Self.fadeKey)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
