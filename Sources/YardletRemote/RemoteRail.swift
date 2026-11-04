import Foundation

/// Facts for the shown task only (docs/REMOTE_PROTOCOL.md §15.34). No credentials or environment values.
public struct RemoteRailFacts: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var remainingPercent: Double?
        public var resetsAt: Int64?
        public var evidence: String
        public init(id: String, name: String, remainingPercent: Double?, resetsAt: Int64?, evidence: String) {
            self.id = id
            self.name = name
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
            self.evidence = evidence
        }
    }
    public struct Step: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var status: String
        public init(id: String, text: String, status: String) {
            self.id = id
            self.text = text
            self.status = status
        }
    }
    public struct Changes: Codable, Equatable, Sendable {
        public var changedFiles: Int
        public var additions: Int
        public var deletions: Int
        public var untrackedFiles: Int
        public init(changedFiles: Int, additions: Int, deletions: Int, untrackedFiles: Int) {
            self.changedFiles = changedFiles
            self.additions = additions
            self.deletions = deletions
            self.untrackedFiles = untrackedFiles
        }
    }
    public struct PullRequest: Codable, Equatable, Sendable {
        public var number: Int
        public var url: URL
        public var repository: String?
        public var state: String?
        public var checks: String?
        public var review: String?
        public init(number: Int, url: URL, repository: String?, state: String?, checks: String?, review: String?) {
            self.number = number
            self.url = url
            self.repository = repository
            self.state = state
            self.checks = checks
            self.review = review
        }
    }
    public struct Agent: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var targetID: String?
        public var title: String
        public var harnessLabel: String?
        public var model: String?
        public var status: String
        public var startedAt: Int64?
        public var depth: Int
        public var canStop: Bool
        public var waitingFor: String? = nil
        public init(id: String, kind: String, targetID: String?, title: String, harnessLabel: String?, model: String?, status: String, startedAt: Int64?, depth: Int, canStop: Bool) {
            self.id = id
            self.kind = kind
            self.targetID = targetID
            self.title = title
            self.harnessLabel = harnessLabel
            self.model = model
            self.status = status
            self.startedAt = startedAt
            self.depth = depth
            self.canStop = canStop
        }
    }
    public struct Terminal: Codable, Equatable, Sendable {
        public var processID: String
        public var itemID: String
        public var command: String
        public var workspacePath: String
        public init(processID: String, itemID: String, command: String, workspacePath: String) {
            self.processID = processID
            self.itemID = itemID
            self.command = command
            self.workspacePath = workspacePath
        }
    }
    public struct Count: Codable, Equatable, Sendable {
        public var label: String
        public var tokens: UInt64
        public init(label: String, tokens: UInt64) {
            self.label = label
            self.tokens = tokens
        }
    }
    public struct UsageBreakdown: Codable, Equatable, Sendable {
        public var title: String
        public var total: UInt64?
        public var counts: [Count]
        public var cacheHitFraction: Double?
        public init(title: String, total: UInt64?, counts: [Count], cacheHitFraction: Double?) {
            self.title = title
            self.total = total
            self.counts = counts
            self.cacheHitFraction = cacheHitFraction
        }
    }
    public struct Context: Codable, Equatable, Sendable {
        public var inputTokens: UInt64?
        public var cachedInputTokens: UInt64?
        public var outputTokens: UInt64?
        public var reasoningTokens: UInt64?
        public var totalCostUSD: Double?
        public var contextWindowTokens: UInt64?
        public var contextUsedTokens: UInt64?
        public init(inputTokens: UInt64?, cachedInputTokens: UInt64?, outputTokens: UInt64?, reasoningTokens: UInt64?, totalCostUSD: Double?, contextWindowTokens: UInt64?, contextUsedTokens: UInt64?) {
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.totalCostUSD = totalCostUSD
            self.contextWindowTokens = contextWindowTokens
            self.contextUsedTokens = contextUsedTokens
        }
    }
    public struct Background: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var title: String
        public var state: String
        public var taskID: String?
        public var taskType: String?
        public var startedAt: Int64
        public init(id: String, kind: String, title: String, state: String, taskID: String?, taskType: String?, startedAt: Int64) {
            self.id = id
            self.kind = kind
            self.title = title
            self.state = state
            self.taskID = taskID
            self.taskType = taskType
            self.startedAt = startedAt
        }
    }
    public struct Check: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var workflow: String?
        public var bucket: String
        public var state: String
        public var link: URL?
        public var startedAt: Int64?
        public var completedAt: Int64?
        public init(id: String, name: String, workflow: String?, bucket: String, state: String, link: URL?, startedAt: Int64?, completedAt: Int64?) {
            self.id = id
            self.name = name
            self.workflow = workflow
            self.bucket = bucket
            self.state = state
            self.link = link
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }
    public struct Review: Codable, Equatable, Sendable {
        public var author: String
        public var decision: String
        public var submittedAt: Int64?
        public init(author: String, decision: String, submittedAt: Int64?) {
            self.author = author
            self.decision = decision
            self.submittedAt = submittedAt
        }
    }
    public struct Detail: Codable, Equatable, Sendable {
        public var number: Int
        public var url: URL
        public var title: String
        public var state: String
        public var headBranch: String?
        public var baseBranch: String?
        public var headSHA: String?
        public var mergeable: String?
        public var mergeState: String
        public var review: String?
        public var reviews: [Review]
        public var autoMerge: String?
        public var checks: [Check]
        public init(number: Int, url: URL, title: String, state: String, headBranch: String?, baseBranch: String?, headSHA: String?, mergeable: String?, mergeState: String, review: String?, reviews: [Review], autoMerge: String?, checks: [Check]) {
            self.number = number
            self.url = url
            self.title = title
            self.state = state
            self.headBranch = headBranch
            self.baseBranch = baseBranch
            self.headSHA = headSHA
            self.mergeable = mergeable
            self.mergeState = mergeState
            self.review = review
            self.reviews = reviews
            self.autoMerge = autoMerge
            self.checks = checks
        }
    }
    public var compactOffered: Bool = false
    public var compactAvailable: Bool = false
    public var folderName: String? = nil
    public var worktreeName: String? = nil
    public var additionalRoots: [String] = []
    public var contextBreakdown: ContextBreakdown? = nil
    public var contextWindowModel: String? = nil
    public var logs: [String: Log] = [:]
    public var branch: String? = nil
    public var branchURL: URL? = nil
    public var instructionPaths: [String] = []
    public var instructionOrigin: String = "detected"
    public var accountName: String? = nil
    public var accountWindows: [Window] = []
    public var accountCheckedAt: Int64? = nil
    public var contextUsage: Context? = nil
    public var reportsContextWindow: Bool = false
    public var usageBreakdowns: [UsageBreakdown] = []
    public var plan: [Step] = []
    public var planExplanation: String? = nil
    public var changes: Changes? = nil
    public var pullRequest: PullRequest? = nil
    public var agents: [Agent] = []
    public var terminals: [Terminal] = []
    public var background: [Background] = []
    public var pullRequestDetail: Detail? = nil
    public var mergeMethods: [String]? = nil
    public var pendingMerge: String? = nil
    public var runningAction: String? = nil
    public var actionError: String? = nil
    public var autoFixOn: Bool? = nil
    public var asksAboutAutoFix: Bool = false
    public var pullRequestLoading: Bool = false
    public struct Category: Codable, Equatable, Sendable {
        public var name: String
        public var tokens: UInt64
        public var kind: String
        public init(name: String, tokens: UInt64, kind: String) {
            self.name = name
            self.tokens = tokens
            self.kind = kind
        }
    }
    public struct ContextBreakdown: Codable, Equatable, Sendable {
        public var categories: [Category]
        public var windowTokens: UInt64?
        public var autoCompactThresholdTokens: UInt64?
        public var isAutoCompactEnabled: Bool
        public var autoCompactSource: String?
        public init(categories: [Category], windowTokens: UInt64?, autoCompactThresholdTokens: UInt64?, isAutoCompactEnabled: Bool, autoCompactSource: String?) {
            self.categories = categories
            self.windowTokens = windowTokens
            self.autoCompactThresholdTokens = autoCompactThresholdTokens
            self.isAutoCompactEnabled = isAutoCompactEnabled
            self.autoCompactSource = autoCompactSource
        }
    }
    public struct Log: Codable, Equatable, Sendable {
        public var state: String
        public var text: String?
        public init(state: String, text: String?) {
            self.state = state
            self.text = text
        }
    }
    public init() {}
}
