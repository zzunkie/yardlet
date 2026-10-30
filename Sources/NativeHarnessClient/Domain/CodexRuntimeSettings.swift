import Foundation

struct CodexRuntimeRequirementsSnapshot: Equatable, Sendable {
    let hasRequirements: Bool
    let allowedApprovalPolicies: [String]
    let allowedSandboxModes: [String]
    let allowedWebSearchModes: [String]
    let permissionProfileCount: Int
    let defaultPermissions: String?
    let networkEnabled: Bool?
    let networkManagedAllowedDomainsOnly: Bool?
    let networkDomainCount: Int
    let featureRequirementCount: Int

    static let empty = CodexRuntimeRequirementsSnapshot(
        hasRequirements: false,
        allowedApprovalPolicies: [],
        allowedSandboxModes: [],
        allowedWebSearchModes: [],
        permissionProfileCount: 0,
        defaultPermissions: nil,
        networkEnabled: nil,
        networkManagedAllowedDomainsOnly: nil,
        networkDomainCount: 0,
        featureRequirementCount: 0
    )

    var isEmpty: Bool {
        !hasRequirements && allowedApprovalPolicies.isEmpty && allowedSandboxModes.isEmpty
            && allowedWebSearchModes.isEmpty && permissionProfileCount == 0
            && defaultPermissions == nil && networkEnabled == nil
            && networkManagedAllowedDomainsOnly == nil && networkDomainCount == 0
            && featureRequirementCount == 0
    }
}

struct CodexRuntimeSettingsSnapshot: Equatable, Sendable {
    let model: String?
    let modelProvider: String?
    let reasoningEffort: String?
    let approvalPolicy: String?
    let sandboxMode: String?
    let serviceTier: String?
    let webSearch: String?
    let originCount: Int
    let layerCount: Int
    let requirements: CodexRuntimeRequirementsSnapshot

    static let empty = CodexRuntimeSettingsSnapshot(
        model: nil,
        modelProvider: nil,
        reasoningEffort: nil,
        approvalPolicy: nil,
        sandboxMode: nil,
        serviceTier: nil,
        webSearch: nil,
        originCount: 0,
        layerCount: 0,
        requirements: .empty
    )

    var isEmpty: Bool {
        model == nil && modelProvider == nil && reasoningEffort == nil
            && approvalPolicy == nil && sandboxMode == nil && serviceTier == nil
            && webSearch == nil && originCount == 0 && layerCount == 0
            && requirements.isEmpty
    }
}

struct CodexRuntimeSettingsProjector: Sendable {
    func snapshot(
        from result: JSONValue?,
        requirementsResult: JSONValue? = nil
    ) -> CodexRuntimeSettingsSnapshot {
        let config = result?["config"]
        let approvalPolicy: String?
        if let value = config?["approval_policy"]?.stringValue {
            approvalPolicy = value
        } else if config?["approval_policy"]?.objectValue != nil {
            // Preserve the fact that the installed schema allows a structured
            // granular policy without attempting to serialize its internals into
            // a user-facing settings row.
            approvalPolicy = L10n.string("Granular")
        } else {
            approvalPolicy = nil
        }

        return CodexRuntimeSettingsSnapshot(
            model: config?["model"]?.stringValue,
            modelProvider: config?["model_provider"]?.stringValue,
            reasoningEffort: config?["model_reasoning_effort"]?.stringValue,
            approvalPolicy: approvalPolicy,
            sandboxMode: config?["sandbox_mode"]?.stringValue,
            serviceTier: config?["service_tier"]?.stringValue,
            webSearch: config?["web_search"]?.stringValue,
            originCount: result?["origins"]?.objectValue?.count ?? 0,
            layerCount: result?["layers"]?.arrayValue?.count ?? 0,
            requirements: requirements(from: requirementsResult)
        )
    }

    private func requirements(from result: JSONValue?) -> CodexRuntimeRequirementsSnapshot {
        guard let requirements = result?["requirements"] else {
            return .empty
        }

        let approvalPolicies = (requirements["allowedApprovalPolicies"]?.arrayValue ?? [])
            .compactMap { value -> String? in
                value.stringValue ?? (
                    value["granular"]?.objectValue != nil ? L10n.string("Granular") : nil
                )
            }
        let sandboxModes = (requirements["allowedSandboxModes"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        let webSearchModes = (requirements["allowedWebSearchModes"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        let network = requirements["network"]
        let domainCount = network?["domains"]?.objectValue?.count ?? 0
        let featureRequirementCount = requirements["featureRequirements"]?.objectValue?.count ?? 0

        return CodexRuntimeRequirementsSnapshot(
            hasRequirements: requirements.objectValue != nil,
            allowedApprovalPolicies: approvalPolicies,
            allowedSandboxModes: sandboxModes,
            allowedWebSearchModes: webSearchModes,
            permissionProfileCount: requirements["allowedPermissionProfiles"]?.objectValue?.count ?? 0,
            defaultPermissions: requirements["defaultPermissions"]?.stringValue,
            networkEnabled: network?["enabled"]?.boolValue,
            networkManagedAllowedDomainsOnly: network?["managedAllowedDomainsOnly"]?.boolValue,
            networkDomainCount: domainCount,
            featureRequirementCount: featureRequirementCount
        )
    }
}

actor CodexRuntimeSettingsBroker {
    private let environmentManager: CodexEnvironmentManager?

    init(environmentManager: CodexEnvironmentManager? = nil) {
        self.environmentManager = environmentManager
    }

    func snapshot(
        executableURL: URL,
        workspaceURL: URL?
    ) async throws -> CodexRuntimeSettingsSnapshot {
        let transport = CodexProcessTransport(
            executableURL: executableURL,
            environmentManager: environmentManager
        )
        do {
            _ = try await transport.request(
                CodexProtocol.initialize(id: 1, clientVersion: "0.2")
            )
            let response = try await transport.request(
                CodexProtocol.readConfig(
                    id: 2,
                    workspaceURL: workspaceURL,
                    includeLayers: true
                )
            )
            // The installed schema exposes requirements as a separate, read-only
            // null-parameter request. Older runtimes may not implement it; the
            // effective config snapshot remains useful without this optional row.
            let requirementsResponse = try? await transport.request(
                CodexProtocol.readConfigRequirements(id: 3)
            )
            await transport.stop()
            return CodexRuntimeSettingsProjector().snapshot(
                from: response.result,
                requirementsResult: requirementsResponse?.result
            )
        } catch {
            await transport.stop()
            throw error
        }
    }
}
