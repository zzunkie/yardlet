import Foundation
import XCTest
@testable import NativeHarnessClient

/// Signing for Developer ID (README "Signing and notarization", docs/BROWSER_HOST.md §7): the ad-hoc
/// path stays as it was, each part's entitlements follow Chrome's, and the Touch ID keychain group
/// patch rewrites only CEF's two constants.
final class DeveloperIDSigningTests: XCTestCase {
    private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appending(path: "yardlet-signing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }

    func testAdHocSigningKeepsEachPartsIdentifierRequirement() throws {
        let app = try assembledBundle()
        let signed = try run("/bin/zsh", [root.appending(path: "scripts/sign-app.sh").path, app.path],
                             environment: ["YARDLET_SIGNING_IDENTITY": "-"])
        XCTAssertEqual(signed.status, 0, signed.output)
        let host = "Contents/Frameworks/Yardlet Browser Host.app"
        let framework = "\(host)/Contents/Frameworks/Chromium Embedded Framework.framework"
        let expected = [
            "": "com.zzunkie.yardlet",
            "Contents/Helpers/yardlet-mcp": "com.zzunkie.yardlet.mcp",
            // The helper reads which app may start it from this identifier.
            "Contents/Helpers/Yardlet Agents.app": "com.zzunkie.yardlet.agents",
            host: "com.zzunkie.yardlet.browser-host",
            "\(host)/Contents/Frameworks/Yardlet Helper.app": "com.zzunkie.yardlet.helper",
            "\(host)/Contents/Frameworks/Yardlet Helper (GPU).app": "com.zzunkie.yardlet.helper.gpu",
            "\(host)/Contents/Frameworks/Yardlet Helper (Renderer).app": "com.zzunkie.yardlet.helper.renderer",
            framework: "org.cef.framework",
            "\(framework)/Versions/A/Libraries/libEGL.dylib": "libEGL",
        ]
        for (path, identifier) in expected {
            let part = path.isEmpty ? app : app.appending(path: path)
            let requirement = try run("/usr/bin/codesign", ["-d", "-r-", part.path])
            // codesign quotes an identifier only when it has more than letters and digits.
            XCTAssertTrue(requirement.output.contains("designated => identifier \"\(identifier)\"")
                          || requirement.output.contains("designated => identifier \(identifier)\n"), "\(path): \(requirement.output)")
            let details = try run("/usr/bin/codesign", ["-dv", part.path]).output
            XCTAssertFalse(details.contains("runtime"), "ad-hoc builds stay without the hardened runtime: \(path)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appending(path: "\(host)/Contents/embedded.provisionprofile").path))
        let verified = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        XCTAssertEqual(verified.status, 0, verified.output)
    }

    func testAProfileNeedsASigningIdentity() throws {
        let app = try assembledBundle()
        let profile = work.appending(path: "Host.provisionprofile")
        try Data("not a profile".utf8).write(to: profile)
        let signed = try run("/bin/zsh", [root.appending(path: "scripts/sign-app.sh").path, app.path],
                             environment: ["YARDLET_SIGNING_IDENTITY": "-", "YARDLET_PROVISIONING_PROFILE": profile.path])
        XCTAssertNotEqual(signed.status, 0)
        XCTAssertTrue(signed.output.contains("needs YARDLET_SIGNING_IDENTITY"), signed.output)
    }

    /// Chrome 155 and chrome/installer/mac/signing/parts.py: only the renderer and GPU helpers run
    /// JIT code; the browser process uses Bluetooth and USB for passkeys, and the camera and microphone
    /// for a site the person allowed (Chromium captures video there on macOS). Yardlet adds the privacy
    /// entitlements of the commands it runs. Keychain groups and the application identifier come
    /// from the profile at signing time, never from these files.
    func testEachPartsEntitlementsFollowChrome() throws {
        func keys(_ name: String) throws -> Set<String> {
            let data = try Data(contentsOf: root.appending(path: "Packaging/Entitlements/\(name).entitlements"))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertTrue(plist.values.allSatisfy { ($0 as? Bool) == true }, name)
            return Set(plist.keys)
        }
        XCTAssertEqual(try keys("BrowserHelperJIT"), ["com.apple.security.cs.allow-jit"])
        XCTAssertEqual(try keys("BrowserHost"), ["com.apple.security.device.bluetooth", "com.apple.security.device.usb",
                                                 "com.apple.security.device.camera", "com.apple.security.device.audio-input"])
        XCTAssertEqual(try keys("Yardlet"), Set(["com.apple.security.device.bluetooth"]).union(Self.commandPermissions.keys))
        // The agents it starts ask as Yardlet Agents for what commands asked Yardlet for.
        XCTAssertEqual(try keys("AgentHost"), Set(Self.commandPermissions.keys))
        let script = try String(contentsOf: root.appending(path: "scripts/sign-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains(#"*"(Renderer).app"|*"(GPU).app") sign_runtime --entitlements "$ENTITLEMENTS/BrowserHelperJIT.entitlements""#))
    }

    /// The hardened runtime's privacy entitlements on Yardlet itself, for the commands it runs
    /// (harnesses, their tools, the terminal), which macOS attributes to Yardlet; each usage string
    /// the system shows in the prompt.
    private static let commandPermissions = [
        "com.apple.security.automation.apple-events": ["NSAppleEventsUsageDescription"],
        "com.apple.security.device.audio-input": ["NSMicrophoneUsageDescription"],
        "com.apple.security.device.camera": ["NSCameraUsageDescription"],
        // The Apple connectors' own EventKit and Contacts use; reminders come under calendars.
        "com.apple.security.personal-information.calendars": ["NSCalendarsFullAccessUsageDescription",
                                                              "NSRemindersFullAccessUsageDescription"],
        "com.apple.security.personal-information.addressbook": ["NSContactsUsageDescription"],
    ]

    func testEachPermissionACommandMayAskForHasTheAppsReason() throws {
        for (plist, localizations) in [("Packaging/Info.plist", "Sources/NativeHarnessClient/Resources"),
                                       ("Packaging/AgentHost/Info.plist", "Packaging/AgentHost")] {
            let data = try Data(contentsOf: root.appending(path: plist))
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            for language in ["en", "ko", "ja", "zh-Hans"] {
                let strings = try XCTUnwrap(NSDictionary(contentsOf: root.appending(
                    path: "\(localizations)/\(language).lproj/InfoPlist.strings")) as? [String: String])
                for key in Self.commandPermissions.values.joined() {
                    XCTAssertNotNil(info[key] as? String, "\(plist) \(key)")
                    XCTAssertFalse(strings[key, default: ""].isEmpty, "\(localizations) \(language) \(key)")
                }
            }
        }
    }

    /// notarize.sh stops before anything leaves the Mac when the notary service would refuse a part.
    func testNotarizationNamesWhatTheNotaryServiceWouldRefuse() throws {
        let app = try assembledBundle()
        XCTAssertEqual(try run("/bin/zsh", [root.appending(path: "scripts/sign-app.sh").path, app.path],
                               environment: ["YARDLET_SIGNING_IDENTITY": "-"]).status, 0)
        let checked = try run("/bin/zsh", [root.appending(path: "scripts/notarize.sh").path, "--dry-run", app.path])
        XCTAssertEqual(checked.status, 1, checked.output)
        for problem in ["Contents/MacOS/Yardlet: not signed with a Developer ID Application certificate",
                        "Contents/Helpers/yardlet-mcp: no secure timestamp",
                        "Yardlet Helper (Renderer).app/Contents/MacOS/Yardlet Helper (Renderer): executable without the hardened runtime"] {
            XCTAssertTrue(checked.output.contains(problem), "\(problem)\n\(checked.output)")
        }
        XCTAssertFalse(checked.output.contains("Dry run; would run"), checked.output)
    }

    func testTheWebAuthnGroupPatchRewritesOnlyCEFsTwoConstants() throws {
        let binary = work.appending(path: "Chromium Embedded Framework")
        var bytes = Data([0x7f, 0x45])
        for text in ["Autofill", ".org.chromium.Chromium.webauthn", "https://domain.com/.well-known/webauthn",
                     "webauthn.touchid.metadata_secret", ".org.chromium.Chromium.webauthn-uvk", "end"] {
            bytes.append(contentsOf: Array(text.utf8) + [0])
        }
        try bytes.write(to: binary)
        let script = root.appending(path: "scripts/cef-webauthn-group.sh").path
        XCTAssertEqual(try run("/bin/zsh", [script, "list", binary.path]).output,
                       ".org.chromium.Chromium.webauthn\n.org.chromium.Chromium.webauthn-uvk\n")

        XCTAssertEqual(try run("/bin/zsh", [script, "patch", binary.path, "ABCDE12345"]).status, 0)
        XCTAssertEqual(try run("/bin/zsh", [script, "list", binary.path]).output,
                       "ABCDE12345.com.zzunkie.webauthn\nABCDE12345.com.zzunkie.webauthn-uvk\n")
        let patched = try Data(contentsOf: binary)
        XCTAssertEqual(patched.count, bytes.count)
        XCTAssertEqual(zip(patched, bytes).filter { $0 != $1 }.count, 44)

        XCTAssertEqual(try run("/bin/zsh", [script, "patch", binary.path, "ABCDE12345"]).status, 0, "running it again changes nothing")
        XCTAssertEqual(try Data(contentsOf: binary), patched)
        XCTAssertNotEqual(try run("/bin/zsh", [script, "patch", binary.path, "ZZZZZ99999"]).status, 0)
        XCTAssertNotEqual(try run("/bin/zsh", [script, "patch", binary.path, "SHORT"]).status, 0)
        XCTAssertEqual(try Data(contentsOf: binary), patched)
    }

    func testAnUpdateMustMeetTheInstalledSignersRequirement() throws {
        let installed = try assembledBundle(at: work.appending(path: "Installed/Yardlet.app"), withBrowser: false)
        let staged = try assembledBundle(at: work.appending(path: "Staged/Yardlet.app"), withBrowser: false)
        for bundle in [installed, staged] {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path]).status, 0)
        }
        XCTAssertNil(try YardletUpdater.signerRequirement(of: installed), "an ad-hoc app has no team")
        XCTAssertNoThrow(try YardletUpdater.verifySignature(of: staged, replacing: installed))
        XCTAssertNoThrow(try YardletUpdater.verify(staged, satisfies: #"identifier "com.zzunkie.yardlet""#))
        for requirement in [#"identifier "com.example.other""#, "anchor apple generic and certificate leaf[subject.OU] = \"CS8S8523XJ\""] {
            XCTAssertThrowsError(try YardletUpdater.verify(staged, satisfies: requirement)) {
                XCTAssertEqual($0 as? YardletUpdater.Problem, .otherSigner)
            }
        }
        XCTAssertTrue(YardletUpdater.installerScript.contains(#"codesign --verify --strict -R "=$requirement" "$pending""#))
    }

    // MARK: - Fixtures

    /// The bundle layout build-app.sh assembles, with /usr/bin/true standing in for each Mach-O.
    private func assembledBundle(at app: URL? = nil, withBrowser: Bool = true) throws -> URL {
        let app = app ?? work.appending(path: "Yardlet.app")
        let contents = app.appending(path: "Contents")
        try executable(at: contents.appending(path: "MacOS/Yardlet"))
        try executable(at: contents.appending(path: "Helpers/yardlet-mcp"))
        try info(["CFBundleIdentifier": "com.zzunkie.yardlet", "CFBundleExecutable": "Yardlet", "CFBundlePackageType": "APPL"],
                 at: contents.appending(path: "Info.plist"))
        guard withBrowser else { return app }
        try executable(at: contents.appending(path: "Helpers/Yardlet Agents.app/Contents/MacOS/Yardlet Agents"))
        try info(["CFBundleIdentifier": "com.zzunkie.yardlet.agents", "CFBundleExecutable": "Yardlet Agents", "CFBundlePackageType": "APPL"],
                 at: contents.appending(path: "Helpers/Yardlet Agents.app/Contents/Info.plist"))
        let host = contents.appending(path: "Frameworks/Yardlet Browser Host.app/Contents")
        try executable(at: host.appending(path: "MacOS/Yardlet Browser Host"))
        try info(["CFBundleIdentifier": "com.zzunkie.yardlet.browser-host", "CFBundleExecutable": "Yardlet Browser Host",
                  "CFBundlePackageType": "APPL"], at: host.appending(path: "Info.plist"))
        let framework = host.appending(path: "Frameworks/Chromium Embedded Framework.framework")
        let version = framework.appending(path: "Versions/A")
        try executable(at: version.appending(path: "Chromium Embedded Framework"))
        try executable(at: version.appending(path: "Libraries/libEGL.dylib"))
        try info(["CFBundleIdentifier": "org.cef.framework", "CFBundleExecutable": "Chromium Embedded Framework",
                  "CFBundlePackageType": "FMWK"], at: version.appending(path: "Resources/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: framework.appending(path: "Versions/Current").path, withDestinationPath: "A")
        for entry in ["Chromium Embedded Framework", "Libraries", "Resources"] {
            try FileManager.default.createSymbolicLink(atPath: framework.appending(path: entry).path,
                                                       withDestinationPath: "Versions/Current/\(entry)")
        }
        for (suffix, identifier) in [("", "com.zzunkie.yardlet.helper"), (" (GPU)", "com.zzunkie.yardlet.helper.gpu"),
                                     (" (Renderer)", "com.zzunkie.yardlet.helper.renderer")] {
            let helper = host.appending(path: "Frameworks/Yardlet Helper\(suffix).app/Contents")
            try executable(at: helper.appending(path: "MacOS/Yardlet Helper\(suffix)"))
            try info(["CFBundleIdentifier": identifier, "CFBundleExecutable": "Yardlet Helper\(suffix)", "CFBundlePackageType": "APPL"],
                     at: helper.appending(path: "Info.plist"))
        }
        return app
    }

    private func executable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: url)
    }

    private func info(_ values: [String: String], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    private func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
