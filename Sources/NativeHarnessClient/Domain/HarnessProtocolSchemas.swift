import Foundation

enum HarnessProtocolInputCapability: String, Codable, Hashable, Sendable {
    case text
    case image
    case audio
}

struct HarnessProtocolSelectOption: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let description: String?
    let isDefault: Bool
}

struct HarnessProtocolModelDefinition: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String?
    let isDefault: Bool
    let contextWindowTokens: UInt64?
    let inputCapabilities: [HarnessProtocolInputCapability]
    let thinkingOptions: [HarnessProtocolSelectOption]
    let defaultThinkingOptionID: String?
    let extensionValues: [String: JSONValue]
}

struct HarnessProtocolModeDefinition: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String?
    let isDefault: Bool
    let isUnattended: Bool
    let extensionValues: [String: JSONValue]
}

enum HarnessProtocolFeatureKind: String, Codable, Sendable {
    case toggle
    case select
}

struct HarnessProtocolFeatureDefinition: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String?
    let kind: HarnessProtocolFeatureKind
    let value: JSONValue
    let options: [HarnessProtocolSelectOption]
    let extensionValues: [String: JSONValue]
}

struct HarnessProtocolCatalog: Codable, Equatable, Sendable {
    let models: [HarnessProtocolModelDefinition]
    let modes: [HarnessProtocolModeDefinition]
    let features: [HarnessProtocolFeatureDefinition]
    let defaultModelID: String?
    let defaultModeID: String?
    let extensionValues: [String: JSONValue]
}

enum HarnessProtocolCatalogViolation: Error, Equatable, Sendable {
    case duplicateModelID(String)
    case duplicateModeID(String)
    case duplicateFeatureID(String)
    case duplicateOptionID(ownerID: String, optionID: String)
    case missingDefaultModel(String)
    case missingDefaultMode(String)
    case missingDefaultThinkingOption(modelID: String, optionID: String)
    case invalidFeatureValue(String)
    case invalidExtensionKey(String)
}

enum HarnessProtocolCatalogValidator {
    static func validate(
        _ catalog: HarnessProtocolCatalog,
        manifest: HarnessAdapterManifest
    ) throws {
        try requireUnique(catalog.models.map(\.id), duplicate: HarnessProtocolCatalogViolation.duplicateModelID)
        try requireUnique(catalog.modes.map(\.id), duplicate: HarnessProtocolCatalogViolation.duplicateModeID)
        try requireUnique(
            catalog.features.map(\.id),
            duplicate: HarnessProtocolCatalogViolation.duplicateFeatureID
        )

        if let defaultModelID = catalog.defaultModelID,
           !catalog.models.contains(where: { $0.id == defaultModelID }) {
            throw HarnessProtocolCatalogViolation.missingDefaultModel(defaultModelID)
        }
        if let defaultModeID = catalog.defaultModeID,
           !catalog.modes.contains(where: { $0.id == defaultModeID }) {
            throw HarnessProtocolCatalogViolation.missingDefaultMode(defaultModeID)
        }

        for model in catalog.models {
            try requireUnique(model.thinkingOptions.map(\.id)) { optionID in
                HarnessProtocolCatalogViolation.duplicateOptionID(
                    ownerID: model.id,
                    optionID: optionID
                )
            }
            if let defaultThinkingOptionID = model.defaultThinkingOptionID,
               !model.thinkingOptions.contains(where: { $0.id == defaultThinkingOptionID }) {
                throw HarnessProtocolCatalogViolation.missingDefaultThinkingOption(
                    modelID: model.id,
                    optionID: defaultThinkingOptionID
                )
            }
            try validateExtensions(model.extensionValues, manifest: manifest)
        }

        for mode in catalog.modes {
            try validateExtensions(mode.extensionValues, manifest: manifest)
        }

        for feature in catalog.features {
            try requireUnique(feature.options.map(\.id)) { optionID in
                HarnessProtocolCatalogViolation.duplicateOptionID(
                    ownerID: feature.id,
                    optionID: optionID
                )
            }
            switch feature.kind {
            case .toggle:
                guard case .bool = feature.value, feature.options.isEmpty else {
                    throw HarnessProtocolCatalogViolation.invalidFeatureValue(feature.id)
                }
            case .select:
                guard let selected = feature.value.stringValue,
                      feature.options.contains(where: { $0.id == selected }) else {
                    throw HarnessProtocolCatalogViolation.invalidFeatureValue(feature.id)
                }
            }
            try validateExtensions(feature.extensionValues, manifest: manifest)
        }
        try validateExtensions(catalog.extensionValues, manifest: manifest)
    }

    private static func requireUnique<E: Error>(
        _ values: [String],
        duplicate: (String) -> E
    ) throws {
        var observed: Set<String> = []
        for value in values where !observed.insert(value).inserted {
            throw duplicate(value)
        }
    }

    private static func validateExtensions(
        _ values: [String: JSONValue],
        manifest: HarnessAdapterManifest
    ) throws {
        do {
            try HarnessProtocolExtensionValidator.validate(values, manifest: manifest)
        } catch let error as HarnessProtocolExtensionViolation {
            switch error {
            case let .undeclaredKey(key):
                throw HarnessProtocolCatalogViolation.invalidExtensionKey(key)
            }
        }
    }
}

enum HarnessProtocolContentBlock: Equatable, Sendable {
    case text(String)
    case inlineData(mimeType: String, base64Data: String)
    case file(path: String, mimeType: String?)
    case remoteURL(URL, mimeType: String?)
}

extension HarnessProtocolContentBlock: Codable {
    private enum Kind: String, Codable {
        case text
        case inlineData = "inline_data"
        case file
        case remoteURL = "remote_url"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case mimeType
        case data
        case path
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .inlineData:
            self = .inlineData(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                base64Data: try container.decode(String.self, forKey: .data)
            )
        case .file:
            self = .file(
                path: try container.decode(String.self, forKey: .path),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        case .remoteURL:
            self = .remoteURL(
                try container.decode(URL.self, forKey: .url),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .inlineData(mimeType, base64Data):
            try container.encode(Kind.inlineData, forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(base64Data, forKey: .data)
        case let .file(path, mimeType):
            try container.encode(Kind.file, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        case let .remoteURL(url, mimeType):
            try container.encode(Kind.remoteURL, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        }
    }
}

struct HarnessProtocolSessionConfig: Codable, Equatable, Sendable {
    let workspacePath: String
    let modelID: String?
    let modeID: String?
    let featureValues: [String: JSONValue]
    let extensionValues: [String: JSONValue]
}

struct HarnessProtocolSessionOptionChoice: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let description: String?
}

struct HarnessProtocolSessionOption: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String?
    let category: String?
    let currentValue: String
    let choices: [HarnessProtocolSessionOptionChoice]
}

struct HarnessProtocolSessionOptionCatalog: Codable, Equatable, Sendable {
    let options: [HarnessProtocolSessionOption]
    let notes: [String]
    let message: String?
    /// Optional metadata in yardlet.provider.options.read/set, a compatibility extension.
    /// Missing on older clients and every provider that does not advertise composer commands.
    let composerCommands: [ProviderComposerCommand]?

    init(
        options: [HarnessProtocolSessionOption],
        notes: [String],
        message: String? = nil,
        composerCommands: [ProviderComposerCommand]? = nil
    ) {
        self.options = options
        self.notes = notes
        self.message = message
        self.composerCommands = composerCommands
    }
}

struct HarnessProtocolSessionOptionsReadParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
}

struct HarnessProtocolSessionOptionSetParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let optionID: String
    let value: String
}

struct HarnessProtocolSessionAction: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let iconName: String?
}

struct HarnessProtocolSessionActionCatalog: Codable, Equatable, Sendable {
    let actions: [HarnessProtocolSessionAction]
    let notes: [String]
    let message: String?
}

struct HarnessProtocolSessionActionsReadParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
}

struct HarnessProtocolSessionActionPerformParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let actionID: String
}

struct HarnessProtocolEmptyParams: Codable, Equatable, Sendable {}

struct HarnessProtocolAcknowledgement: Codable, Equatable, Sendable {
    let accepted: Bool
}

struct HarnessProtocolRuntimeInfo: Codable, Equatable, Sendable {
    let harness: HarnessKind
    let executablePath: String
    let version: String
    let capabilities: [HarnessCapabilityID]
    let fingerprint: String
}

struct HarnessProtocolCatalogRequest: Codable, Equatable, Sendable {
    let workspacePath: String?
    let refresh: Bool
}

struct HarnessProtocolCreateSessionParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let config: HarnessProtocolSessionConfig
    let initialPrompt: [HarnessProtocolContentBlock]
}

struct HarnessProtocolResumeSessionParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let providerSessionID: String
    let config: HarnessProtocolSessionConfig
}

struct HarnessProtocolImportSessionParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let providerHandleID: String
    let config: HarnessProtocolSessionConfig
}

struct HarnessProtocolSessionReference: Codable, Equatable, Sendable {
    let localSessionID: UUID
}

struct HarnessProtocolTurnSubmitParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let clientMessageID: String
    let content: [HarnessProtocolContentBlock]
}

struct HarnessProtocolTurnSteerParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let expectedTurnID: String
    let clientMessageID: String
    let content: [HarnessProtocolContentBlock]
    let clearPendingPermissions: Bool
}

enum HarnessProtocolPermissionKind: String, Codable, Sendable {
    case tool
    case plan
    case question
    case mode
    case other
}

enum HarnessProtocolPermissionBehavior: String, Codable, Sendable {
    case allow
    case deny
}

enum HarnessProtocolPermissionActionRole: String, Codable, Sendable {
    case primary
    case secondary
    case destructive
}

struct HarnessProtocolPermissionAction: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let behavior: HarnessProtocolPermissionBehavior
    let role: HarnessProtocolPermissionActionRole
    let intent: String?
    /// The catalog key Yardlet worded `label` from (`PermissionRequestAction.labelText`); absent for a
    /// provider's own label.
    var labelText: LocalizedText? = nil
}

struct HarnessProtocolPermissionRequest: Codable, Equatable, Sendable {
    let id: String
    let localSessionID: UUID
    let turnID: String?
    let kind: HarnessProtocolPermissionKind
    let name: String
    let title: String
    let description: String?
    let input: JSONValue?
    let suggestions: [JSONValue]
    let actions: [HarnessProtocolPermissionAction]
    let extensionValues: [String: JSONValue]
}

struct HarnessProtocolPermissionResponseParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let requestID: String
    let selectedActionID: String
    let behavior: HarnessProtocolPermissionBehavior
    let updatedInput: JSONValue?
    let message: String?
    let interrupt: Bool
}

struct HarnessProtocolUsage: Codable, Equatable, Sendable {
    let inputTokens: UInt64?
    let cachedInputTokens: UInt64?
    let outputTokens: UInt64?
    let reasoningTokens: UInt64?
    let totalCostUSD: Double?
    let contextWindowTokens: UInt64?
    let contextUsedTokens: UInt64?
    let extensionValues: [String: JSONValue]
    /// What fills the window, where the harness breaks it down (Claude Code). Absent otherwise,
    /// and absent from a payload that predates it.
    var contextBreakdown: HarnessContextBreakdown? = nil
    /// The model the window is that size for, as the harness names it (Claude Code's
    /// `get_context_usage` `model`, `[1m]` suffix included), so a saved conversation read later
    /// can be given the window its model has. Absent where the harness does not say.
    var contextWindowModel: String? = nil
}

enum HarnessProtocolExtensionViolation: Error, Equatable, Sendable {
    case undeclaredKey(String)
}

enum HarnessProtocolExtensionValidator {
    static func validate(
        _ values: [String: JSONValue],
        manifest: HarnessAdapterManifest
    ) throws {
        for key in values.keys {
            guard manifest.extensionNamespaces.contains(where: { namespace in
                key.hasPrefix("\(namespace).")
            }) else {
                throw HarnessProtocolExtensionViolation.undeclaredKey(key)
            }
        }
    }
}

struct HarnessProtocolPayloadCodec: Sendable {
    /// The JSON written here is read straight back, into a `JSONValue` whose objects keep no key
    /// order or into a typed value, so keys are not sorted; a Codex timeline snapshot crosses
    /// this codec twice per state.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func encode<T: Encodable & Sendable>(_ value: T) throws -> JSONValue {
        try decoder.decode(JSONValue.self, from: encoder.encode(value))
    }

    func decode<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try decoder.decode(type, from: encoder.encode(value))
    }
}

extension HarnessProtocolRequest {
    init<T: Encodable & Sendable>(
        id: String,
        method: HarnessProtocolMethodID,
        typedParams: T,
        codec: HarnessProtocolPayloadCodec = HarnessProtocolPayloadCodec()
    ) throws {
        self.init(id: id, method: method, params: try codec.encode(typedParams))
    }

    func decodeParams<T: Decodable & Sendable>(
        _ type: T.Type,
        codec: HarnessProtocolPayloadCodec = HarnessProtocolPayloadCodec()
    ) throws -> T {
        try codec.decode(type, from: params)
    }
}

enum HarnessProtocolRequestSchemaError: Error, Equatable, Sendable {
    case invalidPayload(HarnessProtocolMethodID)
    case invalidExtension(HarnessProtocolExtensionViolation)
}

enum HarnessProtocolRequestSchema {
    static func validate(
        _ request: HarnessProtocolRequest,
        manifest: HarnessAdapterManifest
    ) throws {
        do {
            switch request.method {
            case .runtimeProbe:
                _ = try request.decodeParams(HarnessProtocolEmptyParams.self)
            case .catalogRead:
                _ = try request.decodeParams(HarnessProtocolCatalogRequest.self)
            case .sessionCreate:
                let params = try request.decodeParams(HarnessProtocolCreateSessionParams.self)
                try validate(params.config.extensionValues, manifest: manifest)
            case .sessionResume:
                let params = try request.decodeParams(HarnessProtocolResumeSessionParams.self)
                try validate(params.config.extensionValues, manifest: manifest)
            case .sessionImport:
                let params = try request.decodeParams(HarnessProtocolImportSessionParams.self)
                try validate(params.config.extensionValues, manifest: manifest)
            case .sessionSend:
                _ = try request.decodeParams(HarnessProtocolTurnSubmitParams.self)
            case .sessionSteer:
                _ = try request.decodeParams(HarnessProtocolTurnSteerParams.self)
            case .sessionInterrupt, .sessionClose:
                _ = try request.decodeParams(HarnessProtocolSessionReference.self)
            case .permissionRespond:
                _ = try request.decodeParams(HarnessProtocolPermissionResponseParams.self)
            default:
                return
            }
        } catch let error as HarnessProtocolExtensionViolation {
            throw HarnessProtocolRequestSchemaError.invalidExtension(error)
        } catch {
            throw HarnessProtocolRequestSchemaError.invalidPayload(request.method)
        }
    }

    private static func validate(
        _ extensions: [String: JSONValue],
        manifest: HarnessAdapterManifest
    ) throws {
        try HarnessProtocolExtensionValidator.validate(extensions, manifest: manifest)
    }
}
