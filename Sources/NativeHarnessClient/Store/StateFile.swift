import Foundation
import Observation

/// How Yardlet reads and saves a state file that holds what the person cannot make again: password
/// items, projects, paired computers, schedules, instructions, the window's tabs. Each store keeps its
/// own form and goes through here for the file, so they all follow one rule:
///
/// - A file that is not there is an empty store. A file that is there but cannot be read (damaged, kept
///   from this user, or written by a later Yardlet in a form this one cannot decode) is not: it is kept
///   aside before a save replaces it, so nothing is lost to an older build, and the person is told.
/// - A save hands back whether the contents were written, and a save that failed is told to the person
///   until a later save of the file succeeds.
enum StateFile {
    /// What `file` holds, as `decode` reads it; nil when there is no file. Sees every save handed over
    /// before it. Throws when the file is there but cannot be read or decoded, after keeping it aside.
    static func read<Value>(_ file: URL, _ decode: (Data) throws -> Value) throws -> Value? {
        StateFileWriter.shared.flush()
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            keepAside(file)
            throw error
        }
        do {
            return try decode(data)
        } catch {
            keepAside(file)
            throw error
        }
    }

    /// Hands over `file`'s next contents, which are made and written on `StateFileWriter`'s queue; nil
    /// removes the file. `isPrivate` keeps the file, and the folder made for it, to the person. `done`,
    /// when given, hears on the main actor whether the contents were saved.
    static func save(_ file: URL, isPrivate: Bool = false, done: StateFileWriter.Done? = nil,
                     _ contents: @escaping @Sendable () throws -> Data?) {
        StateFileWriter.shared.write(file, done: { saved in
            StateFileFailures.shared.note(file, saved: saved)
            done?(saved)
        }) {
            try write(contents(), to: file, isPrivate: isPrivate)
        }
    }

    /// Writes `file`'s contents now, on the caller's thread, making its folder; nil removes the file.
    /// For a store that writes on a queue of its own, which then calls `report`. A store that keeps its
    /// own file outside the app, as the paired computers' does, follows the same rule and calls `report`
    /// and `reportUnreadable`. Any other file Yardlet keeps to the person is written here with `isPrivate`.
    static func write(_ contents: Data?, to file: URL, isPrivate: Bool = false) throws {
        let manager = FileManager.default
        guard let contents else {
            if manager.fileExists(atPath: file.path(percentEncoded: false)) { try manager.removeItem(at: file) }
            return
        }
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: isPrivate ? [.posixPermissions: 0o700] : nil)
        if isPrivate {
            try writePrivately(contents, to: file)
        } else {
            try contents.write(to: file, options: .atomic)
        }
    }

    /// Replaces `file` with `contents` through a temporary file beside it that is readable by the person
    /// alone (0600) from the moment it is created, then renamed over `file`. A file written and then
    /// narrowed, as `Data.write` and `FileManager.createFile` do, has the process's default permissions
    /// until it is narrowed. Like an atomic write, a reader sees the old contents or the new ones.
    private static func writePrivately(_ contents: Data, to file: URL) throws {
        #if os(Windows)
        // Windows has no POSIX permissions to give the file.
        try contents.write(to: file, options: .atomic)
        #else
        let temporary = file.deletingLastPathComponent()
            .appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp").path(percentEncoded: false)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: contents)
            try handle.close()
            guard rename(temporary, file.path(percentEncoded: false)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temporary)
            throw error
        }
        #endif
    }

    /// Notes whether a `write` of `file` succeeded, from any thread.
    static func report(_ file: URL, saved: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { StateFileFailures.shared.note(file, saved: saved) }
        }
    }

    /// Notes, from any thread, that `file` was there but could not be read.
    static func reportUnreadable(_ file: URL) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { StateFileFailures.shared.noteUnreadable(file) }
        }
    }

    /// Copies `file` to `<name>-unreadable-<the second it was last written>.<extension>` beside it: once
    /// for each version of the file, however often it is read. A file that cannot be copied either, as
    /// one kept from this user, is moved there instead, since the next save would replace it where it is.
    private static func keepAside(_ file: URL) {
        let manager = FileManager.default
        let written = (try? manager.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.modificationDate] as? Date
        let name = "\(file.deletingPathExtension().lastPathComponent)-unreadable-\(Int((written ?? Date()).timeIntervalSince1970))"
        let aside = file.deletingLastPathComponent().appending(path: name).appendingPathExtension(file.pathExtension)
        if !manager.fileExists(atPath: aside.path(percentEncoded: false)) {
            do { try manager.copyItem(at: file, to: aside) } catch { try? manager.moveItem(at: file, to: aside) }
        }
        reportUnreadable(file)
    }
}

/// The state files Yardlet could not read or save in this run, which the window names to the person:
/// what they see is then not what the file holds, or what they changed is not kept past this run.
@MainActor
@Observable
final class StateFileFailures {
    static let shared = StateFileFailures()

    /// Files read as they were when a store opened them and found unreadable. They stay for the run:
    /// what the store shows did not come from them.
    private(set) var unreadable: [URL] = []
    /// Files whose latest save failed.
    private(set) var unsaved: [URL] = []
    /// Off in a test process, where stores read and fail files of their own on purpose.
    @ObservationIgnored var isOn = NSClassFromString("XCTestCase") == nil

    func noteUnreadable(_ file: URL) {
        guard isOn, !unreadable.contains(file) else { return }
        unreadable.append(file)
    }

    func note(_ file: URL, saved: Bool) {
        guard isOn, unsaved.contains(file) == saved else { return }
        if saved { unsaved.removeAll { $0 == file } } else { unsaved.append(file) }
    }

    /// Forgets every file, as a test that turned this on does when it ends.
    func reset() {
        unreadable = []
        unsaved = []
    }

    /// What the window says, or nil when every file was read and saved.
    var notice: String? {
        var sentences: [String] = []
        if !unreadable.isEmpty {
            sentences.append(L10n.format("Yardlet couldn't read %@, so what it holds isn't shown. A copy is kept in the same folder.",
                                         Self.names(unreadable)))
        }
        if !unsaved.isEmpty {
            sentences.append(L10n.format("Yardlet couldn't save %@. Changes made since then are lost when Yardlet quits.",
                                         Self.names(unsaved)))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func names(_ files: [URL]) -> String {
        files.map { ProjectSidebarPresentation.abbreviatedPath(for: $0) }.joined(separator: ", ")
    }
}
