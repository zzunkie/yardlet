import AppKit
import Markdown
import SwiftUI
import UniformTypeIdentifiers

// The pictures an answer's Markdown shows (`![alt](source)`), drawn where they stand between its words, as
// the Codex and Claude apps draw an image an answer names. One picture is as wide as the conversation allows
// and no larger than its own size; several in a row wrap, each at most 240 pt tall. A click opens the
// message's pictures over the window (`openImageViewer`).
//
// Only an image on this Mac is drawn: a file (a path relative to the task's folder, absolute, `~/…` or a
// `file:` address) or an inline `data:` image. Its size is read from its header first, so it takes its place
// at once; its bitmap is decoded off the main thread while it is on screen and let go once it leaves, so a
// long conversation holds only the pictures in view (and `TranscriptImageThumbnails`' bounded cache). A web
// address is never fetched: the picture shows as a link to it, as a video does to its file.

/// Where a picture's source leads, resolved as the window resolves a link (`TranscriptInlineContent.resolved`).
enum TranscriptPictureTarget: Equatable {
    /// An image file or an inline `data:` image, drawn in place.
    case image(URL)
    /// A file that is not an image (a video, a document): a link to it.
    case file(URL)
    /// A web address: a link to it, never fetched.
    case web(URL)
    /// Nothing this Mac can show.
    case none

    init(_ source: String, workspace: URL?) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("data:") {
            guard trimmed.lowercased().hasPrefix("data:image/"), let url = URL(string: trimmed) else { self = .none; return }
            self = .image(url)
            return
        }
        let escaped = trimmed.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        guard let encoded = escaped.addingPercentEncoding(withAllowedCharacters: Self.linkCharacters),
              let url = URL(string: encoded) else { self = .none; return }
        let file: URL
        switch url.scheme?.lowercased() {
        case "http", "https":
            self = .web(url)
            return
        case "file":
            guard ["", "localhost"].contains(url.host()?.lowercased() ?? "") else { self = .none; return }
            file = URL(filePath: url.path(percentEncoded: false))
        case nil:
            let path = url.path(percentEncoded: false)
            if PathRules.current.isAbsolute(path) {
                file = URL(filePath: path)
            } else if path.hasPrefix("~/") {
                file = FileManager.default.homeDirectoryForCurrentUser.appending(path: String(path.dropFirst(2)))
            } else if let workspace, !path.isEmpty {
                file = workspace.appending(path: path)
            } else {
                self = .none
                return
            }
        default:
            self = .none
            return
        }
        let standardized = file.standardizedFileURL
        let type = UTType(filenameExtension: standardized.pathExtension)
        self = type?.conforms(to: .image) == true ? .image(standardized) : .file(standardized)
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    private static let linkCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
}

/// One block of an answer's pictures.
struct TranscriptMarkdownPictures: View {
    let pictures: [TranscriptMarkdownPicture]
    /// The whole message, whose pictures a click opens together.
    let fullSource: String
    let dialect: TranscriptMarkdownDialect

    @Environment(\.transcriptWorkspaceURL) private var workspaceURL
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openImageViewer) private var openImageViewer
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing

    /// A picture alone, as tall as this at most: a phone screenshot stays within a screenful.
    static let maximumHeight: CGFloat = 480
    /// Each of several pictures in a row.
    static let maximumHeightOfSeveral: CGFloat = 240
    /// Several pictures share a row while they stay at least this tall; past that the row wraps.
    static let minimumRowHeight: CGFloat = 140

    var body: some View {
        let isOneOfSeveral = pictures.count > 1
        TranscriptPictureRows(spacing: 8,
                              maximumHeight: (isOneOfSeveral ? Self.maximumHeightOfSeveral : Self.maximumHeight) * interfaceScale,
                              minimumHeight: Self.minimumRowHeight * interfaceScale) {
            ForEach(Array(pictures.enumerated()), id: \.offset) { _, picture in
                let target = TranscriptPictureTarget(picture.source, workspace: workspaceURL)
                TranscriptMarkdownPictureView(picture: picture, target: target,
                                              isOneOfSeveral: isOneOfSeveral) { url in open(url) }
                    .layoutValue(key: TranscriptPictureRows.Scales.self, value: target.isImage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the message's images over the window at `url`'s.
    private func open(_ url: URL) {
        let items = Self.images(in: fullSource, dialect: dialect, workspace: workspaceURL)
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        pauseFollowing()
        openImageViewer(ImageViewerRequest(
            items: items.map { ImageViewerItem(name: $0.name, source: .url($0.url)) }, index: index))
    }

    /// The images a message's Markdown shows, in order, that this Mac can read.
    static func images(in source: String, dialect: TranscriptMarkdownDialect, workspace: URL?) -> [(name: String, url: URL)] {
        var found: [(name: String, url: URL)] = []
        func visit(_ blocks: [TranscriptMarkdownBlock]) {
            for block in blocks {
                switch block {
                case let .pictures(pictures):
                    for picture in pictures {
                        guard case let .image(url) = TranscriptPictureTarget(picture.source, workspace: workspace),
                              TranscriptImageThumbnails.shared.cachedPreview(for: url, size: .inline).map(\.isImage) ?? true
                        else { continue }
                        found.append((picture.label, url))
                    }
                case let .blockQuote(inner), let .details(_, _, inner): visit(inner)
                case let .unorderedList(items, _), let .orderedList(_, items, _): items.forEach { visit($0.blocks) }
                default: break
                }
            }
        }
        visit(TranscriptMarkdownDocument(source, dialect: dialect).blocks)
        return found
    }
}

extension TranscriptImageThumbnails.Preview {
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// One picture: the image in place, or a link chip for what is not drawn.
private struct TranscriptMarkdownPictureView: View {
    let picture: TranscriptMarkdownPicture
    let target: TranscriptPictureTarget
    let isOneOfSeveral: Bool
    let open: (URL) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.transcriptWorkspaceURL) private var workspaceURL

    /// The link around the picture, resolved as the window resolves a link in the message's words.
    private var link: URL? {
        guard let written = picture.link else { return nil }
        let content = TranscriptInlineContent(markup: Document(parsing: "[link](<\(written)>)"))
        return content.resolved(relativeTo: workspaceURL).runs.compactMap(\.link).first
    }

    var body: some View {
        switch target {
        case let .image(url):
            TranscriptPictureImage(url: url, name: picture.label, link: link, isOneOfSeveral: isOneOfSeveral) { open(url) }
        case let .file(url):
            TranscriptPictureLink(name: picture.label, systemImage: Self.symbol(for: url), help: url.path(percentEncoded: false)) {
                openURL(url)
            }
        case let .web(url):
            // A web picture inside a link (a badge) leads where the link does.
            let destination = link ?? url
            TranscriptPictureLink(name: picture.label, systemImage: "globe", detail: destination.host(),
                                  help: destination.absoluteString) {
                openURL(destination)
            }
        case .none:
            TranscriptPictureLink(name: picture.label, systemImage: "photo", help: picture.source, action: nil)
        }
    }

    private static func symbol(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true { return "play.rectangle" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        return "doc"
    }
}

/// An image file or inline image drawn at its own size within the conversation, and its name where it cannot be read.
private struct TranscriptPictureImage: View {
    let url: URL
    let name: String
    /// The link around the picture, which its menu offers.
    let link: URL?
    let isOneOfSeveral: Bool
    let open: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var read: (url: URL, size: CGSize?)?

    var body: some View {
        let maxHeight = (isOneOfSeveral ? TranscriptMarkdownPictures.maximumHeightOfSeveral
                                        : TranscriptMarkdownPictures.maximumHeight) * interfaceScale
        Group {
            switch size {
            case let size??:
                Button(action: open) {
                    ConversationToolImageFrame(pixelSize: size, maxHeight: maxHeight) {
                        TranscriptPictureBitmap(url: url, size: isOneOfSeveral ? .detail : .inline)
                    }
                    .background(ParityTheme.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityLabel(name)
                .help(L10n.string("View the image"))
                .contextMenu { menu }
            case .some(nil):
                TranscriptPictureLink(name: name, systemImage: "photo", help: url.isFileURL ? url.path(percentEncoded: false) : name,
                                      action: nil)
            case nil:
                RoundedRectangle(cornerRadius: 8)
                    .fill(ParityTheme.subtleFill)
                    .frame(width: min(maxHeight * 1.6, 360 * interfaceScale), height: maxHeight / 2)
                    .accessibilityLabel(name)
            }
        }
        .task(id: url) {
            guard size == nil else { return }
            let size = await TranscriptImageThumbnails.shared.pointSize(for: url)
            guard !Task.isCancelled else { return }
            read = (url, size)
        }
    }

    /// The image's size in points once read: nil while reading, `.some(nil)` when it is no image.
    private var size: CGSize?? {
        if let read, read.url == url { return read.size }
        return TranscriptImageThumbnails.shared.cachedPointSize(for: url).map { .some($0) }
    }

    @Environment(\.openURL) private var openURL

    @ViewBuilder
    private var menu: some View {
        Button(L10n.string("View the image"), action: open)
        if let link {
            Button(L10n.string("Open Link")) { openURL(link) }
        }
        Button(L10n.string("Copy Image")) {
            Task {
                guard let data = await TranscriptImageThumbnails.shared.originalData(for: url) else { return }
                ImageViewerModel.copy(data)
            }
        }
        if url.isFileURL {
            Button(L10n.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// A picture's bitmap, decoded while it is on screen and let go once it leaves.
private struct TranscriptPictureBitmap: NSViewRepresentable {
    let url: URL
    let size: TranscriptImageThumbnails.Size

    func makeNSView(context: Context) -> TranscriptPictureBitmapView {
        let view = TranscriptPictureBitmapView()
        view.show(url, size: size)
        return view
    }

    func updateNSView(_ view: TranscriptPictureBitmapView, context: Context) {
        view.show(url, size: size)
    }

    static func dismantleNSView(_ view: TranscriptPictureBitmapView, coordinator: ()) {
        view.release()
    }
}

final class TranscriptPictureBitmapView: ConversationOnScreenView {
    private var url: URL?
    private var size: TranscriptImageThumbnails.Size = .inline
    private var loading: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        onScreenChanged = { [weak self] isOnScreen in self?.update(isOnScreen: isOnScreen) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The button around the picture takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    /// Whether the picture's bitmap is drawn now.
    var isDrawn: Bool { layer?.contents != nil }

    func show(_ url: URL, size: TranscriptImageThumbnails.Size) {
        guard url != self.url || size != self.size else { return }
        self.url = url
        self.size = size
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
        guard let url, layer?.contents == nil, loading == nil else { return }
        if case let .image(image)? = TranscriptImageThumbnails.shared.cachedPreview(for: url, size: size) {
            layer?.contents = image
            return
        }
        let size = size
        loading = Task { [weak self] in
            let preview = await TranscriptImageThumbnails.shared.preview(for: url, size: size)
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.loading = nil
            if self.isOnScreen, case let .image(image) = preview { self.layer?.contents = image }
        }
    }
}

/// What a picture that is not drawn shows: its name, as a link to where it leads, or as a name alone when it leads
/// nowhere this Mac can open (a file that is not there).
private struct TranscriptPictureLink: View {
    let name: String
    let systemImage: String
    var detail: String? = nil
    let help: String
    let action: (() -> Void)?

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .parityPointer()
                .help(help)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isLink)
        } else {
            label
                .help(help)
                .accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        HStack(spacing: 6 * interfaceScale) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(action == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(ParityTheme.accent))
            if let detail {
                Text(detail)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13 * interfaceScale))
        .padding(.horizontal, 8 * interfaceScale)
        .frame(height: 28 * interfaceScale)
        .frame(maxWidth: 360 * interfaceScale, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Pictures in rows as wide as the message, each row's images at one height, so two screenshots side by side fill the
/// row together instead of wrapping one under the other. A row takes pictures while they stay at least
/// `minimumHeight` tall at the shared height, and is never taller than `maximumHeight` or than an image's own size.
/// What does not scale (a link to a file) keeps its own size.
struct TranscriptPictureRows: Layout {
    struct Scales: LayoutValueKey {
        static let defaultValue = false
    }

    var spacing: CGFloat
    var maximumHeight: CGFloat
    var minimumHeight: CGFloat

    private struct Item {
        let natural: CGSize
        let scales: Bool
        var aspect: CGFloat { natural.width / max(natural.height, 1) }
    }

    private struct Row {
        var items: [Int] = []
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let placed = place(subviews, width: width)
        let used = placed.map { $0.frame.maxX }.max() ?? 0
        let height = placed.map { $0.frame.maxY }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, placement) in place(subviews, width: bounds.width).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.frame.minX, y: bounds.minY + placement.frame.minY),
                                  proposal: ProposedViewSize(placement.frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [(frame: CGRect, index: Int)] {
        let items = subviews.map { subview in
            Item(natural: subview.sizeThatFits(.unspecified), scales: subview[Scales.self])
        }
        var rows: [Row] = []
        var row = Row()
        for index in items.indices {
            let candidate = row.items + [index]
            if row.items.isEmpty || height(of: candidate, items: items, width: width) >= minimumHeight {
                row.items = candidate
            } else {
                rows.append(row)
                row = Row(items: [index])
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        var frames: [(frame: CGRect, index: Int)] = []
        var y: CGFloat = 0
        for row in rows {
            let shared = height(of: row.items, items: items, width: width)
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for index in row.items {
                let item = items[index]
                let size: CGSize
                if item.scales {
                    // Never larger than its own size.
                    let height = min(shared, item.natural.height)
                    size = CGSize(width: (height * item.aspect).rounded(), height: height.rounded())
                } else {
                    size = CGSize(width: min(item.natural.width, width), height: item.natural.height)
                }
                frames.append((CGRect(origin: CGPoint(x: x, y: y), size: size), index))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + spacing
        }
        return frames.sorted { $0.index < $1.index }
    }

    /// The height the scaling pictures of `row` share to fill `width` together, at most `maximumHeight`.
    private func height(of row: [Int], items: [Item], width: CGFloat) -> CGFloat {
        let fixed = row.filter { !items[$0].scales }.reduce(0) { $0 + items[$1].natural.width }
        let aspects = row.filter { items[$0].scales }.reduce(0) { $0 + items[$1].aspect }
        let gaps = spacing * CGFloat(max(row.count - 1, 0))
        guard aspects > 0 else { return maximumHeight }
        return min(maximumHeight, max(0, width - fixed - gaps) / aspects)
    }
}
