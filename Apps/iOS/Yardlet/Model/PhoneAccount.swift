import AuthenticationServices
import Foundation
import Observation
import UIKit
import YardletRemote

/// The person's optional account on the Yardlet relay (docs/REMOTE_PROTOCOL.md §14.4). It lists the Macs signed in to
/// it, so this phone can ask one of them to let it in without a QR code (§12.1); it never carries tasks. The token is
/// in the Keychain on this device only; the account's id, provider and name are kept in the app's preferences so
/// Settings names it. Nothing reads the relay on a schedule: the first screen and Settings read the providers as they
/// open, and the list of Macs reads the account.
@MainActor
@Observable
final class PhoneAccount {
    /// The sign-in providers the relay offers. None, or no answer, shows no sign-in at all.
    private(set) var providers: [String] = []
    private(set) var account: RemoteAccountClient.Account?
    /// The account's Macs as last read; nil until read.
    private(set) var macs: [RemoteAccountClient.Mac]?
    private(set) var isSigningIn = false
    private(set) var isLoading = false
    /// Why the last sign-in or reading of the account failed.
    var error: String?

    /// The relay this build signs in with: `YardletRelayURL` in Info.plist, or a debug build's `-relayURL` argument.
    let relayURL: URL?
    @ObservationIgnored private let client: RemoteAccountClient?

    private static let tokenService = "com.zzunkie.yardlet.remote.account"
    private static let tokenAccount = "token"
    private static let accountKey = "account"

    init() {
        relayURL = Self.configuredRelay
        client = relayURL.map { RemoteAccountClient(baseURL: $0) }
        account = UserDefaults.standard.data(forKey: Self.accountKey)
            .flatMap { try? JSONDecoder().decode(RemoteAccountClient.Account.self, from: $0) }
        // A kept account whose token is gone (another install's preferences) is not signed in.
        if account != nil, token == nil { keep(nil) }
    }

    private static var configuredRelay: URL? {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "relayURL") { return URL(string: text) }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "YardletRelayURL") as? String).flatMap(URL.init(string:))
    }

    private var token: String? {
        Keychain.read(service: Self.tokenService, account: Self.tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "github": "GitHub"
        case "google": "Google"
        default: provider
        }
    }

    /// "GitHub · octocat": the account as Settings and the list of Macs name it.
    var name: String? {
        account.map { [Self.providerName($0.provider), $0.name].compactMap { $0 }.joined(separator: " · ") }
    }

    /// Reads which providers the relay offers. A failed read keeps what an earlier one found.
    func refreshProviders() async {
        guard let client, let providers = try? await client.providers() else { return }
        self.providers = providers
    }

    /// Signs in with `provider` in the system's browser sign-in sheet, which `authenticate` opens and which returns to
    /// `yardlet-remote://auth`, then reads the account's Macs. True once signed in.
    func signIn(with provider: String, authenticate: (URL, String) async throws -> URL) async -> Bool {
        guard let client, !isSigningIn else { return false }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        let pkce = RemoteAccountClient.PKCE()
        let state = RemoteEncoding.base64url(Data(RemoteRandom.bytes(16)))
        guard let url = client.startURL(provider: provider, pkce: pkce, state: state) else { return false }
        do {
            let callback = try await authenticate(url, RemoteAccountClient.callbackScheme)
            guard let code = RemoteAccountClient.code(from: callback, state: state) else {
                error = String(localized: "The sign-in didn't finish. Try again.")
                return false
            }
            let (token, account) = try await client.exchange(code: code, pkce: pkce, deviceName: UIDevice.current.name)
            guard Keychain.write(Data(token.utf8), service: Self.tokenService, account: Self.tokenAccount) else {
                // A sign-in this phone cannot keep ends on the relay too.
                try? await client.logout(token: token)
                error = String(localized: "Couldn't keep the sign-in on this iPhone. Try again.")
                return false
            }
            keep(account)
            macs = nil
            await loadMacs()
            return true
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return false
        } catch is CancellationError {
            return false
        } catch is RemoteAccountClient.Failure {
            error = String(localized: "The sign-in didn't finish. Try again.")
            return false
        } catch {
            self.error = String(localized: "Can't reach the Yardlet server. Check your connection and try again.")
            return false
        }
    }

    /// Reads the account's Macs. A token the relay no longer takes signs out.
    func loadMacs() async {
        guard let client, !isLoading else { return }
        guard let token else {
            forget()
            error = String(localized: "Your sign-in ended. Sign in again.")
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let current = try await client.account(token: token)
            macs = current.macs ?? []
            keep(current)
        } catch let failure as RemoteAccountClient.Failure where failure.isUnauthorized {
            forget()
            error = String(localized: "Your sign-in ended. Sign in again.")
        } catch {
            self.error = String(localized: "Can't reach the Yardlet server. Check your connection and try again.")
        }
    }

    /// Ends this phone's sign-in on the relay and forgets it here. The Macs paired through it stay paired.
    func signOut() async {
        if let client, let token { try? await client.logout(token: token) }
        forget()
        error = nil
    }

    private func forget() {
        Keychain.delete(service: Self.tokenService, account: Self.tokenAccount)
        keep(nil)
        macs = nil
    }

    private func keep(_ account: RemoteAccountClient.Account?) {
        var kept = account
        kept?.macs = nil
        self.account = kept
        if let kept, let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: Self.accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.accountKey)
        }
    }
}
