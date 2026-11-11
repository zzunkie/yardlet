import Foundation

/// Codex's own browser sign-in, as a Codex client starts it: `account/login/start` with `type: "chatgpt"` makes the
/// App Server host the sign-in's local callback and answer with the address to open, and `account/login/completed`
/// says how that sign-in ended. Yardlet opens the address and waits; the credential stays between the browser and
/// Codex. Cancelling sends `account/login/cancel`. The App Server runs only while the sign-in does. A Codex that
/// does not start one (an older App Server, a start refused) is `unavailable`, and the caller runs `codex login`.
actor CodexBrowserSignIn {
    enum Outcome: Equatable, Sendable {
        case signedIn
        /// The sign-in started and did not succeed, with Codex's reason when it gave one.
        case failed(String?)
        case cancelled
        /// No sign-in started, with the reason when there was one.
        case unavailable(String?)
    }

    private let transport: any CodexTransport
    private var loginID: String?
    private var isCancelled = false

    init(executableURL: URL, transport: (any CodexTransport)? = nil, environmentManager: CodexEnvironmentManager? = nil) {
        self.transport = transport ?? CodexProcessTransport(executableURL: executableURL, environmentManager: environmentManager)
    }

    /// Starts the sign-in, hands its address to `open`, and returns once Codex says how it ended.
    func run(open: @escaping @Sendable (URL) async -> Void) async -> Outcome {
        defer { loginID = nil }
        let notifications: AsyncStream<CodexRawFrame>
        let started: CodexRPCIncomingMessage
        do {
            try await transport.start()
            notifications = await transport.notifications()
            _ = try await transport.request(CodexProtocol.initialize(id: 1, clientVersion: "0.2"))
            started = try await transport.request(CodexRPCRequest(
                id: 2, method: "account/login/start", params: .object(["type": .string("chatgpt")])
            ))
        } catch {
            await transport.stop()
            return isCancelled ? .cancelled : .unavailable(error.localizedDescription)
        }
        guard let result = started.result, let id = result["loginId"]?.stringValue,
              let address = result["authUrl"]?.stringValue.flatMap(URL.init(string:)), address.scheme == "https" else {
            await transport.stop()
            return isCancelled ? .cancelled : .unavailable(started.error?["message"]?.stringValue)
        }
        loginID = id
        guard !isCancelled else { return await cancelled() }
        await open(address)
        for await frame in notifications where frame.message.method == "account/login/completed" {
            guard let params = frame.message.params, params["loginId"]?.stringValue ?? id == id else { continue }
            await transport.stop()
            return params["success"]?.boolValue == true ? .signedIn : .failed(params["error"]?.stringValue)
        }
        // The App Server ended: cancelled here, or it stopped on its own.
        await transport.stop()
        return isCancelled ? .cancelled : .failed(nil)
    }

    /// Ends a sign-in still waiting for the browser.
    func cancel() async {
        isCancelled = true
        _ = await cancelled()
    }

    private func cancelled() async -> Outcome {
        if let loginID {
            _ = try? await transport.request(CodexRPCRequest(
                id: 3, method: "account/login/cancel", params: .object(["loginId": .string(loginID)])
            ))
        }
        await transport.stop()
        return .cancelled
    }
}
