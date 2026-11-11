import Foundation

enum YardletProduct {
    static let name = "Yardlet"
    static let bundleIdentifier = "com.zzunkie.yardlet"
    static let applicationSupportDirectoryName = "Yardlet"
    static let legacyApplicationSupportDirectoryName = "NativeHarnessClient"
    static let storageDirectoryName = ".yardlet"

    static func applicationSupportURL(
        baseURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = baseURL.appending(
            path: applicationSupportDirectoryName,
            directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            return destination
        }

        let legacy = baseURL.appending(
            path: legacyApplicationSupportDirectoryName,
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) {
            try fileManager.copyItem(at: legacy, to: destination)
        }
        return destination
    }

    /// Returns the user-visible Yardlet storage root and copies the existing session index on
    /// first use. The Application Support copy remains untouched as a rollback source.
    /// The folder holds task titles, transcripts, schedules and connector records, so it is the
    /// person's alone (0700), also one an earlier version made that the Mac's other accounts could read.
    static func storageRootURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportBaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = homeURL.appending(
            path: storageDirectoryName,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path(percentEncoded: false))

        let previousRoot = try applicationSupportURL(
            baseURL: applicationSupportBaseURL,
            fileManager: fileManager
        )
        for filename in [
            "session-index.sqlite3",
            "session-index.sqlite3-wal",
            "session-index.sqlite3-shm"
        ] {
            let source = previousRoot.appending(path: filename)
            let target = destination.appending(path: filename)
            guard fileManager.fileExists(atPath: source.path()),
                  !fileManager.fileExists(atPath: target.path()) else { continue }
            try fileManager.copyItem(at: source, to: target)
        }
        return destination
    }
}

extension UserDefaults {
    /// Yardlet's preferences wherever a caller names no store: the app's own domain, or, in a test
    /// process, a domain of that process's own in its temporary folder, removed when it exits. A
    /// test that left a store's default alone wrote to xctest's preferences
    /// (`com.apple.dt.xctest.tool`), which held about 32,500 Yardlet keys on 2026-10-24.
    /// UserDefaults is thread-safe, though the SDK does not mark it Sendable.
    nonisolated(unsafe) static let yardlet: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        try? FileManager.default.createDirectory(at: TestProcessPreferences.folder, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestProcessPreferences.folder) }
        // An absolute suite name keeps the domain in that file rather than in ~/Library/Preferences.
        return UserDefaults(suiteName: TestProcessPreferences.folder.appending(path: "yardlet").path(percentEncoded: false))!
    }()
}

private enum TestProcessPreferences {
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "yardlet-preferences-\(UUID().uuidString)", directoryHint: .isDirectory)
}
