import AppKit
import SwiftUI

/// Help › Report a Problem…: the repository's bug report form on GitHub, with the facts about this Mac
/// and this copy of Yardlet filled in. Nothing is sent: the form opens in the browser, and the person
/// reads it, adds what happened and submits it there. What goes in is the versions the app already
/// knows (no agent is started to ask) and, from an error card, that error's message, with this Mac's
/// home folder, user names, email addresses and token-like strings taken out.
enum ProblemReport {
    static let formURL = URL(string: "https://github.com/zzunkie/yardlet/issues/new")!
    static let template = "bug_report.yml"
    /// GitHub refuses a longer address with 414 URI Too Long; an error's message is shortened to fit.
    static let maximumURLLength = 6000
    /// The agents the form names when no error points at one.
    static let reportedHarnesses: [HarnessKind] = [.claudeCode, .codex, .antigravityCLI]

    struct Facts: Equatable {
        /// "0.11.10 (32), commit 1c1a2901".
        var yardlet: String
        /// "macOS 26.1 (25B78)".
        var macOS: String
        var isAppleSilicon: Bool
        var agents: [Agent]
    }

    /// An agent's name and the version Yardlet last read from its CLI, nil when it has none.
    struct Agent: Equatable {
        var name: String
        var version: String?
    }

    /// An error a card showed, and the agent it came from.
    struct Problem: Equatable {
        var harness: String
        var message: String
    }

    /// What is taken out of every value before it goes into the address.
    struct Redaction {
        var homePath: String
        var userNames: [String]

        static var current: Redaction {
            Redaction(homePath: NSHomeDirectory(), userNames: [NSUserName(), NSFullUserName()])
        }

        func apply(_ text: String) -> String {
            var text = text
            if homePath.count > 1 { text = text.replacingOccurrences(of: homePath, with: "~") }
            let patterns: [(String, String)] = [
                (#"/(Users|home)/[^/\s"'`]+"#, "/$1/<user>"),
                (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
                // Keys, tokens and session IDs: a long run of letters and digits with both in it.
                (#"(?=[A-Za-z0-9_\-]*[0-9])(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{32,}"#, "<redacted>"),
            ]
            for (pattern, template) in patterns {
                text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            for name in userNames where name.trimmingCharacters(in: .whitespaces).count >= 3 {
                text = text.replacingOccurrences(of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#,
                                                 with: "<user>", options: [.regularExpression, .caseInsensitive])
            }
            return text
        }
    }

    static func url(facts: Facts, problem: Problem? = nil, redaction: Redaction = .current) -> URL {
        guard let problem else { return address(fields(facts: facts, problem: nil, redaction: redaction)) }
        // Taken out before it is shortened, so a cut never splits a path or a name it would have caught.
        let message = redaction.apply(problem.message.trimmingCharacters(in: .whitespacesAndNewlines))
        func url(keeping count: Int) -> URL {
            let kept = count < message.count ? String(message.prefix(count)) + "\n…" : message
            return address(fields(facts: facts, problem: Problem(harness: problem.harness, message: kept),
                                  redaction: redaction))
        }
        let whole = url(keeping: message.count)
        guard whole.absoluteString.count > maximumURLLength else { return whole }
        // The longest beginning of the message that fits.
        var low = 0, high = message.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if url(keeping: middle).absoluteString.count <= maximumURLLength { low = middle } else { high = middle - 1 }
        }
        return url(keeping: low)
    }

    /// The form's fields by their `id`, in the template's order. GitHub fills text fields from the address
    /// but not dropdowns, so the chip goes beside the macOS version and the install method is left to the person.
    private static func fields(facts: Facts, problem: Problem?, redaction: Redaction) -> [(String, String)] {
        let agents = problem.map { problem in
            [facts.agents.first { $0.name == problem.harness } ?? Agent(name: problem.harness)]
        } ?? facts.agents.filter { $0.version != nil }
        var fields: [(String, String)] = [
            ("version", redaction.apply(facts.yardlet)),
            ("macos", redaction.apply(facts.macOS + (facts.isAppleSilicon ? ", Apple silicon" : ", Intel"))),
        ]
        let agentLine = agents.map { [$0.name, $0.version].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", ")
        if !agentLine.isEmpty { fields.append(("agent", redaction.apply(agentLine))) }
        // The message comes already redacted (`url(facts:problem:redaction:)`).
        if let problem {
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: problem.message) + 1))
            fields.append(("what-happened", "\(problem.harness) showed this error in Yardlet:\n\n\(fence)text\n\(problem.message)\n\(fence)\n"))
        }
        return fields
    }

    private static func address(_ fields: [(String, String)]) -> URL {
        // Only unreserved characters stay as they are: GitHub reads `+` in a query as a space.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = ([("template", template)] + fields)
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return URL(string: formURL.absoluteString + "?" + query)!
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0, current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

// MARK: - This Mac

extension ProblemReport.Facts {
    /// This copy of Yardlet and this Mac, from the bundle, the system and the versions Yardlet already
    /// read from each agent's CLI (`RuntimeSelectionStore.cachedVersion(of:)`). Nothing is started.
    @MainActor
    static func current(runtimeSelections: RuntimeSelectionStore, harnesses: [HarnessKind]) -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = [info["CFBundleShortVersionString"] as? String,
                       (info["CFBundleVersion"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let commit = (info["YardletSourceCommit"] as? String).map { "commit \($0)" }
        let yardlet = [version.isEmpty ? "development build" : version, commit].compactMap { $0 }.joined(separator: ", ")

        let system = ProcessInfo.processInfo.operatingSystemVersion
        var macOS = "macOS \(system.majorVersion).\(system.minorVersion)" + (system.patchVersion > 0 ? ".\(system.patchVersion)" : "")
        if let build = sysctlString("kern.osversion") { macOS += " (\(build))" }

        var seen = Set<HarnessKind>()
        let agents = harnesses.filter { seen.insert($0).inserted }.map { harness in
            ProblemReport.Agent(name: harness.displayName,
                                version: runtimeSelections.selectedURL(for: harness).flatMap(runtimeSelections.cachedVersion(of:)))
        }
        return Self(yardlet: yardlet, macOS: macOS, isAppleSilicon: sysctlInt("hw.optional.arm64") == 1, agents: agents)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

// MARK: - Actions

/// Opens the bug report form, from the Help menu or from an error card. Equal to every other, as
/// `YardletInstallUpdateAction` is, so the window is not evaluated again for a new closure.
struct YardletReportProblemAction: Equatable {
    let report: @MainActor (_ harness: HarnessKind?, _ message: String?) -> Void

    @MainActor func callAsFunction(harness: HarnessKind? = nil, message: String? = nil) { report(harness, message) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }

    @MainActor
    static func opening(runtimeSelections: RuntimeSelectionStore) -> Self {
        Self { harness, message in
            let harnesses = (harness.map { [$0] } ?? []) + ProblemReport.reportedHarnesses
            let facts = ProblemReport.Facts.current(runtimeSelections: runtimeSelections, harnesses: harnesses)
            let problem = harness.flatMap { harness in
                message.map { ProblemReport.Problem(harness: harness.displayName, message: $0) }
            }
            OutsideBrowser.open(ProblemReport.url(facts: facts, problem: problem))
        }
    }
}

private struct YardletReportProblemKey: EnvironmentKey {
    static let defaultValue: YardletReportProblemAction? = nil
}

extension EnvironmentValues {
    /// Report a Problem… for an error card. Nil where there is no app to report from, as in a test's
    /// window or another Mac's.
    var yardletReportProblem: YardletReportProblemAction? {
        get { self[YardletReportProblemKey.self] }
        set { self[YardletReportProblemKey.self] = newValue }
    }
}

/// Help › Show Diagnostic Logs: Yardlet's log folders in the Finder, for the person to choose what to
/// attach. `~/.yardlet/logs` holds the sign-in checks (`account-checks.log`, docs/PROVIDER_CONNECTIONS.md)
/// and `~/Library/Logs/Yardlet` the hang log (README, "Privacy"). Each is made only when something is
/// written to it, so only those that exist open.
@MainActor
enum DiagnosticLogFolders {
    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: YardletProduct.storageDirectoryName).appending(path: "logs", directoryHint: .isDirectory),
                home.appending(path: "Library/Logs/Yardlet", directoryHint: .isDirectory)]
    }

    static func show() {
        guard !QABackground.isOn else { return }
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !existing.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.string("Yardlet has not written any diagnostic logs yet.")
            alert.informativeText = L10n.string("They appear in ~/.yardlet/logs and ~/Library/Logs/Yardlet once something is recorded.")
            alert.runModal()
            return
        }
        existing.forEach { NSWorkspace.shared.open($0) }
    }
}

/// The Help menu: Yardlet Help opens the repository's README, which says how to use the app (the app has
/// no help book, so the system's own item only said help isn't available), then Report a Problem… and
/// Show Diagnostic Logs.
struct YardletHelpCommands: Commands {
    static let helpURL = URL(string: "https://github.com/zzunkie/yardlet#readme")!
    let report: YardletReportProblemAction

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L10n.string("Yardlet Help")) { NSWorkspace.shared.open(Self.helpURL) }
                .keyboardShortcut("?", modifiers: .command)
            Divider()
            Button(L10n.string("Report a Problem…")) { report() }
            Button(L10n.string("Show Diagnostic Logs")) { DiagnosticLogFolders.show() }
        }
    }
}
