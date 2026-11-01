import CSQLite
import Foundation
import XCTest
@testable import NativeHarnessClient

final class ProviderSessionTitleResolverTests: XCTestCase {
    func testReadsGrokGeneratedTitleFromUniqueWorkspace() throws {
        let fixture = try Fixture()
        let providerID = "grok-session"
        let sessionDirectory = fixture.grokRoot
            .appending(path: "workspace", directoryHint: .isDirectory)
            .appending(path: providerID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data(#"{"generated_title":"Inspect Streaming Output"}"#.utf8)
            .write(to: sessionDirectory.appending(path: "summary.json"))

        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .grokBuild, providerID: providerID),
                paths: fixture.paths
            ),
            "Inspect Streaming Output"
        )
    }

    func testGrokResolutionFailsClosedWhenProviderIDIsAmbiguous() throws {
        let fixture = try Fixture()
        let providerID = "duplicate-session"
        for workspace in ["one", "two"] {
            let directory = fixture.grokRoot
                .appending(path: workspace, directoryHint: .isDirectory)
                .appending(path: providerID, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"generated_title":"Must Not Pick Arbitrarily"}"#.utf8)
                .write(to: directory.appending(path: "summary.json"))
        }

        XCTAssertNil(ProviderSessionTitleResolver.title(
            for: fixture.session(harness: .grokBuild, providerID: providerID),
            paths: fixture.paths
        ))
    }

    func testReadsLatestClaudeCustomTitleForExactSession() throws {
        let fixture = try Fixture()
        let providerID = "claude-session"
        let projectDirectory = fixture.claudeRoot.appending(
            path: "workspace",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let jsonl = """
            {"type":"custom-title","sessionId":"other","customTitle":"Wrong"}
            {"type":"custom-title","sessionId":"claude-session","customTitle":"First title"}
            {"type":"custom-title","sessionId":"claude-session","customTitle":"Latest title"}
            """
        try Data(jsonl.utf8).write(to: projectDirectory.appending(path: "\(providerID).jsonl"))

        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .claudeCode, providerID: providerID),
                paths: fixture.paths
            ),
            "Latest title"
        )
    }

    func testClaudeGeneratedTitleStandsInUntilThePersonNamesTheSession() throws {
        let fixture = try Fixture()
        let projectDirectory = fixture.claudeRoot.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        func resolve(_ lines: [String]) throws -> String? {
            try Data(lines.joined(separator: "\n").utf8)
                .write(to: projectDirectory.appending(path: "claude-session.jsonl"))
            return ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .claudeCode, providerID: "claude-session"),
                paths: fixture.paths
            )
        }
        let generated = #"{"type":"ai-title","aiTitle":"Fix the failing test_calc.py test","sessionId":"claude-session"}"#
        let prompt = #"{"type":"user","message":{"role":"user","content":"Run test_calc.py and fix it"},"sessionId":"claude-session"}"#

        // Claude re-appends the generated title as it writes; the latest record is the title.
        XCTAssertEqual(try resolve([
            #"{"type":"ai-title","aiTitle":"Older generated title","sessionId":"claude-session"}"#,
            prompt,
            #"{"type":"ai-title","aiTitle":"Other session","sessionId":"other"}"#,
            generated
        ]), "Fix the failing test_calc.py test")
        // A name the person set comes first, even before a later generated title.
        XCTAssertEqual(try resolve([
            prompt,
            #"{"type":"custom-title","customTitle":"Calculator fix","sessionId":"claude-session"}"#,
            generated
        ]), "Calculator fix")
        // A cleared name leaves the generated title, not an older name.
        XCTAssertEqual(try resolve([
            #"{"type":"custom-title","customTitle":"Old name","sessionId":"claude-session"}"#,
            generated,
            #"{"type":"custom-title","customTitle":"","sessionId":"claude-session"}"#
        ]), "Fix the failing test_calc.py test")
        XCTAssertNil(try resolve([prompt]))

        // An account folder whose `projects` links to the shared one, as Session Switch makes it,
        // reads the same transcript.
        _ = try resolve([prompt, generated])
        let account = fixture.root.appending(path: "account", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: account.appending(path: "projects"), withDestinationURL: fixture.claudeRoot)
        var linked = fixture.session(harness: .claudeCode, providerID: "claude-session")
        linked.connection = ProviderConnection(id: "account", name: "Account", harness: .claudeCode, providerID: nil,
                                               homePath: account.path(percentEncoded: false), credentialSelector: nil)
        XCTAssertEqual(ProviderSessionTitleResolver.title(for: linked, paths: fixture.paths), "Fix the failing test_calc.py test")
    }

    func testReadsOpenCodeTitleFromDatabaseByExactID() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.openCodeDatabase.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.openCodeDatabase.path(), &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT NOT NULL);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO session (id, title) VALUES (?, ?);", -1, &statement, nil),
            SQLITE_OK
        )
        let providerID = "opencode-session"
        sqlite3_bind_text(statement, 1, providerID, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 2, "Repair Session Rendering", -1, testSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)

        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .openCode, providerID: providerID),
                paths: fixture.paths
            ),
            "Repair Session Rendering"
        )
    }

    /// Kimi Code 0.36.0 writes `state.json` in `sessions/<workspace id>/<session id>/`, where the
    /// workspace id is `wd_<slug>_<hash>` and the ACP session id is `session_<uuid>`.
    func testReadsKimiTitleTheWayKimisOwnSessionListDoes() throws {
        let fixture = try Fixture()
        let promptTitled = "session_4f1c2d3e-0000-4000-8000-000000000001"
        try fixture.writeKimiState(
            #"{"createdAt":"2026-09-26T00:00:00.000Z","updatedAt":"2026-09-26T00:01:00.000Z","title":"Fix the flaky login test","isCustomTitle":false,"agents":{},"custom":{}}"#,
            sessionID: promptTitled
        )
        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .kimiCode, providerID: promptTitled),
                paths: fixture.paths
            ),
            "Fix the flaky login test"
        )

        let renamed = "session_4f1c2d3e-0000-4000-8000-000000000002"
        try fixture.writeKimiState(
            #"{"title":"Login test triage","isCustomTitle":true,"agents":{},"custom":{}}"#,
            sessionID: renamed
        )
        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .kimiCode, providerID: renamed),
                paths: fixture.paths
            ),
            "Login test triage"
        )

        // A session migrated from the legacy CLI may carry only `customTitle`.
        let legacy = "session_4f1c2d3e-0000-4000-8000-000000000003"
        try fixture.writeKimiState(
            #"{"customTitle":"Imported title","title":"ignored"}"#,
            sessionID: legacy
        )
        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .kimiCode, providerID: legacy),
                paths: fixture.paths
            ),
            "Imported title"
        )

        // The newer engine may keep the same file under `session-meta/`.
        let metaScoped = "session_4f1c2d3e-0000-4000-8000-000000000004"
        try fixture.writeKimiState(
            #"{"title":"Meta scoped title","isCustomTitle":false}"#,
            sessionID: metaScoped,
            relativePath: "session-meta/state.json"
        )
        XCTAssertEqual(
            ProviderSessionTitleResolver.title(
                for: fixture.session(harness: .kimiCode, providerID: metaScoped),
                paths: fixture.paths
            ),
            "Meta scoped title"
        )
    }

    func testKimiPlaceholderAndAmbiguousSessionsResolveToNoTitle() throws {
        let fixture = try Fixture()
        // Kimi's untitled placeholder before the first prompt is not a title.
        let untitled = "session_4f1c2d3e-0000-4000-8000-000000000010"
        try fixture.writeKimiState(
            #"{"title":"New Session","isCustomTitle":false}"#,
            sessionID: untitled
        )
        XCTAssertNil(ProviderSessionTitleResolver.title(
            for: fixture.session(harness: .kimiCode, providerID: untitled),
            paths: fixture.paths
        ))

        let duplicate = "session_4f1c2d3e-0000-4000-8000-000000000011"
        for workspace in ["wd_one_111111111111", "wd_two_222222222222"] {
            try fixture.writeKimiState(
                #"{"title":"Must Not Pick Arbitrarily","isCustomTitle":true}"#,
                sessionID: duplicate,
                workspace: workspace
            )
        }
        XCTAssertNil(ProviderSessionTitleResolver.title(
            for: fixture.session(harness: .kimiCode, providerID: duplicate),
            paths: fixture.paths
        ))
    }

    func testKimiAndGrokSessionsFollowTheirHomeAndATasksAccountFolder() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        XCTAssertEqual(
            ProviderSessionTitlePaths.live(homeURL: home, environment: ["GROK_HOME": "/Volumes/work/grok"])
                .grokSessionsRoot.path(percentEncoded: false),
            "/Volumes/work/grok/sessions/"
        )
        // A saved account's sessions are in its own folder, where its harness ran.
        let paths = ProviderSessionTitlePaths.live(homeURL: home, environment: [:])
        for (harness, expected) in [(HarnessKind.kimiCode, "/accounts/b/sessions/"), (.grokBuild, "/accounts/b/sessions/"),
                                    (.claudeCode, "/accounts/b/projects/"), (.openCode, "/accounts/b/data/opencode/opencode.db")] {
            let scoped = paths.forAccount(ProviderConnection(id: "b", name: "B", harness: harness, providerID: nil,
                homePath: "/accounts/b", credentialSelector: nil))
            let read = switch harness {
            case .kimiCode: scoped.kimiSessionsRoot
            case .grokBuild: scoped.grokSessionsRoot
            case .claudeCode: scoped.claudeProjectsRoot
            default: scoped.openCodeDatabaseURL
            }
            XCTAssertEqual(read.path(percentEncoded: false), expected, harness.rawValue)
        }
        XCTAssertEqual(paths.forAccount(nil).grokSessionsRoot, paths.grokSessionsRoot)
        XCTAssertEqual(
            ProviderSessionTitlePaths.live(homeURL: home, environment: [:])
                .kimiSessionsRoot.path(percentEncoded: false),
            "/Users/example/.kimi-code/sessions/"
        )
        XCTAssertEqual(
            ProviderSessionTitlePaths.live(
                homeURL: home,
                environment: ["KIMI_CODE_HOME": "/Volumes/work/kimi"]
            ).kimiSessionsRoot.path(percentEncoded: false),
            "/Volumes/work/kimi/sessions/"
        )
        // A relative or empty value names no directory this process could read.
        XCTAssertEqual(
            ProviderSessionTitlePaths.live(homeURL: home, environment: ["KIMI_CODE_HOME": ""])
                .kimiSessionsRoot.path(percentEncoded: false),
            "/Users/example/.kimi-code/sessions/"
        )
    }

    func testRejectsUnsafeProviderPathComponent() throws {
        let fixture = try Fixture()
        XCTAssertNil(ProviderSessionTitleResolver.title(
            for: fixture.session(harness: .grokBuild, providerID: "../outside"),
            paths: fixture.paths
        ))
    }

    func testCodexTitlesArePushedAndEveryOtherHarnessIsRead() throws {
        XCTAssertEqual(ProviderTitleSource(harness: .codex), .push)
        for harness in HarnessCatalog.builtIns.map(\.id) where harness != .codex {
            XCTAssertEqual(ProviderTitleSource(harness: harness), .pull, harness.rawValue)
        }
        let fixture = try Fixture()
        XCTAssertNil(ProviderSessionTitleResolver.title(
            for: fixture.session(harness: .codex, providerID: "codex-thread"),
            paths: fixture.paths
        ), "A pushed title has no stored copy to read")
    }
}

private struct Fixture {
    let root: URL
    let grokRoot: URL
    let claudeRoot: URL
    let openCodeDatabase: URL
    let kimiRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-title-resolver-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        grokRoot = root.appending(path: "grok", directoryHint: .isDirectory)
        claudeRoot = root.appending(path: "claude", directoryHint: .isDirectory)
        openCodeDatabase = root.appending(path: "opencode/opencode.db")
        kimiRoot = root.appending(path: "kimi-code/sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: grokRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kimiRoot, withIntermediateDirectories: true)
    }

    var paths: ProviderSessionTitlePaths {
        ProviderSessionTitlePaths(
            grokSessionsRoot: grokRoot,
            claudeProjectsRoot: claudeRoot,
            openCodeDatabaseURL: openCodeDatabase,
            kimiSessionsRoot: kimiRoot
        )
    }

    func writeKimiState(
        _ json: String,
        sessionID: String,
        workspace: String = "wd_workspace_0123456789ab",
        relativePath: String = "state.json"
    ) throws {
        let file = kimiRoot
            .appending(path: workspace, directoryHint: .isDirectory)
            .appending(path: sessionID, directoryHint: .isDirectory)
            .appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: file)
    }

    func session(harness: HarnessKind, providerID: String) -> SessionRecord {
        SessionRecord(
            harness: harness,
            workspaceURL: URL(filePath: "/tmp/workspace"),
            runtimeExecutableURL: URL(filePath: "/tmp/runtime"),
            title: "Prompt title",
            providerSessionID: providerID
        )
    }
}

private let testSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
