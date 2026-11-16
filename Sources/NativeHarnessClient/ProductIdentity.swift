import Foundation

enum YardletProduct {
    static let name = "Yardlet"
    static let bundleIdentifier = "com.zzunkie.yardlet"
    static let applicationSupportDirectoryName = "Yardlet"
    static let storageDirectoryName = ".yardlet"

    /// Returns the user-visible Yardlet storage root, made on first use. The folder holds task titles,
    /// transcripts, schedules and connector records, so it is the person's alone (0700), also one an
    /// earlier version made that the Mac's other accounts could read.
    static func storageRootURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = homeURL.appending(
            path: storageDirectoryName,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path(percentEncoded: false))
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
