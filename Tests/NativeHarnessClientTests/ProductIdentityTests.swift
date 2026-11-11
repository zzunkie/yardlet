import Foundation
import XCTest
@testable import NativeHarnessClient

final class ProductIdentityTests: XCTestCase {
    func testProductAndBundleIdentityAreStable() {
        XCTAssertEqual(YardletProduct.name, "Yardlet")
        XCTAssertEqual(YardletProduct.bundleIdentifier, "com.zzunkie.yardlet")
    }

    func testLegacySupportDirectoryIsCopiedWithoutRemovingRollbackData() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-product-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let legacy = root.appending(
            path: YardletProduct.legacyApplicationSupportDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyIndex = legacy.appending(path: "session-index.sqlite3")
        try Data("legacy-index".utf8).write(to: legacyIndex)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try YardletProduct.applicationSupportURL(baseURL: root)

        XCTAssertEqual(destination.lastPathComponent, YardletProduct.applicationSupportDirectoryName)
        XCTAssertEqual(
            try Data(contentsOf: destination.appending(path: "session-index.sqlite3")),
            Data("legacy-index".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyIndex.path()))
    }

    func testStorageRootCopiesExistingSessionIndexWithoutRemovingRollbackSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-storage-root-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let existing = support
            .appending(path: YardletProduct.applicationSupportDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("session-index".utf8).write(to: existing.appending(path: "session-index.sqlite3"))
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try YardletProduct.storageRootURL(
            homeURL: home,
            applicationSupportBaseURL: support
        )

        XCTAssertEqual(destination, home.appending(path: ".yardlet", directoryHint: .isDirectory))
        XCTAssertEqual(
            try Data(contentsOf: destination.appending(path: "session-index.sqlite3")),
            Data("session-index".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: existing.appending(path: "session-index.sqlite3").path()
        ))

        // The folder is the person's alone, also one that was made open to the Mac's other accounts.
        func permissions() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.posixPermissions] as? Int
        }
        XCTAssertEqual(try permissions(), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path(percentEncoded: false))
        _ = try YardletProduct.storageRootURL(homeURL: home, applicationSupportBaseURL: support)
        XCTAssertEqual(try permissions(), 0o700)
    }
}
