import Foundation
import XCTest
@testable import NativeHarnessClient

final class ProductIdentityTests: XCTestCase {
    func testProductAndBundleIdentityAreStable() {
        XCTAssertEqual(YardletProduct.name, "Yardlet")
        XCTAssertEqual(YardletProduct.bundleIdentifier, "com.zzunkie.yardlet")
    }

    func testStorageRootIsTheHiddenFolderInHome() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-storage-root-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try YardletProduct.storageRootURL(homeURL: home)

        XCTAssertEqual(destination, home.appending(path: ".yardlet", directoryHint: .isDirectory))

        // The folder is the person's alone, also one that was made open to the Mac's other accounts.
        func permissions() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.posixPermissions] as? Int
        }
        XCTAssertEqual(try permissions(), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path(percentEncoded: false))
        _ = try YardletProduct.storageRootURL(homeURL: home)
        XCTAssertEqual(try permissions(), 0o700)
    }
}
