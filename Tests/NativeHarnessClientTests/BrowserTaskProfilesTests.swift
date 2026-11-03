import CSQLite
import Foundation
import XCTest
@testable import NativeHarnessClient

/// Which profile each task's tabs use and which folders go (docs/BROWSER_SESSION_ISOLATION.md): a task that moves to
/// another profile without a sign signs the person out or in as someone else, removing the wrong folder loses a
/// task's own sign-in, and copying one profile's cookies over another's loses the accounts it lacked.
@MainActor
final class BrowserTaskProfilesTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_792_900_000)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "BrowserTaskProfilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: testDefaultsSuite("BrowserTaskProfiles"))!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testTasksShareTheDefaultProfileUntilTheySignInThemselvesAndKeepOnlyTheirOwnFolders() async throws {
        let profiles = BrowserTaskProfiles(root: folder, defaults: defaults)
        // Said here rather than left to the default, which another domain in the preferences search list could answer.
        profiles.storage = .perTask
        XCTAssertNotNil(profiles.shareEarlierProfiles(setAside: folder.appending(path: "Trash/Aside")) { _ in
            XCTFail("no earlier profile to empty")
            return []
        })
        let signer = UUID(), child = UUID(), sharedChild = UUID(), plain = UUID(), stale = UUID(), archived = UUID()
        profiles.parentOf = { [child: signer, sharedChild: plain][$0] }

        XCTAssertNil(profiles.opening(for: signer), "a task uses the default profile")
        XCTAssertNil(profiles.opening(for: sharedChild), "a child of a task in the default profile stays there")
        XCTAssertFalse(profiles.takeOwnProfile(for: TaskWorkspaceStore.draftID), "the new-task screen has no agent")

        // Before its agent signs in itself, a task takes a profile of its own, once, which starts from the default one.
        XCTAssertTrue(profiles.takeOwnProfile(for: signer))
        XCTAssertFalse(profiles.takeOwnProfile(for: signer))
        XCTAssertEqual(profiles.profile(for: signer), BrowserTabProfile(key: signer.uuidString, seedFrom: nil))
        // Chromium opens a profile on disk only in a direct child of its root cache.
        XCTAssertEqual(profiles.folder(for: signer.uuidString).deletingLastPathComponent().standardizedFileURL,
                       folder.standardizedFileURL)
        try makeFolder(profiles.folder(for: signer.uuidString))
        XCTAssertEqual(profiles.opening(for: child), BrowserTabProfile(key: child.uuidString, seedFrom: signer.uuidString),
                       "a child of a task with a profile of its own starts with a copy of it")
        try makeFolder(profiles.folder(for: child.uuidString))
        XCTAssertNil(profiles.profile(for: child)?.seedFrom, "an existing profile is not seeded again")
        XCTAssertTrue(profiles.takeOwnProfile(for: plain))
        XCTAssertNil(profiles.opening(for: sharedChild), "a child whose first tab opened in the default profile stays there")

        // A folder left from before is no copy of the default profile: the task's profile of its own gets another key.
        try makeFolder(profiles.folder(for: stale.uuidString))
        XCTAssertTrue(profiles.takeOwnProfile(for: stale))
        let staleKey = profiles.key(for: stale)
        XCTAssertNotEqual(staleKey, stale.uuidString)
        XCTAssertEqual(profiles.profile(for: stale), BrowserTabProfile(key: staleKey, seedFrom: nil))

        let reread = BrowserTaskProfiles(root: folder, defaults: defaults)
        reread.parentOf = profiles.parentOf
        for task in [signer, child, plain, stale] {
            XCTAssertEqual(reread.profile(for: task), profiles.profile(for: task), "a task's profile outlives the app")
        }
        XCTAssertNil(reread.opening(for: sharedChild))

        // The root cache also holds the default profile and Chromium's own folders; they stay.
        XCTAssertTrue(profiles.takeOwnProfile(for: archived))
        try makeFolder(profiles.folder(for: archived.uuidString))
        let chromium = ["Default", archived.uuidString, "Profile 1", "Safe Browsing"].map { folder.appending(path: $0) }
        for url in chromium { try makeFolder(url) }
        // Chromium lists the profiles it opened in Local State and keeps a removed one there.
        let gone = "Task-" + archived.uuidString, stays = "Task-" + signer.uuidString
        let entry: [String: Any] = ["name": "Person"], groups: [Any] = []
        let localState: [String: Any] = [
            "profile": ["info_cache": ["Default": entry, gone: entry, stays: entry], "profiles_order": ["Default", gone, stays]],
            "variations_google_groups": [gone: groups, stays: groups], "browser": ["enabled_labs_experiments": groups]
        ]
        try JSONSerialization.data(withJSONObject: localState).write(to: folder.appending(path: "Local State"))
        try Data("cache".utf8).write(to: profiles.folder(for: archived.uuidString).appending(path: "Cache"))
        let removed = profiles.removeFolders(keeping: [signer, child, sharedChild, stale])
        XCTAssertEqual(Set(removed), [archived.uuidString, stale.uuidString],
                       "an archived task's profile goes, and so does a folder no task's profile of its own uses")
        XCTAssertFalse(profiles.folderExists(archived.uuidString), "the profile is gone at once")
        let removing = folder.appending(path: BrowserTaskProfiles.removingFolderName).path(percentEncoded: false)
        try await waitUntil { !FileManager.default.fileExists(atPath: removing) }
        for kept in [signer.uuidString, child.uuidString] {
            XCTAssertTrue(profiles.folderExists(kept), kept)
        }
        for url in chromium {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), url.lastPathComponent)
        }
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "Local State"))) as? [String: Any])
        let profileState = after["profile"] as? [String: Any]
        XCTAssertEqual((profileState?["info_cache"] as? [String: Any]).map { Set($0.keys) }, ["Default", stays])
        XCTAssertEqual(profileState?["profiles_order"] as? [String], ["Default", stays])
        XCTAssertEqual((after["variations_google_groups"] as? [String: Any]).map { Set($0.keys) }, [stays])
        XCTAssertNotNil(after["browser"], "the rest of Local State stays")
        XCTAssertNil(profiles.profile(for: archived), "an archived task's profile of its own goes with its folder")

        profiles.storage = .shared
        XCTAssertNil(profiles.profile(for: signer), "shared storage opens every tab in the default profile")
        XCTAssertFalse(profiles.takeOwnProfile(for: UUID()))
    }

    /// The task profiles from before tasks shared the default profile, sorted once: one that had signed in to a site
    /// itself stays; one of copies moves its task to the default profile, which first takes the sites it holds and the
    /// default profile has no cookie of, never over the default profile's own, and its folder goes to the Trash, where the
    /// person can take it back; one that cannot be taken stays.
    func testEarlierProfilesKeepTheirOwnSignInsAndTheRestFillTheDefaultProfileWithoutOverwritingIt() throws {
        let own = UUID().uuidString, copies = UUID().uuidString, older = UUID().uuidString, other = UUID().uuidString
        try makeDatabase("Default", [("accounts.example.com", "sid", "person", "", 1, 10)])
        try makeDatabase("Task-" + copies, [
            ("accounts.example.com", "sid", "copy", "", 1, 20),        // the default profile has the site: it stays the person's
            ("only.example.org", "token", "copies", "", 1, 30),         // a site only this task signed in to
            (".only.example.org", "pref", "copies", "", 1, 30),
            ("embed.example.org", "chips", "copies", "https://a.test", 1, 30),  // partitioned: stays behind
            ("gone.example.net", "old", "copies", "", -1, 30)           // expired
        ])
        try makeDatabase("Task-" + older, [("only.example.org", "token", "older", "", 1, 5), ("z.example.net", "z", "older", "", 1, 5)])
        try makeDatabase("Task-" + own, [("x.example.com", "x", "own", "", 1, 5)])
        // Another table: its rows cannot go over column for column, so its task keeps its profile.
        try makeDatabase("Task-" + other, [("w.example.info", "w", "other", "", 1, 5)], schema: 23)
        let earlier: [String: Any] = ["aliases": [String: String](), "draftKey": UUID().uuidString, "following": [
            "own": [own: ["example.com"], copies: []], "signIns": ["example.com": 3], "received": [copies: ["example.com": 3]],
            "followers": [own, copies], "readAgentFills": true
        ]]
        try JSONSerialization.data(withJSONObject: earlier).write(to: folder.appending(path: "TaskProfiles.json"))
        let profiles = BrowserTaskProfiles(root: folder, defaults: defaults)
        profiles.storage = .perTask
        XCTAssertNotNil(profiles.profile(for: UUID(uuidString: copies)!), "until they are sorted, tasks keep the folders they have")

        let trash = folder.appending(path: "Trash"), aside = trash.appending(path: "Yardlet task profiles test")
        var taken: [String: String] = [:]
        let sorted = profiles.shareEarlierProfiles(setAside: aside) { keys in
            XCTAssertEqual(Set(keys), [copies, older, other])
            let outcome = BrowserProfileMerge.fill(root: folder, from: keys, trash: trash, now: now)
            taken = outcome?.sites ?? [:]
            return outcome?.unread
        }
        XCTAssertEqual(sorted?.kept, 2)
        XCTAssertEqual(sorted?.moved, 2)
        XCTAssertEqual(taken, ["example.org": copies, "example.net": older], "the profile that used a site last gives it")
        XCTAssertEqual(rows("Default"), [
            ".only.example.org pref copies", "accounts.example.com sid person", "only.example.org token copies", "z.example.net z older"
        ])
        for (key, stays) in [(own, true), (other, true), (copies, false), (older, false)] {
            XCTAssertEqual(profiles.profile(for: UUID(uuidString: key)!) != nil, stays, key)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: trash.path(percentEncoded: false)).filter { $0 != aside.lastPathComponent }
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appending(path: "\(backups[0])/Default/Cookies").path(percentEncoded: false)))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: aside.path(percentEncoded: false))),
                       ["Task-" + copies, "Task-" + older], "the moved tasks' folders are in the Trash, whole")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.appending(path: "Task-\(copies)/Cookies").path(percentEncoded: false)))
        for (key, stays) in [(own, true), (other, true), (copies, false), (older, false)] {
            XCTAssertEqual(profiles.folderExists(key), stays, key)
        }
        XCTAssertNil(BrowserTaskProfiles(root: folder, defaults: defaults).shareEarlierProfiles(setAside: aside) { _ in
            XCTFail("sorted once")
            return []
        })
    }

    /// A `Cookies` database with Chromium 154's table and version (23 leaves out `has_cross_site_ancestor`): host, name,
    /// value, partition, hours until it expires (negative: expired) and when it was used last, in hours.
    private func makeDatabase(_ profile: String, _ rows: [(String, String, String, String, Int64, Int64)], schema: Int = 24) throws {
        let directory = folder.appending(path: profile)
        try makeFolder(directory)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appending(path: "Cookies").path(percentEncoded: false), &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let ancestor = schema >= 24 ? ", has_cross_site_ancestor INTEGER NOT NULL" : ""
        var sql = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '\(schema)');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
              last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
              source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL\(ancestor));
            """
        let present = Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000), hour: Int64 = 3_600_000_000
        for (index, row) in rows.enumerated() {
            sql += "INSERT INTO cookies VALUES(\(index), '\(row.0)', '\(row.3)', '\(row.1)', '\(row.2)', X'00', '/', "
                + "\(present + row.4 * hour), 1, 1, \(present - 100 * hour + row.5 * hour), 1, 1, 1, -1, 2, 443, 0, 1"
                + (schema >= 24 ? ", 0);" : ");")
        }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    private func rows(_ profile: String) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(folder.appending(path: "\(profile)/Cookies").path(percentEncoded: false), &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT host_key, name, value FROM cookies ORDER BY host_key, name", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<3).map { String(cString: sqlite3_column_text(statement, $0)) }.joined(separator: " "))
        }
        return rows
    }
}
