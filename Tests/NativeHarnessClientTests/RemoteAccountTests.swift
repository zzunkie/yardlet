import AuthenticationServices
import CryptoKit
import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// The Mac's side of the relay's accounts (docs/REMOTE_PROTOCOL.md §14.4, §12.1): signing in with PKCE
/// in the browser sheet, with remote connections on or off, putting this Mac on the account with a
/// signature the relay can check, taking link requests only while signed in, and signing out. The relay
/// is a stub on `relay.example.test`.
@MainActor
final class RemoteAccountTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubRelay.reset()
        URLProtocol.registerClass(StubRelay.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubRelay.self)
        super.tearDown()
    }

    func testIdentityLoadingDoesNotBlockTheMainActorAndCancelledRequestsStayCancelled() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteIdentity")))
        defaults.set(true, forKey: RemoteControlService.enabledKey)
        let store = DelayedRemoteIdentityStore()
        defer { store.release() }
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            identityStore: store, defaults: defaults, environment: [:], interfaces: { [] },
            resolveName: { _ in nil }, listens: false)
        XCTAssertEqual(store.reads, 0, "Constructing the service must not read the keychain")
        let starting = Task { await service.start() }
        try await waitUntil { store.reads == 1 }
        var pairingStarted = false
        let pairing = Task {
            pairingStarted = true
            await service.startPairing()
        }
        try await waitUntil { pairingStarted }
        service.cancelPairing()
        service.setEnabled(false)
        store.release()
        await starting.value
        await pairing.value
        XCTAssertNil(service.pairing)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(store.writes, 0, "Disabling while loading must not create an identity or start serving")
        XCTAssertFalse(store.usedMainThread)

        // Concurrent first-use requests share one stored key, including its creation.
        async let first: Void = service.startPairing()
        async let second: Void = service.startPairing()
        _ = await (first, second)
        XCTAssertEqual(store.writes, 1)
        XCTAssertFalse(store.usedMainThread)
        let url = try XCTUnwrap(service.pairing?.url)
        let parsed = try XCTUnwrap(RemoteSecurePairingURL.parse(url))
        XCTAssertEqual(parsed.macKey, store.storedPublicKey)
        await service.shutdown()
    }

    func testPairingWaitsForTheRelayToStartAfterIdentityLoading() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteIdentityPairing")))
        defaults.set("http://127.0.0.1:1", forKey: RemoteControlService.relayURLKey)
        defaults.set("http://127.0.0.1:2", forKey: RemoteControlService.relayAlternateURLKey)
        let store = DelayedRemoteIdentityStore(blockedRead: 2)
        defer { store.release() }
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            identityStore: store, defaults: defaults, environment: [:], interfaces: { [] },
            resolveName: { _ in nil })
        await service.start()
        service.setEnabled(true)
        try await waitUntil { store.reads == 2 }
        let pairing = Task { await service.startPairing() }
        store.release()
        await pairing.value
        let url = try XCTUnwrap(service.pairing?.url)
        let parsed = try XCTUnwrap(RemoteSecurePairingURL.parse(url))
        XCTAssertEqual(parsed.relayURL, "http://127.0.0.1:1",
                       "A pairing requested during activation must include the relay, as it did before loading became asynchronous")
        XCTAssertEqual(parsed.alternateRelayURL, "http://127.0.0.1:2")
        XCTAssertEqual(parsed.macKey, store.storedPublicKey)
        XCTAssertEqual(store.writes, 1)
        service.setEnabled(false)
        await service.shutdown()

        // A relay set elsewhere does not take this second address, which may reach another relay.
        let developer = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil, defaults: defaults,
            environment: [RemoteControlService.relayURLEnvironmentKey: "ws://127.0.0.1:3"], interfaces: { [] },
            resolveName: { _ in nil }, listens: false)
        XCTAssertEqual(developer.relayURL?.absoluteString, "ws://127.0.0.1:3")
        XCTAssertNil(developer.relayAlternateURL)

        // A Windows build carries its relay in files beside its executable (Windows/scripts/place-relay.ps1), the
        // second address only with the first; with nothing set by hand the remote takes both.
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-relay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "NativeHarnessClient.exe")
        try Data("https://relay-two.example.test".utf8).write(to: folder.appending(path: RemoteControlService.builtInRelayAlternateURLKey))
        XCTAssertNil(RemoteHostPlatform.relay(besides: executable))
        try Data("wss://relay.example.test\n".utf8).write(to: folder.appending(path: RemoteControlService.builtInRelayURLKey))
        var platform = RemoteHostPlatform.current
        platform.builtInRelay = { RemoteHostPlatform.relay(besides: executable) }
        let built = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteBuiltInRelay"))), environment: [:],
            platform: platform, interfaces: { [] }, resolveName: { _ in nil }, listens: false)
        XCTAssertEqual(built.relayURL?.absoluteString, "wss://relay.example.test")
        XCTAssertEqual(built.relayAlternateURL?.absoluteString, "https://relay-two.example.test")
    }

    func testDesktopCanEnrollWithAnAlreadyConnectedPhoneOnAnOlderRelay() async throws {
        let stack = try await LoopbackStack(name: "Mac Studio")
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let phone = try await stack.phone(key: .generate(), hello: .init(name: "iPhone", platform: "ios",
                                                                         pair: RemoteEncoding.base64url(ticket.secret)))
        defer { phone.close() }
        await stack.server.setAcceptsLinks(true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAccountTests.legacy")))
        defaults.set("ws://127.0.0.1:\(stack.port)", forKey: RemoteControlService.relayURLKey)
        defaults.set(Data(#"{"id":"ACC","provider":"github"}"#.utf8), forKey: RemoteControlService.accountKey)
        StubRelay.accountPort = Int(stack.port)
        let identity = stack.identity
        StubRelay.macs = [["room": identity.room, "macKey": RemoteEncoding.base64url(identity.noise.publicKey),
                           "relayKey": RemoteEncoding.base64url(identity.relayPublicKey), "name": "Mac Studio"]]
        let client = RemoteControlService(bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
                                          identityStore: RemoteMemoryIdentityStore(.generate()),
                                          accountToken: RemoteMemorySecret("ACC.secret"), defaults: defaults,
                                          environment: [:], listens: false)
        let listed = try await client.otherAccountMacs()
        let mac = try XCTUnwrap(listed.first)
        struct LockedKeys: RemoteClientKeyStoring {
            func load(hostID: String) -> RemoteKeyPair? { nil }
            func save(_ key: RemoteKeyPair, hostID: String) {}
            func delete(hostID: String) {}
        }
        let locked = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: LockedKeys(), hello: .init())
        let callsBefore = StubRelay.calls
        do {
            _ = try await locked.connect(to: mac, service: client) { _ in XCTFail("Unexpected link request") }
            XCTFail("A client with no usable key enrolled")
        } catch let failure as RemoteHostDirectory.PairingFailure {
            XCTAssertEqual(failure, .keyUnavailable)
        }
        XCTAssertEqual(StubRelay.calls, callsBefore, "The host receives no request until the key can be saved")
        XCTAssertTrue(locked.hosts.isEmpty)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: .init(name: "Laptop", platform: "macos"))
        let number = Box<String?>(nil)
        let connecting = Task {
            try await directory.connect(to: mac, service: client) { number.value = $0 }
        }
        defer { connecting.cancel() }
        try await waitUntil { number.value != nil && !phone.events(.linkRequest).isEmpty }
        let request = try XCTUnwrap(phone.events(.linkRequest).first)
        XCTAssertEqual(request.code, number.value)
        let id = try XCTUnwrap(request.requestId)
        let approval = RemoteRequestEnvelope(id: "approve", request: .answerLink(requestID: id, approve: true))
        try await phone.send(String(decoding: approval.encoded(), as: UTF8.self))
        let host = try await connecting.value
        XCTAssertEqual(host.room, identity.room)
        let model = try XCTUnwrap(directory.model(for: host.id))
        defer { directory.close(host.id) }
        try await waitUntil { model.hasSnapshot }
        XCTAssertEqual(host.name, "Mac Studio")
    }

    func testTheMacSignsInPutsItselfOnTheAccountAndTakesLinkRequests() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAccountTests")))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let identity = RemoteIdentity.generate()
        let token = RemoteMemorySecret()
        var sheet: URL?
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            identityStore: RemoteMemoryIdentityStore(identity), accountToken: token,
            webSignIn: { url, scheme in
                sheet = url
                XCTAssertEqual(scheme, "yardlet-remote")
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                StubRelay.challenge = items.first { $0.name == "code_challenge" }?.value
                let state = items.first { $0.name == "state" }?.value ?? ""
                return URL(string: "yardlet-remote://auth?code=C1&state=\(state)")!
            },
            defaults: defaults, environment: [:], interfaces: { [] }, resolveName: { _ in nil }, listens: false,
            macName: "MacBook Pro", appVersion: "test")
        await service.start()
        // Remote connections off: Settings › Yardlet Account reads the providers as it opens, and nothing
        // else reaches the relay until the person signs in.
        StubRelay.providers = []
        await service.refreshAccountPage()
        XCTAssertEqual(service.accountProvidersRead, true)
        XCTAssertEqual(service.accountProviders, [], "A relay without sign-in providers offers no sign-in")
        StubRelay.providers = ["github"]
        await service.refreshAccountPage()
        XCTAssertEqual(service.accountProviders, ["github"])
        XCTAssertNil(service.account)
        XCTAssertEqual(StubRelay.calls, ["GET /v1/auth/providers", "GET /v1/auth/providers"])

        await service.signIn(with: "github")
        XCTAssertFalse(service.isEnabled, "Signing in leaves remote connections as they were")
        XCTAssertEqual(sheet?.path(), "/v1/auth/github/start")
        XCTAssertEqual(service.account?.name, "octocat")
        XCTAssertEqual(token.load(), "ACC.secret")
        let registered = try XCTUnwrap(StubRelay.registered)
        XCTAssertEqual(registered.room, identity.room)
        XCTAssertTrue(registered.signatureValid, "The relay can check the Mac holds the room's key")
        XCTAssertEqual(registered.name, "MacBook Pro")

        let studio = RemoteIdentity.generate()
        StubRelay.macs = [(identity, "This Mac"), (studio, "Mac Studio")].map { item, name in
            ["room": item.room, "macKey": RemoteEncoding.base64url(item.noise.publicKey),
             "relayKey": RemoteEncoding.base64url(item.relayPublicKey), "name": name]
        }
        let accountMacs = try await service.otherAccountMacs()
        XCTAssertEqual(accountMacs.map(\.name), ["Mac Studio"], "Outgoing connections work with hosting off and omit this Mac")

        // The next launch names the account before anything reaches the Keychain or the relay.
        let relaunched = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil, defaults: defaults,
            environment: [:], interfaces: { [] }, resolveName: { _ in nil }, listens: false)
        XCTAssertEqual(relaunched.account?.name, "octocat")
        XCTAssertEqual(YardletAccountSettingsView.summary(relaunched), "GitHub · octocat")

        // Signed in with remote connections on: a phone of the account may ask to link.
        service.setEnabled(true)
        await service.refreshAccount()
        let asking = try await PipePhone.link(server: service.server, macStatic: identity.noise, name: "Pixel 10")
        XCTAssertEqual(asking.reveal?.ok, true)
        await service.answerLink(approve: false)

        let peer = RemoteKeyPair.generate()
        StubRelay.grantKey = RemoteEncoding.base64url(peer.publicKey)
        let localMac = try JSONDecoder().decode(RemoteAccountClient.Mac.self,
                                                from: JSONSerialization.data(withJSONObject: StubRelay.macs[0]))
        let grant = try await service.accountGrant(for: localMac, key: peer.publicKey, accountID: "ACC")
        var hello = RemoteHandshakeHello(name: "Laptop", platform: "macos", link: true,
                                         linkCommit: RemoteEncoding.base64url(Data(RemoteRandom.bytes(32))))
        hello.accountGrant = try XCTUnwrap(grant)
        let enrolled = try await PipePhone.connect(server: service.server, macStatic: identity.noise, phoneKey: peer,
                                                    hello: hello, targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertTrue(enrolled.reply.ok)
        XCTAssertTrue(StubRelay.calls.contains("POST /v1/account/macs/\(identity.room)/link-grants/redeem"))

        await service.signOut()
        XCTAssertNil(service.account)
        XCTAssertNil(token.load())
        XCTAssertNil(defaults.data(forKey: RemoteControlService.accountKey), "Signing out leaves no account behind")
        XCTAssertEqual(YardletAccountSettingsView.summary(service), L10n.string("Not signed in"))
        XCTAssertEqual(StubRelay.calls.suffix(2), ["DELETE /v1/account/macs/\(identity.room)", "POST /v1/auth/logout"])
        let refused = try await PipePhone.connect(server: service.server, macStatic: identity.noise, phoneKey: .generate(),
                                                  hello: RemoteHandshakeHello(name: "Pixel 11", link: true),
                                                  targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertEqual(refused.reply.error?.code, .linkUnavailable)
    }

    /// The sheet can't be shown (another default browser failed to take it, or the session would not start):
    /// the sign-in opens in the default browser and finishes from the `yardlet-remote://auth` link the app gets,
    /// taking only the return for the sign-in in progress. A long computer name is cut to what the relay keeps.
    func testSignInFallsBackToTheDefaultBrowserAndTakesOnlyItsOwnReturn() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAccountBrowser")))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let token = RemoteMemorySecret()
        var opened: URL?
        let longName = String(repeating: "가", count: 40) + " MacBook Pro 👩‍💻"
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            identityStore: RemoteMemoryIdentityStore(.generate()), accountToken: token,
            webSignIn: { _, _ in throw RemoteWebSignInUnavailable(code: "asweb_2") },
            openInBrowser: { opened = $0 },
            defaults: defaults, environment: [:], interfaces: { [] }, resolveName: { _ in nil }, listens: false,
            macName: longName, appVersion: "test")
        await service.signIn(with: "github")
        let start = try XCTUnwrap(opened)
        XCTAssertTrue(service.awaitsBrowserSignIn)
        XCTAssertFalse(service.isSigningIn, "Signing in again stays possible while the browser is open")
        XCTAssertNil(service.accountError)
        let items = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems ?? []
        StubRelay.challenge = items.first { $0.name == "code_challenge" }?.value
        let state = try XCTUnwrap(items.first { $0.name == "state" }?.value)

        // A pairing link, another sign-in's return, or one for a different host are not this sign-in's.
        let pairing = try XCTUnwrap(URL(string: "yardlet-remote://pair?k=x"))
        XCTAssertFalse(RemoteAccountClient.isSignInCallback(pairing))
        XCTAssertFalse(service.receiveSignInCallback(pairing))
        XCTAssertFalse(service.receiveSignInCallback(URL(string: "yardlet-remote://auth?code=C1&state=other")!))
        XCTAssertTrue(service.awaitsBrowserSignIn)

        let callback = try XCTUnwrap(URL(string: "YARDLET-REMOTE://Auth?code=C1&state=\(state)"))
        XCTAssertTrue(RemoteAccountClient.isSignInCallback(callback))
        XCTAssertTrue(service.receiveSignInCallback(callback))
        XCTAssertFalse(service.receiveSignInCallback(callback), "A return is taken once")
        try await waitUntil { service.account != nil }
        XCTAssertEqual(token.load(), "ACC.secret")
        XCTAssertFalse(service.awaitsBrowserSignIn)
        let name = try XCTUnwrap(StubRelay.registered?.name)
        XCTAssertTrue(StubRelay.registered?.signatureValid == true, "The signature covers the name the relay keeps")
        XCTAssertLessThanOrEqual(name.utf16.count, RemoteAccountClient.maxNameLength)
        XCTAssertTrue(longName.hasPrefix(name))
        XCTAssertEqual(RemoteAccountClient.relayName("  Mac  "), "Mac")
    }

    /// What Settings shows and a problem report carries when signing in fails: a sentence instead of
    /// "Failure error 1", and a code naming the step and the error without the code, token or state.
    func testSignInFailuresReadAsSentencesAndReportOnlyTheirCode() async throws {
        XCTAssertEqual(RemoteAccountClient.Failure(status: 401, code: "unauthorized").localizedDescription,
                       L10n.string("Your Yardlet sign-in has expired. Sign in again."))
        XCTAssertEqual(RemoteAccountClient.Failure(status: 0, code: "noResponse").localizedDescription,
                       L10n.string("Can't reach the Yardlet server"))
        XCTAssertFalse(RemoteAccountClient.Failure(status: 400, code: "badRequest").localizedDescription.contains("Failure"))
        XCTAssertEqual(RemoteControlService.failureCode(RemoteAccountClient.Failure(status: 400, code: "badRequest")),
                       "http_400_badRequest")
        XCTAssertEqual(RemoteControlService.failureCode(NSError(domain: NSCocoaErrorDomain, code: 4097)), "xpc_4097")
        XCTAssertEqual(RemoteControlService.failureCode(URLError(.notConnectedToInternet)), "url_-1009")
        XCTAssertNil(RemoteControlService.failureCode(RemoteAccountClient.Failure(status: 400, code: "token ACC.secret")),
                     "A relay's error text that isn't a code is left out")

        // The session's own outcomes: a quick "cancel" is a sheet that never showed, a later one the person.
        let quick = RemoteAccountSignIn.outcome(callback: nil, error: NSError(
            domain: ASWebAuthenticationSessionErrorDomain, code: ASWebAuthenticationSessionError.canceledLogin.rawValue), after: 0.2)
        XCTAssertEqual((quick.failureValue as? RemoteWebSignInUnavailable)?.code, "asweb_1")
        let closed = RemoteAccountSignIn.outcome(callback: nil, error: NSError(
            domain: ASWebAuthenticationSessionErrorDomain, code: ASWebAuthenticationSessionError.canceledLogin.rawValue), after: 5)
        XCTAssertTrue(closed.failureValue is CancellationError)
        let invalid = RemoteAccountSignIn.outcome(callback: nil, error: NSError(
            domain: ASWebAuthenticationSessionErrorDomain, code: 2), after: 0.1)
        XCTAssertEqual((invalid.failureValue as? RemoteWebSignInUnavailable)?.code, "asweb_2")

        // The relay sent its error back instead of a code.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAccountFailure")))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            identityStore: RemoteMemoryIdentityStore(.generate()),
            webSignIn: { url, _ in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
                return URL(string: "yardlet-remote://auth?error=providerFailed&state=\(state)")!
            },
            defaults: defaults, environment: [:], interfaces: { [] }, resolveName: { _ in nil }, listens: false,
            macName: "Mac", appVersion: "test")
        await service.signIn(with: "github")
        XCTAssertEqual(service.accountError, L10n.string("The sign-in did not finish."))
        XCTAssertEqual(service.accountErrorCode, "relay_providerFailed")
    }

    /// The session's completion, a failed start and the task's cancellation may each resume the sign-in;
    /// only the first does, and a cancellation that comes first still ends it.
    func testTheSignInContinuationResumesOnce() async throws {
        let once = SignInResumeOnce<Int>()
        let value = try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            once.resume(with: .success(1))
            once.resume(throwing: CancellationError())
            once.resume(with: .success(2))
        }
        XCTAssertEqual(value, 1)
        let early = SignInResumeOnce<Int>()
        early.resume(throwing: CancellationError())
        do {
            _ = try await withCheckedThrowingContinuation { early.set($0) }
            XCTFail("An early cancellation ends the wait")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

/// The relay's account endpoints on `relay.example.test`, as the tests need them.
final class StubRelay: URLProtocol {
    struct Registration {
        var room: String
        var name: String
        var signatureValid: Bool
    }

    nonisolated(unsafe) static var challenge: String?
    nonisolated(unsafe) static var registered: Registration?
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var grantKey: String?
    nonisolated(unsafe) static var accountPort: Int?
    nonisolated(unsafe) static var macs: [[String: String]] = []
    nonisolated(unsafe) static var providers = ["github"]

    static func reset() {
        challenge = nil
        registered = nil
        macs = []
        grantKey = nil
        accountPort = nil
        calls = []
        providers = ["github"]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "relay.example.test" || (url.host == "127.0.0.1" && url.port == accountPort &&
            url.scheme == "http" && url.path().hasPrefix("/v1/account"))
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        Self.calls.append("\(method) \(url.path())")
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer ACC.secret"
        var status = 200
        var answer: Any = ["ok": true]
        switch (method, url.path()) {
        case ("GET", "/v1/auth/providers"):
            answer = ["providers": Self.providers]
        case ("POST", "/v1/auth/token"):
            let verifier = json["codeVerifier"] ?? ""
            let challenge = RemoteEncoding.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
            if json["code"] == "C1", challenge == Self.challenge {
                answer = ["token": "ACC.secret", "account": ["id": "ACC", "provider": "github", "name": "octocat"]]
            } else {
                status = 401
                answer = ["error": "unauthorized"]
            }
        case ("GET", "/v1/account") where authorized:
            answer = ["id": "ACC", "provider": "github", "name": "octocat", "macs": Self.macs]
        case ("PUT", let path) where authorized && path.hasPrefix("/v1/account/macs/"):
            let room = String(path.dropFirst("/v1/account/macs/".count))
            let relayKey = RemoteEncoding.data(base64url: json["relayKey"] ?? "") ?? Data()
            let signature = RemoteEncoding.data(base64url: json["sig"] ?? "") ?? Data()
            let message = Data("yardlet-account-mac/1\nACC\n\(room)\n\(json["macKey"] ?? "")\n\(json["name"] ?? "")".utf8)
            let valid = (try? Curve25519.Signing.PublicKey(rawRepresentation: relayKey).isValidSignature(signature, for: message)) ?? false
            Self.registered = Registration(room: room, name: json["name"] ?? "",
                                           signatureValid: valid && RemoteIdentity.room(for: relayKey) == room)
        case ("POST", let path) where authorized && path.hasSuffix("/link-grants"):
            if let key = Self.grantKey, json["clientKey"] == key {
                answer = ["grant": RemoteEncoding.base64url(Data(repeating: 5, count: 32))]
            } else {
                status = 404
                answer = [:]
            }
        case ("POST", let path) where authorized && path == "/v1/account/macs/\(Self.registered?.room ?? "")/link-grants/redeem":
            answer = ["ok": json["clientKey"] == Self.grantKey && json["grant"] == RemoteEncoding.base64url(Data(repeating: 5, count: 32))]
        case ("DELETE", _), ("POST", "/v1/auth/logout"):
            status = authorized ? 204 : 401
        default:
            status = 401
            answer = ["error": "unauthorized"]
        }
        let data = status == 204 ? Data() : (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class DelayedRemoteIdentityStore: RemoteIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var identity: RemoteIdentity?
    private var readCount = 0
    private var writeCount = 0
    private var onMain = false
    private let blockedRead: Int
    init(blockedRead: Int = 1) { self.blockedRead = blockedRead }
    var storedPublicKey: Data? { lock.withLock { identity?.noise.publicKey } }
    var reads: Int { lock.withLock { readCount } }
    var writes: Int { lock.withLock { writeCount } }
    var usedMainThread: Bool { lock.withLock { onMain } }

    func release() { gate.signal() }

    func load() throws -> RemoteIdentity? {
        let first = lock.withLock {
            readCount += 1
            onMain = onMain || Thread.isMainThread
            return readCount == blockedRead
        }
        // A regression must fail rather than hang the test's main actor.
        if first && !Thread.isMainThread { gate.wait() }
        return lock.withLock { identity }
    }

    func save(_ value: RemoteIdentity) throws {
        lock.withLock {
            writeCount += 1
            onMain = onMain || Thread.isMainThread
            identity = value
        }
    }
}
