import Foundation

/// A harness's runtime status and installation choices on the host (§15.37). Host filesystem paths never travel.
public struct RemoteHarnessRuntime: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var selected: Bool

        public init(id: String, label: String, selected: Bool) {
            self.id = id
            self.label = label
            self.selected = selected
        }
    }

    public var harness: String
    public var installed: Bool
    public var label: String?
    public var versionNote: String?
    public var versionVerified: Bool?
    public var checkingDefault: Bool?
    public var choices: [Choice]

    public init(
        harness: String,
        installed: Bool,
        label: String? = nil,
        versionNote: String? = nil,
        versionVerified: Bool? = nil,
        checkingDefault: Bool? = nil,
        choices: [Choice] = []
    ) {
        self.harness = harness
        self.installed = installed
        self.label = label
        self.versionNote = versionNote
        self.versionVerified = versionVerified
        self.checkingDefault = checkingDefault
        self.choices = choices
    }
}

/// One connector in the host's Connector Center (§15.37). Credentials, OAuth client IDs, headers and host paths never travel.
public struct RemoteConnectorInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var slug: String
    public var status: String
    public var authorization: String
    public var toolCount: Int
    public var presetId: String?
    public var localService: String?
    public var account: String?
    public var programSummary: String?
    public var serverHost: String?
    public var usesRegisteredClient: Bool?
    public var activity: String?
    public var failure: String?
    public var enabled: Bool?

    public init(
        id: String,
        name: String,
        slug: String,
        status: String,
        authorization: String = "unknown",
        toolCount: Int = 0,
        presetId: String? = nil,
        localService: String? = nil,
        account: String? = nil,
        programSummary: String? = nil,
        serverHost: String? = nil,
        usesRegisteredClient: Bool? = nil,
        activity: String? = nil,
        failure: String? = nil,
        enabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.status = status
        self.authorization = authorization
        self.toolCount = toolCount
        self.presetId = presetId
        self.localService = localService
        self.account = account
        self.programSummary = programSummary
        self.serverHost = serverHost
        self.usesRegisteredClient = usesRegisteredClient
        self.activity = activity
        self.failure = failure
        self.enabled = enabled
    }
}

/// The host's Account Center, harness runtimes and connectors (§15.37).
public struct RemoteAccountsState: Codable, Equatable, Sendable {
    public var accounts: [RemoteAccount]
    public var harnesses: [RemoteHarnessRuntime]
    public var connectors: [RemoteConnectorInfo]
    public var picksNewTaskAccount: Bool
    public var continuesAtUsageLimit: Bool
    public var movesTasksToAccountWithRoom: Bool
    public var claudeAIConnectors: Bool
    public var cannotReadConnectors: Bool?
    public var xcodeDescription: String?
    public var harnessesWithTasks: [String]?
    public var harnessesWithSubagents: [String]?
    public var newTaskHarness: String?
    public var editable: Bool?

    public init(
        accounts: [RemoteAccount] = [],
        harnesses: [RemoteHarnessRuntime] = [],
        connectors: [RemoteConnectorInfo] = [],
        picksNewTaskAccount: Bool = false,
        continuesAtUsageLimit: Bool = false,
        movesTasksToAccountWithRoom: Bool = false,
        claudeAIConnectors: Bool = true,
        cannotReadConnectors: Bool? = nil,
        xcodeDescription: String? = nil,
        harnessesWithTasks: [String]? = nil,
        harnessesWithSubagents: [String]? = nil,
        newTaskHarness: String? = nil,
        editable: Bool? = nil
    ) {
        self.accounts = accounts
        self.harnesses = harnesses
        self.connectors = connectors
        self.picksNewTaskAccount = picksNewTaskAccount
        self.continuesAtUsageLimit = continuesAtUsageLimit
        self.movesTasksToAccountWithRoom = movesTasksToAccountWithRoom
        self.claudeAIConnectors = claudeAIConnectors
        self.cannotReadConnectors = cannotReadConnectors
        self.xcodeDescription = xcodeDescription
        self.harnessesWithTasks = harnessesWithTasks
        self.harnessesWithSubagents = harnessesWithSubagents
        self.newTaskHarness = newTaskHarness
        self.editable = editable
    }
}
