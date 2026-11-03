import Foundation

/// The task profiles' changes, one line each, beside the host's log (`Browser/Logs/sign-ins.log`): when a task took a
/// profile of its own before its agent's sign-in (the site, the task, how it signed in), and when the task profiles
/// from before tasks shared the default profile were sorted (docs/BROWSER_SESSION_ISOLATION.md 3 and 7). Never a
/// cookie's value or an account's name. The log is kept under `maximumFileSize`; the lines before go to
/// `sign-ins.1.log`.
final class BrowserSignInLog: Sendable {
    let file: URL
    static let maximumFileSize = 1_000_000
    private let queue = DispatchQueue(label: "Yardlet browser sign-in log", qos: .utility)

    init(file: URL) {
        self.file = file
    }

    func write(_ line: String) {
        let entry = Date.ISO8601FormatStyle(timeZone: .current).format(Date()) + " " + line + "\n"
        let file = file
        queue.async {
            let manager = FileManager.default
            let path = file.path(percentEncoded: false)
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > Self.maximumFileSize {
                let previous = file.deletingPathExtension().appendingPathExtension("1.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        }
    }
}
