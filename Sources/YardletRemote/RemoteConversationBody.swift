import Foundation

/// Optional bodies for the shared conversation cards in a full subscription (§15.31).
/// These contain display values only, never a host file URL or provider payload.
public struct RemoteConversationBody: Codable, Equatable, Sendable {
    public var output: String?
    public var detail: String?
    public var error: String?
    public var toolName: String?
    public var hasOutput: Bool?
    public var reasoning: String?
    public var command: String?
    public var headBytes: Int?
    public var background: Bool?
    public var files: [File]?
    public var mcp: [Block]?
    public init() {}

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var kind: String
        public var state: String
        public var preview: String
        public var additions: Int?
        public var deletions: Int?
        public var lines: [Line]
        public var hidden: Int
        public var firstChangedLine: Int?
        public init(path: String, kind: String, state: String, preview: String, additions: Int?, deletions: Int?,
                    lines: [Line], hidden: Int, firstChangedLine: Int?) {
            self.path = path; self.kind = kind; self.state = state; self.preview = preview
            self.additions = additions; self.deletions = deletions; self.lines = lines
            self.hidden = hidden; self.firstChangedLine = firstChangedLine
        }
    }
    public struct Line: Codable, Equatable, Sendable {
        public var kind: String
        public var number: Int?
        public var text: String
        public init(kind: String, number: Int?, text: String) {
            self.kind = kind; self.number = number; self.text = text
        }
    }
    public struct Block: Codable, Equatable, Sendable {
        public var kind: String
        public var text: String?
        public var image: RemoteImagePreview?
        public var name: String?
        public var title: String?
        public var uri: String?
        public var mimeType: String?
        public init(kind: String, text: String? = nil, image: RemoteImagePreview? = nil,
                    name: String? = nil, title: String? = nil, uri: String? = nil, mimeType: String? = nil) {
            self.kind = kind; self.text = text; self.image = image; self.name = name
            self.title = title; self.uri = uri; self.mimeType = mimeType
        }
    }
}


extension RemoteConversationBody {
    var estimatedBytes: Int {
        let textBytes = [output, detail, error, toolName, reasoning, command].reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        let fileBytes = (files ?? []).reduce(0) { total, file in
            total + file.path.utf8.count + 160 + file.lines.reduce(0) { $0 + $1.text.utf8.count + 64 }
        }
        let blockBytes = (mcp ?? []).reduce(0) { total, block in
            total + [block.text, block.name, block.title, block.uri, block.mimeType].reduce(0) { $0 + ($1?.utf8.count ?? 0) }
                + (block.image?.data.count ?? 0) * 4 / 3 + 160
        }
        return textBytes + fileBytes + blockBytes + 160
    }
}
