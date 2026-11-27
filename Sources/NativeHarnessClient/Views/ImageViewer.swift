import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// A conversation image opened over the window, as the Codex and Claude apps' image previews open
// one: the window dims and the image fits in it, never larger than its own size, with its name, the
// zoom, the other images it came with, copy and save, and markup for an attachment still in the
// composer. Esc, a click beside the image or the close button puts it away.

/// One image the viewer shows: a sent or attached image by its URL (a file or an inline `data:`
/// image; a remote URL is never fetched), or a tool's image by its bytes.
struct ImageViewerItem {
    enum Source: Sendable {
        case url(URL)
        case data(Data)
    }

    let name: String
    let source: Source

    /// The bytes as they were sent or returned, read off the main thread.
    func originalData() async -> Data? {
        switch source {
        case let .url(url): await TranscriptImageThumbnails.shared.originalData(for: url)
        case let .data(data): data
        }
    }
}

/// A click on a conversation image: the images it came with (a message's, a tool result's), the one
/// clicked, and the markup an attachment still in the composer offers.
struct ImageViewerRequest: Identifiable {
    let id = UUID()
    let items: [ImageViewerItem]
    let index: Int
    /// Opens the markup editor on the image; only a composer attachment has it.
    var markUp: (() -> Void)?
}

private struct OpenImageViewerKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (ImageViewerRequest) -> Void = { _ in NSSound.beep() }
}

extension EnvironmentValues {
    /// Opens images over the window that shows them (`imageViewerHost()`); without a host it beeps.
    var openImageViewer: @MainActor @Sendable (ImageViewerRequest) -> Void {
        get { self[OpenImageViewerKey.self] }
        set { self[OpenImageViewerKey.self] = newValue }
    }
}

extension View {
    /// Shows the images `openImageViewer` opens over this view: once at a window's root, and in a
    /// sheet that shows a conversation.
    func imageViewerHost() -> some View {
        modifier(ImageViewerHost())
    }
}

private struct ImageViewerHost: ViewModifier {
    @State private var request: ImageViewerRequest?
    @State private var focusBookmark: WindowFocusBookmark?

    func body(content: Content) -> some View {
        content
            .environment(\.openImageViewer, { request in
                let window = NSApp.keyWindow
                focusBookmark = WindowFocusBookmark(window: window)
                // Nothing typed reaches the composer behind while the image loads; its canvas then
                // takes the keyboard.
                window?.makeFirstResponder(nil)
                self.request = request
            })
            .overlay {
                if let request {
                    ImageViewer(request: request, close: close)
                        .id(request.id)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: request?.id)
    }

    private func close() {
        request = nil
        // The viewer's canvas held the keyboard; the composer or list behind it takes it back.
        focusBookmark?.restore()
        focusBookmark = nil
    }
}

/// What the viewer shows and the zoom its canvas reports.
@MainActor
@Observable
final class ImageViewerModel {
    enum Content {
        case loading
        case image(NSImage, data: Data)
        case unavailable
    }

    let items: [ImageViewerItem]
    private(set) var index: Int
    private(set) var content: Content = .loading
    /// The canvas's zoom, 1 being the image's own size; nil until it has laid out.
    var zoom: CGFloat?
    /// Whether the image follows the window's size, as it does until the person zooms.
    var fitsWindow = true
    @ObservationIgnored weak var canvas: ImageViewerCanvasView?

    init(items: [ImageViewerItem], index: Int) {
        self.items = items
        self.index = items.indices.contains(index) ? index : 0
    }

    var item: ImageViewerItem? { items.indices.contains(index) ? items[index] : nil }
    var canShowPrevious: Bool { index > 0 }
    var canShowNext: Bool { index < items.count - 1 }

    func showPrevious() { show(index - 1) }
    func showNext() { show(index + 1) }

    private func show(_ index: Int) {
        guard items.indices.contains(index), index != self.index else { return }
        self.index = index
        content = .loading
        zoom = nil
        fitsWindow = true
    }

    /// Reads the current image; a newer `show` makes the result stale.
    func load() async {
        guard let item else {
            content = .unavailable
            return
        }
        let shown = index
        let data = await item.originalData()
        guard shown == index, !Task.isCancelled else { return }
        if let data, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 {
            content = .image(image, data: data)
        } else {
            content = .unavailable
        }
    }

    func zoom(_ step: ImageViewerCanvasView.Zoom) {
        canvas?.zoom(step)
    }

    /// The image's original bytes and a TIFF copy, so it pastes into any app.
    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard case let .image(image, data) = content else { return false }
        return Self.copy(data, image: image, to: pasteboard)
    }

    /// An image's original bytes and a TIFF copy on `pasteboard`, so it pastes into any app.
    @discardableResult
    static func copy(_ data: Data, image: NSImage? = nil, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = image ?? NSImage(data: data) else { return false }
        let entry = NSPasteboardItem()
        if let type = type(of: data) {
            entry.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        if let tiff = image.tiffRepresentation { entry.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([entry])
    }

    /// Asks where to save the original bytes, over `window`.
    func save(over window: NSWindow?) {
        guard case let .image(_, data) = content, let item else { return }
        let type = Self.type(of: data) ?? .png
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: item.name, type: type)
        let write: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
            }
            self?.canvas?.takeKeyboard()
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { panel.begin(completionHandler: write) }
    }

    nonisolated static func type(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }

    /// The image's own name when it already ends in its type's extension, else the name with it.
    nonisolated static func fileName(for name: String, type: UTType) -> String {
        let fileExtension = type.preferredFilenameExtension ?? "png"
        let current = (name as NSString).pathExtension.lowercased()
        if !current.isEmpty, type.tags[.filenameExtension]?.contains(current) == true { return name }
        return "\(name).\(fileExtension)"
    }
}

/// The images over the window: dimmed behind, the image fitted between its name and the zoom
/// controls, the arrows to the images it came with at the sides.
struct ImageViewer: View {
    let request: ImageViewerRequest
    let close: () -> Void

    @State private var model: ImageViewerModel
    @State private var copied = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    init(request: ImageViewerRequest, close: @escaping () -> Void) {
        self.request = request
        self.close = close
        _model = State(initialValue: ImageViewerModel(items: request.items, index: request.index))
    }

    private var showsArrows: Bool { model.items.count > 1 }

    var body: some View {
        ZStack {
            // A click beside the image puts it away, as in both apps.
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                header
                    .frame(height: 52 * interfaceScale)
                HStack(spacing: 0) {
                    arrow(previous: true)
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    arrow(previous: false)
                }
                footer
                    .frame(height: 60 * interfaceScale)
            }
        }
        // The viewer is drawn over a dark backdrop in either appearance, as both apps draw theirs.
        .environment(\.colorScheme, .dark)
        .task(id: model.index) { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(L10n.string("Image preview"))
    }

    // MARK: - Header: the name, then copy, save, markup and close

    private var header: some View {
        ZStack {
            if let item = model.item {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13 * interfaceScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsArrows {
                        Text(verbatim: "\(model.index + 1) / \(model.items.count)")
                            .font(.system(size: 12 * interfaceScale).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .accessibilityLabel(L10n.format("Image %lld of %lld", model.index + 1, model.items.count))
                    }
                }
                // Clear of the window's buttons on the left and the viewer's on the right.
                .padding(.horizontal, 190 * interfaceScale)
            }
            HStack(spacing: 6) {
                Spacer()
                if let markUp = request.markUp {
                    ImageViewerButton(systemName: "pencil", title: L10n.string("Mark Up")) {
                        close()
                        markUp()
                    }
                    .disabled(!model.hasImage)
                }
                ImageViewerButton(systemName: copied ? "checkmark" : "doc.on.doc", title: L10n.string("Copy Image"),
                                  shortcut: MacShortcut.imageCopy.binding?.displayText) {
                    copied = model.copy()
                }
                .keyboardShortcut(MacShortcut.imageCopy.binding)
                .disabled(!model.hasImage)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
                ImageViewerButton(systemName: "square.and.arrow.down", title: L10n.string("Save Image…")) {
                    model.save(over: model.canvas?.window ?? NSApp.keyWindow)
                }
                .disabled(!model.hasImage)
                ImageViewerButton(systemName: "xmark", title: L10n.string("Close image preview"), shortcut: MacShortcut.imageClose.isCustomized ? MacShortcut.imageClose.binding?.displayText : "Esc",
                                  action: close)
                    .keyboardShortcut(MacShortcut.imageClose.binding)
            }
            .padding(.horizontal, 14)
        }
    }

    // MARK: - The image

    @ViewBuilder
    private var canvas: some View {
        switch model.content {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .allowsHitTesting(false)
        case let .image(image, _):
            ImageViewerCanvas(model: model, image: image, name: model.item?.name ?? "",
                              markUp: request.markUp, close: close)
        case .unavailable:
            Text(L10n.string("The image could not be opened."))
                .font(.system(size: 13 * interfaceScale))
                .foregroundStyle(.white.opacity(0.7))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func arrow(previous: Bool) -> some View {
        if showsArrows {
            let enabled = previous ? model.canShowPrevious : model.canShowNext
            ImageViewerButton(systemName: previous ? "chevron.left" : "chevron.right",
                              title: L10n.string(previous ? "Previous image" : "Next image"),
                              shortcut: (previous ? MacShortcut.imagePrevious : .imageNext).binding?.displayText, size: 36) {
                previous ? model.showPrevious() : model.showNext()
            }
            .keyboardShortcut((previous ? MacShortcut.imagePrevious : .imageNext).binding)
            .disabled(!enabled)
            .frame(width: 64 * interfaceScale)
        } else {
            Color.clear.frame(width: 24 * interfaceScale).allowsHitTesting(false)
        }
    }

    // MARK: - Footer: zoom out, the zoom (fit or actual size), zoom in

    private var footer: some View {
        HStack(spacing: 2) {
            ImageViewerButton(systemName: "minus", title: L10n.string("Zoom Out"), shortcut: MacShortcut.imageZoomOut.isCustomized ? MacShortcut.imageZoomOut.binding?.displayText : "⌘−", fill: false) {
                model.zoom(.out)
            }
            let fits = model.fitsWindow
            let percent = Double(model.zoom ?? 1).formatted(.percent.precision(.fractionLength(0)))
            Button {
                model.zoom(fits ? .actualSize : .fit)
            } label: {
                Text(verbatim: percent)
                    .font(.system(size: 12 * interfaceScale, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 48 * interfaceScale, minHeight: 28 * interfaceScale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .help(fits ? L10n.string("Actual Size") : ShortcutHelp.text(L10n.string("Zoom to Fit"), MacShortcut.imageFit.binding))
            .accessibilityLabel(L10n.string(fits ? "Actual Size" : "Zoom to Fit"))
            .accessibilityValue(Text(verbatim: percent))
            ImageViewerButton(systemName: "plus", title: L10n.string("Zoom In"), shortcut: MacShortcut.imageZoomIn.isCustomized ? MacShortcut.imageZoomIn.binding?.displayText : "⌘+", fill: false) {
                model.zoom(.in)
            }
        }
        .padding(.horizontal, 4)
        .background(.white.opacity(0.12), in: Capsule())
        .disabled(!model.hasImage)
    }
}

private extension ImageViewerModel {
    var hasImage: Bool {
        if case .image = content { true } else { false }
    }
}

/// A round button on the viewer's dark backdrop.
private struct ImageViewerButton: View {
    let systemName: String
    let title: String
    var shortcut: String?
    var size: CGFloat = 30
    var fill = true
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13 * interfaceScale, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
                .frame(width: size * interfaceScale, height: size * interfaceScale)
                .background {
                    Circle().fill(.white.opacity(isHovering && isEnabled ? 0.24 : fill ? 0.12 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}

// MARK: - Canvas

private struct ImageViewerCanvas: NSViewRepresentable {
    let model: ImageViewerModel
    let image: NSImage
    let name: String
    let markUp: (() -> Void)?
    let close: () -> Void

    func makeNSView(context: Context) -> ImageViewerCanvasView {
        let view = ImageViewerCanvasView()
        model.canvas = view
        return view
    }

    func updateNSView(_ view: ImageViewerCanvasView, context: Context) {
        let model = model
        let close = close
        let markUp = markUp
        view.onZoom = { zoom, fits in
            model.zoom = zoom
            model.fitsWindow = fits
        }
        view.onClose = close
        view.onPrevious = { model.showPrevious() }
        view.onNext = { model.showNext() }
        let fileURL: URL? = {
            guard case let .url(url) = model.item?.source, url.isFileURL else { return nil }
            return url
        }()
        view.setContextActions(
            copyImage: { _ = model.copy() },
            saveImage: { [weak view] in model.save(over: view?.window ?? NSApp.keyWindow) },
            showInFinder: fileURL.map { url in
                { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            zoomActualSize: { model.zoom(.actualSize) },
            zoomFit: { model.zoom(.fit) },
            markUp: markUp.map { run in { close(); run() } },
            canShowMenu: { model.hasImage }
        )
        view.show(image, name: name)
    }
}

/// The image in a magnifying scroll view: fitted to the view, and never larger than its own size,
/// until the person zooms (a pinch, ⌘+ ⌘− ⌘0, a double click), and centered while smaller than the
/// view. It holds the keyboard while the viewer shows, so typing does not reach the composer behind.
final class ImageViewerCanvasView: NSScrollView {
    enum Zoom {
        case `in`, out, fit, actualSize
    }

    /// The zooms ⌘+ and ⌘− step through, besides the fitted one.
    static let steps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    var onZoom: ((_ zoom: CGFloat, _ fitsWindow: Bool) -> Void)?
    var onClose: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let imageView = ImageViewerImageView()
    private(set) var fitsWindow = true

    init() {
        super.init(frame: .zero)
        let clip = ImageViewerClipView()
        clip.drawsBackground = false
        clip.onClickBeside = { [weak self] in self?.onClose?() }
        contentView = clip
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerKnobStyle = .light
        allowsMagnification = true
        maxMagnification = Self.steps.last ?? 8
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.onDoubleClick = { [weak self] point in
            guard let self else { return }
            zoom(fitsWindow && fitMagnification < 1 ? .actualSize : fitsWindow ? .in : .fit, at: point)
        }
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: NSImage, name: String) {
        // An image view is read through its cell.
        imageView.cell?.setAccessibilityLabel(name)
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        fitsWindow = true
        needsLayout = true
    }

    /// The zoom that fits the whole image in the view, at most its own size.
    var fitMagnification: CGFloat {
        let size = imageView.frame.size
        let available = contentView.frame.size
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / size.width, available.height / size.height)
    }

    // The scroll view tiles when its size changes, and lays out after `show`.
    override func tile() {
        super.tile()
        refit()
    }

    override func layout() {
        super.layout()
        refit()
    }

    private func refit() {
        minMagnification = min(fitMagnification, Self.steps[0])
        if fitsWindow, abs(magnification - fitMagnification) > 0.0001 { magnification = fitMagnification }
        report()
    }

    func zoom(_ step: Zoom) {
        zoom(step, at: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }

    /// Zooms with `point` (in the image's coordinates) held where it is.
    private func zoom(_ step: Zoom, at point: NSPoint) {
        let fit = fitMagnification
        let target: CGFloat = switch step {
        case .fit: fit
        case .actualSize: 1
        case .in: Self.steps.first { $0 > magnification + 0.001 } ?? maxMagnification
        case .out: Self.steps.last { $0 < magnification - 0.001 } ?? minMagnification
        }
        fitsWindow = step == .fit || target <= fit + 0.001
        setMagnification(fitsWindow ? fit : target, centeredAt: point)
        report()
    }

    override func magnify(with event: NSEvent) {
        fitsWindow = false
        super.magnify(with: event)
        report()
    }

    override func smartMagnify(with event: NSEvent) {
        imageView.onDoubleClick?(imageView.convert(event.locationInWindow, from: nil))
    }

    @objc private func liveMagnifyEnded() {
        // A pinch back to the fitted size or below follows the window again.
        if magnification <= fitMagnification + 0.001 {
            fitsWindow = true
            magnification = fitMagnification
        }
        report()
    }

    private var reported: (zoom: CGFloat, fitsWindow: Bool)?

    /// Tells the viewer the zoom once it changed, after the layout that changed it.
    private func report() {
        let now = (zoom: magnification, fitsWindow: fitsWindow)
        guard reported.map({ abs($0.zoom - now.zoom) > 0.0001 || $0.fitsWindow != now.fitsWindow }) ?? true else { return }
        reported = now
        Task { @MainActor [weak self] in self?.onZoom?(now.zoom, now.fitsWindow) }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    // A scroll view hands the keyboard on to its document, which the image view declines; the
    // canvas keeps it itself.
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeKeyboard()
    }

    /// Takes the keyboard from the composer behind, once the view is in its window.
    func takeKeyboard() {
        Task { @MainActor [weak self] in
            guard let self, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        zoom(forKey: event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if zoom(forKey: event) { return }
        let key = MacShortcutEvent(event)
        switch [MacShortcut.imageClose, .imagePrevious, .imageNext].first(where: { $0.matches(key) }) {
        case .imageClose: onClose?()
        case .imagePrevious: onPrevious?()
        case .imageNext: onNext?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if MacShortcut.imageClose.isCustomized, let event = NSApp.currentEvent, event.type == .keyDown,
           !MacShortcut.imageClose.matches(MacShortcutEvent(event)) { return }
        onClose?()
    }

    // MARK: Context menu

    /// Passes the right-click menu through to the image view, so a click on the scroll view's margin
    /// still opens the image's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        imageView.menu(for: event)
    }

    /// The right-click menu the canvas would build now, for tests.
    var contextMenu: NSMenu? { imageView.makeContextMenu() }

    /// The closures the image's right-click menu runs. `showInFinder` and `markUp` are nil when the
    /// image is not a file on disk (the Finder entry) or when the request did not offer markup.
    func setContextActions(copyImage: @escaping () -> Void,
                           saveImage: @escaping () -> Void,
                           showInFinder: (() -> Void)?,
                           zoomActualSize: @escaping () -> Void,
                           zoomFit: @escaping () -> Void,
                           markUp: (() -> Void)?,
                           canShowMenu: @escaping () -> Bool) {
        imageView.copyImage = copyImage
        imageView.saveImage = saveImage
        imageView.showInFinder = showInFinder
        imageView.zoomActualSize = zoomActualSize
        imageView.zoomFit = zoomFit
        imageView.markUpImage = markUp
        imageView.canShowMenu = canShowMenu
    }

    /// ⌘+ (or ⌘=) and ⌘− zoom in steps and ⌘0 fits again, as in the Codex app, wherever the keyboard is
    /// in the window while the viewer shows.
    private func zoom(forKey event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let key = MacShortcutEvent(event)
        switch [MacShortcut.imageZoomIn, .imageZoomOut, .imageFit].first(where: { $0.matches(key) }) {
        case .imageZoomIn: zoom(.in)
        case .imageZoomOut: zoom(.out)
        case .imageFit: zoom(.fit)
        default: return false
        }
        return true
    }
}

/// Keeps the image in the middle of the view while it is smaller than the view, and takes the
/// clicks beside it.
private final class ImageViewerClipView: NSClipView {
    var onClickBeside: (() -> Void)?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return bounds }
        if bounds.width > document.width { bounds.origin.x = (document.width - bounds.width) / 2 }
        if bounds.height > document.height { bounds.origin.y = (document.height - bounds.height) / 2 }
        return bounds
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click opens the context menu through `menuForEvent:`, as in the Codex app; the click
        // itself must not close the viewer.
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        // The image takes its own clicks, so this one landed beside it.
        onClickBeside?()
    }
}

private final class ImageViewerImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?

    // The right-click menu's actions. `showInFinder` and `markUpImage` are nil when the image is not
    // a file on disk or when the request did not offer markup; those items are left out of the menu.
    var copyImage: (() -> Void)?
    var saveImage: (() -> Void)?
    var showInFinder: (() -> Void)?
    var zoomActualSize: (() -> Void)?
    var zoomFit: (() -> Void)?
    var markUpImage: (() -> Void)?
    var canShowMenu: () -> Bool = { false }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Control-click opens the context menu through `menuForEvent:` on the way up; the view's own
        // double-click path must not swallow the event.
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 { onDoubleClick?(convert(event.locationInWindow, from: nil)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu()
    }

    /// The right-click menu for the image: Copy and Save; Show in Finder for a file on disk;
    /// Actual Size and Zoom to Fit; and Mark Up when the request offered it. Returns nil before an
    /// image has been loaded, so the menu does not open over the loading or unavailable placeholder.
    func makeContextMenu() -> NSMenu? {
        guard canShowMenu() else { return nil }
        let menu = NSMenu()
        add(to: menu, title: L10n.string("Copy Image"), action: #selector(runCopyImage))
        add(to: menu, title: L10n.string("Save Image…"), action: #selector(runSaveImage))
        if showInFinder != nil {
            add(to: menu, title: L10n.string("Show in Finder"), action: #selector(runShowInFinder))
        }
        menu.addItem(.separator())
        add(to: menu, title: L10n.string("Actual Size"), action: #selector(runActualSize))
        add(to: menu, title: L10n.string("Zoom to Fit"), action: #selector(runZoomFit))
        if markUpImage != nil {
            menu.addItem(.separator())
            add(to: menu, title: L10n.string("Mark Up"), action: #selector(runMarkUp))
        }
        return menu
    }

    private func add(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func runCopyImage() { copyImage?() }
    @objc private func runSaveImage() { saveImage?() }
    @objc private func runShowInFinder() { showInFinder?() }
    @objc private func runActualSize() { zoomActualSize?() }
    @objc private func runZoomFit() { zoomFit?() }
    @objc private func runMarkUp() { markUpImage?() }
}
