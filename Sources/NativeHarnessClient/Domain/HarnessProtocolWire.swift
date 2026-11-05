import Foundation

struct HarnessProtocolMethodID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let runtimeProbe = Self(rawValue: "runtime.probe")
    static let catalogRead = Self(rawValue: "catalog.read")
    static let sessionCreate = Self(rawValue: "session.create")
    static let sessionResume = Self(rawValue: "session.resume")
    static let sessionImport = Self(rawValue: "session.import")
    static let sessionSend = Self(rawValue: "session.send")
    static let sessionSteer = Self(rawValue: "session.steer")
    static let sessionInterrupt = Self(rawValue: "session.interrupt")
    static let permissionRespond = Self(rawValue: "permission.respond")
    static let sessionClose = Self(rawValue: "session.close")
    static let compatibilityOptionsRead = Self(rawValue: "yardlet.provider.options.read")
    static let compatibilityOptionsSet = Self(rawValue: "yardlet.provider.options.set")
    static let compatibilityActionsRead = Self(rawValue: "yardlet.provider.actions.read")
    static let compatibilityActionPerform = Self(rawValue: "yardlet.provider.actions.perform")
    static let codexPresentationRead = Self(rawValue: "yardlet.codex.presentation.read")
    static let codexComposerSubmit = Self(rawValue: "yardlet.codex.composer.submit")
    static let codexTurnsLoad = Self(rawValue: "yardlet.codex.presentation.turns.load")
    static let codexItemsLoad = Self(rawValue: "yardlet.codex.presentation.items.load")
    static let codexSkillsRead = Self(rawValue: "yardlet.codex.skills.read")
    static let codexPluginsRead = Self(rawValue: "yardlet.codex.plugins.read")
    static let codexHistoryRecent = Self(rawValue: "yardlet.codex.history.recent")
    static let codexHistoryInteractive = Self(rawValue: "yardlet.codex.history.interactive")
    static let codexHistorySearch = Self(rawValue: "yardlet.codex.history.search")
    static let codexHistoryOccurrences = Self(rawValue: "yardlet.codex.history.occurrences")
    static let codexModelsRead = Self(rawValue: "yardlet.codex.models.read")
    static let codexModelSet = Self(rawValue: "yardlet.codex.model.set")
    static let codexControlsRead = Self(rawValue: "yardlet.codex.controls.read")
    static let codexAccountRateLimitsRead = Self(rawValue: "yardlet.codex.account.rate_limits.read")
    static let codexCollaborationSet = Self(rawValue: "yardlet.codex.collaboration.set")
    static let codexRunLocationSet = Self(rawValue: "yardlet.codex.run_location.set")
    static let codexSessionFork = Self(rawValue: "yardlet.codex.session.fork")
    static let codexConversationEdit = Self(rawValue: "yardlet.codex.conversation.edit")
    static let codexTurnRetry = Self(rawValue: "yardlet.codex.turn.retry")
    static let codexTurnContinue = Self(rawValue: "yardlet.codex.turn.continue")
    static let codexCompactStart = Self(rawValue: "yardlet.codex.compact.start")
    static let codexReviewStart = Self(rawValue: "yardlet.codex.review.start")
    static let codexThreadRead = Self(rawValue: "yardlet.codex.thread.read")
    static let codexThreadTurnsRead = Self(rawValue: "yardlet.codex.thread.turns.read")
    static let codexThreadRename = Self(rawValue: "yardlet.codex.thread.rename")
    static let codexTaskTitleSuggest = Self(rawValue: "yardlet.codex.task.title.suggest")
    static let codexThreadArchive = Self(rawValue: "yardlet.codex.thread.archive")
    static let codexThreadUnarchive = Self(rawValue: "yardlet.codex.thread.unarchive")
    static let codexThreadDelete = Self(rawValue: "yardlet.codex.thread.delete")
    static let codexServerRequestRespond = Self(rawValue: "yardlet.codex.server_request.respond")
}

struct HarnessProtocolRequest: Codable, Equatable, Sendable {
    let id: String
    let method: HarnessProtocolMethodID
    let params: JSONValue
}

struct HarnessProtocolResponseError: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let data: JSONValue?
}

struct HarnessProtocolResponse: Codable, Equatable, Sendable {
    let id: String
    let result: JSONValue?
    let error: HarnessProtocolResponseError?

    init(id: String, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: String, error: HarnessProtocolResponseError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

enum HarnessProtocolFrame: Equatable, Sendable {
    case hello(HarnessAdapterManifest)
    case ready(HarnessProtocolVersion)
    case request(version: HarnessProtocolVersion, HarnessProtocolRequest)
    case response(version: HarnessProtocolVersion, HarnessProtocolResponse)
    case event(version: HarnessProtocolVersion, HarnessProtocolEventEnvelope)
}

extension HarnessProtocolFrame: Codable {
    private enum Kind: String, Codable {
        case hello
        case ready
        case request
        case response
        case event
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case manifest
        case request
        case response
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello(try container.decode(HarnessAdapterManifest.self, forKey: .manifest))
        case .ready:
            self = .ready(try container.decode(HarnessProtocolVersion.self, forKey: .version))
        case .request:
            self = .request(
                version: try container.decode(HarnessProtocolVersion.self, forKey: .version),
                try container.decode(HarnessProtocolRequest.self, forKey: .request)
            )
        case .response:
            self = .response(
                version: try container.decode(HarnessProtocolVersion.self, forKey: .version),
                try container.decode(HarnessProtocolResponse.self, forKey: .response)
            )
        case .event:
            self = .event(
                version: try container.decode(HarnessProtocolVersion.self, forKey: .version),
                try container.decode(HarnessProtocolEventEnvelope.self, forKey: .event)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(manifest):
            try container.encode(Kind.hello, forKey: .type)
            try container.encode(manifest, forKey: .manifest)
        case let .ready(version):
            try container.encode(Kind.ready, forKey: .type)
            try container.encode(version, forKey: .version)
        case let .request(version, request):
            try container.encode(Kind.request, forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(request, forKey: .request)
        case let .response(version, response):
            try container.encode(Kind.response, forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(response, forKey: .response)
        case let .event(version, event):
            try container.encode(Kind.event, forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(event, forKey: .event)
        }
    }
}

struct HarnessProtocolJSONLCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func encodeLine(_ frame: HarnessProtocolFrame) throws -> Data {
        var data = try encoder.encode(frame)
        data.append(0x0A)
        return data
    }

    func decodeLine(_ data: Data) throws -> HarnessProtocolFrame {
        let trimmed = data.drop(while: { $0 == 0x0A || $0 == 0x0D })
        return try decoder.decode(HarnessProtocolFrame.self, from: Data(trimmed))
    }
}
