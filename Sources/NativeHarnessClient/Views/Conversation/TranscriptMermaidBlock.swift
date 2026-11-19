import AppKit
import SwiftUI

/// A Mermaid block of an answer (`TranscriptMarkdownBlock.mermaid`), drawn as its diagram, as the Codex and Claude apps
/// draw one: a picture Mermaid made in its sandbox (`MermaidDiagrams`), asked for only once the block is on screen,
/// as wide as the message at most and never larger than its own size. Until it is drawn, when Mermaid cannot draw it,
/// while find's current match is in it, or when the person asks for its source, the block is the code block it was.
/// On hover: "Copy code", "Show source" and "Expand diagram", which opens it in the image viewer.
struct TranscriptMermaidBlock: View {
    let text: String
    let findKey: ConversationFindSegmentKey
    let copyPayload: () -> String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationFindSlot) private var findSlot
    @Environment(\.openImageViewer) private var openImageViewer
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing
    @Environment(\.revealsSentMessageActions) private var revealsActions
    @State private var isOnScreen = false
    /// What this block was told last; the shared cache holds it too, but a view is not told when that changes.
    @State private var drawn: (key: MermaidDiagrams.Key, result: MermaidDiagrams.Result)?
    @State private var showsSource = false
    @State private var isHovering = false

    private struct Request: Equatable {
        let key: MermaidDiagrams.Key
        let isOnScreen: Bool
    }

    var body: some View {
        let key = MermaidDiagrams.Key(source: text, isDark: colorScheme == .dark)
        let result = drawn.flatMap { $0.key == key ? $0.result : nil } ?? MermaidDiagrams.shared.cached(key)
        let diagram: MermaidDiagram? = if case let .diagram(diagram)? = result { diagram } else { nil }
        // Find marks its matches in the code; a diagram has none to mark.
        let findIsHere = findSlot?.query != nil && findSlot?.active?.key == findKey
        // Drawn in the other appearance and being drawn in this one: its place, empty, rather than its code.
        let redrawing: MermaidDiagram? = if result == nil,
            case let .diagram(diagram)? = MermaidDiagrams.shared.cached(.init(source: text, isDark: !key.isDark)) { diagram } else { nil }
        // One stack, so the signal behind it stays the same view whichever the block shows.
        VStack(alignment: .leading, spacing: 0) {
            if let diagram, !showsSource, !findIsHere {
                picture(diagram, isDark: key.isDark)
            } else if let redrawing, !showsSource, !findIsHere {
                ConversationToolImageFrame(pixelSize: redrawing.size, maxHeight: .infinity) { Color.clear }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(ParityTheme.separator) }
                    .accessibilityLabel(L10n.string("Diagram"))
            } else {
                TranscriptCodeBlock(
                    language: "mermaid", text: text, findKey: findKey,
                    accessory: diagram == nil || findIsHere ? nil : AnyView(showDiagramButton), copyPayload: copyPayload)
            }
        }
        .background(TranscriptOnScreenSignal { isOnScreen = $0 })
        .task(id: Request(key: key, isOnScreen: isOnScreen)) {
            guard isOnScreen, result == nil, let result = await MermaidDiagrams.shared.result(for: key),
                  !Task.isCancelled else { return }
            drawn = (key, result)
        }
    }

    private func picture(_ diagram: MermaidDiagram, isDark: Bool) -> some View {
        Button { expand(diagram, isDark: isDark) } label: {
            ConversationToolImageFrame(pixelSize: diagram.size, maxHeight: .infinity) {
                TranscriptMermaidBitmap(diagram: diagram)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(L10n.string("Expand diagram"))
        .accessibilityLabel(L10n.string("Diagram"))
        .accessibilityActions {
            Button(L10n.string("Expand diagram")) { expand(diagram, isDark: isDark) }
            Button(L10n.string("Show source")) { showsSource = true }
            Button(L10n.string("Copy code")) { TranscriptClipboard.copy(copyPayload()) }
        }
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(ParityTheme.separator) }
        .overlay(alignment: .topTrailing) {
            if isHovering || revealsActions {
                HStack(spacing: 2) {
                    TranscriptBlockButton(systemName: "doc.on.doc", title: L10n.string("Copy code")) {
                        TranscriptClipboard.copy(copyPayload())
                    }
                    TranscriptBlockButton(systemName: "chevron.left.forwardslash.chevron.right", title: L10n.string("Show source")) {
                        showsSource = true
                    }
                    TranscriptBlockButton(systemName: "arrow.up.left.and.arrow.down.right", title: L10n.string("Expand diagram")) {
                        expand(diagram, isDark: isDark)
                    }
                }
                .padding(4)
                .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(ParityTheme.separator) }
                .padding(6)
            }
        }
        .pointerHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.string("Expand diagram")) { expand(diagram, isDark: isDark) }
            Button(L10n.string("Show source")) { showsSource = true }
            Button(L10n.string("Copy code")) { TranscriptClipboard.copy(copyPayload()) }
            Button(L10n.string("Copy Image")) {
                Task {
                    guard let png = await diagram.opaquePNG(isDark: isDark) else { return }
                    ImageViewerModel.copy(png)
                }
            }
        }
    }

    private var showDiagramButton: some View {
        Button { showsSource = false } label: {
            Label(L10n.string("Show diagram"), systemImage: "point.3.connected.trianglepath.dotted")
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(L10n.string("Show diagram"))
    }

    /// The diagram in the image viewer, on its appearance's background, which the viewer's dark backdrop needs.
    private func expand(_ diagram: MermaidDiagram, isDark: Bool) {
        pauseFollowing()
        Task {
            guard let png = await diagram.opaquePNG(isDark: isDark) else { return }
            openImageViewer(ImageViewerRequest(items: [ImageViewerItem(name: L10n.string("Diagram"), source: .data(png))],
                                               index: 0))
        }
    }
}

/// A diagram's picture, decoded while it is on screen and let go once it leaves, as a picture's bitmap is
/// (`TranscriptPictureBitmapView`).
private struct TranscriptMermaidBitmap: NSViewRepresentable {
    let diagram: MermaidDiagram

    func makeNSView(context: Context) -> TranscriptMermaidBitmapView {
        let view = TranscriptMermaidBitmapView()
        view.show(diagram)
        return view
    }

    func updateNSView(_ view: TranscriptMermaidBitmapView, context: Context) {
        view.show(diagram)
    }

    static func dismantleNSView(_ view: TranscriptMermaidBitmapView, coordinator: ()) {
        view.release()
    }
}

final class TranscriptMermaidBitmapView: ConversationOnScreenView {
    private var diagram: MermaidDiagram?
    private var loading: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        onScreenChanged = { [weak self] isOnScreen in self?.update(isOnScreen: isOnScreen) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The button around the diagram takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    /// Whether the diagram's bitmap is drawn now.
    var isDrawn: Bool { layer?.contents != nil }

    func show(_ diagram: MermaidDiagram) {
        guard diagram !== self.diagram else { return }
        self.diagram = diagram
        release()
        update(isOnScreen: isOnScreen)
    }

    func release() {
        loading?.cancel()
        loading = nil
        layer?.contents = nil
    }

    private func update(isOnScreen: Bool) {
        guard isOnScreen else {
            release()
            return
        }
        guard let diagram, layer?.contents == nil, loading == nil else { return }
        loading = Task { [weak self] in
            let bitmap = await diagram.bitmap()
            guard let self, !Task.isCancelled, self.diagram === diagram else { return }
            self.loading = nil
            if self.isOnScreen, let bitmap { self.layer?.contents = bitmap.image }
        }
    }
}

/// Tells when its place in the conversation comes on screen and leaves it (`ConversationOnScreenView`).
private struct TranscriptOnScreenSignal: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TranscriptOnScreenSignalView {
        let view = TranscriptOnScreenSignalView()
        view.onScreenChanged = { [weak view] _ in
            // Told while SwiftUI places the view, which may not change its state then; by then a view that left the
            // window has nothing to tell.
            Task { @MainActor in
                guard let view, view.window != nil else { return }
                changed(view.isOnScreen)
            }
        }
        return view
    }

    func updateNSView(_ view: TranscriptOnScreenSignalView, context: Context) {}
}

/// Behind the block, never in the way of its clicks.
final class TranscriptOnScreenSignalView: ConversationOnScreenView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
