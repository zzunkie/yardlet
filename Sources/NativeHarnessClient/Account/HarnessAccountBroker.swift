import Foundation

actor HarnessAccountBroker {
    private var codexAccountMonitor: CodexAccountMonitor?
    private let codexEnvironmentManager: CodexEnvironmentManager?
    private let connection: ProviderConnection?
    private let museUsageStore: MuseSubscriptionUsageStore

    init(
        codexEnvironmentManager: CodexEnvironmentManager? = nil,
        connection: ProviderConnection? = nil,
        museUsageStore: MuseSubscriptionUsageStore = .shared
    ) {
        self.connection = connection
        self.codexEnvironmentManager = connection?.codexEnvironmentManager() ?? codexEnvironmentManager
        self.museUsageStore = museUsageStore
    }

    func snapshot(
        for descriptor: HarnessDescriptor,
        executableURL: URL?
    ) async -> HarnessAccountSnapshot {
        guard let executableURL else { return .unavailable(for: descriptor) }
        do {
            if descriptor.id == .codex {
                return try await codexSnapshot(executableURL: executableURL)
            }
            if descriptor.id == .pi {
                return try await piCodexSnapshot(executableURL: executableURL)
            }
            if descriptor.id == .antigravityCLI {
                return antigravitySnapshot(descriptor: descriptor)
            }
            if descriptor.id == .museCode {
                return await museCodeSnapshot(descriptor: descriptor)
            }
            return try await commandSnapshot(
                descriptor: descriptor,
                executableURL: executableURL
            )
        } catch {
            return HarnessAccountSnapshot(
                id: descriptor.id == .pi ? "pi:openai-codex" : descriptor.id.rawValue,
                harness: descriptor.id,
                providerID: connection?.providerID ?? (descriptor.id == .pi ? Self.piConfiguredProvider(homePath: connection?.homePath) : nil),
                state: .unknown,
                accountLabel: nil,
                detail: error.localizedDescription,
                credentialOwner: descriptor.displayName,
                checkedAt: Date(),
                usage: [notExposedUsage()],
                canLogin: supportsLogin(descriptor.id),
                canLogout: false
            )
        }
    }

    /// Starts the account-center-scoped Codex notification monitor. The caller must
    /// stop it when the Account Center closes so a dormant account sheet cannot keep
    /// an App Server process alive.
    func startCodexAccountUpdates(
        executableURL: URL
    ) async throws -> AsyncStream<HarnessAccountSnapshot> {
        if let codexAccountMonitor {
            return try await codexAccountMonitor.start()
        }
        let monitor = CodexAccountMonitor(
            executableURL: executableURL,
            environmentManager: codexEnvironmentManager
        )
        codexAccountMonitor = monitor
        do {
            return try await monitor.start()
        } catch {
            codexAccountMonitor = nil
            throw error
        }
    }

    func stopCodexAccountUpdates() async {
        let monitor = codexAccountMonitor
        codexAccountMonitor = nil
        await monitor?.stop()
    }

    func loginCommand(
        for harness: HarnessKind,
        executableURL: URL
    ) async -> AccountInteractiveCommand? {
        let arguments: [String]
        let initialInput: String?
        let startupMessage: String?
        switch harness {
        case .codex:
            arguments = ["login"]
            initialInput = nil
            startupMessage = nil
        case .claudeCode:
            arguments = ["auth", "login"]
            initialInput = nil
            startupMessage = nil
        case .cursorAgent:
            arguments = ["login"]
            initialInput = nil
            startupMessage = nil
        case .grokBuild:
            arguments = ["login", "--device-auth"]
            initialInput = nil
            startupMessage = nil
        case .kimiCode:
            arguments = ["login"]
            initialInput = nil
            startupMessage = nil
        case .hermes:
            // Hermes owns provider/model selection and authentication. Its ACP
            // --check only checks imports; it is never account evidence.
            arguments = ["acp", "--setup"]
            initialInput = nil
            startupMessage = nil
        case .openCode:
            // OpenCode owns its provider picker and provider-specific authentication.
            arguments = ["auth", "login"]
            initialInput = nil
            startupMessage = nil
        case .museCode:
            // Muse owns the browser/device-code handoff. Yardlet only hosts the
            // official command's terminal and never handles the credential.
            arguments = ["login"]
            initialInput = nil
            startupMessage = nil
        case .antigravityCLI:
            guard executableURL.lastPathComponent == "agy" else { return nil }
            arguments = []
            // Current agy releases first present a TUI-owned login-method picker.
            // The Account Center's primary sign-in action means the default Google
            // OAuth choice, so confirm that highlighted choice and let agy open its
            // own browser flow. Without this input the console waits indefinitely.
            initialInput = "\r"
            startupMessage = [
                L10n.string("Opening Antigravity CLI sign-in…"),
                L10n.string("Antigravity uses its own browser sign-in. Keep this window open until authentication finishes.")
            ].joined(separator: "\n") + "\n"
        case .pi:
            arguments = []
            initialInput = connection?.providerID.map { "/login \($0)\r" } ?? "/login\r"
            startupMessage = nil
        default:
            return nil
        }
        let environment: [String: String]
        if harness == .codex, let codexEnvironmentManager {
            guard let nativeEnvironment = try? await codexEnvironmentManager
                .processEnvironment().values else { return nil }
            environment = Self.codexEnvironmentOverrides(from: nativeEnvironment)
        } else {
            environment = connection?.environment ?? [:]
        }
        return AccountInteractiveCommand(
            executableURL: executableURL,
            arguments: arguments,
            initialInput: initialInput,
            initialInputTrigger: harness == .antigravityCLI ? "Select login method:" : nil,
            usesPseudoTerminal: [HarnessKind.antigravityCLI, .hermes].contains(harness),
            environment: environment,
            startupMessage: startupMessage,
            interaction: ([.hermes, .openCode, .pi].contains(harness)
                && !(harness == .pi && connection?.providerID != nil))
                ? .terminalRequired
                : .guided
        )
    }

    func logoutCommand(
        for harness: HarnessKind,
        executableURL: URL
    ) async -> AccountInteractiveCommand? {
        let arguments: [String]
        let initialInput: String?
        switch harness {
        case .codex:
            arguments = ["logout"]
            initialInput = nil
        case .claudeCode:
            arguments = ["auth", "logout"]
            initialInput = nil
        case .cursorAgent, .grokBuild:
            arguments = ["logout"]
            initialInput = nil
        case .openCode:
            arguments = ["auth", "logout"]
            initialInput = nil
        case .kimiCode:
            arguments = []
            initialInput = "/logout\r"
        case .antigravityCLI:
            guard executableURL.lastPathComponent == "agy" else { return nil }
            arguments = []
            initialInput = "/logout\r"
        case .pi:
            arguments = []
            initialInput = "/logout\r"
        default:
            return nil
        }
        let environment: [String: String]
        if harness == .codex, let codexEnvironmentManager {
            guard let nativeEnvironment = try? await codexEnvironmentManager
                .processEnvironment().values else { return nil }
            environment = Self.codexEnvironmentOverrides(from: nativeEnvironment)
        } else {
            environment = connection?.environment ?? [:]
        }
        return AccountInteractiveCommand(
            executableURL: executableURL,
            arguments: arguments,
            initialInput: initialInput,
            environment: environment,
            operation: .disconnect,
            interaction: [.kimiCode, .antigravityCLI, .pi].contains(harness)
                ? .terminalRequired
                : .guided
        )
    }

    private static func codexEnvironmentOverrides(
        from environment: [String: String]
    ) -> [String: String] {
        ["CODEX_HOME", "YARDLET_NATIVE_CODEX_HOME", "YARDLET_ACCOUNT_ENVIRONMENT"].reduce(into: [:]) { values, key in
            values[key] = environment[key]
        }
    }

    private func codexSnapshot(executableURL: URL) async throws -> HarnessAccountSnapshot {
        let transport = CodexProcessTransport(
            executableURL: executableURL,
            environmentManager: codexEnvironmentManager
        )
        let account: JSONValue?
        let rateLimits: JSONValue?
        do {
            _ = try await transport.request(CodexProtocol.initialize(id: 1, clientVersion: "0.2"))
            account = try await transport.request(CodexRPCRequest(
                id: 2,
                method: "account/read",
                params: .object(["refreshToken": .bool(false)])
            )).result
            let accountUsage: JSONValue?
            if Self.codexAccountIsSignedIn(account) {
                // Quota endpoints require authentication and are supplementary to
                // the account state. A missing/older endpoint must not turn a valid
                // signed-in or signed-out account snapshot into an internal error.
                rateLimits = try? await transport.request(
                    CodexProtocol.accountRateLimits(id: 3)
                ).result
                accountUsage = try? await transport.request(
                    CodexProtocol.accountUsage(id: 4)
                ).result
            } else {
                rateLimits = nil
                accountUsage = nil
            }
            await transport.stop()

            return Self.codexSnapshot(
                account: account,
                rateLimits: rateLimits,
                accountUsage: accountUsage
            )
        } catch {
            await transport.stop()
            throw error
        }
    }

    static func piConfiguredProvider(homePath: String?) -> String? {
        let root = homePath.map { URL(filePath: $0) } ?? ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent")
        guard let data = try? Data(contentsOf: root.appending(path: "settings.json")), data.count < 1_048_576,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let provider = value["defaultProvider"]?.stringValue,
              provider.range(of: #"^[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return provider
    }

    private func piCodexSnapshot(executableURL: URL) async throws -> HarnessAccountSnapshot {
        let configured = connection?.providerID ?? Self.piConfiguredProvider(homePath: connection?.homePath)
        guard let provider = configured else {
            return HarnessAccountSnapshot(id: "pi:openai-codex", harness: .pi, providerID: nil, state: .unknown,
                accountLabel: nil, detail: L10n.string("Choose a provider and model in this account environment."),
                credentialOwner: "Pi", checkedAt: Date(), usage: [], canLogin: true, canLogout: false)
        }
        let result = try await AccountCommandRunner.run(
            executableURL: executableURL,
            arguments: [
                "auth", "check",
                "--provider", provider,
                "--json",
                "--no-refresh"
            ],
            environment: connection?.environment ?? [:]
        )
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.output.utf8))
        let state: AccountAuthState
        if value["provider"]?.stringValue == provider,
           value["status"]?.stringValue == "ready", result.exitCode == 0 {
            state = .signedIn
        } else if value["provider"]?.stringValue == provider,
                  value["status"]?.stringValue == "not_ready", result.exitCode == 1,
                  value["reason"]?.stringValue == "credentials_not_configured" {
            state = .signedOut
        } else {
            // Pi also returns `invalid` and `provider_not_found`. Neither proves
            // that a user's credential is missing, and future schemas fail closed.
            state = .unknown
        }
        let detail: String = switch state {
        case .signedIn: L10n.format("%@ authentication is ready in Pi.", provider)
        case .signedOut: L10n.format("%@ is not connected in Pi.", provider)
        default: L10n.string("Account status could not be confirmed.")
        }
        return HarnessAccountSnapshot(
            id: "pi:openai-codex",
            harness: .pi,
            providerID: provider,
            state: state,
            accountLabel: nil,
            detail: detail,
            credentialOwner: L10n.string("Pi credential store (separate OAuth session)"),
            checkedAt: Date(),
            usage: [AccountUsageMetric(
                id: "pi-local",
                label: L10n.string("Pi usage"),
                usedFraction: nil,
                detail: L10n.string("Pi exposes per-session token usage, not subscription quota."),
                resetsAt: nil,
                evidence: .localSession
            )],
            canLogin: state != .signedIn,
            canLogout: state == .signedIn
        )
    }

    private func commandSnapshot(
        descriptor: HarnessDescriptor,
        executableURL: URL
    ) async throws -> HarnessAccountSnapshot {
        let arguments: [String]
        switch descriptor.id {
        case .claudeCode: arguments = ["auth", "status"]
        case .cursorAgent: arguments = ["status", "--format", "json"]
        case .grokBuild:
            return grokSnapshot(descriptor: descriptor)
        case .kimiCode: arguments = ["provider", "list"]
        case .openCode: arguments = ["auth", "list"]
        default:
            return HarnessAccountSnapshot(
                id: descriptor.id.rawValue,
                harness: descriptor.id,
                providerID: nil,
                state: .unknown,
                accountLabel: nil,
                detail: L10n.string("This runtime does not expose a structured account probe."),
                credentialOwner: descriptor.displayName,
                checkedAt: Date(),
                usage: [notExposedUsage()],
                canLogin: supportsLogin(descriptor.id),
                canLogout: false
            )
        }

        let result = try await AccountCommandRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: connection?.environment ?? [:]
        )
        let state = Self.commandAccountState(
            for: descriptor.id,
            result: result
        )
        let canLogout: Bool
        if descriptor.id == .openCode {
            let normalized = AccountLoginController.stripANSI(result.output).lowercased()
            canLogout = (Self.openCodePersistedCredentialCount(from: normalized) ?? 0) > 0
        } else {
            canLogout = supportsLogout(descriptor.id) && state == .signedIn
        }
        let detail: String
        if descriptor.id == .openCode,
           state == .signedOut,
           Self.openCodeProviderEvidence(from: AccountLoginController.stripANSI(result.output).lowercased())?
               .environmentVariableCount ?? 0 > 0 {
            detail = L10n.string(
                "Environment keys are available, but OpenCode has no stored provider connection."
            )
        } else if descriptor.id == .openCode, state == .signedOut {
            detail = L10n.string("No model provider is connected in OpenCode.")
        } else if descriptor.id == .openCode, state == .signedIn {
            detail = L10n.string("OpenCode has at least one configured model provider.")
        } else if descriptor.id == .openCode {
            detail = L10n.string("OpenCode provider status could not be confirmed.")
        } else if state == .signedOut {
            detail = L10n.string("No usable runtime-owned account was found.")
        } else if state == .signedIn {
            detail = L10n.string("The selected runtime reports usable authentication.")
        } else {
            detail = L10n.string("Account status could not be confirmed.")
        }
        // Claude publishes the signed-in identity in the same structured payload
        // that proves the session. Read only those fields; never the credential.
        let claudeIdentity = descriptor.id == .claudeCode && state == .signedIn
            ? Self.claudeAccountIdentity(from: result.output)
            : nil
        var usage = [notExposedUsage()]
        if descriptor.id == .claudeCode, state == .signedIn {
            let metrics = try? await ClaudeUsageProbe.read(executableURL: executableURL,
                environment: connection?.environment ?? [:])
            usage = metrics.flatMap { $0.isEmpty ? nil : $0 } ?? [AccountUsageMetric(id: "not-reported",
                label: L10n.string("Usage"), usedFraction: nil,
                detail: L10n.string("Claude Code did not report plan limits for this login."),
                resetsAt: nil, evidence: .notExposed)]
        }
        return HarnessAccountSnapshot(
            id: descriptor.id.rawValue,
            harness: descriptor.id,
            providerID: nil,
            state: state,
            accountLabel: claudeIdentity?.displayLabel,
            accountOrganization: claudeIdentity?.groupingOrganization,
            accountPlan: claudeIdentity?.planLabel,
            detail: detail,
            credentialOwner: descriptor.id == .openCode
                ? L10n.string("OpenCode provider credentials and environment")
                : L10n.format("%@ credential store", descriptor.displayName),
            checkedAt: Date(),
            usage: usage,
            canLogin: descriptor.id == .openCode
                ? true
                : supportsLogin(descriptor.id) && state != .signedIn,
            canLogout: canLogout
        )
    }

    /// Read in the environment the account's Grok runs in: a saved account's `GROK_HOME`, without
    /// the API keys an account folder does not inherit.
    private func grokSnapshot(descriptor: HarnessDescriptor) -> HarnessAccountSnapshot {
        let state = Self.grokCredentialState(environment: RuntimeProcessEnvironment.accountScoped(
            ProcessInfo.processInfo.environment.merging(connection?.environment ?? [:]) { _, new in new }))
        let detail: String
        switch state {
        case .signedIn:
            detail = L10n.string("Grok has a locally stored OAuth session or API key.")
        case .signedOut:
            detail = L10n.string("No Grok OAuth session or API key was found.")
        case .unknown, .actionRequired, .unavailable:
            detail = L10n.string("Grok credential status could not be read safely.")
        }
        return HarnessAccountSnapshot(
            id: descriptor.id.rawValue,
            harness: descriptor.id,
            providerID: nil,
            state: state,
            accountLabel: nil,
            detail: detail,
            credentialOwner: L10n.string("Grok Build credential store"),
            checkedAt: Date(),
            usage: [notExposedUsage()],
            canLogin: state != .signedIn,
            canLogout: state == .signedIn
        )
    }

    private func antigravitySnapshot(descriptor: HarnessDescriptor) -> HarnessAccountSnapshot {
        let state = Self.antigravityCredentialState()
        let detail: String
        switch state {
        case .signedIn:
            detail = L10n.string("Antigravity CLI credentials are stored in macOS Keychain.")
        case .signedOut:
            detail = L10n.string("No Antigravity CLI credentials were found in macOS Keychain.")
        case .unknown, .actionRequired, .unavailable:
            detail = L10n.string("Antigravity CLI Keychain status could not be confirmed.")
        }
        return HarnessAccountSnapshot(
            id: descriptor.id.rawValue,
            harness: descriptor.id,
            providerID: nil,
            state: state,
            accountLabel: nil,
            detail: detail,
            credentialOwner: L10n.string("macOS Keychain (Antigravity CLI)"),
            checkedAt: Date(),
            usage: [notExposedUsage()],
            canLogin: state != .signedIn,
            canLogout: state == .signedIn
        )
    }

    /// MSP v1 intentionally has no authentication-status method. Installing Muse
    /// or completing the protocol handshake does not prove that its provider
    /// credential can run a turn, so Account Center stays fail-closed.
    /// Muse's account state stays unknown. Its subscription usage is what a running Muse session
    /// last read from its host, checked as of the host's own arrival stamp; no host is started
    /// here, because a new one has observed nothing. Before any observation there is no row.
    private func museCodeSnapshot(descriptor: HarnessDescriptor) async -> HarnessAccountSnapshot {
        let observed = await museUsageStore.latest(for: descriptor.id)
        return HarnessAccountSnapshot(
            id: descriptor.id.rawValue,
            harness: descriptor.id,
            providerID: nil,
            state: .unknown,
            accountLabel: nil,
            detail: L10n.string(
                "Muse Code does not expose a stable account-status probe through MSP v1."
            ),
            credentialOwner: L10n.string("Muse Code credential store"),
            checkedAt: observed?.observedAt ?? Date(),
            usage: observed.map(Self.museSubscriptionUsage(from:)) ?? [],
            canLogin: true,
            canLogout: false
        )
    }

    static func grokCredentialState(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AccountAuthState {
        if let apiKey = environment["XAI_API_KEY"],
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .signedIn
        }
        let home: URL
        if let configuredHome = environment["GROK_HOME"], !configuredHome.isEmpty {
            home = URL(filePath: configuredHome, directoryHint: .isDirectory)
        } else if let userHome = environment["HOME"], !userHome.isEmpty {
            home = URL(filePath: userHome, directoryHint: .isDirectory)
                .appending(path: ".grok", directoryHint: .isDirectory)
        } else {
            return .unknown
        }
        let authURL = home.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path(percentEncoded: false)) else {
            return .signedOut
        }
        do {
            let values = try authURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0 else { return .unknown }
            return .signedIn
        } catch {
            return .unknown
        }
    }

    /// Converts command output into account truth without treating a successful
    /// model/provider-list command as proof of authentication. Several runtimes
    /// return exit code zero while merely listing built-in models or providers.
    /// Signed-in state therefore requires explicit machine-readable or textual
    /// evidence; absence of that evidence remains unknown.
    static func commandAccountState(
        for harness: HarnessKind,
        result: AccountCommandResult
    ) -> AccountAuthState {
        let normalized = AccountLoginController.stripANSI(result.output).lowercased()
        let structured = structuredAccountPayload(from: result.output)
        let structuredAuth = structured?["loggedIn"]?.boolValue
            ?? structured?["authenticated"]?.boolValue
        if let structuredAuth {
            return structuredAuth ? .signedIn : .signedOut
        }
        if harness == .cursorAgent,
           let status = structured?["status"]?.stringValue?.lowercased() {
            switch status {
            case "authenticated", "logged_in", "signed_in": return .signedIn
            case "unauthenticated", "logged_out", "signed_out": return .signedOut
            default: break
            }
        }
        if harness == .openCode,
           let providerState = openCodeProviderState(from: normalized) {
            return providerState
        }
        let signedOutMarkers = [
            "not logged in", "not authenticated", "authentication required",
            "please sign in", "please log in", "no auth credentials",
            "no providers configured", "0 credentials"
        ]
        if signedOutMarkers.contains(where: normalized.contains) {
            return .signedOut
        }
        guard result.exitCode == 0 else { return .unknown }

        let signedInMarkers = [
            "logged in as", "authenticated as", "authentication: active",
            "account status: ready"
        ]
        if signedInMarkers.contains(where: normalized.contains) {
            return .signedIn
        }
        return .unknown
    }

    /// The account fields `claude auth status` publishes beside its login truth.
    /// Only the identity is read here; the credential stays owned by the CLI.
    struct ClaudeAccountIdentity: Equatable, Sendable {
        let email: String?
        let organization: String?
        let subscription: String?

        /// The email is the account. An organization alone still names the
        /// account, but it must not also be repeated as the plan line.
        var displayLabel: String? { email ?? organization }
        var groupingOrganization: String? { email == nil ? nil : organization }
        /// The plan as the Claude app names it ("Max"). The organization goes beside the address
        /// (`AccountChoice.organizationTitle`); an organization alone names the account.
        var planLabel: String? {
            subscription.map { L10n.format("Claude %@ plan", HarnessAccountBroker.planName($0)) }
        }
    }

    /// A plan id as the Codex and Claude apps write it ("ChatGPT Plus", "Max"): "max" → "Max",
    /// "pro" → "Pro". A name already written for people stays as it is.
    static func planName(_ id: String) -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }) else { return id }
        return id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func claudeAccountIdentity(from output: String) -> ClaudeAccountIdentity? {
        guard let payload = structuredAccountPayload(from: output) else { return nil }
        func value(_ candidates: [JSONValue?]) -> String? {
            for candidate in candidates {
                guard let text = candidate?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= 200,
                      text.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                return text
            }
            return nil
        }
        let email = value([payload["email"], payload["emailAddress"], payload["account"]?["email"]])
        let organization = value([
            payload["orgName"], payload["organizationName"],
            payload["organization"], payload["organization"]?["name"],
            payload["account"]?["organizationName"]
        ])
        let subscription = value([payload["subscriptionType"], payload["subscription"]])
        guard email != nil || organization != nil || subscription != nil else { return nil }
        return ClaudeAccountIdentity(
            email: email,
            organization: organization,
            subscription: subscription
        )
    }

    struct OpenCodeProviderEvidence: Equatable {
        let persistedCredentialCount: Int
        let environmentVariableCount: Int?
    }

    /// `opencode auth list` reports persisted credentials and environment-backed
    /// keys separately. Only a stored credential is an explicit OpenCode connection;
    /// inheriting a shell key must not claim that the user connected a provider.
    static func openCodeProviderState(from normalizedOutput: String) -> AccountAuthState? {
        guard let evidence = openCodeProviderEvidence(from: normalizedOutput) else { return nil }
        return evidence.persistedCredentialCount > 0 ? .signedIn : .signedOut
    }

    static func openCodeProviderEvidence(from normalizedOutput: String) -> OpenCodeProviderEvidence? {
        let lines = normalizedOutput
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        func count(labelPattern: String) -> Int? {
            // Match the summary row, not `┌ Credentials <path>`. The heading
            // appears first and its path may itself contain unrelated numbers.
            guard let expression = try? NSRegularExpression(
                pattern: #"^\s*(?:└\s*)?([0-9]+)\s+"# + labelPattern + #"\s*$"#
            ) else { return nil }
            for line in lines {
                guard let match = expression.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                ), let range = Range(match.range(at: 1), in: line) else { continue }
                return Int(line[range])
            }
            return nil
        }
        guard let persistedCredentialCount = count(labelPattern: "credentials?") else { return nil }
        let environmentVariableCount = count(labelPattern: "environment variables?")
        return OpenCodeProviderEvidence(
            persistedCredentialCount: persistedCredentialCount,
            environmentVariableCount: environmentVariableCount
        )
    }

    /// Environment-backed providers cannot be removed by `opencode auth logout`.
    /// Expose disconnect only when OpenCode reports at least one stored credential.
    static func openCodePersistedCredentialCount(from normalizedOutput: String) -> Int? {
        openCodeProviderEvidence(from: normalizedOutput)?.persistedCredentialCount
    }

    private static func structuredAccountPayload(from output: String) -> JSONValue? {
        func decode(_ text: String) -> JSONValue? {
            text.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(JSONValue.self, from: $0)
            }
        }
        if let direct = decode(output) { return direct }
        guard let opening = output.firstIndex(of: "{"),
              let closing = output.lastIndex(of: "}"),
              opening <= closing else { return nil }
        return decode(String(output[opening...closing]))
    }

    private func codexUsage(from value: JSONValue?) -> [AccountUsageMetric] {
        Self.codexRateLimitUsage(from: value)
    }

    /// Projects the installed response's multi-bucket view, falling back to its
    /// required backward-compatible single `rateLimits` bucket when the newer
    /// keyed map is absent. It never treats an absent/partial window as quota.
    static func codexRateLimitUsage(from value: JSONValue?) -> [AccountUsageMetric] {
        guard let value else { return [] }
        let entries: [(String, JSONValue)]
        if let limits = value["rateLimitsByLimitId"]?.objectValue, !limits.isEmpty {
            entries = limits.sorted { $0.key < $1.key }
        } else if let legacy = value["rateLimits"]?.objectValue {
            let key = legacy["limitId"]?.stringValue ?? "codex"
            entries = [(key, .object(legacy))]
        } else {
            return []
        }

        let buckets = entries.map { key, limit in
            (key: key, name: limit["limitName"]?.stringValue ?? key, windows: ["primary", "secondary"].compactMap {
                windowID -> (id: String, window: JSONValue, used: Double)? in
                guard let window = limit[windowID], let used = window["usedPercent"]?.doubleValue,
                      used.isFinite, used >= 0 else { return nil }
                return (windowID, window, used)
            })
        }.filter { !$0.windows.isEmpty }
        // Several buckets are told apart by name; Codex's one default bucket ("codex") needs none, as
        // the Codex app's Usage page says only "5-hour limit".
        return buckets.flatMap { bucket in
            bucket.windows.map { windowID, window, used in
                let label = usageWindowLabel(
                    minutes: window["windowDurationMins"]?.doubleValue,
                    fallback: L10n.string(windowID == "primary" ? "Primary limit" : "Secondary limit")
                )
                return AccountUsageMetric(
                    id: "\(bucket.key):\(windowID)", label: buckets.count > 1 ? "\(bucket.name) · \(label)" : label,
                    usedFraction: min(1, used / 100), detail: L10n.format("%.0f%% remaining", max(0, 100 - used)),
                    resetsAt: window["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
                    evidence: .exactQuota,
                    windowMinutes: window["windowDurationMins"]?.doubleValue
                )
            }
        }
    }

    /// A usage window named by its length, as the provider reported it.
    static func usageWindowLabel(minutes: Double?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes.truncatingRemainder(dividingBy: 1_440) == 0 {
            return L10n.format("%.0f day limit", minutes / 1_440)
        }
        if minutes >= 60 { return L10n.format("%.0f hour limit", minutes / 60) }
        return L10n.format("%.0f minute limit", minutes)
    }

    /// Projects a Muse host's last-observed subscription usage as provider quota, the same rows
    /// Codex rate limits produce. MSP sends no length for the weekly block; it is the rolling
    /// seven days its name says.
    static func museSubscriptionUsage(from usage: MuseSubscriptionUsage) -> [AccountUsageMetric] {
        let windows: [(String, MuseSubscriptionUsage.Window?, String)] = [
            ("window", usage.window, L10n.string("Primary limit")),
            ("weekly", usage.weekly.map {
                MuseSubscriptionUsage.Window(
                    usedPercent: $0.usedPercent,
                    durationMinutes: 7 * 1_440,
                    resetsAt: $0.resetsAt
                )
            }, L10n.string("Secondary limit"))
        ]
        return windows.compactMap { id, window, fallback in
            guard let window else { return nil }
            return AccountUsageMetric(
                id: "muse:\(id)",
                label: usageWindowLabel(minutes: window.durationMinutes, fallback: fallback),
                usedFraction: min(1, window.usedPercent / 100),
                detail: L10n.format("%.0f%% remaining", max(0, 100 - window.usedPercent)),
                resetsAt: window.resetsAt,
                evidence: .exactQuota,
                windowMinutes: window.durationMinutes
            )
        }
    }

    /// Merges the installed sparse `account/rateLimits/updated` notification into
    /// the most recent `account/rateLimits/read` response. Nullable account metadata
    /// in the notification is intentionally ignored so a rolling update cannot erase
    /// a previously observed label, plan, or window. The legacy single-bucket view and
    /// the keyed view are both kept coherent when the keyed view is present.
    static func mergedCodexRateLimits(
        previous: JSONValue?,
        update: JSONValue?
    ) -> JSONValue? {
        guard case let .object(updateObject)? = update,
              case let .object(updateRateLimits)? = updateObject["rateLimits"] else {
            return previous
        }

        guard case let .object(previousObject)? = previous else {
            return .object(["rateLimits": .object(updateRateLimits)])
        }

        var merged = previousObject
        let legacy = mergedRateLimitSnapshot(
            previous: merged["rateLimits"]?.objectValue ?? [:],
            update: updateRateLimits
        )
        merged["rateLimits"] = .object(legacy)

        if var keyed = merged["rateLimitsByLimitId"]?.objectValue,
           !keyed.isEmpty {
            let key = updateRateLimits["limitId"]?.stringValue
                ?? legacy["limitId"]?.stringValue
                ?? (keyed.count == 1 ? keyed.keys.first : nil)
            if let key {
                keyed[key] = .object(mergedRateLimitSnapshot(
                    previous: keyed[key]?.objectValue ?? [:],
                    update: updateRateLimits
                ))
                merged["rateLimitsByLimitId"] = .object(keyed)
            }
        }

        return .object(merged)
    }

    /// Builds one account snapshot from already-read runtime values. This is shared
    /// by the one-shot account probe and the opt-in live monitor, keeping their
    /// evidence and unavailable behavior identical.
    static func codexSnapshot(
        account: JSONValue?,
        rateLimits: JSONValue?,
        accountUsage: JSONValue?
    ) -> HarnessAccountSnapshot {
        let accountValue = account?["account"]
        let signedIn = codexAccountIsSignedIn(account)
        let email = accountValue?["email"]?.stringValue
        let plan = accountValue?["planType"]?.stringValue
        let usage = codexRateLimitUsage(from: rateLimits)
            + codexAccountUsage(from: accountUsage)
        return HarnessAccountSnapshot(
            id: HarnessKind.codex.rawValue,
            harness: .codex,
            providerID: accountValue?["type"]?.stringValue == "apiKey" ? "openai" : "openai-codex",
            state: signedIn ? .signedIn : .signedOut,
            accountLabel: email,
            accountPlan: plan.map { L10n.format("ChatGPT %@ plan", planName($0)) },
            detail: plan.map { L10n.format("ChatGPT %@ plan", planName($0)) }
                ?? L10n.string("Codex App Server account"),
            credentialOwner: L10n.string("Codex CLI / system credential store"),
            checkedAt: Date(),
            usage: usage.isEmpty ? [
                AccountUsageMetric(
                    id: "not-exposed",
                    label: L10n.string("Usage"),
                    usedFraction: nil,
                    detail: L10n.string("This CLI does not expose account quota in a stable machine-readable command."),
                    resetsAt: nil,
                    evidence: .notExposed
                )
            ] : usage,
            usageResets: signedIn ? codexUsageResets(from: rateLimits, plan: plan).map { resets in
                // A reset restores the general Codex limit (`codex`), not a model's own.
                var resets = resets
                resets.restores = usage.filter { $0.evidence == .exactQuota && $0.id.hasPrefix("codex:") }.map(\.id)
                return resets
            } : nil,
            canLogin: !signedIn,
            canLogout: signedIn
        )
    }

    /// The Codex app's "Buy an instant reset" page. The app offers it to personal plans only.
    static let codexResetPurchaseURL = URL(string: "https://chatgpt.com/codex/purchase/reset")!

    /// The resets of its plan limits the account holds (`rateLimitResetCredits`): the count, and the
    /// available ones the service listed, soonest to expire first. An App Server that reports none
    /// gives nil.
    static func codexUsageResets(from value: JSONValue?, plan: String? = nil) -> AccountUsageResets? {
        guard let summary = value?["rateLimitResetCredits"], summary.objectValue != nil,
              let count = summary["availableCount"]?.doubleValue, count.isFinite else { return nil }
        let resets = (summary["credits"]?.arrayValue ?? []).compactMap { credit -> AccountUsageResets.Reset? in
            guard credit["status"]?.stringValue == "available" else { return nil }
            let title = credit["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AccountUsageResets.Reset(id: credit["id"]?.stringValue,
                title: title?.isEmpty == false ? title : nil,
                expiresAt: credit["expiresAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)))
        }
        return AccountUsageResets(availableCount: max(0, Int(count)),
            resets: resets.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) },
            purchaseURL: ["plus", "pro", "prolite", "promax"].contains(plan ?? "") ? codexResetPurchaseURL : nil)
    }

    /// Uses one reset of the account's plan limits through the harness's own call. Only Codex has
    /// one: the App Server's `account/rateLimitResetCredit/consume`, under this broker's login.
    /// The caller keeps `attemptID` until it gets an answer, and sends it again on a retry.
    func useUsageReset(harness: HarnessKind, executableURL: URL, attemptID: String,
                       resetID: String?) async throws -> AccountUsageResetOutcome {
        guard harness == .codex else { throw AccountUsageResetError.unsupported }
        let transport = CodexProcessTransport(executableURL: executableURL, environmentManager: codexEnvironmentManager)
        let result: JSONValue?
        do {
            _ = try await transport.request(CodexProtocol.initialize(id: 1, clientVersion: "0.2"))
            result = try await transport.request(CodexProtocol.consumeRateLimitResetCredit(
                id: 2, idempotencyKey: attemptID, creditID: resetID)).result
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
        switch result?["outcome"]?.stringValue {
        case "reset", "alreadyRedeemed": return .reset
        case "nothingToReset": return .nothingToReset
        case "noCredit": return .noResets
        default: throw AccountUsageResetError.unrecognizedAnswer
        }
    }

    static func codexAccountIsSignedIn(_ account: JSONValue?) -> Bool {
        account?["account"]?.objectValue != nil
    }

    private static func mergedRateLimitSnapshot(
        previous: [String: JSONValue],
        update: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = previous
        for (key, value) in update {
            // Nullable account metadata in the sparse notification means
            // “not available in this update”, not “clear the snapshot”.
            if case .null = value { continue }
            if key == "primary" || key == "secondary",
               case let .object(window) = value,
               case let .object(previousWindow)? = merged[key] {
                var mergedWindow = previousWindow
                for (windowKey, windowValue) in window {
                    if case .null = windowValue { continue }
                    mergedWindow[windowKey] = windowValue
                }
                merged[key] = .object(mergedWindow)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// Projects the locked `GetAccountTokenUsageResponse` without inventing a
    /// quota fraction. Token history is an account-wide usage series, not a
    /// rate-limit window, so it remains visibly distinct from `exactQuota`.
    /// The id each day of Codex's account history starts with, before its date.
    static let dailyUsageIDPrefix = "account-daily-"

    static func codexAccountUsage(from value: JSONValue?) -> [AccountUsageMetric] {
        guard let value else { return [] }
        var metrics: [AccountUsageMetric] = []
        let summary = value["summary"]
        let summaryValues: [(String, String, Int64?)] = [
            ("lifetime", L10n.string("Lifetime tokens"), summary?["lifetimeTokens"]?.integerValue),
            ("peak-daily", L10n.string("Peak daily tokens"), summary?["peakDailyTokens"]?.integerValue),
            ("current-streak", L10n.string("Current streak"), summary?["currentStreakDays"]?.integerValue),
            ("longest-streak", L10n.string("Longest streak"), summary?["longestStreakDays"]?.integerValue)
        ]
        for (id, label, value) in summaryValues {
            guard let value else { continue }
            let detail = id.contains("streak")
                ? L10n.format("%lld days", value)
                : L10n.format("%lld tokens", value)
            metrics.append(AccountUsageMetric(
                id: "account-\(id)",
                label: label,
                usedFraction: nil,
                detail: detail,
                resetsAt: nil,
                evidence: .accountUsage
            ))
        }

        let dailyBuckets = value["dailyUsageBuckets"]?.arrayValue ?? []
        for bucket in dailyBuckets {
            guard let date = bucket["startDate"]?.stringValue,
                  let tokens = bucket["tokens"]?.integerValue else { continue }
            metrics.append(AccountUsageMetric(
                id: dailyUsageIDPrefix + date,
                label: date,
                usedFraction: nil,
                detail: L10n.format("%lld tokens", tokens),
                resetsAt: nil,
                evidence: .accountUsage
            ))
        }
        return metrics
    }

    private func notExposedUsage() -> AccountUsageMetric {
        AccountUsageMetric(
            id: "not-exposed",
            label: L10n.string("Usage"),
            usedFraction: nil,
            detail: L10n.string("This CLI does not expose account quota in a stable machine-readable command."),
            resetsAt: nil,
            evidence: .notExposed
        )
    }

    private func supportsLogin(_ harness: HarnessKind) -> Bool {
        HarnessCatalog.descriptor(for: harness) != nil
    }

    private func supportsLogout(_ harness: HarnessKind) -> Bool {
        supportsLogin(harness) && ![HarnessKind.museCode, .hermes].contains(harness)
    }
}

extension JSONValue {
    var doubleValue: Double? {
        switch self {
        case let .number(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }
}
