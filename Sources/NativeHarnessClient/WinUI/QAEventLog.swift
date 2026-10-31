import Foundation

/// The main window's events, appended to the file YARDLET_QA_EVENT_LOG names, for the check that opens
/// the Windows app and types Korean through the IME (Windows/scripts/check-window.ps1). Without it
/// nothing is written.
final class QAEventLog {
    private let handle: FileHandle?

    init() {
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
}
