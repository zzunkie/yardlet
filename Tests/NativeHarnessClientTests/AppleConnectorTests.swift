import CryptoKit
import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's Apple connectors (docs/CONNECTORS.md, "Apple"): App Store Connect with the person's API
/// key, the Mac's calendars, reminders, and contacts, and Xcode's own MCP server through
/// `mcpbridge`. App Store Connect is a local fake that checks each token's signature, the Mac's
/// data a store of the test's own, and Xcode's bridge a fake server or a small shell script: no
/// request leaves the machine, no privacy prompt or keychain item appears, and Xcode never starts.
@MainActor
final class AppleConnectorTests: XCTestCase {
    nonisolated private static let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func makeCenter(
        http: any ConnectorHTTPTransport = FakeAppStoreConnect(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        repository: InMemoryConnectorRepository = InMemoryConnectorRepository(),
        macData: (any MacDataStoring)? = nil,
        bridge: FakeStdioServer? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: repository, credentials: credentials, http: http, userAgent: nil,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: now)
        environment.appStoreConnect = FakeAppStoreConnect.base
        environment.es256 = MacES256Signer()
        environment.timeZone = { Self.seoul }
        environment.macData = macData
        if let bridge {
            environment.xcodeBridge = { FakeStdioServer.path }
            environment.stdioLauncher = { _ in bridge }
        }
        return ConnectorCenter(environment: environment)
    }

    private func call(_ center: ConnectorCenter, _ name: String, _ arguments: [String: ToolJSON] = [:]) async throws -> AgentToolResult {
        try XCTUnwrapAsync(await center.callConnectorTool(named: name, arguments: .object(arguments), for: ConnectorToolContext()))
    }

    private func json(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> ToolJSON {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSONDecoder().decode(ToolJSON.self, from: Data(result.text.utf8))
    }

    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    private func body(_ request: URLRequest) throws -> ToolJSON {
        try JSONDecoder().decode(ToolJSON.self, from: XCTUnwrap(request.httpBody))
    }

    // MARK: - App Store Connect: the key and its tokens

    /// A team key's token names its issuer, an individual key's says `sub: user`; both are ES256
    /// over the header and payload, live at most 20 minutes, and verify with the key's public half.
    func testTokensAreSignedForTeamAndIndividualKeys() throws {
        let privateKey = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signer = MacES256Signer()
        let team = try AppStoreConnectKey(id: "2x9r4hxf34", issuer: FakeAppStoreConnect.issuer.uppercased(),
                                          pem: privateKey.pemRepresentation, signer: signer)
        XCTAssertEqual(team.id, "2X9R4HXF34")
        XCTAssertTrue(team.isTeamKey)
        let teamToken = try FakeAppStoreConnect.decode(team.token(now: now), verifyingWith: privateKey.publicKey)
        XCTAssertEqual(teamToken.header, .object(["alg": .string("ES256"), "kid": .string("2X9R4HXF34"), "typ": .string("JWT")]))
        XCTAssertEqual(teamToken.payload["iss"], .string(FakeAppStoreConnect.issuer))
        XCTAssertEqual(teamToken.payload["aud"], .string("appstoreconnect-v1"))
        XCTAssertNil(teamToken.payload["sub"])
        func integer(_ value: ToolJSON?) -> Int64? {
            if case .integer(let number)? = value { return number }
            return nil
        }
        let issued = try XCTUnwrap(integer(teamToken.payload["iat"]))
        let expires = try XCTUnwrap(integer(teamToken.payload["exp"]))
        XCTAssertEqual(issued, 1_800_000_000)
        XCTAssertEqual(expires - issued, 900, "Fifteen minutes, within Apple's twenty")
        let long = try FakeAppStoreConnect.decode(team.token(now: now, lifetime: 3_600), verifyingWith: privateKey.publicKey)
        XCTAssertEqual(integer(long.payload["exp"]), 1_800_000_000 + 1_200, "Never past twenty minutes")

        let individual = try AppStoreConnectKey(id: "ABCDEF1234", issuer: nil, pem: privateKey.pemRepresentation, signer: signer)
        let individualToken = try FakeAppStoreConnect.decode(individual.token(now: now), verifyingWith: privateKey.publicKey)
        XCTAssertEqual(individualToken.payload["sub"], .string("user"))
        XCTAssertNil(individualToken.payload["iss"])

        XCTAssertEqual(AppStoreConnectKey.keyID(fromFileName: "AuthKey_2X9R4HXF34.p8"), "2X9R4HXF34")
        XCTAssertNil(AppStoreConnectKey.keyID(fromFileName: "key.p8"))
        XCTAssertThrowsError(try AppStoreConnectKey(id: "2X9R4HXF34", issuer: nil, pem: "-----BEGIN PRIVATE KEY-----\nnot a key\n",
                                                    signer: signer))
        XCTAssertThrowsError(try AppStoreConnectKey(id: "short", issuer: nil, pem: privateKey.pemRepresentation, signer: signer))
        XCTAssertThrowsError(try AppStoreConnectKey(id: "2X9R4HXF34", issuer: "not-a-uuid", pem: privateKey.pemRepresentation,
                                                    signer: signer))
        XCTAssertThrowsError(try AppStoreConnectKey(id: "2X9R4HXF34", issuer: nil, pem: privateKey.pemRepresentation, signer: nil))
    }

    /// The key goes to the secure store only: `connectors.json` has its key ID and nothing else of
    /// it. Connecting reads the app list once with a signed token; the tools then reach every task.
    /// Adding the same key again replaces it, and removing it leaves nothing behind.
    func testAKeyLivesInTheKeychainOnlyAndConnectsWithOneRead() async throws {
        let apple = FakeAppStoreConnect()
        let credentials = InMemoryConnectorCredentialStore()
        let repository = InMemoryConnectorRepository()
        let center = makeCenter(http: apple, credentials: credentials, repository: repository)
        await XCTAssertThrowsErrorAsync(try await center.addAppStoreConnectKey(privateKey: "nonsense", keyID: "2X9R4HXF34",
                                                                               issuerID: FakeAppStoreConnect.issuer))
        XCTAssertTrue(center.connectors.isEmpty, "A file that is not a key stores nothing")

        let record = try await center.addAppStoreConnectKey(privateKey: apple.privateKey.pemRepresentation, keyID: "2X9R4HXF34",
                                                            issuerID: FakeAppStoreConnect.issuer)
        await center.waitForConnection(record.id)
        let connected = try XCTUnwrap(center.record(record.id))
        XCTAssertEqual(connected.status, .connected, center.failures[record.id] ?? "")
        XCTAssertEqual(connected.displayName, "App Store Connect · 2X9R4HXF34")
        XCTAssertEqual(connected.slug, "app_store_connect")
        let stored = try XCTUnwrap(credentials.load(record.id))
        XCTAssertEqual(stored.kind, .signingKey)
        XCTAssertEqual(stored.issuerID, FakeAppStoreConnect.issuer)
        XCTAssertNotNil(stored.privateKey.flatMap { try? P256.Signing.PrivateKey(pemRepresentation: $0) })
        let file = String(decoding: try JSONEncoder().encode(repository.records), as: UTF8.self)
        XCTAssertFalse(file.contains("PRIVATE KEY") || file.contains(FakeAppStoreConnect.issuer), "No key in connectors.json")

        XCTAssertEqual(apple.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }, ["GET /v1/apps"])
        XCTAssertEqual(query(apple.requests[0])["limit"], "1")

        let names = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, AppStoreConnectToolCatalog.tools.compactMap { $0["name"]?.stringValue }.map { "app_store_connect_\($0)" })

        let again = try await center.addAppStoreConnectKey(privateKey: apple.privateKey.pemRepresentation, keyID: "2X9R4HXF34",
                                                           issuerID: FakeAppStoreConnect.issuer)
        await center.waitForConnection(again.id)
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(center.connectors.count, 1, "The same key replaces itself")

        center.remove(record.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(record.id))
        XCTAssertTrue(repository.records.isEmpty)
    }

    /// Each tool's request and the answer it makes of Apple's JSON:API.
    func testToolsAskAppStoreConnectWhatTheySay() async throws {
        let apple = FakeAppStoreConnect()
        let center = makeCenter(http: apple)
        let record = try await center.addAppStoreConnectKey(privateKey: apple.privateKey.pemRepresentation, keyID: "2X9R4HXF34",
                                                            issuerID: FakeAppStoreConnect.issuer)
        await center.waitForConnection(record.id)

        apple.answers["GET /v1/builds"] = (200, .object([
            "data": .array([.object([
                "type": .string("builds"), "id": .string("b1"),
                "attributes": .object(["version": .string("45"), "processingState": .string("VALID"),
                                       "uploadedDate": .string("2026-10-25T09:00:00Z"), "expired": .bool(false)]),
                "relationships": .object([
                    "preReleaseVersion": .object(["data": .object(["type": .string("preReleaseVersions"), "id": .string("p1")])]),
                    "buildBetaDetail": .object(["data": .object(["type": .string("buildBetaDetails"), "id": .string("d1")])])
                ])
            ])]),
            "included": .array([
                .object(["type": .string("preReleaseVersions"), "id": .string("p1"),
                         "attributes": .object(["version": .string("1.2.0"), "platform": .string("IOS")])]),
                .object(["type": .string("buildBetaDetails"), "id": .string("d1"),
                         "attributes": .object(["internalBuildState": .string("IN_BETA_TESTING"),
                                                "externalBuildState": .string("WAITING_FOR_BETA_REVIEW")])])
            ]),
            "links": .object(["next": .string("https://api.appstoreconnect.apple.com/v1/builds?cursor=Mg.Abc&limit=20")])
        ]))
        let builds = try json(try await call(center, "app_store_connect_list_builds", ["appId": .string("123"), "version": .string("1.2.0")]))
        let request = try XCTUnwrap(apple.requests.last)
        XCTAssertEqual(query(request)["filter[app]"], "123")
        XCTAssertEqual(query(request)["filter[preReleaseVersion.version]"], "1.2.0")
        XCTAssertEqual(query(request)["sort"], "-uploadedDate")
        XCTAssertEqual(query(request)["include"], "preReleaseVersion,buildBetaDetail")
        let build = try XCTUnwrap(builds["builds"]?.arrayValue?.first)
        XCTAssertEqual(build["buildNumber"], .string("45"))
        XCTAssertEqual(build["version"], .string("1.2.0"))
        XCTAssertEqual(build["platform"], .string("IOS"))
        XCTAssertEqual(build["externalBuildState"], .string("WAITING_FOR_BETA_REVIEW"))
        XCTAssertEqual(builds["nextCursor"], .string("Mg.Abc"))

        apple.answers["GET /v1/apps/123/customerReviews"] = (200, .object([
            "data": .array([.object([
                "type": .string("customerReviews"), "id": .string("r1"),
                "attributes": .object(["rating": .integer(2), "title": .string("Too slow"), "body": .string("The app is slow"),
                                       "territory": .string("KOR")]),
                "relationships": .object(["response": .object(["data": .object(["type": .string("customerReviewResponses"),
                                                                               "id": .string("rr1")])])])
            ])]),
            "included": .array([.object(["type": .string("customerReviewResponses"), "id": .string("rr1"),
                                         "attributes": .object(["responseBody": .string("We will fix it"),
                                                                "state": .string("PUBLISHED")])])])
        ]))
        let reviews = try json(try await call(center, "app_store_connect_list_customer_reviews",
                                              ["appId": .string("123"), "sort": .string("lowest"), "rating": .integer(2)]))
        XCTAssertEqual(query(try XCTUnwrap(apple.requests.last))["sort"], "rating")
        XCTAssertEqual(query(try XCTUnwrap(apple.requests.last))["filter[rating]"], "2")
        XCTAssertEqual(reviews["reviews"]?.arrayValue?.first?["response"]?["responseBody"], .string("We will fix it"))

        apple.answers["GET /v1/apps/123/betaFeedbackScreenshotSubmissions"] = (200, .object(["data": .array([
            .object(["type": .string("betaFeedbackScreenshotSubmissions"), "id": .string("s1"),
                     "attributes": .object(["createdDate": .string("2026-10-24T01:00:00Z"), "comment": .string("The button is cut off"),
                                            "screenshots": .array([.object(["url": .string("https://example.test/s.png"),
                                                                            "width": .integer(10), "expirationDate": .string("x")])])])])
        ])]))
        apple.answers["GET /v1/apps/123/betaFeedbackCrashSubmissions"] = (200, .object(["data": .array([
            .object(["type": .string("betaFeedbackCrashSubmissions"), "id": .string("c1"),
                     "attributes": .object(["createdDate": .string("2026-10-25T01:00:00Z"), "comment": .string("Quits right after launch"),
                                            "appUptimeInMilliseconds": .integer(12)])])
        ])]))
        let feedback = try json(try await call(center, "app_store_connect_list_beta_feedback", ["appId": .string("123")]))
        XCTAssertEqual(feedback["feedback"]?.arrayValue?.map { $0["kind"] }, [.string("crash"), .string("screenshot")], "Newest first")
        XCTAssertNil(feedback["feedback"]?.arrayValue?.first?["appUptimeInMilliseconds"])
        XCTAssertEqual(feedback["feedback"]?.arrayValue?.last?["screenshots"]?.arrayValue?.first,
                       .object(["url": .string("https://example.test/s.png"), "width": .integer(10)]))

        // Writes.
        _ = try json(try await call(center, "app_store_connect_add_beta_tester",
                                    ["groupId": .string("g1"), "email": .string("tester@example.test"), "firstName": .string("Minsu")]))
        let invite = try body(try XCTUnwrap(apple.requests.last))
        XCTAssertEqual(apple.requests.last?.url?.path, "/v1/betaTesters")
        XCTAssertEqual(invite["data"]?["attributes"]?["email"], .string("tester@example.test"))
        XCTAssertEqual(invite["data"]?["relationships"]?["betaGroups"]?["data"]?.arrayValue?.first?["id"], .string("g1"))

        _ = try json(try await call(center, "app_store_connect_remove_beta_tester", ["groupId": .string("g1"), "testerId": .string("t9")]))
        XCTAssertEqual(apple.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(apple.requests.last?.url?.path, "/v1/betaGroups/g1/relationships/betaTesters")
        XCTAssertEqual(try body(try XCTUnwrap(apple.requests.last))["data"]?.arrayValue?.first?["id"], .string("t9"))

        _ = try json(try await call(center, "app_store_connect_add_build_to_group", ["groupId": .string("g1"), "buildId": .string("b1")]))
        XCTAssertEqual(apple.requests.last?.url?.path, "/v1/betaGroups/g1/relationships/builds")

        _ = try json(try await call(center, "app_store_connect_reply_to_review",
                                    ["reviewId": .string("r1"), "responseBody": .string("Fixed in the update.")]))
        let reply = try body(try XCTUnwrap(apple.requests.last))
        XCTAssertEqual(reply["data"]?["attributes"]?["responseBody"], .string("Fixed in the update."))
        XCTAssertEqual(reply["data"]?["relationships"]?["review"]?["data"]?["id"], .string("r1"))

        // Submitting reuses the app's submission not sent yet, adds the version, and sends it.
        apple.answers["GET /v1/appStoreVersions/v7"] = (200, .object(["data": .object([
            "type": .string("appStoreVersions"), "id": .string("v7"),
            "attributes": .object(["platform": .string("IOS"), "versionString": .string("1.2.0")]),
            "relationships": .object(["app": .object(["data": .object(["type": .string("apps"), "id": .string("123")])])])
        ])]))
        apple.answers["GET /v1/reviewSubmissions"] = (200, .object(["data": .array([.object(["type": .string("reviewSubmissions"),
                                                                                            "id": .string("rs1")])])]))
        apple.answers["PATCH /v1/reviewSubmissions/rs1"] = (200, .object(["data": .object([
            "type": .string("reviewSubmissions"), "id": .string("rs1"),
            "attributes": .object(["state": .string("WAITING_FOR_REVIEW")])
        ])]))
        let before = apple.requests.count
        let submitted = try json(try await call(center, "app_store_connect_submit_for_review", ["versionId": .string("v7")]))
        XCTAssertEqual(apple.requests.dropFirst(before).map { "\($0.httpMethod ?? "") \($0.url!.path)" },
                       ["GET /v1/appStoreVersions/v7", "GET /v1/reviewSubmissions", "POST /v1/reviewSubmissionItems",
                        "PATCH /v1/reviewSubmissions/rs1"])
        XCTAssertEqual(query(apple.requests[before + 1])["filter[state]"], "READY_FOR_REVIEW")
        XCTAssertEqual(try body(apple.requests[before + 2])["data"]?["relationships"]?["appStoreVersion"]?["data"]?["id"], .string("v7"))
        XCTAssertEqual(try body(apple.requests[before + 3])["data"]?["attributes"]?["submitted"], .bool(true))
        XCTAssertEqual(submitted["submission"]?["state"], .string("WAITING_FOR_REVIEW"))

        // With none open, a new submission for the version's platform.
        apple.answers["GET /v1/reviewSubmissions"] = (200, .object(["data": .array([])]))
        apple.answers["POST /v1/reviewSubmissions"] = (201, .object(["data": .object(["type": .string("reviewSubmissions"),
                                                                                       "id": .string("rs2")])]))
        let fresh = apple.requests.count
        _ = try json(try await call(center, "app_store_connect_submit_for_review", ["versionId": .string("v7")]))
        XCTAssertEqual(apple.requests.dropFirst(fresh).map { "\($0.httpMethod ?? "") \($0.url!.path)" },
                       ["GET /v1/appStoreVersions/v7", "GET /v1/reviewSubmissions", "POST /v1/reviewSubmissions",
                        "POST /v1/reviewSubmissionItems", "PATCH /v1/reviewSubmissions/rs2"])
        XCTAssertEqual(try body(apple.requests[fresh + 2])["data"]?["attributes"]?["platform"], .string("IOS"))

        // Apple's own error words, and an ID refused before any request.
        apple.answers["GET /v1/apps/404/appStoreVersions"] = (404, .object(["errors": .array([.object([
            "status": .string("404"), "code": .string("NOT_FOUND"), "title": .string("The specified resource does not exist"),
            "detail": .string("There is no resource of type 'apps' with id '404'")
        ])])]))
        let missing = try await call(center, "app_store_connect_list_app_store_versions", ["appId": .string("404")])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.text, "App Store Connect: There is no resource of type 'apps' with id '404' (HTTP 404)")
        let count = apple.requests.count
        let bad = try await call(center, "app_store_connect_list_customer_reviews", ["appId": .string("../users")])
        XCTAssertTrue(bad.isError)
        XCTAssertEqual(apple.requests.count, count)
    }

    /// Apple refusing a fresh token too means the key is gone: the connector needs a new key, and
    /// the call says where to add one.
    func testARefusedKeyNeedsANewKey() async throws {
        let apple = FakeAppStoreConnect()
        let center = makeCenter(http: apple)
        let record = try await center.addAppStoreConnectKey(privateKey: apple.privateKey.pemRepresentation, keyID: "2X9R4HXF34",
                                                            issuerID: nil)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        let token = try FakeAppStoreConnect.decode(XCTUnwrap(apple.requests.first?.value(forHTTPHeaderField: "Authorization"))
            .replacingOccurrences(of: "Bearer ", with: ""), verifyingWith: apple.privateKey.publicKey)
        XCTAssertEqual(token.payload["sub"], .string("user"), "An individual key")

        apple.refusesKey = true
        let before = apple.requests.count
        let result = try await call(center, "app_store_connect_list_apps")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Yardlet Settings → Connectors → App Store Connect"), result.text)
        XCTAssertEqual(apple.requests.count - before, 2, "Once more with a fresh token")
        XCTAssertEqual(center.record(record.id)?.status, .signInRequired)
    }

    // MARK: - Writes ask

    /// Reads go without asking; each write asks every time, with the Yardlet wording in Claude
    /// Code's card and annotations Codex reads.
    func testWritesAskEveryTime() throws {
        func annotations(_ tools: [ToolJSON]) -> [String: ToolJSON] {
            Dictionary(uniqueKeysWithValues: tools.compactMap { tool in tool["name"]?.stringValue.map { ($0, tool["annotations"] ?? .null) } })
        }
        for (service, tools) in [(LocalConnectorService.appStoreConnect, AppStoreConnectToolCatalog.tools),
                                 (.appleCalendar, MacCalendarToolCatalog.tools), (.appleReminders, MacRemindersToolCatalog.tools),
                                 (.appleContacts, MacContactsToolCatalog.tools)] {
            let names = Set(tools.compactMap { $0["name"]?.stringValue })
            XCTAssertTrue(service.approvalRequiredTools.isSubset(of: names), "\(service)")
            for (name, annotation) in annotations(tools) {
                let asks = service.approvalRequiredTools.contains(name)
                XCTAssertEqual(annotation["readOnlyHint"], .bool(!asks), "\(service) \(name)")
                XCTAssertEqual(annotation["openWorldHint"], .bool(asks), "\(service) \(name): a write reaches the account's server")
                let description = tools.first { $0["name"]?.stringValue == name }?["description"]?.stringValue ?? ""
                XCTAssertLessThan(description.count, 260, name)
            }
        }
        XCTAssertFalse(AgentToolServerLaunch.claudeAllowedTools.contains { $0.contains("app_store") || $0.contains("apple_") })

        let labels = ConnectorToolLabels()
        labels.update([
            ConnectorRecord(name: "App Store Connect", slug: "app_store_connect", serverURL: FakeAppStoreConnect.base,
                            presetID: "app-store-connect", localService: .appStoreConnect, account: "2X9R4HXF34"),
            ConnectorRecord(name: "Apple Calendar", slug: "apple_calendar", serverURL: LocalConnectorService.appleCalendar.address,
                            presetID: "apple-calendar", localService: .appleCalendar),
            ConnectorRecord(name: "Apple Reminders", slug: "apple_reminders", serverURL: LocalConnectorService.appleReminders.address,
                            presetID: "apple-reminders", localService: .appleReminders)
        ])
        let submit = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__app_store_connect_submit_for_review",
                                                              input: .object(["versionId": .string("v7")]), labels: labels))
        XCTAssertEqual(submit.title, L10n.string("Allow Claude to submit an App Store version for App Review?"))
        XCTAssertTrue(submit.detail.contains("v7") && submit.detail.contains("2X9R4HXF34"), submit.detail)
        let reply = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__app_store_connect_reply_to_review",
                                                             input: .object(["reviewId": .string("r1"),
                                                                             "responseBody": .string("Fixed")]), labels: labels))
        XCTAssertTrue(reply.detail.contains("Fixed"))
        let invite = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__app_store_connect_add_beta_tester",
                                                              input: .object(["groupId": .string("g1"),
                                                                              "email": .string("tester@example.test")]), labels: labels))
        XCTAssertTrue(invite.detail.contains("tester@example.test"))
        let event = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__apple_calendar_create_event",
                                                             input: .object(["summary": .string("Team meeting"),
                                                                             "startTime": .string("2026-10-27T10:00:00")]),
                                                             labels: labels))
        XCTAssertEqual(event.title, L10n.string("Allow Claude to create an event in this Mac's calendars?"))
        XCTAssertTrue(event.detail.contains("Team meeting"))
        let done = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__apple_reminders_complete_reminder",
                                                            input: .object(["reminderId": .string("x")]), labels: labels))
        XCTAssertEqual(done.title, L10n.string("Allow Claude to mark a reminder done?"))
        XCTAssertNil(GoogleToolApproval.request(toolName: "mcp__yardlet__app_store_connect_list_apps", input: .object([:]), labels: labels))
        XCTAssertNil(GoogleToolApproval.request(toolName: "mcp__yardlet__apple_calendar_list_events", input: .object([:]), labels: labels))
    }

    // MARK: - The Mac's calendars, reminders, and contacts

    /// Turning a Mac connector on asks macOS once; once allowed, connecting again asks nothing. Where
    /// macOS said no, connecting says where to allow it and brings up no prompt.
    func testTurningOnAsksMacOSOnce() async throws {
        let store = FakeMacData()
        store.permissions = [.calendars: .notDetermined, .reminders: .denied, .contacts: .granted]
        let center = makeCenter(macData: store)
        guard let preset = ConnectorPreset.preset(id: "apple-calendar") else { return XCTFail("No Apple Calendar") }
        let calendar = try await center.add(name: preset.name, serverURL: preset.serverURL, preset: preset)
        XCTAssertEqual(calendar.localService, .appleCalendar)
        XCTAssertEqual(calendar.slug, "apple_calendar")
        center.connect(calendar.id)
        await center.waitForConnection(calendar.id)
        XCTAssertEqual(center.record(calendar.id)?.status, .connected)
        XCTAssertEqual(store.prompts, [.calendars])
        center.connect(calendar.id)
        await center.waitForConnection(calendar.id)
        XCTAssertEqual(store.prompts, [.calendars], "Allowed already: no second prompt")
        XCTAssertEqual(center.addLocal(.appleCalendar).id, calendar.id, "One per Mac")

        let reminders = center.addLocal(.appleReminders)
        center.connect(reminders.id)
        await center.waitForConnection(reminders.id)
        XCTAssertEqual(center.record(reminders.id)?.status, .notConnected)
        XCTAssertEqual(center.failures[reminders.id], MacDataError.notAllowed(.reminders, .denied).localizedDescription)
        XCTAssertTrue(center.failures[reminders.id]?.contains(L10n.string("Reminders")) == true)
        XCTAssertEqual(store.prompts, [.calendars], "macOS said no before: no prompt")

        let names = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, MacCalendarToolCatalog.tools.compactMap { $0["name"]?.stringValue }.map { "apple_calendar_\($0)" })

        // Taken away in System Settings later: the call says so and where to allow it again.
        store.permissions[.calendars] = .denied
        let refused = try await call(center, "apple_calendar_list_calendars")
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains(L10n.string("Calendars")), refused.text)

        center.remove(calendar.id)
        XCTAssertNil(center.record(calendar.id))
        XCTAssertEqual(store.prompts, [.calendars])
    }

    /// The calendar tools: the range, the words, an all-day event's days, a time without an offset
    /// read in the Mac's zone or the call's, alerts, moving only the start, and one occurrence of a
    /// recurring event by its ID.
    func testCalendarToolsReadAndWriteThroughTheStore() async throws {
        let store = FakeMacData()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let center = makeCenter(macData: store, now: { now })
        center.connect(center.addLocal(.appleCalendar).id)
        await center.waitForConnection(center.connectors[0].id)

        let listed = try json(try await call(center, "apple_calendar_list_events", ["query": .string("standup")]))
        XCTAssertEqual(store.ranges.last?.0, now)
        XCTAssertEqual(store.ranges.last?.1, now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(listed["events"]?.arrayValue?.map { $0["summary"] }, [.string("Daily standup")])
        let standup = try XCTUnwrap(listed["events"]?.arrayValue?.first)
        XCTAssertEqual(standup["recurring"], .bool(true))
        let occurrenceID = try XCTUnwrap(standup["id"]?.stringValue)
        XCTAssertTrue(occurrenceID.hasPrefix("E1@"), occurrenceID)
        XCTAssertEqual(standup["startTime"], .string("2026-10-26T10:00:00+09:00"))

        let holiday = try json(try await call(center, "apple_calendar_get_event", ["eventId": .string("E2")]))
        XCTAssertEqual(holiday["allDay"], .bool(true))
        XCTAssertEqual(holiday["startTime"], .string("2026-10-28"))
        XCTAssertEqual(holiday["endTime"], .string("2026-10-29"), "The last day, included")

        _ = try json(try await call(center, "apple_calendar_create_event", [
            "summary": .string("Dentist"), "startTime": .string("2026-10-30T15:00:00"), "endTime": .string("2026-10-30T16:00:00"),
            "location": .string("Gangnam"), "alertMinutes": .array([.integer(30)]), "calendarId": .string("work")
        ]))
        let created = try XCTUnwrap(store.savedEvents.last)
        XCTAssertNil(created.id)
        XCTAssertEqual(created.start, ISO8601DateFormatter().date(from: "2026-10-30T06:00:00Z"), "Read in the Mac's zone")
        XCTAssertEqual(created.alarmMinutes, [30])
        XCTAssertEqual(created.calendarID, "work")

        _ = try json(try await call(center, "apple_calendar_create_event", [
            "summary": .string("Vacation"), "startTime": .string("2026-11-02"), "endTime": .string("2026-11-03"), "allDay": .bool(true)
        ]))
        let vacation = try XCTUnwrap(store.savedEvents.last)
        XCTAssertEqual(vacation.start, ISO8601DateFormatter().date(from: "2026-11-01T15:00:00Z"))
        XCTAssertEqual(vacation.end, ISO8601DateFormatter().date(from: "2026-11-03T14:59:59Z"))

        _ = try json(try await call(center, "apple_calendar_update_event", [
            "eventId": .string(occurrenceID), "startTime": .string("2026-10-26T11:00:00+09:00"), "span": .string("futureEvents")
        ]))
        let moved = try XCTUnwrap(store.savedEvents.last)
        XCTAssertEqual(moved.id, "E1")
        XCTAssertNotNil(moved.occurrence)
        XCTAssertTrue(moved.futureEvents)
        XCTAssertEqual(moved.end.flatMap { end in moved.start.map { end.timeIntervalSince($0) } }, 15 * 60, "Moving only the start keeps the length")

        _ = try json(try await call(center, "apple_calendar_delete_event", ["eventId": .string(occurrenceID)]))
        XCTAssertEqual(store.deleted.last?.0, "E1")
        XCTAssertEqual(store.deleted.last?.2, false)

        let bad = try await call(center, "apple_calendar_create_event", ["summary": .string("x"), "startTime": .string("tomorrow"),
                                                                           "endTime": .string("2026-10-30T16:00:00")])
        XCTAssertTrue(bad.isError)
        XCTAssertEqual(store.savedEvents.count, 3, "Refused before the store")
    }

    func testRemindersAndContacts() async throws {
        let store = FakeMacData()
        let center = makeCenter(macData: store)
        for service in [LocalConnectorService.appleReminders, .appleContacts] {
            let record = center.addLocal(service)
            center.connect(record.id)
            await center.waitForConnection(record.id)
        }
        let lists = try json(try await call(center, "apple_reminders_list_reminder_lists"))
        XCTAssertEqual(lists["lists"]?.arrayValue?.first?["title"], .string("Reminders"))

        _ = try json(try await call(center, "apple_reminders_create_reminder", [
            "title": .string("Buy milk"), "dueDate": .string("2026-10-31"), "priority": .string("high")
        ]))
        let reminder = try XCTUnwrap(store.savedReminders.last)
        XCTAssertEqual(reminder.due?.year, 2026)
        XCTAssertEqual(reminder.due?.day, 31)
        XCTAssertNil(reminder.due?.hour, "A day without a time")
        XCTAssertEqual(reminder.priority, 1)

        let listed = try json(try await call(center, "apple_reminders_list_reminders", ["query": .string("milk")]))
        XCTAssertEqual(store.reminderQueries.last?.status, .incomplete)
        XCTAssertEqual(listed["reminders"]?.arrayValue?.first?["dueDate"], .string("2026-10-31"))
        XCTAssertEqual(listed["reminders"]?.arrayValue?.first?["priority"], .string("high"))

        _ = try json(try await call(center, "apple_reminders_complete_reminder", ["reminderId": .string("R1")]))
        XCTAssertEqual(store.savedReminders.last?.id, "R1")
        XCTAssertEqual(store.savedReminders.last?.completed, true)

        let found = try json(try await call(center, "apple_contacts_search_contacts", ["query": .string("Minsu")]))
        XCTAssertEqual(found["contacts"]?.arrayValue?.first?["name"], .string("Minsu Kim"))
        XCTAssertEqual(found["contacts"]?.arrayValue?.first?["emails"]?.arrayValue?.first?["value"], .string("minsu@example.test"))
        XCTAssertNil(found["contacts"]?.arrayValue?.first?["birthday"], "Search keeps it short")
        let contact = try json(try await call(center, "apple_contacts_get_contact", ["contactId": .string("C1")]))
        XCTAssertEqual(contact["birthday"], .string("--03-14"))
        let none = try await call(center, "apple_contacts_get_contact", ["contactId": .string("nobody")])
        XCTAssertTrue(none.isError)
    }

    // MARK: - Xcode

    /// Xcode's bridge is found by path, never by running `xcrun`: `DEVELOPER_DIR`, then the
    /// `xcode-select` link, then `/Applications`. A Mac without one is not offered Xcode, and a
    /// harness's own `xcrun mcpbridge` is suggested for Yardlet.
    func testXcodeIsOfferedOnlyWithItsBridge() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcode-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeXcode(_ name: String, version: String) throws -> URL {
            let app = root.appending(path: name, directoryHint: .isDirectory)
            let bridge = app.appending(path: "Contents/Developer/usr/bin/mcpbridge")
            try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bridge.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            try (["CFBundleShortVersionString": version] as NSDictionary).write(to: app.appending(path: "Contents/Info.plist"))
            return bridge
        }
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        XCTAssertNil(XcodeBridge.locate(environment: [:], selectLink: root.appending(path: "none").path, applications: applications))
        let installed = try makeXcode("Applications/Xcode.app", version: "27.1")
        let beta = try makeXcode("Xcode-beta.app", version: "27.2")
        XCTAssertEqual(XcodeBridge.locate(environment: [:], selectLink: root.appending(path: "none").path, applications: applications)?
            .resolvingSymlinksInPath(), installed.resolvingSymlinksInPath())
        let link = root.appending(path: "xcode_select_link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appending(path: "Xcode-beta.app/Contents/Developer").path)
        XCTAssertEqual(XcodeBridge.locate(environment: [:], selectLink: link.path, applications: applications)?.path, beta.path)
        XCTAssertEqual(XcodeBridge.locate(environment: ["DEVELOPER_DIR": root.appending(path: "Applications/Xcode.app").path],
                                          selectLink: link.path, applications: applications)?.path, installed.path)
        XCTAssertEqual(XcodeBridge.version(of: beta), "27.2")

        let without = makeCenter()
        let xcode = try XCTUnwrap(ConnectorPreset.preset(id: "xcode"))
        XCTAssertFalse(without.isAvailable(xcode))
        XCTAssertTrue(without.isAvailable(try XCTUnwrap(ConnectorPreset.preset(id: "apple-calendar"))))
        XCTAssertTrue(makeCenter(bridge: FakeStdioServer()).isAvailable(xcode))
        XCTAssertEqual(ConnectorSetupGuide.Kind.of(xcode), .oneClick)
        XCTAssertEqual(ConnectorSetupGuide.Kind.of(try XCTUnwrap(ConnectorPreset.preset(id: "app-store-connect"))), .key)

        XCTAssertEqual(NativeMCPConfigFiles.packageName(in: ["mcpbridge"]), "mcpbridge")
        let inventory = [NativeMCPInventoryEntry(home: NativeMCPHome(kind: .codex(home: root)),
                                                 servers: [NativeMCPServer(name: "xcode", command: "xcrun", package: "mcpbridge",
                                                                           scope: .codex)],
                                                 accountConnectors: [])]
        let suggestion = try XCTUnwrap(ConnectorImportSuggestion.suggestions(from: inventory, connected: []).first)
        XCTAssertEqual(suggestion.name, "Xcode")
        XCTAssertTrue(suggestion.connectsInOneClick)
    }

    /// Xcode's tools come from its bridge, which Yardlet starts on the first need and starts again
    /// after it stops; a call's answer passes through, and a bridge that stopped says why and what
    /// Xcode needs. Removing the connector ends the bridge.
    func testXcodeToolsComeThroughTheBridge() async throws {
        let bridge = FakeStdioServer()
        let center = makeCenter(bridge: bridge)
        let record = center.addLocal(.xcode)
        XCTAssertEqual(record.serverURL, FakeStdioServer.path)
        XCTAssertEqual(bridge.launches, 0, "Adding starts nothing")
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected, center.failures[record.id] ?? "")
        XCTAssertEqual(bridge.launches, 1)
        let names = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["xcode_XcodeListWindows", "xcode_BuildProject"])
        XCTAssertEqual(bridge.received.first?["method"], .string("initialize"))
        XCTAssertEqual(bridge.received.dropFirst().first?["method"], .string("notifications/initialized"))

        let built = try await call(center, "xcode_BuildProject", ["tabIdentifier": .string("windowtab1")])
        XCTAssertFalse(built.isError, built.text)
        XCTAssertEqual(built.text, "Build succeeded for windowtab1")

        bridge.exitAll(saying: "error: Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model Context Protocol, or run `sudo xcrun mcp-server enable`, then retry.\n")
        try await Task.sleep(for: .milliseconds(50))
        let stopped = try await call(center, "xcode_BuildProject", ["tabIdentifier": .string("windowtab1")])
        XCTAssertEqual(bridge.launches, 2, "Started again for the next call")
        XCTAssertFalse(stopped.isError, "The new bridge answers")

        bridge.exitOnStart = "error: No running Xcode found and could not launch one automatically.\n"
        bridge.exitAll(saying: "")
        try await Task.sleep(for: .milliseconds(50))
        let noXcode = try await call(center, "xcode_BuildProject")
        XCTAssertTrue(noXcode.isError)
        XCTAssertTrue(noXcode.text.contains("No running Xcode found") && noXcode.text.contains("Intelligence"), noXcode.text)

        bridge.exitOnStart = nil
        center.remove(record.id)
        try await waitUntil { bridge.channels.allSatisfy(\.terminated) }
        XCTAssertTrue(bridge.channels.allSatisfy(\.terminated), "Removing ends the bridge")
    }

    /// Requests meet their replies by ID whatever the order, a request from the server gets an
    /// answer, and a cancelled request is cancelled at the server.
    func testTheStdioClientMatchesRepliesAndCancels() async throws {
        let server = FakeStdioServer()
        let client = MCPStdioClient(launcher: server, clientVersion: "9.9")
        async let slow = client.callTool(name: "Slow", arguments: .object([:]))
        try await Task.sleep(for: .milliseconds(50))
        let fast = try await client.callTool(name: "BuildProject", arguments: .object(["tabIdentifier": .string("a")]))
        XCTAssertEqual(fast["content"]?.arrayValue?.first?["text"], .string("Build succeeded for a"))
        server.release()
        let slowResult = try await slow
        XCTAssertEqual(slowResult["content"]?.arrayValue?.first?["text"], .string("Done slowly"))
        server.channels.last?.ask(.object(["jsonrpc": .string("2.0"), "id": .string("srv-1"), "method": .string("ping")]))
        try await waitUntil {
            server.received.contains { $0["id"] == .string("srv-1") && $0["result"] == .object([:]) }
        }
        XCTAssertTrue(server.received.contains { $0["id"] == .string("srv-1") && $0["result"] == .object([:]) })

        let waiting = Task { try await client.callTool(name: "Slow", arguments: .object([:])) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await XCTAssertThrowsErrorAsync(try await waiting.value)
        try await waitUntil { server.received.contains { $0["method"] == .string("notifications/cancelled") } }
        XCTAssertTrue(server.received.contains { $0["method"] == .string("notifications/cancelled") })
        await client.close()
    }

    /// A real child process over pipes: a reply holding U+2028 stays one message, closing the server
    /// ends what it started too, and the reason a server writes to standard error before it exits is
    /// the error.
    func testTheStdioClientSpeaksToARealProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "stdio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "server.sh")
        try Data(#"""
        # The first server starts something in a process group of its own, as a server may start a
        # browser, and waits for it once its input ends.
        if [ ! -e "$0.child" ]; then
          set -m
          sleep 60 &
          set +m
          printf '%s' $! > "$0.child"
        fi
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          [ -z "$id" ] && continue
          case "$line" in
            *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fake"}}}\n' "$id" ;;
            *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"BuildProject","description":"Builds\342\200\250the project","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
            *) echo "error: Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model Context Protocol." >&2; exit 1 ;;
          esac
        done
        wait
        """#.utf8).write(to: script)
        let client = MCPStdioClient(launcher: ProcessMCPStdioLauncher(executable: URL(filePath: "/bin/sh"), arguments: [script.path]),
                                    clientVersion: "9.9")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.first?["description"], .string("Builds\u{2028}the project"))
        let child = try XCTUnwrap(pid_t(String(contentsOf: URL(filePath: script.path + ".child"), encoding: .utf8)))
        await client.close()
        try await waitUntil { kill(child, 0) != 0 }
        if kill(child, 0) == 0 { kill(child, SIGKILL) }
        // The next request starts the server again.
        do {
            _ = try await client.callTool(name: "BuildProject", arguments: .object([:]))
            XCTFail("The server exits")
        } catch let failure as MCPStdioError {
            XCTAssertEqual(failure, .exited("Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model Context Protocol."))
        }
        await client.close()
    }
}

/// Fails unless `expression` throws.
@MainActor
private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("No error was thrown", file: file, line: line)
    } catch {}
}

// MARK: - Fakes

/// App Store Connect for tests: every request's token must verify with the key's public half; a
/// request's answer is the test's, or an empty page.
final class FakeAppStoreConnect: ConnectorHTTPTransport, @unchecked Sendable {
    static let base = URL(string: "https://asc.fake.test/")!
    static let issuer = "57246542-96fe-1a63-e053-0824d011072a"

    let privateKey = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var answerTable: [String: (Int, ToolJSON)] = [:]
    private var refusing = false

    var requests: [URLRequest] { lock.withLock { recorded } }
    var answers: [String: (Int, ToolJSON)] {
        get { lock.withLock { answerTable } }
        set { lock.withLock { answerTable = newValue } }
    }
    var refusesKey: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let verified = (try? Self.decode(token, verifyingWith: privateKey.publicKey)) != nil
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let (status, body): (Int, ToolJSON) = if refusesKey || !verified {
            (401, .object(["errors": .array([.object(["status": .string("401"), "code": .string("NOT_AUTHORIZED"),
                                                      "title": .string("Authentication credentials are missing or invalid.")])])]))
        } else {
            answers[key] ?? (request.httpMethod == "DELETE" ? 204 : 200, request.httpMethod == "DELETE" ? .null : .object(["data": .array([])]))
        }
        let data = body == .null ? Data() : try JSONEncoder().encode(body)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }

    /// A token's header and payload, after its signature verified.
    static func decode(_ token: String, verifyingWith key: P256.Signing.PublicKey) throws -> (header: ToolJSON, payload: ToolJSON) {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3 else { throw URLError(.userAuthenticationRequired) }
        func bytes(_ text: String) throws -> Data {
            var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            guard let data = Data(base64Encoded: base64) else { throw URLError(.cannotDecodeContentData) }
            return data
        }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes(parts[2]))
        guard key.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)) else {
            throw URLError(.userAuthenticationRequired)
        }
        return (try JSONDecoder().decode(ToolJSON.self, from: bytes(parts[0])),
                try JSONDecoder().decode(ToolJSON.self, from: bytes(parts[1])))
    }
}

/// The Mac's data for tests, with macOS's answer per kind; `prompts` counts the prompts macOS would
/// have shown.
final class FakeMacData: MacDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    var permissions: [MacDataKind: MacDataAccess] = [.calendars: .granted, .reminders: .granted, .contacts: .granted]
    private(set) var prompts: [MacDataKind] = []
    private(set) var ranges: [(Date, Date)] = []
    private(set) var savedEvents: [MacEventChange] = []
    private(set) var deleted: [(String, Date?, Bool)] = []
    private(set) var savedReminders: [MacReminderChange] = []
    private(set) var reminderQueries: [MacReminderQuery] = []

    static let standupStart = ISO8601DateFormatter().date(from: "2026-10-26T01:00:00Z")!
    static let seoul = TimeZone(identifier: "Asia/Seoul")!

    let stored = [
        MacEvent(id: "E1", occurrence: standupStart, calendarID: "work", calendarTitle: "Work", title: "Daily standup",
                 start: standupStart, end: standupStart.addingTimeInterval(15 * 60), allDay: false, timeZone: seoul,
                 isRecurring: true),
        MacEvent(id: "E2", calendarID: "home", calendarTitle: "Family", title: "Holiday",
                 start: ISO8601DateFormatter().date(from: "2026-10-27T15:00:00Z")!,
                 end: ISO8601DateFormatter().date(from: "2026-10-29T14:59:59Z")!, allDay: true, isRecurring: false)
    ]

    func access(_ kind: MacDataKind) -> MacDataAccess { lock.withLock { permissions[kind] ?? .denied } }

    func requestAccess(_ kind: MacDataKind) async throws -> Bool {
        try lock.withLock {
            let now = permissions[kind] ?? .denied
            guard now == .notDetermined else {
                if now == .granted { return true }
                throw MacDataError.notAllowed(kind, now)
            }
            prompts.append(kind)
            permissions[kind] = .granted
            return true
        }
    }

    private func allowed(_ kind: MacDataKind) throws {
        let now = access(kind)
        guard now == .granted else { throw MacDataError.notAllowed(kind, now) }
    }

    func calendars(_ kind: MacDataKind) throws -> [MacCalendarInfo] {
        try allowed(kind)
        return kind == .reminders
            ? [MacCalendarInfo(id: "L1", title: "Reminders", account: "iCloud", allowsChanges: true, isDefault: true)]
            : [MacCalendarInfo(id: "work", title: "Work", account: "iCloud", color: "#1BADF8", allowsChanges: true, isDefault: true),
               MacCalendarInfo(id: "holidays", title: "South Korean Holidays", account: "Subscribed", allowsChanges: false, isDefault: false)]
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [MacEvent] {
        try allowed(.calendars)
        lock.withLock { ranges.append((start, end)) }
        return stored
    }

    func event(id: String, occurrence: Date?) throws -> MacEvent? {
        try allowed(.calendars)
        return stored.first { $0.id == id && (occurrence == nil || $0.occurrence == occurrence) }
    }

    func saveEvent(_ change: MacEventChange) throws -> MacEvent {
        try allowed(.calendars)
        lock.withLock { savedEvents.append(change) }
        var event = change.id.flatMap { id in stored.first { $0.id == id } }
            ?? MacEvent(id: "NEW", calendarID: change.calendarID ?? "work", calendarTitle: "Work", title: "", start: Date(),
                        end: Date(), allDay: false, isRecurring: false)
        if let title = change.title { event.title = title }
        if let start = change.start { event.start = start }
        if let end = change.end { event.end = end }
        if let allDay = change.allDay { event.allDay = allDay }
        return event
    }

    func deleteEvent(id: String, occurrence: Date?, futureEvents: Bool) throws {
        try allowed(.calendars)
        lock.withLock { deleted.append((id, occurrence, futureEvents)) }
    }

    func reminders(_ query: MacReminderQuery) async throws -> [MacReminder] {
        try allowed(.reminders)
        lock.withLock { reminderQueries.append(query) }
        var due = DateComponents(year: 2026, month: 10, day: 31)
        due.calendar = Calendar(identifier: .gregorian)
        return [MacReminder(id: "R1", listID: "L1", listTitle: "Reminders", title: "Buy milk", due: due, priority: 1, completed: false),
                MacReminder(id: "R2", listID: "L1", listTitle: "Reminders", title: "Dry cleaning", priority: 0, completed: false)]
    }

    func saveReminder(_ change: MacReminderChange) throws -> MacReminder {
        try allowed(.reminders)
        lock.withLock { savedReminders.append(change) }
        return MacReminder(id: change.id ?? "R9", listID: change.listID ?? "L1", listTitle: "Reminders", title: change.title ?? "Buy milk",
                           due: change.due, priority: change.priority ?? 0, completed: change.completed ?? false)
    }

    func contacts(matching text: String, limit: Int) throws -> [MacContact] {
        try allowed(.contacts)
        return [Self.minsu].filter { $0.givenName.contains(text) || $0.emails.contains { $0.value == text } }
    }

    func contact(id: String) throws -> MacContact? {
        try allowed(.contacts)
        return id == "C1" ? Self.minsu : nil
    }

    static let minsu = MacContact(id: "C1", givenName: "Minsu", familyName: "Kim", organization: "Acme",
                                  emails: [.init(label: "work", value: "minsu@example.test")],
                                  phones: [.init(label: "mobile", value: "010-0000-0000")],
                                  birthday: DateComponents(month: 3, day: 14))
}

/// Xcode's bridge for tests: answers `initialize`, lists two tools, builds at once, and holds a
/// `Slow` call until released. It can stop as `mcpbridge` does, with its reason on standard error,
/// or stop as soon as it starts.
final class FakeStdioServer: MCPStdioLaunching, @unchecked Sendable {
    static let path = URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge")

    private let lock = NSLock()
    private var started: [FakeStdioChannel] = []
    private var stopping: String?

    var launches: Int { lock.withLock { started.count } }
    var channels: [FakeStdioChannel] { lock.withLock { started } }
    var received: [ToolJSON] { channels.flatMap(\.received) }
    var exitOnStart: String? {
        get { lock.withLock { stopping } }
        set { lock.withLock { stopping = newValue } }
    }

    func launch() throws -> any MCPStdioChannel {
        let channel = FakeStdioChannel()
        lock.withLock { started.append(channel) }
        if let reason = exitOnStart { channel.exit(saying: reason) }
        return channel
    }

    func exitAll(saying reason: String) {
        for channel in channels { channel.exit(saying: reason) }
    }

    func release() {
        for channel in channels { channel.release() }
    }
}

final class FakeStdioChannel: MCPStdioChannel, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var messages: [ToolJSON] = []
    private var held: [ToolJSON] = []
    private var errors = ""
    private var ended = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        lines = stream
        self.continuation = continuation
    }

    var received: [ToolJSON] { lock.withLock { messages } }
    var terminated: Bool { lock.withLock { ended } }

    func send(_ message: Data) throws {
        let value = try JSONDecoder().decode(ToolJSON.self, from: message)
        let closed = lock.withLock {
            messages.append(value)
            return ended
        }
        guard !closed else { throw URLError(.networkConnectionLost) }
        guard let id = value["id"], let method = value["method"]?.stringValue else { return }
        switch method {
        case "initialize":
            reply(id, .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])]),
                               "serverInfo": .object(["name": .string("xcode-tools"), "version": .string("27.1")])]))
        case "tools/list":
            reply(id, .object(["tools": .array([
                .object(["name": .string("XcodeListWindows"), "description": .string("Lists open Xcode windows."),
                         "inputSchema": .object(["type": .string("object")]),
                         "annotations": .object(["readOnlyHint": .bool(true)])]),
                .object(["name": .string("BuildProject"), "description": .string("Builds the project."),
                         "inputSchema": .object(["type": .string("object")])])
            ])]))
        case "tools/call" where value["params"]?["name"] == .string("Slow"):
            lock.withLock { held.append(id) }
        case "tools/call":
            let tab = value["params"]?["arguments"]?["tabIdentifier"]?.stringValue ?? "the workspace"
            reply(id, .object(["content": .array([.object(["type": .string("text"), "text": .string("Build succeeded for \(tab)")])])]))
        default:
            reply(id, .object([:]))
        }
    }

    func release() {
        let waiting = lock.withLock {
            defer { held.removeAll() }
            return held
        }
        for id in waiting {
            reply(id, .object(["content": .array([.object(["type": .string("text"), "text": .string("Done slowly")])])]))
        }
    }

    /// A request from the server to the client.
    func ask(_ message: ToolJSON) {
        continuation.yield(String(decoding: (try? JSONEncoder().encode(message)) ?? Data(), as: UTF8.self))
    }

    func exit(saying reason: String) {
        lock.withLock {
            errors = reason
            ended = true
        }
        continuation.finish()
    }

    func errorTail() -> String { lock.withLock { errors } }

    func terminate() {
        lock.withLock { ended = true }
        continuation.finish()
    }

    private func reply(_ id: ToolJSON, _ result: ToolJSON) {
        continuation.yield(String(decoding: (try? JSONEncoder().encode(ToolJSON.object(["jsonrpc": .string("2.0"), "id": id,
                                                                                      "result": result]))) ?? Data(), as: UTF8.self))
    }
}
