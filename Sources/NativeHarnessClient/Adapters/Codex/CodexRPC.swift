import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // JSON decoding converts no JSON type into another, so this order only decides how
        // many attempts fail, each building an error, before one succeeds. Strings and objects,
        // most of every provider frame, go first; a boolean is still tried before an integer
        // and an integer before a floating-point number.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

struct CodexRPCRequest: Codable, Equatable, Sendable {
    let id: CodexRPCID
    let method: String
    let params: JSONValue

    init(id: Int64, method: String, params: JSONValue) {
        self.id = .integer(id)
        self.method = method
        self.params = params
    }
}

enum CodexRPCID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RPC IDs must be an integer or string"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

struct CodexRPCIncomingMessage: Codable, Equatable, Sendable {
    let id: CodexRPCID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: JSONValue?
    let emittedAtMs: Int64?
}

extension CodexRPCIncomingMessage {
    /// The envelope fields are read strictly; `emittedAtMs` is only a diagnostic timestamp, so a
    /// runtime that sends it as a fraction or a string still has its frame read rather than lost.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(CodexRPCID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
        emittedAtMs = switch (try? container.decodeIfPresent(JSONValue.self, forKey: .emittedAtMs)) ?? nil {
        case let .integer(value)?: value
        case let .number(value)? where value.isFinite && abs(value) < 9.0e18: Int64(value)
        default: nil
        }
    }
}

struct CodexRPCRequestFailure: LocalizedError, Equatable, Sendable {
    let requestID: Int64
    let payload: JSONValue

    var errorDescription: String? {
        let message = (payload["message"]?.stringValue ?? payload.stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.flatMap { $0.isEmpty ? nil : $0 }
            ?? L10n.format("%@ could not complete the request", "Codex")
    }

    /// Codex lets one App Server write a thread at a time (`$CODEX_HOME/thread-writer-locks`).
    /// While another one has the thread open, such as the Codex app's, `thread/resume` answers
    /// `-32600 "thread <id> already has an active writer"` (0.157.1 and 0.163.0 alike).
    var isThreadWriterConflict: Bool {
        payload["message"]?.stringValue?.contains("already has an active writer") == true
    }

    /// `turn/interrupt` reached the App Server after the turn ended: `-32600 "no active turn to
    /// interrupt"` (0.169.0). A turn ID that names another running turn is answered differently
    /// ("expected active turn id … but found …") and stays a failure.
    var isNoActiveTurn: Bool {
        payload["message"]?.stringValue?.hasPrefix("no active turn") == true
    }

    /// `thread/archive` found no open thread by that ID: `-32600 "no rollout found for thread id
    /// <id>"`, for a thread already archived and for one that is gone alike (0.172.0).
    var isNoOpenThread: Bool {
        payload["message"]?.stringValue?.hasPrefix("no rollout found for thread id") == true
    }

    /// `thread/unarchive` found no archived thread by that ID: `-32600 "no archived rollout found for
    /// thread id <id>"`, for a thread that is open and for one that is gone alike (0.172.0).
    var isNoArchivedThread: Bool {
        payload["message"]?.stringValue?.hasPrefix("no archived rollout found for thread id") == true
    }
}

/// A Codex thread that another App Server is writing, such as the one the ChatGPT app runs, cannot
/// be continued here until that one lets it go; quitting that app always does. The notice is the
/// first line and the provider's own words follow it in the details.
struct CodexThreadHeldElsewhere: LocalizedError, Equatable, Sendable {
    let providerMessage: String

    var errorDescription: String? {
        let notice = L10n.string(
            "This conversation is open in another Codex app, such as ChatGPT, so it cannot continue here. Quit that app, then send again."
        )
        return providerMessage.isEmpty ? notice : "\(notice)\n\n\(providerMessage)"
    }
}

struct CodexRPCResponse: Codable, Equatable, Sendable {
    let id: CodexRPCID
    let result: JSONValue
}

struct CodexRPCErrorResponse: Codable, Equatable, Sendable {
    let id: CodexRPCID
    let error: JSONValue

    init(id: CodexRPCID, code: Int64, message: String, data: JSONValue? = nil) {
        self.id = id
        var payload: [String: JSONValue] = [
            "code": .integer(code),
            "message": .string(message)
        ]
        if let data {
            payload["data"] = data
        }
        error = .object(payload)
    }
}

struct CodexRPCCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func encodeLine(_ request: CodexRPCRequest) throws -> Data {
        var data = try encoder.encode(request)
        data.append(0x0A)
        return data
    }

    func encodeLine(_ response: CodexRPCResponse) throws -> Data {
        var data = try encoder.encode(response)
        data.append(0x0A)
        return data
    }

    func encodeLine(_ response: CodexRPCErrorResponse) throws -> Data {
        var data = try encoder.encode(response)
        data.append(0x0A)
        return data
    }

    func decodeLine(_ data: Data) throws -> CodexRPCIncomingMessage {
        let trimmed = data.drop(while: { $0 == 0x0A || $0 == 0x0D })
        return try decoder.decode(CodexRPCIncomingMessage.self, from: Data(trimmed))
    }
}
