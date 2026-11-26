import AppKit
import AuthenticationServices
import Foundation
import os
import Security

/// The browser sign-in sheet for the relay's accounts (docs/REMOTE_PROTOCOL.md §14.4), as apps sign in
/// with a provider: the system's web authentication session, returning to `yardlet-remote://auth`. When the
/// sheet can't be shown, as when another default browser fails to take it over, it throws
/// `RemoteWebSignInUnavailable` and the sign-in goes on in the default browser instead
/// (`RemoteControlService.signIn(with:)`).
@MainActor
final class RemoteAccountSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// A sheet that ends as "cancelled" sooner than this was not closed by a person: it never showed.
    nonisolated static let shortestClosedByPerson: TimeInterval = 2

    private var session: ASWebAuthenticationSession?

    func signIn(at url: URL, callbackScheme: String) async throws -> URL {
        let resume = SignInResumeOnce<URL>()
        var finished = false
        // A sign-in that ends any other way than the session's own completion (its task was cancelled)
        // closes the sheet it may have left open.
        defer {
            if !finished { session?.cancel() }
            session = nil
        }
        let callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resume.set(continuation)
                guard !Task.isCancelled else { return resume.resume(throwing: CancellationError()) }
                let started = ProcessInfo.processInfo.systemUptime
                // The session calls back on its own XPC queue, not the main actor this class runs on.
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable callback, error in
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    resume.resume(with: Self.outcome(callback: callback, error: error, after: elapsed))
                }
                session.presentationContextProvider = self
                self.session = session
                guard !Task.isCancelled else { return resume.resume(throwing: CancellationError()) }
                if !session.start() { resume.resume(throwing: RemoteWebSignInUnavailable(code: "start_failed")) }
            }
        } onCancel: {
            resume.resume(throwing: CancellationError())
        }
        finished = true
        return callback
    }

    /// What the session's completion means: the return address, the person closing the sheet, or a sheet
    /// that could not be shown.
    nonisolated static func outcome(callback: URL?, error: (any Error)?, after elapsed: TimeInterval) -> Result<URL, any Error> {
        if let callback { return .success(callback) }
        let nsError = error.map { $0 as NSError }
        if let nsError, nsError.domain == ASWebAuthenticationSessionErrorDomain {
            if nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue, elapsed >= shortestClosedByPerson {
                return .failure(CancellationError())
            }
            return .failure(RemoteWebSignInUnavailable(code: "asweb_\(nsError.code)"))
        }
        if let nsError { return .failure(RemoteWebSignInUnavailable(code: RemoteControlService.failureCode(nsError) ?? "asweb_other")) }
        return .failure(RemoteWebSignInUnavailable(code: "asweb_none"))
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // A sheet (Settings shows the account in one), a panel or the menu bar's window can't present the
            // session; the window a sheet hangs from can.
            let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
            return Self.anchor(among: candidates) ?? ASPresentationAnchor()
        }
    }

    /// The first window that can present the session, once each candidate's sheets are taken off.
    static func anchor(among candidates: [NSWindow]) -> NSWindow? {
        for window in candidates {
            var candidate = window
            while let parent = candidate.sheetParent { candidate = parent }
            if candidate.isVisible, candidate.contentView != nil, candidate.canBecomeMain, !(candidate is NSPanel) {
                return candidate
            }
        }
        return nil
    }
}

/// A checked continuation resumed at most once: a sign-in session's completion, a failed start and the
/// task's cancellation may all try to resume it. A result that comes before the continuation is set resumes
/// it as it is set.
final class SignInResumeOnce<Value: Sendable>: Sendable {
    private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Value, any Error>?, early: Result<Value, any Error>?, done: Bool)>(
        initialState: (nil, nil, false))


    func set(_ continuation: CheckedContinuation<Value, any Error>) {
        let early: Result<Value, any Error>? = state.withLock {
            guard let early = $0.early else {
                $0.continuation = continuation
                return nil
            }
            return early
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(throwing error: any Error) { resume(with: .failure(error)) }

    func resume(with result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock {
            guard !$0.done else { return nil }
            $0.done = true
            guard let continuation = $0.continuation else {
                $0.early = result
                return nil
            }
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

/// The account token in the login keychain under the remote's own service (`<bundle identifier>.remote`).
struct KeychainRemoteSecret: RemoteSecretStoring {
    let service: String
    let account: String

    static func accountToken(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier) -> Self {
        KeychainRemoteSecret(service: "\(bundleIdentifier).remote", account: "account-token")
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func load() -> String? {
        var search = query
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Yardlet remote account"
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    func delete() {
        _ = SecItemDelete(query as CFDictionary)
    }
}
