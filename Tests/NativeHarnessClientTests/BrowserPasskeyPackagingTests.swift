import Foundation
import XCTest
@testable import NativeHarnessClient

/// Passkeys on a phone (WebAuthn hybrid) need Bluetooth, and Chromium refuses it unless the app
/// responsible for the browser host says why in its Info.plist ("Cannot use Bluetooth because the
/// responsible app for the process does not have Bluetooth metadata in its Info.plist"). Yardlet
/// launches the host, so both bundles carry the reason, in English and Korean for the system prompt.
final class BrowserPasskeyPackagingTests: XCTestCase {
    private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheAppAndTheBrowserHostSayWhyTheyUseBluetooth() throws {
        for path in ["Packaging/Info.plist", "Packaging/CEF/BrowserHost-Info.plist"] {
            let info = try plist(path)
            for key in ["NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"] {
                let reason = try XCTUnwrap(info[key] as? String, "\(path) \(key)")
                XCTAssertTrue(reason.contains("passkey"), reason)
            }
        }
        for language in ["en", "ko", "ja", "zh-Hans"] {
            let strings = try XCTUnwrap(NSDictionary(contentsOf: root.appending(
                path: "Sources/NativeHarnessClient/Resources/\(language).lproj/InfoPlist.strings")) as? [String: String])
            XCTAssertNotNil(strings["NSBluetoothAlwaysUsageDescription"], language)
            XCTAssertNotNil(strings["NSBluetoothPeripheralUsageDescription"], language)
        }
    }
}
