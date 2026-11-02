#if DEBUG
import AppKit
import Foundation
import YardletAgentTools

/// DEBUG-only scene for Yardlet's public screenshots and videos (`--ui-fixture=showcase`): an
/// ordinary working day, in English, with a made-up person, projects and accounts. Nothing in it is
/// a test case; there are no failures, prompts or diagnostics on screen.
///
/// - Sidebar: three projects under `--ui-fixture-workspace=<root>` (`acme-web`, `payments-api`,
///   `design-system`) with Codex, Claude Code and OpenCode tasks, some running, some unread.
/// - The selected task is a Codex task whose latest turn adds a dark mode toggle: the request, the
///   folded exploring, the file changes (+50 −4), the tests and the answer. Its rail shows that
///   uncommitted work and pull request #128 with every check passed.
/// - `--ui-fixture-split=right` puts the running Claude Code task beside it.
/// - `--ui-fixture-settings-section=accounts|connectors` opens Settings on the same accounts and
///   connectors.
/// - `--ui-fixture-playback` plays, over and over, the dark mode task being started on the Codex
///   account with room left, beside the running Claude Code task (`ShowcasePlayback`).
///
/// Conversations go through the providers' own decoders: the Codex task is App Server items and
/// notifications through `CodexTaskReducer`, the Claude Code task stream-json lines through
/// `ClaudeSessionProjection`. Git is not faked: scripts/showcase/make-projects.sh makes the
/// projects as repositories whose uncommitted work is the same diff, and the rail reads them.
/// Nothing reaches a provider, `gh` or a connector's server.
enum ShowcaseFixture {
    static let argument = "--ui-fixture=showcase"

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }
    static var isPlaybackRequested: Bool { isRequested && CommandLine.arguments.contains("--ui-fixture-playback") }

    // MARK: Tasks

    static let darkModeTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000001")!
    static let flakyCheckoutTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000002")!
    static let imagesTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000003")!
    static let refundDocsTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000004")!
    static let rateLimitTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000005")!
    static let driverTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000006")!
    static let contrastTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000007")!
    static let tooltipTaskID = UUID(uuidString: "5C0A5E00-0000-0000-0000-000000000008")!

    static let codexThreadID = "019a2f4e-7c1d-7d40-9b5e-3f1c0a8e2d61"
    static let latestTurnID = "turn-dark-mode"

    /// Where the projects are: `--ui-fixture-workspace=<root>`, else a folder in the temporary
    /// directory (which then holds no repositories, so the rail reads no Git).
    static func root(arguments: [String] = CommandLine.arguments) -> URL {
        arguments.first(where: { $0.hasPrefix("--ui-fixture-workspace=") })
            .map { URL(filePath: String($0.dropFirst("--ui-fixture-workspace=".count)), directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "yardlet-showcase", directoryHint: .isDirectory)
    }

    /// The three projects' folders, as tasks store them (no trailing slash).
    static func projects(root: URL) -> (web: URL, api: URL, design: URL) {
        let root = root.standardizedFileURL
        return (root.appending(path: "acme-web").standardizedFileURL,
                root.appending(path: "payments-api").standardizedFileURL,
                root.appending(path: "design-system").standardizedFileURL)
    }

    static func scenario(root: URL) -> VisualFixtureScenario {
        let now = Date()
        let (web, api, design) = projects(root: root)
        // Yardlet's own place for the worktrees it makes, beside the projects' parent (the QA home).
        let worktree = root.deletingLastPathComponent()
            .appending(path: ".yardlet/worktrees/acme-web/fix-flaky-checkout").standardizedFileURL
        let cli = URL(filePath: "/usr/bin/true")

        func task(_ id: UUID, _ harness: HarnessKind, _ folder: URL, _ title: String, _ status: SessionStatus,
                  minutesAgo: Double, unread: Bool = false, connection: ProviderConnection? = nil,
                  branch: String? = nil) -> SessionRecord {
            SessionRecord(
                id: id, harness: harness, workspaceURL: folder, runtimeExecutableURL: cli, title: title,
                titleOrigin: .automatic, status: status,
                createdAt: now.addingTimeInterval(-minutesAgo * 60 - 1_800),
                updatedAt: now.addingTimeInterval(-minutesAgo * 60),
                providerSessionID: "showcase-\(id.uuidString.suffix(4))",
                hasUnreadUpdate: unread,
                completionState: status == .completed ? .completed : .none,
                connection: connection, branch: branch)
        }

        // Made in a worktree of acme-web, so the sidebar lists it there with its worktree line.
        let flakyCheckout = SessionRecord(
            id: flakyCheckoutTaskID, harness: .claudeCode, workspaceURL: worktree, runtimeExecutableURL: cli,
            title: "Fix the flaky checkout test", titleOrigin: .automatic, status: .running,
            createdAt: now.addingTimeInterval(-600), updatedAt: now, providerSessionID: "showcase-flaky-checkout",
            providerOptions: ["permissionMode": "acceptEdits"],
            originWorkspacePath: web.path(percentEncoded: false), worktreeName: "fix-flaky-checkout",
            branch: "fix/flaky-checkout")

        // The first two are the split's panes (`--ui-fixture-split=right`). The dark mode task runs
        // on the personal Codex account, the one with room left.
        let sessions = [
            task(darkModeTaskID, .codex, web, "Add a dark mode toggle to settings", .completed,
                 minutesAgo: 1, connection: Accounts.codexPersonal, branch: "feat/settings-sections"),
            flakyCheckout,
            task(imagesTaskID, .openCode, web, "Serve product images in AVIF", .completed, minutesAgo: 26, unread: true),
            task(refundDocsTaskID, .codex, api, "Document the /v2/refunds endpoint", .running,
                 minutesAgo: 3, connection: Accounts.codexPersonal),
            task(rateLimitTaskID, .claudeCode, api, "Rate-limit the public search endpoint", .completed,
                 minutesAgo: 48, unread: true),
            task(driverTaskID, .openCode, api, "Upgrade the Postgres driver", .completed, minutesAgo: 190),
            task(contrastTaskID, .claudeCode, design, "Check color tokens for contrast", .completed,
                 minutesAgo: 320, connection: Accounts.claudePersonal),
            task(tooltipTaskID, .codex, design, "Add a Tooltip component", .completed,
                 minutesAgo: 1_500)
        ]

        let webPath = web.path(percentEncoded: false)
        var scenario = VisualFixtureScenario(
            sessions: sessions,
            transcripts: [
                flakyCheckoutTaskID: flakyCheckoutTranscript(worktree: worktree),
                imagesTaskID: shortTranscript(
                    "Product images are slow on mobile. Serve them as AVIF with a WebP fallback.",
                    "Product images now go through `next/image` with `formats: [\"image/avif\", \"image/webp\"]`. "
                        + "The largest product page drops from 2.4 MB to 610 KB of images."),
                rateLimitTaskID: shortTranscript(
                    "Rate-limit /v2/search to 60 requests a minute per client.",
                    "Added `rateLimit({ perMinute: 60 })` to `/v2/search`. Over the limit it answers 429 with `Retry-After`. "
                        + "Pull request #57 is merged."),
                driverTaskID: shortTranscript(
                    "Upgrade the Postgres driver to the latest major version.",
                    "Upgraded to the new driver and replaced the two deprecated pool options. All 214 tests pass."),
                contrastTaskID: shortTranscript(
                    "Check every text color token against its surfaces for WCAG AA.",
                    "Every pair passes AA except `text.secondary` on `surface.raised` (4.2:1). "
                        + "Darkening it to `#55555c` brings it to 4.6:1.")
            ],
            errors: [:],
            codexPresentation: [
                darkModeTaskID: darkModeState(workspacePath: webPath, includesLatestTurn: true),
                refundDocsTaskID: refundDocsState(workspacePath: api.path(percentEncoded: false))
            ],
            codexQueues: [:],
            codexCapabilities: [
                darkModeTaskID: codexCapabilities,
                refundDocsTaskID: codexCapabilities,
                tooltipTaskID: codexCapabilities
            ],
            providerCapabilities: [flakyCheckoutTaskID: claudeCapabilities],
            providerUsage: [:],
            initialTaskSurface: CommandLine.arguments
                .first(where: { $0.hasPrefix("--ui-fixture-surface=") })
                .map { String($0.dropFirst("--ui-fixture-surface=".count)).lowercased() }
                .flatMap { ["chat", "diff", "terminal", "browser", "full"].contains($0) ? $0 : nil },
            initialCodexCapabilitySection: nil,
            initialCodexHistoryQuery: nil,
            initialSettingsSection: CommandLine.arguments
                .first(where: { $0.hasPrefix("--ui-fixture-settings-section=") })
                .map { String($0.dropFirst("--ui-fixture-settings-section=".count)).lowercased() },
            initialNotificationAuthorization: .authorized
        )
        scenario.projects = ProjectSnapshot(
            projects: [web, api, design].map { Project(name: $0.lastPathComponent, primaryRoot: $0) },
            didImportFolderPreferences: true)
        return scenario
    }

    /// Settings for the scene, emptied at every launch, so it neither reads nor changes the
    /// person's own.
    static func preferences() -> UserDefaults {
        let name = "NativeHarnessClient.ShowcaseFixture"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// What the model takes beyond the scenario: the connectors, the rail's order, the models, and
    /// the tasks' pull requests as GitHub would answer.
    @MainActor
    static func prepare(_ model: AppModel, root: URL) {
        let web = projects(root: root).web
        // In place before any window, so Settings and the composers read these, not the app's own.
        model.connectorCenter = connectorCenter()
        // While a script captures the windows (`--ui-fixture-ignore-pointer`), the app drops every
        // pointer event from before its first window, so wherever the person's pointer is, nothing
        // shows a hover or takes a click.
        if CommandLine.arguments.contains("--ui-fixture-ignore-pointer") {
            HoverRevealedActionsCapture.hidesActions = true
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .mouseEntered, .mouseExited, .mouseMoved, .cursorUpdate, .scrollWheel,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp
            ]) { _ in nil }
        }
        // The rail leads with the work to review and the plan, as a person may order it.
        model.sessionRailPreferences.update {
            $0 = SessionRailPreferences(order: [.changes, .progress]
                + SessionRailCardKind.defaultOrder.filter { $0 != .changes && $0 != .progress })
        }
        // The models each account's CLI would list, and the ones the tasks run on.
        let codexModels = [
            CodexModelOption(id: "gpt-5.6-codex", model: "gpt-5.6-codex", displayName: "GPT-5.6-Codex",
                             defaultReasoningEffort: "medium", supportedReasoningEfforts: ["low", "medium", "high"], isDefault: true),
            CodexModelOption(id: "gpt-5.6", model: "gpt-5.6", displayName: "GPT-5.6",
                             defaultReasoningEffort: "medium", supportedReasoningEfforts: ["low", "medium", "high"], isDefault: false)
        ]
        for session in model.store.sessions where session.harness == .codex {
            model.modelCatalogs.recordCodex(CodexModelCatalog(
                models: codexModels, selection: CodexModelSelection(model: "gpt-5.6-codex", reasoningEffort: "high")), for: session)
        }
        let url = URL(string: "https://github.com/acme/acme-web/pull/128")!
        model.pullRequests.setPullRequest(
            TaskPullRequest(number: 128, url: url, repository: "acme/acme-web", source: .branch("feat/settings-sections"),
                            state: .open, checks: .passing, review: .approved),
            for: darkModeTaskID)
        var state = PullRequestDetailCenter.TaskState(url: url, folder: web, repository: "acme/acme-web")
        state.detail = GitHubPullRequestDetailParser.parse(Data(pullRequestJSON(url: url).utf8))
        state.mergeMethods = .all
        state.lastAsked = Date()
        model.pullRequestDetails.setState(state, for: darkModeTaskID)
        // Answered already, so the card does not ask about auto-fix.
        model.pullRequestDetails.setAutoFix(false, taskID: darkModeTaskID)
        model.pullRequests.setPullRequest(
            TaskPullRequest(number: 57, url: URL(string: "https://github.com/acme/payments-api/pull/57")!,
                            repository: "acme/payments-api", state: .merged, checks: .passing, review: .approved),
            for: rateLimitTaskID)
    }

    private static func pullRequestJSON(url: URL) -> String {
        let format = ISO8601DateFormatter()
        func ago(_ minutes: Double) -> String { format.string(from: Date().addingTimeInterval(-minutes * 60)) }
        func check(_ name: String, _ workflow: String, job: Int, started: Double, took: Double) -> String {
            #"{"__typename":"CheckRun","name":"\#(name)","workflowName":"\#(workflow)","status":"COMPLETED","conclusion":"SUCCESS","#
                + #""startedAt":"\#(ago(started))","completedAt":"\#(ago(started - took))","#
                + #""detailsUrl":"https://github.com/acme/acme-web/actions/runs/18204/job/\#(job)"}"#
        }
        return """
            {"autoMergeRequest":null,"baseRefName":"main","headRefName":"feat/settings-sections",
             "headRefOid":"4f2c9a71d0b8e35a6c1f7e2d9b40a8c6e5d3f219","isDraft":false,
             "latestReviews":[{"author":{"login":"sam-rivera"},"authorAssociation":"MEMBER","body":"Looks great.",
               "submittedAt":"\(ago(12))","state":"APPROVED","commit":{"oid":"4f2c9a71d0b8e35a6c1f7e2d9b40a8c6e5d3f219"}}],
             "mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","number":128,"reviewDecision":"APPROVED",
             "state":"OPEN","title":"Split settings into sections","url":"\(url.absoluteString)",
             "statusCheckRollup":[
              \(check("build", "CI", job: 1, started: 19, took: 2.4)),
              \(check("test", "CI", job: 2, started: 19, took: 3.1)),
              \(check("lint", "CI", job: 3, started: 19, took: 0.8)),
              \(check("e2e", "CI", job: 4, started: 18, took: 4.6)),
              {"__typename":"StatusContext","context":"preview","state":"SUCCESS",
               "targetUrl":"https://example.com/previews/acme-web-128","startedAt":"\(ago(17))"}
             ]}
            """
    }

    @MainActor private static var pointerMonitor: Any?

    /// Once the window is up: the playback when asked for, and a pointer that passes through.
    @MainActor
    static func install(in model: AppModel) {
        guard isRequested, model.usesVisualFixture else { return }
        if isPlaybackRequested { ShowcasePlayback.start(model: model) }
        // While a script captures the windows, clicks pass through them to the person's own windows,
        // and each goes behind those, out of their way (the capture draws it whatever covers it).
        if CommandLine.arguments.contains("--ui-fixture-ignore-pointer") {
            Task { @MainActor in
                var placed = Set<ObjectIdentifier>()
                for _ in 0..<20 {
                    for window in NSApp.windows {
                        window.ignoresMouseEvents = true
                        guard window.isVisible, window.sheetParent == nil, window.parent == nil,
                              placed.insert(ObjectIdentifier(window)).inserted else { continue }
                        // Only its place in the order: hiding and showing it again would hand its
                        // keyboard focus to the first control, which then shows its actions.
                        window.orderBack(nil)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    // MARK: Accounts and connectors

    /// The person's accounts. Codex and Claude Code each have their own home's login (work,
    /// jordan@example.com), which Settings › Accounts lists first, and a saved personal account;
    /// OpenCode has the provider it is set up with. Each shows the usage its harness reports: the
    /// work Codex login has 6% of its five-hour limit left, the personal one 88%.
    enum Accounts {
        static let codexPersonal = ProviderConnection(id: "showcase-codex-personal", name: "Personal", harness: .codex,
            providerID: "openai-codex", homePath: "/tmp/yardlet-showcase-accounts/codex-personal", credentialSelector: nil)
        static let claudePersonal = ProviderConnection(id: "showcase-claude-personal", name: "Personal", harness: .claudeCode,
            providerID: "anthropic", homePath: "/tmp/yardlet-showcase-accounts/claude-personal", credentialSelector: nil)

        static func usage(_ shortUsed: Double, _ longUsed: Double, resetsIn hours: Double, now: Date) -> [AccountUsageMetric] {
            [
                AccountUsageMetric(id: "short", label: L10n.format("%.0f hour limit", 5.0), usedFraction: shortUsed,
                    detail: L10n.format("%.0f%% remaining", (1 - shortUsed) * 100),
                    resetsAt: now.addingTimeInterval(hours * 3_600), evidence: .exactQuota),
                AccountUsageMetric(id: "long", label: L10n.format("%.0f day limit", 7.0), usedFraction: longUsed,
                    detail: L10n.format("%.0f%% remaining", (1 - longUsed) * 100),
                    resetsAt: now.addingTimeInterval(3 * 86_400), evidence: .exactQuota)
            ]
        }

        /// The fixtures' default logins (`VisualFixtureScenario.harnessCenterSnapshots`) with Codex's
        /// and Claude Code's in the person's name.
        static func defaultSnapshots(replacing base: [HarnessAccountSnapshot]) -> [HarnessAccountSnapshot] {
            let now = Date()
            let own = [
                HarnessAccountSnapshot(id: HarnessKind.codex.rawValue, harness: .codex, providerID: "openai-codex",
                    state: .signedIn, accountLabel: "jordan@example.com", accountPlan: L10n.format("ChatGPT %@ plan", "Pro"),
                    detail: "", credentialOwner: L10n.string("Codex CLI / system credential store"), checkedAt: now,
                    usage: usage(0.94, 0.58, resetsIn: 1.2, now: now), canLogin: false, canLogout: false),
                HarnessAccountSnapshot(id: HarnessKind.claudeCode.rawValue, harness: .claudeCode, providerID: "anthropic",
                    state: .signedIn, accountLabel: "jordan@example.com", accountPlan: "Claude Max",
                    detail: "", credentialOwner: "Claude Code", checkedAt: now,
                    usage: usage(0.41, 0.28, resetsIn: 1.5, now: now), canLogin: false, canLogout: false)
            ]
            return base.map { snapshot in own.first { $0.harness == snapshot.harness } ?? snapshot }
        }

        @MainActor
        static func add(to connections: ProviderConnectionStore, selections: RuntimeSelectionStore) {
            connections.usesFixtureSnapshots = true
            for harness in [HarnessKind.codex, .claudeCode, .openCode] {
                selections.select(URL(filePath: "/usr/bin/true"), for: harness)
            }
            let now = Date()
            connections.publishDefaults(VisualFixtureScenario.harnessCenterSnapshots)
            let accounts: [(ProviderConnection, String, String?, [AccountUsageMetric])] = [
                (codexPersonal, "jpark@example.net", L10n.format("ChatGPT %@ plan", "Plus"),
                 usage(0.12, 0.46, resetsIn: 4, now: now)),
                (claudePersonal, "jpark@example.net", "Claude Pro", usage(0.63, 0.52, resetsIn: 3, now: now))
            ]
            for (connection, label, plan, metrics) in accounts {
                try? connections.save(connection)
                connections.publish(HarnessAccountSnapshot(
                    id: connection.id, harness: connection.harness, providerID: connection.providerID,
                    state: .signedIn, accountLabel: label, accountPlan: plan, detail: "",
                    credentialOwner: connection.harness.rawValue, checkedAt: now, usage: metrics,
                    canLogin: false, canLogout: false), for: connection)
            }
        }
    }

    /// Settings › Connectors and the composer's connectors: services already connected, in memory,
    /// with their tools as the servers listed them. Nothing connects, signs in or fetches.
    @MainActor
    static func connectorCenter() -> ConnectorCenter {
        func tools(_ names: [String]) -> [ToolJSON] {
            names.map { .object(["name": .string($0), "description": .string($0.replacingOccurrences(of: "_", with: " "))]) }
        }
        let now = Date()
        let records = [
            ConnectorRecord(name: "GitHub", slug: "github", serverURL: URL(string: "https://api.githubcopilot.com/mcp/")!,
                            authorization: .token, status: .connected,
                            tools: tools(["search_code", "get_pull_request", "create_pull_request", "list_issues", "add_issue_comment"]),
                            toolsUpdatedAt: now, presetID: "github", account: "jordan-park"),
            ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                            authorization: .oauth, status: .connected,
                            tools: tools(["list_issues", "get_issue", "save_issue", "list_projects", "save_comment"]),
                            toolsUpdatedAt: now, presetID: "linear", account: "jordan@example.com"),
            ConnectorRecord(name: "Notion", slug: "notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!,
                            authorization: .oauth, status: .connected,
                            tools: tools(["search", "fetch", "create_pages", "update_page"]),
                            toolsUpdatedAt: now, presetID: "notion", account: "jordan@example.com"),
            ConnectorRecord(name: "Sentry", slug: "sentry", serverURL: URL(string: "https://mcp.sentry.dev/mcp")!,
                            authorization: .oauth, status: .connected,
                            tools: tools(["search_issues", "get_issue_details", "list_events"]),
                            toolsUpdatedAt: now, presetID: "sentry", account: "acme"),
            ConnectorRecord(name: "Slack", slug: "slack", serverURL: URL(string: "https://mcp.slack.com/mcp")!,
                            authorization: .oauth, status: .connected,
                            tools: tools(["search_messages", "read_channel", "send_message"]),
                            toolsUpdatedAt: now, presetID: "slack", account: "Acme")
        ]
        return ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records), credentials: InMemoryConnectorCredentialStore(),
            http: NoConnectorTransport(), userAgent: nil, sha256: { $0 }, clientVersion: "0"))
    }

    private struct NoConnectorTransport: ConnectorHTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    // MARK: Composer options

    static let codexCapabilities = CodexCapabilityState(
        modes: [
            CodexCollaborationPreset(name: "Default", mode: "default", model: "gpt-5.6-codex", reasoningEffort: "high"),
            CodexCollaborationPreset(name: "Plan", mode: "plan", model: "gpt-5.6-codex", reasoningEffort: "high")
        ],
        selectedModeID: nil, skills: [], plugins: [])

    static let claudeCapabilities = ProviderCapabilityState(selectors: [
        ProviderCapabilitySelector(id: "model", name: L10n.string("Model"), description: nil, category: "model",
            currentValue: "opus", choices: [
                ProviderCapabilityChoice(value: "opus", name: "Opus", description: nil),
                ProviderCapabilityChoice(value: "sonnet", name: "Sonnet", description: nil)
            ]),
        ProviderCapabilitySelector(id: "permissionMode", name: L10n.string("Permission mode"), description: nil,
            category: "mode", currentValue: "acceptEdits", choices: [
                ProviderCapabilityChoice(value: "default", name: L10n.string("Manual"), description: nil),
                ProviderCapabilityChoice(value: "acceptEdits", name: "Accept edits", description: nil),
                ProviderCapabilityChoice(value: "plan", name: L10n.string("Plan"), description: nil)
            ])
    ])

    // MARK: The Codex task

    static let latestRequest = "Add a dark mode toggle to the settings page. Follow the system appearance by default and remember the choice."

    /// The dark mode task's thread: an earlier turn that opened #128, then, unless the playback is
    /// about to play it, the latest turn complete.
    static func darkModeState(workspacePath: String, includesLatestTurn: Bool) -> CodexTaskState {
        let reducer = CodexTaskReducer()
        let started = Date().addingTimeInterval(-40 * 60).timeIntervalSince1970
        let earlier: JSONValue = .object([
            "id": .string("turn-sections"), "status": .string("completed"),
            "startedAt": .integer(Int64(started)), "durationMs": .integer(150_000), "itemsView": .string("full"),
            "items": .array([
                userMessage("user-sections", "Split the settings page into Profile, Appearance and Notifications sections, then open a PR."),
                command("cmd-sections-1", "sed -n 1,40p src/app/settings/page.tsx", in: workspacePath,
                        output: "export default function SettingsPage() {\n  return (\n    <main className=\"settings\">",
                        actions: [read("page.tsx", "src/app/settings/page.tsx")]),
                command("cmd-sections-2", "git push -u origin feat/settings-sections && gh pr create --fill", in: workspacePath,
                        output: "https://github.com/acme/acme-web/pull/128"),
                agentMessage("answer-sections", """
                    Settings now has three sections, each in a shared `Section` component. \
                    Appearance is empty for now, with a TODO for the theme.

                    Opened [#128](https://github.com/acme/acme-web/pull/128) from `feat/settings-sections`.
                    """, phase: "final_answer")
            ])
        ])
        var turns = [earlier]
        if includesLatestTurn {
            turns.append(.object([
                "id": .string(latestTurnID), "status": .string("completed"),
                "startedAt": .integer(Int64(Date().addingTimeInterval(-3 * 60).timeIntervalSince1970)),
                "durationMs": .integer(Int64(latestTurnDurationMs)), "itemsView": .string("full"),
                "items": .array([userMessage("user-dark-mode", latestRequest)] + latestTurnItems(workspacePath: workspacePath))
            ]))
        }
        var state = CodexTaskState.empty
        _ = reducer.applySnapshot(.object([
            "id": .string(codexThreadID), "name": .string("Add a dark mode toggle to settings"),
            "preview": .string(latestRequest), "cwd": .string(workspacePath),
            "status": .object(["type": .string("idle")]), "turns": .array(turns)
        ]), to: &state)
        var sequence: UInt64 = 0
        func notify(_ method: String, _ params: [String: JSONValue]) {
            sequence += 1
            var params = params
            params["threadId"] = .string(codexThreadID)
            _ = reducer.applyNotification(method: method, params: .object(params), sequence: sequence, to: &state)
        }
        // The earlier turn's plan and the context so far stay the same with or without the latest
        // turn, so a playback round ends and starts with the rail as it was.
        notify("turn/plan/updated", ["turnId": .string("turn-sections"), "plan": .array(
            ["Read the settings page", "Split it into sections", "Open a pull request"].map {
                .object(["step": .string($0), "status": .string("completed")])
            })])
        if includesLatestTurn {
            notify("turn/plan/updated", ["turnId": .string(latestTurnID), "plan": plan(done: latestPlan.count)])
            notify("turn/diff/updated", ["turnId": .string(latestTurnID), "diff": .string(latestTurnDiff)])
        }
        notify("thread/tokenUsage/updated", ["turnId": .string(includesLatestTurn ? latestTurnID : "turn-sections"),
                                             "tokenUsage": tokenUsage(61_420)])
        return state
    }

    /// The dark mode task as the playback starts it: a new thread with nothing in it yet.
    static func newTaskState(workspacePath: String) -> CodexTaskState {
        var state = CodexTaskState.empty
        _ = CodexTaskReducer().applySnapshot(.object([
            "id": .string(codexThreadID), "name": .string("Add a dark mode toggle to settings"),
            "preview": .string(latestRequest), "cwd": .string(workspacePath),
            "status": .object(["type": .string("idle")]), "turns": .array([])
        ]), to: &state)
        return state
    }

    /// The playback shows the turn's seconds counting from 4 to 14; the still says the same.
    static let latestTurnDurationMs = 14_400

    static let latestPlan = [
        "Read how the theme is set today",
        "Add a system option and remember the choice",
        "Put a toggle in Settings › Appearance",
        "Run the tests and lint"
    ]

    static func plan(done: Int) -> JSONValue {
        .array(latestPlan.enumerated().map { index, step in
            .object(["step": .string(step), "status": .string(index < done ? "completed" : index == done ? "inProgress" : "pending")])
        })
    }

    static func tokenUsage(_ total: Int) -> JSONValue {
        let usage: JSONValue = .object([
            "inputTokens": .integer(Int64(total - total / 12)), "cachedInputTokens": .integer(Int64(total / 2)),
            "cacheWriteInputTokens": .integer(0), "outputTokens": .integer(Int64(total / 12)),
            "reasoningOutputTokens": .integer(Int64(total / 30)), "totalTokens": .integer(Int64(total))
        ])
        return .object(["total": usage, "last": usage, "modelContextWindow": .integer(272_000)])
    }

    /// The latest turn after its request, in the order the playback shows them. The playback's new
    /// task has no pull request yet, so its answer offers to open one (`newTaskAnswer`).
    static func latestTurnItems(workspacePath: String, answer: String = latestAnswer) -> [JSONValue] {
        [
            agentMessage("note-dark-mode-1", "I’ll look at how the theme is set and where the settings page leaves room for it.",
                         phase: "commentary"),
            command("cmd-dark-mode-1", #"rg -n "theme" src"#, in: workspacePath, output: """
                src/app/layout.tsx:5:    <html lang="en" data-theme="light">
                src/app/settings/page.tsx:11:        {/* TODO: theme */}
                src/lib/theme.ts:1:export type Theme = "light";
                src/lib/theme.ts:3:export const defaultTheme: Theme = "light";
                """, actions: [search("theme", "src")], durationMs: 41),
            command("cmd-dark-mode-2", "cat src/lib/theme.ts", in: workspacePath, output: """
                export type Theme = "light";

                export const defaultTheme: Theme = "light";

                export function applyTheme(theme: Theme) {
                  document.documentElement.dataset.theme = theme;
                }
                """, actions: [read("theme.ts", "src/lib/theme.ts")], durationMs: 12),
            command("cmd-dark-mode-3", "sed -n 1,40p src/app/settings/page.tsx", in: workspacePath,
                    output: "import { Section } from \"@/components/Section\";\n…",
                    actions: [read("page.tsx", "src/app/settings/page.tsx")], durationMs: 10),
            agentMessage("note-dark-mode-2", """
                The theme is fixed to light. I’ll add a `system` choice that follows `prefers-color-scheme`, \
                keep the person’s choice in `localStorage`, and put a three-way toggle in Appearance.
                """, phase: "commentary"),
            fileChange("patch-dark-mode", workspacePath: workspacePath),
            command("cmd-dark-mode-4", "pnpm test settings theme", in: workspacePath, output: testOutput, durationMs: 2_410),
            command("cmd-dark-mode-5", "pnpm lint", in: workspacePath, output: "✔ No ESLint warnings or errors", durationMs: 3_870),
            agentMessage("answer-dark-mode", answer, phase: "final_answer")
        ]
    }

    static let testOutput = """

         RUN  v3.2.4

         ✓ src/lib/theme.test.ts (5 tests) 4ms
         ✓ src/components/ThemeToggle.test.tsx (4 tests) 38ms
         ✓ src/app/settings/page.test.tsx (3 tests) 61ms

         Test Files  3 passed (3)
              Tests  12 passed (12)
           Duration  2.41s
        """

    static let latestAnswer = """
        Settings › Appearance now has a **System / Light / Dark** toggle.

        - **`src/lib/theme.ts`**: `system` is the new default and follows `prefers-color-scheme`. The choice is saved under `acme.theme` and read back with `savedTheme()`.
        - **`src/components/ThemeToggle.tsx`**: a segmented control that applies the theme as soon as it changes.
        - **`src/app/settings/page.tsx`**: the toggle takes the place of the TODO.

        `pnpm test` passes (12 tests) and lint is clean. These changes are not committed yet; say the word and I’ll push them to #128.
        """

    static var newTaskAnswer: String {
        latestAnswer.replacingOccurrences(of: "I’ll push them to #128.", with: "I’ll open a pull request.")
    }

    /// The dark mode change as App Server's `fileChange` item has it: hunks for an update, the
    /// whole text for an added file. It is the diff make-projects.sh leaves uncommitted.
    static func fileChange(_ id: String, workspacePath: String, status: String = "completed") -> JSONValue {
        func change(_ path: String, _ kind: String, _ diff: String) -> JSONValue {
            .object(["path": .string(workspacePath + "/" + path),
                     "kind": .object(kind == "update" ? ["type": .string(kind), "move_path": .null] : ["type": .string(kind)]),
                     "diff": .string(diff)])
        }
        return .object([
            "id": .string(id), "type": .string("fileChange"), "status": .string(status),
            "changes": .array([
                change("src/lib/theme.ts", "update", """
                    @@ -1,7 +1,16 @@
                    -export type Theme = "light";
                    +export type Theme = "system" | "light" | "dark";

                    -export const defaultTheme: Theme = "light";
                    +export const defaultTheme: Theme = "system";
                    +const storageKey = "acme.theme";
                    +
                    +export function savedTheme(): Theme {
                    +  const value = localStorage.getItem(storageKey);
                    +  return value === "light" || value === "dark" ? value : defaultTheme;
                    +}

                     export function applyTheme(theme: Theme) {
                    -  document.documentElement.dataset.theme = theme;
                    +  localStorage.setItem(storageKey, theme);
                    +  const dark = theme === "dark"
                    +    || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
                    +  document.documentElement.dataset.theme = dark ? "dark" : "light";
                     }

                    """),
                change("src/components/ThemeToggle.tsx", "add", themeToggleSource),
                change("src/app/settings/page.tsx", "update", """
                    @@ -1,4 +1,5 @@
                     import { Section } from "@/components/Section";
                    +import { ThemeToggle } from "@/components/ThemeToggle";

                     export default function SettingsPage() {
                       return (
                    @@ -8,7 +9,7 @@ export default function SettingsPage() {
                             <ProfileForm />
                           </Section>
                           <Section title="Appearance">
                    -        {/* TODO: theme */}
                    +        <ThemeToggle />
                           </Section>
                           <Section title="Notifications">
                             <NotificationPreferences />

                    """)
            ])
        ])
    }

    /// The turn's diff, for the review panel's Last turn.
    static var latestTurnDiff: String {
        """
        diff --git a/src/lib/theme.ts b/src/lib/theme.ts
        --- a/src/lib/theme.ts
        +++ b/src/lib/theme.ts
        @@ -1,7 +1,16 @@
        -export type Theme = "light";
        +export type Theme = "system" | "light" | "dark";

        -export const defaultTheme: Theme = "light";
        +export const defaultTheme: Theme = "system";
        +const storageKey = "acme.theme";
        +
        +export function savedTheme(): Theme {
        +  const value = localStorage.getItem(storageKey);
        +  return value === "light" || value === "dark" ? value : defaultTheme;
        +}

         export function applyTheme(theme: Theme) {
        -  document.documentElement.dataset.theme = theme;
        +  localStorage.setItem(storageKey, theme);
        +  const dark = theme === "dark"
        +    || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
        +  document.documentElement.dataset.theme = dark ? "dark" : "light";
         }
        diff --git a/src/components/ThemeToggle.tsx b/src/components/ThemeToggle.tsx
        new file mode 100644
        --- /dev/null
        +++ b/src/components/ThemeToggle.tsx
        @@ -0,0 +1,36 @@

        """ + themeToggleSource.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            .map { "+" + $0 }.joined(separator: "\n") + "\n" + """
        diff --git a/src/app/settings/page.tsx b/src/app/settings/page.tsx
        --- a/src/app/settings/page.tsx
        +++ b/src/app/settings/page.tsx
        @@ -1,4 +1,5 @@
         import { Section } from "@/components/Section";
        +import { ThemeToggle } from "@/components/ThemeToggle";

         export default function SettingsPage() {
           return (
        @@ -8,7 +9,7 @@ export default function SettingsPage() {
                 <ProfileForm />
               </Section>
               <Section title="Appearance">
        -        {/* TODO: theme */}
        +        <ThemeToggle />
               </Section>
               <Section title="Notifications">
                 <NotificationPreferences />

        """
    }

    static let themeToggleSource = """
        "use client";

        import { useEffect, useState } from "react";
        import { applyTheme, savedTheme, type Theme } from "@/lib/theme";

        const choices: { value: Theme; label: string }[] = [
          { value: "system", label: "System" },
          { value: "light", label: "Light" },
          { value: "dark", label: "Dark" },
        ];

        export function ThemeToggle() {
          const [theme, setTheme] = useState<Theme>("system");

          useEffect(() => setTheme(savedTheme()), []);

          function choose(next: Theme) {
            setTheme(next);
            applyTheme(next);
          }

          return (
            <div role="radiogroup" aria-label="Theme" className="segmented">
              {choices.map((choice) => (
                <button
                  key={choice.value}
                  role="radio"
                  aria-checked={theme === choice.value}
                  onClick={() => choose(choice.value)}
                >
                  {choice.label}
                </button>
              ))}
            </div>
          );
        }

        """

    /// A second Codex task, mid-turn: it has read the route and is writing the reference.
    static func refundDocsState(workspacePath: String) -> CodexTaskState {
        var state = CodexTaskState.empty
        _ = CodexTaskReducer().applySnapshot(.object([
            "id": .string("019a2f51-0b6e-7a92-8c3d-5e7f1a2b4c90"), "name": .string("Document the /v2/refunds endpoint"),
            "cwd": .string(workspacePath),
            "status": .object(["type": .string("active"), "activeFlags": .array([.string("turn")])]),
            "turns": .array([.object([
                "id": .string("turn-refund-docs"), "status": .string("inProgress"),
                "startedAt": .integer(Int64(Date().addingTimeInterval(-95).timeIntervalSince1970)), "itemsView": .string("full"),
                "items": .array([
                    userMessage("user-refund-docs", "Write the OpenAPI reference for /v2/refunds, with an example for each error."),
                    command("cmd-refund-docs-1", "rg -n \"refunds\" src/routes", in: workspacePath,
                            output: "src/routes/refunds.ts:8:refunds.post(\"/v2/refunds\", …", actions: [search("refunds", "src/routes")]),
                    agentMessage("note-refund-docs", "The route has four error cases. I’m writing the schema for each one now.",
                                 phase: "commentary")
                ])
            ])])
        ]), to: &state)
        return state
    }

    // MARK: App Server items

    static func userMessage(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    static func agentMessage(_ id: String, _ text: String, phase: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "phase": .string(phase), "text": .string(text)])
    }

    /// A command as Codex runs it, in its login shell, with what the server parsed it into.
    static func command(_ id: String, _ script: String, in workspacePath: String, output: String?,
                        actions: [JSONValue] = [], durationMs: Int = 800, status: String = "completed") -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(id), "type": .string("commandExecution"),
            "command": .string("/bin/zsh -lc '\(script.replacingOccurrences(of: "'", with: "'\\''"))'"),
            "cwd": .string(workspacePath), "status": .string(status),
            "commandActions": .array(actions.isEmpty ? [.object(["type": .string("unknown"), "command": .string(script)])] : actions)
        ]
        if status == "completed" {
            item["aggregatedOutput"] = output.map(JSONValue.string) ?? .null
            item["exitCode"] = .integer(0)
            item["durationMs"] = .integer(Int64(durationMs))
        } else {
            item["aggregatedOutput"] = .null
        }
        return .object(item)
    }

    static func read(_ name: String, _ path: String) -> JSONValue {
        .object(["type": .string("read"), "name": .string(name), "path": .string(path), "command": .string("cat \(path)")])
    }

    static func search(_ query: String, _ path: String) -> JSONValue {
        .object(["type": .string("search"), "query": .string(query), "path": .string(path),
                 "command": .string("rg -n \"\(query)\" \(path)")])
    }

    // MARK: The Claude Code task

    /// The running Claude Code task, as its stream-json would have it so far: it reproduced the
    /// failure, found the fixed wait, replaced it, and is running the test fifty times. `finished`,
    /// as the playback ends it: the fifty runs passed and it says so.
    static func flakyCheckoutTranscript(worktree: URL, finished: Bool = false) -> [TranscriptEntry] {
        let folder = worktree.path(percentEncoded: false)
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("The checkout e2e test fails about one run in five on CI. Find out why and fix it.")
        func line(_ object: [String: JSONValue]) {
            guard let data = try? JSONEncoder().encode(JSONValue.object(object)),
                  let frame = try? ClaudeWireCodec().decodeLine(data) else { return }
            for payload in projection.payloads(from: frame) { builder.apply(payload) }
        }
        func assistant(_ content: [JSONValue]) {
            line(["type": .string("assistant"), "message": .object(["role": .string("assistant"), "content": .array(content)])])
        }
        func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }
        func tool(_ id: String, _ name: String, _ input: [String: JSONValue]) -> JSONValue {
            .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": .object(input)])
        }
        func result(_ id: String, _ content: String) {
            line(["type": .string("user"), "message": .object(["role": .string("user"), "content": .array([
                .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(content)])
            ])])])
        }
        func todos(_ done: Int) -> [String: JSONValue] {
            let steps = [("Reproduce the failure", "Reproducing the failure"), ("Find the cause", "Finding the cause"),
                         ("Wait for the Pay button instead of a fixed delay", "Replacing the fixed delay"),
                         ("Confirm with 50 runs", "Running the test 50 times")]
            return ["todos": .array(steps.enumerated().map { index, step in
                .object(["content": .string(step.0), "activeForm": .string(step.1),
                         "status": .string(index < done ? "completed" : index == done ? "in_progress" : "pending")])
            })]
        }

        assistant([text("I’ll run the test repeatedly to reproduce the failure first."), tool("todo-1", "TodoWrite", todos(0))])
        result("todo-1", "Todos have been modified successfully")
        assistant([tool("bash-1", "Bash", ["command": .string("pnpm playwright test checkout.spec.ts --repeat-each=20"),
                                             "description": .string("Run the checkout test 20 times")])])
        result("bash-1", "Running 20 tests using 4 workers\n\n  3 failed\n    [chromium] › checkout.spec.ts:3:5 › a signed-in shopper can pay for their cart\n  17 passed (1.4m)")
        assistant([tool("read-1", "Read", ["file_path": .string(folder + "/tests/e2e/checkout.spec.ts")])])
        result("read-1", """
                 1→import { expect, test } from "@playwright/test";
                 2→
                 3→test("a signed-in shopper can pay for their cart", async ({ page }) => {
                 4→  await page.goto("/cart");
                 5→  await page.getByRole("button", { name: "Check out" }).click();
                 6→  await page.getByLabel("Card number").fill("4242 4242 4242 4242");
                 7→  await page.waitForTimeout(500);
                 8→  await page.getByRole("button", { name: "Pay" }).click();
                 9→  await expect(page.getByText("Thanks for your order")).toBeVisible();
                10→});
            """)
        assistant([text("""
            The test waits a fixed 500 ms after filling the card and then clicks **Pay**. The button stays disabled \
            until the card is validated, which takes longer than that on a busy CI runner, so the click lands on a \
            disabled button about one time in five.

            I’ll wait for the button to be enabled instead of sleeping.
            """), tool("todo-2", "TodoWrite", todos(2))])
        result("todo-2", "Todos have been modified successfully")
        assistant([tool("edit-1", "Edit", [
            "file_path": .string(folder + "/tests/e2e/checkout.spec.ts"),
            "old_string": .string("  await page.waitForTimeout(500);\n  await page.getByRole(\"button\", { name: \"Pay\" }).click();"),
            "new_string": .string("  const pay = page.getByRole(\"button\", { name: \"Pay\" });\n  await expect(pay).toBeEnabled();\n  await pay.click();")
        ])])
        result("edit-1", "The file \(folder)/tests/e2e/checkout.spec.ts has been updated successfully.")
        assistant([tool("todo-3", "TodoWrite", todos(3))])
        result("todo-3", "Todos have been modified successfully")
        assistant([tool("bash-2", "Bash", ["command": .string("pnpm playwright test checkout.spec.ts --repeat-each=50"),
                                             "description": .string("Run the checkout test 50 times")])])
        guard finished else { return builder.entries }
        result("bash-2", "Running 50 tests using 4 workers\n\n  50 passed (3.4m)")
        assistant([tool("todo-4", "TodoWrite", todos(4))])
        result("todo-4", "Todos have been modified successfully")
        assistant([text("""
            All 50 runs passed. The test now waits for **Pay** to be enabled instead of sleeping for 500 ms, \
            so a slow card check on CI no longer lands the click on a disabled button.
            """)])
        line(["type": .string("result"), "subtype": .string("success"), "is_error": .bool(false),
              "duration_ms": .integer(214_000), "num_turns": .integer(9), "result": .string("All 50 runs passed.")])
        return builder.entries
    }

    /// A finished task's request and answer.
    static func shortTranscript(_ request: String, _ answer: String) -> [TranscriptEntry] {
        [TranscriptEntry(content: .user(text: request)), TranscriptEntry(content: .assistant(text: answer, isStreaming: false))]
    }
}
#endif
