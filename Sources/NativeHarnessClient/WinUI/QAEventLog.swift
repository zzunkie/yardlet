import Foundation

/// The windows' events, appended to the file YARDLET_QA_EVENT_LOG names, for the checks that open the
/// Windows app, type Korean through the IME (Windows/scripts/check-window.ps1) and connect it to a host
/// (Windows/scripts/check-remote.ps1). Without it nothing is written.
@MainActor
final class QAEventLog {
    /// The app's one log, which every window writes to.
    static let shared = QAEventLog()

    private let handle: FileHandle?

    private init() {
        guard let path = ProcessInfo.processInfo.environment["YARDLET_QA_EVENT_LOG"], !path.isEmpty else {
            handle = nil
            return
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }

    /// A line added to a log that is already there, from a process that must not start it afresh: an installer's
    /// hook, which runs with the environment of the app or the check that started the installer.
    nonisolated static func append(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["YARDLET_QA_EVENT_LOG"], !path.isEmpty,
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data((line + "\n").utf8))
    }
}
