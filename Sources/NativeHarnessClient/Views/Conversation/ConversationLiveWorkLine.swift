import AppKit
import SwiftUI

/// The one live line under a running turn (`ConversationLiveWork`): what the provider is doing now,
/// then the turn's step count and how long the turn has run, for every harness: the turn header reads
/// no time while the turn runs. Each state reads apart at a glance: thinking has its own mark, a
/// running call the spinner every running line has, both shimmering while the provider works as the
/// Codex app's activity header and the Claude app's working line do; waiting on the person is orange
/// with a raised hand and still. While a call runs or the thinking streams, a click opens what the
/// line stands for, as a summary line would; it starts folded
/// (`ConversationWorkDisclosure.liveLineStartsOpen`).
struct ConversationLiveWorkLine<Cell: View>: View {
    let live: ConversationLiveWork
    /// When the turn began, for its elapsed time; nil counts from when the line was first drawn.
    let startedAt: Date?
    /// The person opened or folded the line.
    let onToggle: (Bool) -> Void
    let cell: (ConversationItem) -> Cell

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var firstObservedAt = Date()
    @State private var isOpen: Bool

    init(live: ConversationLiveWork, startsOpen: Bool, startedAt: Date?,
         onToggle: @escaping (Bool) -> Void, @ViewBuilder cell: @escaping (ConversationItem) -> Cell) {
        self.live = live
        self.startedAt = startedAt
        self.onToggle = onToggle
        self.cell = cell
        _isOpen = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if live.items.isEmpty {
                label(isOpen: false)
            } else {
                HStack(alignment: .center, spacing: 2) {
                    Button {
                        isOpen.toggle()
                        onToggle(isOpen)
                    } label: {
                        label(isOpen: isOpen)
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .accessibilityValue(L10n.string(isOpen ? "Expanded" : "Collapsed"))
                    // Folded, the line shows its calls' images, as a summary line does.
                    if !isOpen {
                        ConversationToolImageThumbnails(images: live.items.flatMap(\.toolPreviewImages))
                    }
                }
            }
            if isOpen, !live.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(live.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle().fill(ParityTheme.separator).frame(height: 1)
                        }
                        cell(item)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ParityTheme.separator, lineWidth: 1)
                }
                .padding(.bottom, 4)
            }
        }
        .onChange(of: ConversationWorkDisclosure.groupHasFailure(live.items)) { _, failed in
            if failed { isOpen = true }
        }
    }

    private func label(isOpen: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = BackgroundTasksProjection.elapsedText(since: startedAt ?? firstObservedAt, now: context.date)
            let detail = ConversationLiveWork.detail(steps: live.steps, elapsed: elapsed)
            HStack(alignment: .center, spacing: 6) {
                mark
                    .frame(width: 14 * interfaceScale, height: 14 * interfaceScale)
                ShimmeringText(text: live.activity.text, isShimmering: live.activity.isProviderWorking)
                    .foregroundStyle(live.activity.isWaitingOnPerson ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if !detail.isEmpty {
                    Text(verbatim: "· " + detail)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if !live.items.isEmpty {
                    DisclosureCaret(isOpen: isOpen, size: 8 * interfaceScale)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            // The size of the status lines it stands for and becomes.
            .font(.system(size: ConversationStatusLineFont.size * interfaceScale))
            .frame(minHeight: 24 * interfaceScale)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel([live.activity.text, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    /// The mark before the words, one for each kind of state.
    @ViewBuilder
    private var mark: some View {
        switch live.activity.mark {
        case .thinking:
            Image(systemName: "brain")
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .working:
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        case .waitingOnPerson:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .reconnecting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Text with a light band sweeping across it while `isShimmering`, the treatment both apps give a
/// line that is still working (the Codex app's `loading-shimmer`, 2 s per sweep; the Claude app's
/// `cds-shimmer-text-band`). Still where the person asked for less motion.
struct ShimmeringText: View {
    let text: String
    let isShimmering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .overlay {
                if isShimmering, !reduceMotion {
                    ShimmerBand(color: .primary.opacity(0.85))
                        .mask(Text(text))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The band `ShimmeringText` sweeps, which Core Animation moves. Moved by SwiftUI, every frame of
/// the sweep updated the running turn's view graph and laid out and drew the turn again, for as
/// long as the provider worked.
private struct ShimmerBand: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> ShimmerBandView {
        ShimmerBandView()
    }

    func updateNSView(_ view: ShimmerBandView, context: Context) {
        view.color = color.resolve(in: context.environment).cgColor
    }
}

/// A gradient 45% of the text's width, fading out to both sides, that moves from one text width
/// before the words to 1.2 widths after their start every 2 s at a steady pace.
private final class ShimmerBandView: NSView {
    private static let sweepKey = "Yardlet.sweep"
    private let band = CAGradientLayer()
    /// When the sweep began and the width it crosses: a new width keeps the band where it was.
    private var sweepStart: CFTimeInterval?
    private var sweptWidth: CGFloat?

    var color: CGColor? {
        didSet { if color != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.addSublayer(band)
        return layer
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The ends fade to the band's own color, not to clear black, as SwiftUI's gradient does.
        band.colors = color.map { [$0.copy(alpha: 0) ?? $0, $0, $0.copy(alpha: 0) ?? $0] }
        band.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.45, height: bounds.height)
        CATransaction.commit()
        sweep()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sweep()
    }

    private func sweep() {
        let width = bounds.width
        guard window != nil, width > 0,
              width != sweptWidth || band.animation(forKey: Self.sweepKey) == nil else { return }
        let start = sweepStart ?? band.convertTime(CACurrentMediaTime(), from: nil)
        sweepStart = start
        sweptWidth = width
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -width
        sweep.toValue = width * 1.2
        sweep.duration = 2
        sweep.repeatCount = .infinity
        sweep.beginTime = start
        band.add(sweep, forKey: Self.sweepKey)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
