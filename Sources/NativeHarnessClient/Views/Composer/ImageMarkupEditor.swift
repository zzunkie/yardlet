import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Marking up an image attached to the composer: arrows, rectangles and freehand
// lines over the image, saved as a copy that takes the attachment's place, as the Codex app's image
// markup saves `markup.png` beside the original (`ImageMarkupEditor`, `exportImageMarkup`). macOS's
// own Markup is Quick Look's, which apps cannot ask for on macOS: the editing mode is iOS's
// `QLPreviewController` alone, and `QLPreviewPanel` keeps its markup to Finder's private delegate.

/// One mark, in the image's pixels with the origin at the top left.
struct ImageMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
    }

    enum Color: String, CaseIterable, Sendable {
        case red, yellow, blue, black

        var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
            switch self {
            case .red: (0.93, 0.19, 0.18)
            case .yellow: (0.98, 0.78, 0.10)
            case .blue: (0.10, 0.46, 0.95)
            case .black: (0.08, 0.08, 0.08)
            }
        }

        var name: String {
            switch self {
            case .red: L10n.string("Red")
            case .yellow: L10n.string("Yellow")
            case .blue: L10n.string("Blue")
            case .black: L10n.string("Black")
            }
        }
    }

    var kind: Kind
    var color: Color
    var lineWidth: CGFloat
}

/// What the editor marks: the image's pixels, the marks so far, and the tool and color the next one takes.
@MainActor
@Observable
final class ImageMarkupModel {
    enum Tool: String, CaseIterable, Sendable {
        case arrow, rectangle, pen

        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .pen: "scribble"
            }
        }

        var name: String {
            switch self {
            case .arrow: L10n.string("Arrow")
            case .rectangle: L10n.string("Rectangle")
            case .pen: L10n.string("Pen")
            }
        }
    }

    let image: CGImage
    private(set) var marks: [ImageMark] = []
    /// The mark being drawn, until the drag ends.
    private(set) var drawing: ImageMark?
    var tool: Tool = .arrow
    var color: ImageMark.Color = .red

    init(image: CGImage) {
        self.image = image
    }

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    /// Lines thick enough to see on a screenshot of any size, in the image's pixels.
    var lineWidth: CGFloat { max(3, (min(size.width, size.height) / 160).rounded()) }

    func drag(from start: CGPoint, to point: CGPoint) {
        let start = clamped(start), point = clamped(point)
        switch tool {
        case .arrow: drawing = ImageMark(kind: .arrow(from: start, to: point), color: color, lineWidth: lineWidth)
        case .rectangle: drawing = ImageMark(kind: .rectangle(from: start, to: point), color: color, lineWidth: lineWidth)
        case .pen:
            if case .pen(var points)? = drawing?.kind {
                points.append(point)
                drawing?.kind = .pen(points)
            } else {
                drawing = ImageMark(kind: .pen([start, point]), color: color, lineWidth: lineWidth)
            }
        }
    }

    /// The drag ended: a mark too small to see (a click) is not kept.
    func endDrag() {
        defer { drawing = nil }
        guard let drawing, Self.isVisible(drawing, lineWidth: lineWidth) else { return }
        marks.append(drawing)
    }

    func undo() {
        if !marks.isEmpty { marks.removeLast() }
    }

    func add(_ mark: ImageMark) {
        marks.append(mark)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    private static func isVisible(_ mark: ImageMark, lineWidth: CGFloat) -> Bool {
        switch mark.kind {
        case let .arrow(from, to), let .rectangle(from, to): hypot(to.x - from.x, to.y - from.y) >= lineWidth * 2
        case let .pen(points): points.count > 1
        }
    }
}

/// Draws marks over an image, on screen and into the saved copy alike.
enum ImageMarkupRenderer {
    /// The marks in a context whose user space is the image's pixels with the origin at the top left.
    static func draw(_ marks: [ImageMark], in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            let (red, green, blue) = mark.color.components
            context.setStrokeColor(red: red, green: green, blue: blue, alpha: 1)
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.setLineWidth(mark.lineWidth)
            switch mark.kind {
            case let .arrow(from, to):
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = max(mark.lineWidth * 4, 12)
                // The shaft stops inside the head, so its round cap does not show past the point.
                let shaftEnd = CGPoint(x: to.x - cos(angle) * head * 0.6, y: to.y - sin(angle) * head * 0.6)
                context.move(to: from)
                context.addLine(to: shaftEnd)
                context.strokePath()
                context.move(to: to)
                context.addLine(to: CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7)))
                context.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7)))
                context.closePath()
                context.fillPath()
            case let .rectangle(from, to):
                context.stroke(CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                                      width: abs(to.x - from.x), height: abs(to.y - from.y)))
            case let .pen(points):
                guard let first = points.first else { continue }
                context.move(to: first)
                points.dropFirst().forEach { context.addLine(to: $0) }
                context.strokePath()
            }
        }
    }

    /// The image with its marks, as PNG data at the image's own size.
    static func png(_ image: CGImage, marks: [ImageMark]) -> Data? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Marks are kept from the top left, as the screen shows them.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(marks, in: context)
        guard let marked = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, marked, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The image a file holds, upright as it is shown (a photo's orientation applied), at its full size.
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary)
    }

    /// Saves the marked copy as a private file of its own, as a pasted image is kept; the original stays.
    static func saveCopy(_ image: CGImage, marks: [ImageMark]) -> URL? {
        guard let data = png(image, marks: marks) else { return nil }
        return try? ComposerAttachmentIntake.storePastedImage(data, fileExtension: "png")
    }
}

/// Opens the editor for an attached image and hands back its marked copy. A sheet over the composer's
/// window; DEBUG QA replaces it so that nothing opens on the person's screen.
@MainActor
enum ImageMarkupPresenter {
    static var open: @MainActor (_ image: URL, _ window: NSWindow?, _ saved: @escaping (URL) -> Void) -> Void = presentSheet

    private static func presentSheet(_ url: URL, over window: NSWindow?, saved: @escaping (URL) -> Void) {
        guard let window = window ?? NSApp.keyWindow, let image = ImageMarkupRenderer.image(at: url) else {
            NSSound.beep()
            return
        }
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: ImageMarkupEditor.windowSize(for: image)),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let model = ImageMarkupModel(image: image)
        sheet.contentViewController = NSHostingController(rootView: ImageMarkupEditor(model: model) { result in
            guard sheet.sheetParent != nil else { return }
            window.endSheet(sheet)
            guard let marks = result, !marks.isEmpty else { return }
            Task {
                let copy = await Task.detached(priority: .userInitiated) { ImageMarkupRenderer.saveCopy(image, marks: marks) }.value
                if let copy { saved(copy) } else { NSSound.beep() }
            }
        })
        window.beginSheet(sheet)
    }
}

/// The editor: the image fitted to the sheet with its marks, the tools and colors above it, Undo,
/// Cancel and Done. Escape cancels; Return is Done.
struct ImageMarkupEditor: View {
    let model: ImageMarkupModel
    /// The marks on Done, nil on Cancel.
    let finish: ([ImageMark]?) -> Void

    @State private var dragStart: CGPoint?

    static func windowSize(for image: CGImage) -> NSSize {
        let scale = min(1, 880 / CGFloat(image.width), 620 / CGFloat(image.height))
        return NSSize(width: max(480, CGFloat(image.width) * scale + 32), height: max(320, CGFloat(image.height) * scale + 84))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { proxy in
                let fit = min(proxy.size.width / model.size.width, proxy.size.height / model.size.height, 1)
                let shown = CGSize(width: model.size.width * fit, height: model.size.height * fit)
                canvas(scale: fit)
                    .frame(width: shown.width, height: shown.height)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let start = CGPoint(x: value.startLocation.x / fit, y: value.startLocation.y / fit)
                            model.drag(from: start, to: CGPoint(x: value.location.x / fit, y: value.location.y / fit))
                        }
                        .onEnded { _ in model.endDrag() })
                    .accessibilityElement()
                    .accessibilityLabel(L10n.string("Image to mark up"))
                    .accessibilityAddTraits(.isImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
        .background(ParityTheme.canvas)
    }

    /// The image and its marks, drawn by the renderer the saved copy uses.
    private func canvas(scale: CGFloat) -> some View {
        Canvas { context, size in
            context.draw(Image(decorative: model.image, scale: 1), in: CGRect(origin: .zero, size: size))
            context.withCGContext { cg in
                cg.scaleBy(x: scale, y: scale)
                ImageMarkupRenderer.draw(model.marks + (model.drawing.map { [$0] } ?? []), in: cg)
            }
        }
        .overlay { Rectangle().stroke(ParityTheme.separator) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker(L10n.string("Tool"), selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
                ForEach(ImageMarkupModel.Tool.allCases, id: \.self) { tool in
                    Image(systemName: tool.symbol).help(tool.name).accessibilityLabel(tool.name).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 6) {
                ForEach(ImageMark.Color.allCases, id: \.self) { color in
                    Button { model.color = color } label: {
                        Circle()
                            .fill(SwiftUI.Color(red: color.components.red, green: color.components.green, blue: color.components.blue))
                            .frame(width: 16, height: 16)
                            .overlay { Circle().stroke(Color.primary.opacity(model.color == color ? 0.9 : 0.15),
                                                       lineWidth: model.color == color ? 2 : 1) }
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .help(color.name)
                    .accessibilityLabel(color.name)
                    .accessibilityAddTraits(model.color == color ? .isSelected : [])
                }
            }
            ParityIconButton(systemName: "arrow.uturn.backward", help: L10n.string("Undo")) { model.undo() }
                .keyboardShortcut(MacShortcut.markupUndo.binding)
                .disabled(model.marks.isEmpty)
            Spacer(minLength: 8)
            Button(L10n.string("Cancel")) { finish(nil) }
                .keyboardShortcut(MacShortcut.dismiss.binding)
            Button(L10n.string("Done")) { finish(model.marks) }
                .keyboardShortcut(MacShortcut.confirmDialog.binding)
                .parityProminentButton()
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }
}
