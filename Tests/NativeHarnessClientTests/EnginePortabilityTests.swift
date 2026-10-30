import Foundation
import XCTest

/// Keeps the shared engine free of new macOS-only code (docs/PLATFORM_PORTABILITY.md).
/// Every source file outside the screen and platform layers is engine code, so a new folder
/// is scanned by default. Existing violations are listed per file and may only shrink.
final class EnginePortabilityTests: XCTestCase {
    /// Screen and platform layers. Everything else under the app target is engine code.
    private static let nonEnginePaths = [
        "Views/", "Browser/", "Development/", "Platform/", "NativeHarnessClientApp.swift"
    ]

    /// Existing engine violations, by file. Remove an entry when its file stops matching,
    /// and never add one: move the macOS code to `Platform/macOS/` behind a small protocol.
    private static let allowedViolations: [String: Set<String>] = [:]

    /// Lower this when an entry leaves the list; never raise it.
    private static let allowedViolationCeiling = 0

    private static let forbiddenModules = [
        "SwiftUI", "AppKit", "UIKit", "Cocoa", "WebKit", "SwiftTerm", "Darwin", "Security",
        "UserNotifications", "CryptoKit", "CoreServices", "Carbon", "ServiceManagement",
        "IOKit", "CoreGraphics", "QuartzCore", "Combine", "OSLog", "os"
    ]

    private static let rules: [(name: String, pattern: String)] = [
        ("Darwin-qualified symbol", #"\bDarwin\.\w+"#),
        ("POSIX process control",
         #"(?<![\w.])(?:kill|killpg|waitpid|wait4|setpgid|getpgid|setsid|signal|sigaction|usleep)\s*\("#
            + #"|\bSIG(?:HUP|INT|QUIT|KILL|TERM|CHLD|PIPE|USR1|USR2|STOP|CONT|TSTP)\b|\bpid_t\b"#),
        ("Darwin process inspection",
         #"(?<![\w.])(?:proc_\w+|sysctl|sysctlbyname)\s*\(|\bkinfo_proc\b|\bKERN_PROC\w*"#),
        ("PTY", #"(?<![\w.])(?:forkpty|openpty|posix_openpt|grantpt|unlockpt|ptsname|login_tty)\s*\("#),
        ("posix_spawn", #"\bposix_spawn\w*"#),
        ("Darwin file cloning", #"(?<![\w.])(?:copyfile|clonefile|fclonefileat)\s*\(|\bCOPYFILE_\w+"#),
        ("Keychain", #"\b(?:SecItem\w+|SecKeychain\w*|SecAccess\w*|kSec\w+|errSec\w+|OSStatus)\b"#),
        ("UserNotifications type", #"\bUN[A-Z][a-z]\w*"#),
        ("AppKit type",
         #"\b(?:NSWorkspace|NSPasteboard|NSImage|NSColor|NSFont|NSApplication|NSApp|NSScreen|NSSound"#
            + #"|NSAlert|NSOpenPanel|NSSavePanel|NSRunningApplication|NSView|NSWindow|NSEvent|NSMenu"#
            + #"|NSCursor|NSHostingView|NSViewRepresentable|NSStatusBar|UIApplication|UIImage|UIColor)\b"#),
        ("File system events", #"\bFSEvent\w*|\bkqueue\b|\bmakeFileSystemObjectSource\b"#),
        // swift-corelibs-foundation does not provide these outside Apple platforms.
        ("Apple-only Foundation API",
         #"\b(?:NSDataDetector|NSAppleScript|NSUserAppleScriptTask|DistributedNotificationCenter"#
            + #"|NSXPCConnection|NSUserNotification)\b"#),
        ("macOS system URL", #"x-apple\.[\w.-]+"#)
    ]

    func testEngineFilesTakeOnNoNewUIFrameworksOrDarwinOnlyAPIs() throws {
        let sources = try Self.engineSources()
        XCTAssertTrue(sources.keys.contains("AppModel.swift"), "The engine scan found no sources")
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            let found = try Self.violations(in: text)
            let allowed = Self.allowedViolations[path] ?? []
            let added = found.subtracting(allowed)
            XCTAssertTrue(
                added.isEmpty,
                "\(path) uses \(added.sorted()). Keep engine code portable; put the macOS part in Platform/macOS/."
            )
        }
    }

    func testAllowedViolationsOnlyShrink() throws {
        let sources = try Self.engineSources()
        for (path, allowed) in Self.allowedViolations.sorted(by: { $0.key < $1.key }) {
            guard let text = sources[path] else {
                XCTFail("\(path) is no longer an engine source; remove it from the allowed violations")
                continue
            }
            let stale = allowed.subtracting(try Self.violations(in: text))
            XCTAssertTrue(stale.isEmpty, "\(path) no longer uses \(stale.sorted()); remove those entries")
        }
        let count = Self.allowedViolations.values.map(\.count).reduce(0, +)
        XCTAssertLessThanOrEqual(count, Self.allowedViolationCeiling, "The allowed violations grew")
    }

    func testScannerCatchesEachCategory() throws {
        let sample = """
        import SwiftUI
        @preconcurrency import SwiftTerm
        _ = Darwin.kill(pid, SIGKILL)
        _ = copyfile(a, b, nil, 0)
        let status: OSStatus = SecItemCopyMatching(query, nil)
        NSWorkspace.shared.open(url)
        let detector = try NSDataDetector(types: 0)
        // import AppKit in a comment is not a violation
        process.terminate()
        """
        XCTAssertEqual(try Self.violations(in: sample), [
            "import SwiftUI", "import SwiftTerm", "Darwin-qualified symbol", "POSIX process control",
            "Darwin file cloning", "Keychain", "AppKit type", "Apple-only Foundation API"
        ])
    }

    /// The app target, and the library the app shares with the Yardlet MCP server (`yardlet-mcp`),
    /// whose sources are keyed with its target name.
    private static let engineTargets = ["NativeHarnessClient", "YardletAgentTools"]

    private static func engineSources() throws -> [String: String] {
        let sourcesRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources", directoryHint: .isDirectory)
        var sources: [String: String] = [:]
        for target in engineTargets {
            let root = sourcesRoot.appending(path: target, directoryHint: .isDirectory).standardizedFileURL
            let rootPath = root.path(percentEncoded: false)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
                guard !nonEnginePaths.contains(where: { path == $0 || path.hasPrefix($0) }) else { continue }
                let key = target == engineTargets[0] ? path : "\(target)/\(path)"
                sources[key] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        XCTAssertTrue(sources.keys.contains("YardletAgentTools/MCPServer.swift"), "The shared tool library was not scanned")
        return sources
    }

    private static func violations(in source: String) throws -> Set<String> {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let range = NSRange(code.startIndex..., in: code)
        var found = Set<String>()

        let modules = forbiddenModules.joined(separator: "|")
        let imports = try NSRegularExpression(
            pattern: #"^\s*(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?("#
                + modules + #")\b"#,
            options: .anchorsMatchLines
        )
        for match in imports.matches(in: code, range: range) {
            if let module = Range(match.range(at: 1), in: code) { found.insert("import \(code[module])") }
        }
        for rule in rules where try NSRegularExpression(pattern: rule.pattern).firstMatch(in: code, range: range) != nil {
            found.insert(rule.name)
        }
        return found
    }
}
