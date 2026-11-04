import Foundation

/// The host's Settings values for a remote desktop window (§15.36). Never carries credentials,
/// tokens, vault entries, device lists, or host file paths.
public struct RemoteHostSettings: Codable, Equatable, Sendable {
    public struct Instructions: Codable, Equatable, Sendable {
        public var text: String
        public var hasEvaluation: Bool
        public var lastEvaluationAt: Int64?

        public init(text: String, hasEvaluation: Bool = false, lastEvaluationAt: Int64? = nil) {
            self.text = text
            self.hasEvaluation = hasEvaluation
            self.lastEvaluationAt = lastEvaluationAt
        }
    }

    public struct CLIUpdates: Codable, Equatable, Sendable {
        public struct Row: Codable, Equatable, Identifiable, Sendable {
            public var id: String { harness }
            public var harness: String
            public var title: String
            public var method: String
            public var versions: String
            public var status: String?
            public var isWarning: Bool
            public var working: Bool
            public var newerVersion: String?
            public var newerText: String?

            public init(
                harness: String,
                title: String,
                method: String,
                versions: String,
                status: String? = nil,
                isWarning: Bool = false,
                working: Bool = false,
                newerVersion: String? = nil,
                newerText: String? = nil
            ) {
                self.harness = harness
                self.title = title
                self.method = method
                self.versions = versions
                self.status = status
                self.isWarning = isWarning
                self.working = working
                self.newerVersion = newerVersion
                self.newerText = newerText
            }
        }

        public struct Notice: Codable, Equatable, Sendable {
            public var text: String
            public var isWarning: Bool

            public init(text: String, isWarning: Bool = false) {
                self.text = text
                self.isWarning = isWarning
            }
        }

        public var rows: [Row]
        public var isChecking: Bool
        public var lastCheckedAt: Int64?
        public var notice: Notice?

        public init(rows: [Row] = [], isChecking: Bool = false, lastCheckedAt: Int64? = nil, notice: Notice? = nil) {
            self.rows = rows
            self.isChecking = isChecking
            self.lastCheckedAt = lastCheckedAt
            self.notice = notice
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public struct Amount: Codable, Equatable, Sendable {
            public var freshInput: Int64
            public var cacheWrite: Int64
            public var cacheRead: Int64
            public var output: Int64
            public var requests: Int
            public var kindCost: [String: Double]

            public init(
                freshInput: Int64 = 0,
                cacheWrite: Int64 = 0,
                cacheRead: Int64 = 0,
                output: Int64 = 0,
                requests: Int = 0,
                kindCost: [String: Double] = [:]
            ) {
                self.freshInput = freshInput
                self.cacheWrite = cacheWrite
                self.cacheRead = cacheRead
                self.output = output
                self.requests = requests
                self.kindCost = kindCost
            }
        }

        public struct Day: Codable, Equatable, Sendable {
            public var start: Int64
            public var amount: Amount

            public init(start: Int64, amount: Amount) {
                self.start = start
                self.amount = amount
            }
        }

        public struct Row: Codable, Equatable, Sendable {
            public var id: String
            public var title: String
            public var detail: String?
            public var harness: String?
            public var amount: Amount

            public init(
                id: String,
                title: String,
                detail: String? = nil,
                harness: String? = nil,
                amount: Amount
            ) {
                self.id = id
                self.title = title
                self.detail = detail
                self.harness = harness
                self.amount = amount
            }
        }

        public struct LimitWindow: Codable, Equatable, Sendable {
            public var id: String
            public var label: String
            public var usedFraction: Double?
            public var detail: String
            public var resetsAt: Int64?
            public var evidence: String
            public var windowMinutes: Double?
            public var model: String?

            public init(
                id: String,
                label: String,
                usedFraction: Double? = nil,
                detail: String,
                resetsAt: Int64? = nil,
                evidence: String,
                windowMinutes: Double? = nil,
                model: String? = nil
            ) {
                self.id = id
                self.label = label
                self.usedFraction = usedFraction
                self.detail = detail
                self.resetsAt = resetsAt
                self.evidence = evidence
                self.windowMinutes = windowMinutes
                self.model = model
            }
        }

        public struct LimitLine: Codable, Equatable, Sendable {
            public var id: String
            public var account: String
            public var address: String
            public var harness: String
            public var windows: [LimitWindow]
            public var runsOutAt: [String: Int64]

            public init(
                id: String,
                account: String,
                address: String,
                harness: String,
                windows: [LimitWindow],
                runsOutAt: [String: Int64] = [:]
            ) {
                self.id = id
                self.account = account
                self.address = address
                self.harness = harness
                self.windows = windows
                self.runsOutAt = runsOutAt
            }
        }

        public var isCounting: Bool
        public var limitsCheckedAt: Int64?
        public var updatedAt: Int64
        public var days: [Day]
        public var limits: [LimitLine]
        public var rows: [String: [String: [Row]]]

        public init(
            isCounting: Bool = false,
            limitsCheckedAt: Int64? = nil,
            updatedAt: Int64,
            days: [Day] = [],
            limits: [LimitLine] = [],
            rows: [String: [String: [Row]]] = [:]
        ) {
            self.isCounting = isCounting
            self.limitsCheckedAt = limitsCheckedAt
            self.updatedAt = updatedAt
            self.days = days
            self.limits = limits
            self.rows = rows
        }
    }

    /// True when the connected device is allowed to change settings (`RemoteDevicePermission.settings`).
    public var writable: Bool
    /// The host's current setting values keyed by `YardletSetting.id`.
    public var values: [String: String]
    /// When non-nil, the host shows `hide_keys_and_tokens`, and this flag says whether the host build is team-signed.
    public var credentialHidingAllowedBuild: Bool?
    /// When non-nil, the host shows `keep_working_with_lid_closed` with this helper status (`unavailable`, `off`, `needsApproval`, `ready`).
    public var lidHelperStatus: String?
    public var instructions: Instructions?
    public var cliUpdates: CLIUpdates?
    public var usage: Usage?

    public init(
        writable: Bool = false,
        values: [String: String] = [:],
        credentialHidingAllowedBuild: Bool? = nil,
        lidHelperStatus: String? = nil,
        instructions: Instructions? = nil,
        cliUpdates: CLIUpdates? = nil,
        usage: Usage? = nil
    ) {
        self.writable = writable
        self.values = values
        self.credentialHidingAllowedBuild = credentialHidingAllowedBuild
        self.lidHelperStatus = lidHelperStatus
        self.instructions = instructions
        self.cliUpdates = cliUpdates
        self.usage = usage
    }
}
