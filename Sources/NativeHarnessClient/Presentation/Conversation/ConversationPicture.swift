import Foundation

/// One picture of a call the conversation shows: a file or an inline `data:` image by its URL, or bytes an MCP result
/// returned. A web image is never fetched. The Mac (`ConversationToolImage`) and the Windows app
/// (`WinUI/ConversationImages.swift`) draw a call's pictures from these, in the same order.
struct ConversationPicture: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case url(URL)
        case data(Data)
    }

    /// Names the picture where its previews are kept: its URL, or the MCP block and its length.
    let key: String
    let name: String
    /// Nil for a picture whose bytes are not kept (an inline image restored from the reading cache).
    let source: Source?

    /// The picture's bytes where it carries them: an MCP result's, or an inline `data:` image's.
    var inlineData: Data? {
        switch source {
        case let .data(data)?: data
        case let .url(url)? where url.scheme == "data":
            InlineImageInput.image(from: url).flatMap { Data(base64Encoded: $0.base64Data) }
        default: nil
        }
    }

    /// The picture's file, where it is one.
    var file: URL? {
        if case let .url(url)? = source, url.isFileURL { return url }
        return nil
    }
}

extension ConversationTool {
    /// The call's pictures in order: the ones it looked at, made or returned, then its MCP result's.
    var pictures: [ConversationPicture] {
        let own = images.map { image in
            ConversationPicture(key: image.url?.absoluteString ?? "", name: image.name ?? L10n.string("Image"),
                                source: image.url.map { .url($0) })
        }
        return own + (mcpResult?.pictures ?? [])
    }
}

extension CodexMCPResultProjection {
    /// The result's images, in order.
    var pictures: [ConversationPicture] {
        blocks.compactMap { block in
            guard case let .image(id, data, _) = block else { return nil }
            return ConversationPicture(key: Self.previewKey(block: id, data: data),
                                       name: L10n.string("Tool result image"), source: .data(data))
        }
    }

    /// An image block's key in the preview cache: the block, which names the call, and its length.
    static func previewKey(block id: String, data: Data) -> String {
        "\(id):\(data.count)"
    }
}

extension ConversationItem {
    /// A call's pictures (`ConversationTool.pictures`); none for anything else.
    var toolPictures: [ConversationPicture] {
        if case let .tool(tool) = kind { tool.pictures } else { [] }
    }
}
