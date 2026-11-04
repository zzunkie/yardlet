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
        XCTAssertEqual(parsed.macKey, store.storedPublicKey)
        XCTAssertEqual(store.writes, 1)
        service.setEnabled(false)
        await service.shutdown()
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
    nonisolated(unsafe) static var providers = ["github"]

    static func reset() {
        challenge = nil
        registered = nil
        calls = []
        providers = ["github"]
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.example.test" }
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
            answer = ["id": "ACC", "provider": "github", "name": "octocat", "macs": []]
        case ("PUT", let path) where authorized && path.hasPrefix("/v1/account/macs/"):
            let room = String(path.dropFirst("/v1/account/macs/".count))
            let relayKey = RemoteEncoding.data(base64url: json["relayKey"] ?? "") ?? Data()
            let signature = RemoteEncoding.data(base64url: json["sig"] ?? "") ?? Data()
            let message = Data("yardlet-account-mac/1\nACC\n\(room)\n\(json["macKey"] ?? "")\n\(json["name"] ?? "")".utf8)
            let valid = (try? Curve25519.Signing.PublicKey(rawRepresentation: relayKey).isValidSignature(signature, for: message)) ?? false
            Self.registered = Registration(room: room, name: json["name"] ?? "",
                                           signatureValid: valid && RemoteIdentity.room(for: relayKey) == room)
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
