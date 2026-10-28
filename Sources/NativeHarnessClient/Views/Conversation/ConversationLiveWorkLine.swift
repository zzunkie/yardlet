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
    @State private var sweep: CGFloat = -1

    var body: some View {
        Text(text)
            .overlay {
                if isShimmering, !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .primary.opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.45)
                            .offset(x: sweep * proxy.size.width)
                    }
                    .mask(Text(text))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear {
                        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { sweep = 1.2 }
                    }
                }
            }
    }
}
