import Foundation
import XCTest
@testable import NativeHarnessClient

/// Which folder holds each task's browser profile, and which folders go: removing the wrong one signs a
/// person out of a running task without a sign, and a folder Chromium cannot open as a profile keeps its
/// sign-ins only in memory (docs/BROWSER_SESSION_ISOLATION.md).
@MainActor
final class BrowserTaskProfilesTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!

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

    func testATaskStartsFromItsParentTakesTheDraftsProfileAndKeepsOnlyKeptFolders() throws {
        let profiles = BrowserTaskProfiles(root: folder, defaults: defaults)
        let parent = UUID(), child = UUID(), started = UUID(), archived = UUID()
        profiles.parentOf = { $0 == child ? parent : nil }
        // Chromium opens a profile on disk only in a direct child of its root cache.
        XCTAssertEqual(profiles.folder(for: parent.uuidString).deletingLastPathComponent().standardizedFileURL,
                       folder.standardizedFileURL)

        // A new task with no parent profile starts from the default profile.
        XCTAssertEqual(profiles.profile(for: parent), BrowserTabProfile(key: parent.uuidString, seedFrom: nil))
        try makeFolder(profiles.folder(for: parent.uuidString))
        XCTAssertEqual(profiles.profile(for: child)?.seedFrom, parent.uuidString, "a child task starts signed in as its parent")
        try makeFolder(profiles.folder(for: child.uuidString))
        XCTAssertNil(profiles.profile(for: child)?.seedFrom, "an existing profile is not seeded again")

        // The new-task screen's tabs go to the task it starts, with their profile; the screen gets a new one.
        let draftKey = profiles.key(for: TaskWorkspaceStore.draftID)
        try makeFolder(profiles.folder(for: draftKey))
        profiles.tabsMoved(from: TaskWorkspaceStore.draftID, to: started)
        XCTAssertEqual(profiles.key(for: started), draftKey)
        XCTAssertNotEqual(profiles.key(for: TaskWorkspaceStore.draftID), draftKey)
        XCTAssertEqual(BrowserTaskProfiles(root: folder, defaults: defaults).key(for: started), draftKey,
                       "the alias outlives the app")

        // The root cache also holds the default profile and Chromium's own folders; they stay.
        try makeFolder(profiles.folder(for: archived.uuidString))
        let chromium = ["Default", archived.uuidString, "Profile 1", "Safe Browsing"].map { folder.appending(path: $0) }
        for url in chromium { try makeFolder(url) }
        // Chromium lists the profiles it opened in Local State and keeps a removed one there.
        let gone = "Task-" + archived.uuidString, stays = "Task-" + parent.uuidString
        let entry: [String: Any] = ["name": "Person"], groups: [Any] = []
        let localState: [String: Any] = [
            "profile": ["info_cache": ["Default": entry, gone: entry, stays: entry], "profiles_order": ["Default", gone, stays]],
            "variations_google_groups": [gone: groups, stays: groups], "browser": ["enabled_labs_experiments": groups]
        ]
        try JSONSerialization.data(withJSONObject: localState).write(to: folder.appending(path: "Local State"))
        let removed = profiles.removeFolders(keeping: [parent, child, started])
        XCTAssertEqual(removed, [archived.uuidString])
        for kept in [parent.uuidString, child.uuidString, draftKey] {
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

        profiles.storage = .shared
        XCTAssertNil(profiles.profile(for: parent), "shared storage opens every tab in the default profile")
    }

    /// Which of the person's sign-ins a task's tab takes when it opens (docs/BROWSER_SESSION_ISOLATION.md 11): one it
    /// has not yet, unless the site is the task's own; a task from before following keeps what it has and only fills
    /// the sites it has none of. Taking a sign-in twice, or one over a task's own account, signs the task out or in
    /// as someone else without a sign.
    func testATaskTakesThePersonsSignInsItHasNotYetExceptOnItsOwnSites() throws {
        let profiles = BrowserTaskProfiles(root: folder, defaults: defaults)
        // Following is per-task storage's: said here rather than left to the default, which another domain in the
        // preferences search list could answer.
        profiles.storage = .perTask
        let person = UUID(), running = UUID(), agent = UUID(), closed = UUID(), earlier = UUID(), later = UUID(), child = UUID()
        profiles.parentOf = { $0 == child ? agent : nil }
        let key = { (task: UUID) in profiles.key(for: task) }
        // A task from before following: its folder is there and it never opened since.
        try makeFolder(profiles.folder(for: key(earlier)))
        for task in [person, running, agent, closed] {
            XCTAssertNil(profiles.opening(for: task)?.follow, "a new task starts with the default profile, which holds every sign-in")
            try makeFolder(profiles.folder(for: key(task)))
        }
        profiles.signedInItself(to: "example.com", in: key(agent))

        // The person signs in on one task's page: the default profile and the open tasks that follow the site take it.
        let targets = profiles.personSignedIn(to: "example.com", in: key(person),
                                              open: [key(person), key(running), key(agent)])
        XCTAssertEqual(targets, [nil, key(running)], "not the task the sign-in came from, nor one with its own")
        XCTAssertNil(profiles.opening(for: running)?.follow, "a running task took it already")
        XCTAssertEqual(profiles.opening(for: closed)?.follow, ["example.com"], "a closed task takes it when its tab opens")
        XCTAssertNil(profiles.opening(for: closed)?.follow, "once")
        XCTAssertNil(profiles.opening(for: agent)?.follow, "the task's own sign-in stays")
        XCTAssertEqual(profiles.personSignedIn(to: "example.com", in: key(agent), open: []), [],
                       "a sign-in on a task's own site stays the task's")

        let first = profiles.opening(for: earlier)
        XCTAssertEqual(first?.fill, true, "a task from before following fills the sites it has none of")
        XCTAssertEqual(first?.follow, ["example.com"], "and takes the sign-ins made since")
        XCTAssertNil(profiles.opening(for: earlier)?.fill, "once")
        XCTAssertNil(profiles.opening(for: later)?.follow, "a task made after a sign-in starts with it")
        let fromParent = profiles.opening(for: child)
        XCTAssertEqual(fromParent?.seedFrom, key(agent))
        XCTAssertNil(fromParent?.follow, "a child task keeps its parent's own sign-in")

        let reread = BrowserTaskProfiles(root: folder, defaults: defaults)
        XCTAssertEqual(reread.following, profiles.following, "following outlives the app")
        reread.adoptEarlierAgentFills { [(closed, "example.org")] }
        reread.adoptEarlierAgentFills { [(closed, "example.net")] }
        XCTAssertTrue(reread.isOwn("example.org", in: key(closed)), "an agent's earlier fill is its task's own sign-in")
        XCTAssertFalse(reread.isOwn("example.net", in: key(closed)), "the earlier fills are read once")
    }
}
