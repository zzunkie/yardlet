import Foundation
@testable import NativeHarnessClient

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
