import Foundation
import UWP
@preconcurrency import WindowsFoundation
import WinUI

/// The pictures in a conversation as the Mac draws them (`SentImageAttachments`, `ConversationToolImages`): a sent
/// message's images as squares above its bubble, and the pictures a call looked at, made or returned
/// (`ConversationTool.pictures`), small at the end of its folded line and whole when the line opens. Each is decoded
/// off the window's thread, a file as the app reads its own pictures (`PackagedImage`) and bytes from memory. A picture
/// that cannot be read reads as its name, and a line whose pictures cannot be read reads as its words alone. A web
/// image is never fetched. The Mac opens a picture over its window on a click; here it shows its name on hover.
@MainActor
enum ConversationImages {
    /// A sent message's images, five to a row against the right: an 80-point square for each that can be read, filled
    /// from its middle, with 8-point corners and a ring, and its name otherwise.
    static func sent(_ images: [TranscriptImageAttachment]) -> UIElement {
        let pictures = images.map { image in
            ConversationPicture(key: image.url?.absoluteString ?? "", name: image.name ?? L10n.string("Image"),
                                source: image.url.map { .url($0) })
        }
        let side = 80.0
        let tiles: [UIElement] = pictures.map { picture in
            guard let bitmap = bitmap(for: picture, decodeHeight: Int32(side * 2)) else { return nameChip(picture.name) }
            let image = Image()
            image.source = bitmap
            image.stretch = .uniformToFill
            let frame = framed(image, corner: 8, name: picture.name)
            frame.width = side
            frame.height = side
            return frame
        }
        let rows = StackPanel()
        rows.spacing = 6
        rows.horizontalAlignment = .right
        for start in stride(from: 0, to: tiles.count, by: 5) {
            let row = ConversationStyle.row(Array(tiles[start..<min(start + 5, tiles.count)]), spacing: 6)
            row.horizontalAlignment = .right
            rows.children.append(row)
        }
        return rows
    }

    /// A call's pictures at the end of its folded line (the Claude app's `size: "sm"`): the last three that can be
    /// read, each as tall as the line and at most 44 points wide, filled from its middle, with the count of the earlier
    /// ones before them. Nil when none can be read.
    static func thumbnails(_ pictures: [ConversationPicture]) -> FrameworkElement? {
        let shown = pictures.filter(\.canShow)
        guard !shown.isEmpty else { return nil }
        var pieces: [UIElement] = []
        let kept = shown.suffix(3)
        if shown.count > kept.count {
            let more = ConversationStyle.text("+\(shown.count - kept.count)", size: ConversationStyle.captionSize,
                                              tone: .tertiary, selectable: false, wraps: false)
            more.verticalAlignment = .center
            more.margin = Thickness(left: 0, top: 0, right: 4, bottom: 0)
            pieces.append(more)
        }
        for picture in kept {
            guard let bitmap = bitmap(for: picture, decodeHeight: 48) else { continue }
            let image = Image()
            image.source = bitmap
            image.stretch = .uniformToFill
            image.height = 24
            image.minWidth = 12
            image.maxWidth = 44
            pieces.append(framed(image, corner: 4, name: picture.name))
        }
        let row = ConversationStyle.row(pieces, spacing: 4)
        row.verticalAlignment = .center
        return row
    }

    /// A call's pictures when its line opens (the Claude app's `size: "lg"`): each whole and no larger than it is, as
    /// wide as the column allows and at most 320 points high, or 240 among several, one under another. Nil for none.
    static func details(_ pictures: [ConversationPicture]) -> UIElement? {
        guard !pictures.isEmpty else { return nil }
        let stack = StackPanel()
        stack.spacing = 8
        for picture in pictures { stack.children.append(tile(picture, isOneOfSeveral: pictures.count > 1)) }
        return stack
    }

    /// One picture of an opened line, or its name where it cannot be read.
    static func tile(_ picture: ConversationPicture, isOneOfSeveral: Bool) -> UIElement {
        guard let bitmap = bitmap(for: picture, decodeHeight: nil) else { return nameChip(picture.name) }
        let image = Image()
        image.source = bitmap
        image.stretch = .uniform
        image.maxHeight = isOneOfSeveral ? 240 : 320
        // Scaled down to fit, never up: once read, the picture is at most as wide as it is.
        image.imageOpened.addHandler { sender, _ in
            guard let shown = sender as? Image, bitmap.pixelWidth > 0 else { return }
            shown.maxWidth = Double(bitmap.pixelWidth)
        }
        let frame = framed(image, corner: 8, name: picture.name)
        frame.horizontalAlignment = .left
        return frame
    }

    // MARK: - Pieces

    /// A picture in a ring with rounded corners, on the subtle fill while it is read, named for assistive apps and on
    /// hover.
    private static func framed(_ image: Image, corner: Double, name: String) -> Border {
        let frame = Border()
        frame.cornerRadius = ConversationStyle.corners(corner)
        frame.background = WindowsTheme.subtleFill.brush
        frame.borderBrush = WindowsTheme.separator.brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.child = image
        try? AutomationProperties.setName(frame, name)
        try? ToolTipService.setToolTip(frame, name)
        return frame
    }

    /// A picture that cannot be shown, by its name beside a picture mark (the Mac's `SentImageNameChip`).
    static func nameChip(_ name: String) -> UIElement {
        let words = ConversationStyle.text(name, size: ConversationStyle.captionSize, tone: .secondary, wraps: false)
        words.maxWidth = 200
        let chip = Border()
        chip.background = WindowsTheme.subtleFill.brush
        chip.cornerRadius = ConversationStyle.corners(12)
        chip.padding = Thickness(left: 8, top: 0, right: 8, bottom: 0)
        chip.height = 24
        chip.horizontalAlignment = .right
        let row = ConversationStyle.row([ConversationStyle.icon(ConversationStyle.Glyph.picture, size: 12), words], spacing: 4)
        row.verticalAlignment = .center
        chip.child = row
        try? AutomationProperties.setName(chip, name)
        try? ToolTipService.setToolTip(chip, name)
        return chip
    }

    /// The picture's bitmap, decoded at most `decodeHeight` pixels high where one is given; nil for a picture that
    /// cannot be read: a file that is gone, a web image, or one whose bytes were not kept.
    private static func bitmap(for picture: ConversationPicture, decodeHeight: Int32?) -> BitmapImage? {
        if let file = picture.file {
            guard picture.canShow else { return nil }
            if let decodeHeight { return PackagedImage.thumbnail(of: file, height: decodeHeight) }
            let bitmap = BitmapImage()
            Task { await read(file, into: bitmap) }
            return bitmap
        }
        guard let data = picture.inlineData, !data.isEmpty else { return nil }
        let bitmap = BitmapImage()
        if let decodeHeight { bitmap.decodePixelHeight = decodeHeight }
        Task { await read(data, into: bitmap) }
        return bitmap
    }

    private static func read(_ file: URL, into bitmap: BitmapImage) async {
        do {
            guard let opened = try await StorageFile.getFileFromPathAsync(file.nativePath)?.get(),
                  let stream = try await opened.openAsync(.read)?.get() else { return }
            try await bitmap.setSourceAsync(stream)?.get()
        } catch {
            QAEventLog.shared.write("image not read: \(file.lastPathComponent): \(error)")
        }
    }

    /// Bytes go to the bitmap through a stream in memory, as XAML reads a picture only from a stream.
    private static func read(_ data: Data, into bitmap: BitmapImage) async {
        do {
            let stream = InMemoryRandomAccessStream()
            let writer = DataWriter(try stream.getOutputStreamAt(0))
            try writer.writeBytes([UInt8](data))
            _ = try await writer.storeAsync()?.get()
            _ = try writer.detachStream()
            try stream.seek(0)
            try await bitmap.setSourceAsync(stream)?.get()
        } catch {
            QAEventLog.shared.write("image not read: \(data.count) bytes: \(error)")
        }
    }
}

private extension ConversationPicture {
    /// Whether the picture can be drawn: a file that is there, or bytes it carries.
    var canShow: Bool {
        if let file { return (try? file.checkResourceIsReachable()) == true }
        return inlineData?.isEmpty == false
    }
}
