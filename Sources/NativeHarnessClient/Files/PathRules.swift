import Foundation

/// How a platform writes an absolute path and whether one path lies inside a folder (docs/PLATFORM_PORTABILITY.md,
/// "Paths and executable lookup"). A path is judged by its text alone: it is split into names at the platform's
/// separators, `.` and `..` are taken out by name, and nothing is looked up, so a caller that must not be led out of
/// a folder through a link resolves the links first.
///
/// macOS and Linux: an absolute path starts with `/`, and names compare as Swift compares strings. Windows: an
/// absolute path starts with a drive (`C:\`, or `/C:/` as a file URL's path writes it) or names a share
/// (`\\server\share`), also in the `\\?\` and `\\.\` forms; `\` and `/` both separate names, and names compare in any
/// case, one character for one, as NTFS compares them. There `\x` (the current drive's root) and `C:x` (drive C's
/// current folder) depend on where they are read from, so they are neither absolute nor relative.
struct PathRules: Equatable, Sendable {
    /// Windows' rules rather than POSIX's.
    let isWindows: Bool

    static let posix = PathRules(isWindows: false)
    static let windows = PathRules(isWindows: true)

    /// This platform's rules.
    static let current: PathRules = {
        #if os(Windows)
        return .windows
        #else
        return .posix
        #endif
    }()

    /// Whether `path` names the same place wherever it is read from.
    func isAbsolute(_ path: String) -> Bool {
        parsed(path) != nil
    }

    /// Whether `path` is read from the folder it is given in: it starts at no root, and on Windows at no drive.
    /// An empty path is relative.
    func isRelative(_ path: String) -> Bool {
        var scalars = path.unicodeScalars.makeIterator()
        guard let first = scalars.next() else { return true }
        guard !isSeparator(first) else { return false }
        return !(isWindows && first.isASCII && first.properties.isAlphabetic && scalars.next() == ":")
    }

    /// The names `path` is made of, split at this platform's separators; the empty names of a repeated, leading or
    /// trailing separator are kept.
    func names(_ path: String) -> [String] {
        path.unicodeScalars.split(omittingEmptySubsequences: false, whereSeparator: isSeparator)
            .map { String(Substring($0)) }
    }

    /// `path` below `folder`, its names joined with `/`, or "" when it is `folder` itself; nil when it lies anywhere
    /// else or either is not absolute.
    func relativePath(of path: String, in folder: String) -> String? {
        guard let path = parsed(path), let folder = parsed(folder),
              path.root.count == folder.root.count, zip(path.root, folder.root).allSatisfy(same),
              path.names.count >= folder.names.count, zip(path.names, folder.names).allSatisfy(same) else { return nil }
        return path.names.dropFirst(folder.names.count).joined(separator: "/")
    }

    /// Whether `path` is `folder` or lies inside it.
    func isInside(_ path: String, folder: String) -> Bool {
        relativePath(of: path, in: folder) != nil
    }

    /// Whether `path` lies inside `folder` and is not `folder` itself.
    func isStrictlyInside(_ path: String, folder: String) -> Bool {
        relativePath(of: path, in: folder).map { !$0.isEmpty } ?? false
    }

    func relativePath(of url: URL, in folder: URL) -> String? {
        relativePath(of: path(of: url), in: path(of: folder))
    }

    func isInside(_ url: URL, folder: URL) -> Bool {
        relativePath(of: url, in: folder) != nil
    }

    func isStrictlyInside(_ url: URL, folder: URL) -> Bool {
        relativePath(of: url, in: folder).map { !$0.isEmpty } ?? false
    }

    /// `url`'s path as these rules read it; on Windows a share's server, which a file URL may keep as its host,
    /// leads it (`//server/share/x`).
    func path(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard isWindows, let host = url.host(percentEncoded: false), !host.isEmpty,
              host.lowercased() != "localhost" else { return path }
        return "//" + host + path
    }

    /// The file `path` names: itself when it is absolute, else read from `folder`.
    func url(for path: String, in folder: URL, directoryHint: URL.DirectoryHint = .inferFromPath) -> URL {
        if isAbsolute(path) { return URL(filePath: path, directoryHint: directoryHint) }
        return folder.appending(path: isWindows ? path.replacingOccurrences(of: "\\", with: "/") : path,
                                directoryHint: directoryHint)
    }

    // MARK: - Reading a path

    private func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "/" || (isWindows && scalar == "\\")
    }

    /// An absolute path's root (none on POSIX; a drive, or a share's server and name, on Windows) and its names with
    /// `.` and `..` taken out; nil when `path` is not absolute.
    private func parsed(_ path: String) -> (root: [String], names: [String])? {
        let pieces = names(path)
        guard isWindows else {
            guard pieces.count > 1, pieces[0].isEmpty else { return nil }
            return ([], Self.lexical(pieces.dropFirst()))
        }
        guard pieces.count > 1 else { return nil }
        // `C:\x`
        if Self.isDrive(pieces[0]) { return ([pieces[0]], Self.lexical(pieces.dropFirst())) }
        guard pieces[0].isEmpty else { return nil }
        // `/C:/x`, as a file URL's path writes `C:\x`; `\x` alone is the current drive's root.
        if !pieces[1].isEmpty {
            return Self.isDrive(pieces[1]) ? ([pieces[1]], Self.lexical(pieces.dropFirst(2))) : nil
        }
        guard pieces.count > 3, !pieces[2].isEmpty, !pieces[3].isEmpty else { return nil }
        // `\\?\` and `\\.\`: a drive, a share (`UNC\server\share`) or another device after them.
        if pieces[2] == "?" || pieces[2] == "." {
            let rest = pieces.dropFirst(3)
            if Self.isDrive(pieces[3]) { return ([pieces[3]], Self.lexical(rest.dropFirst())) }
            if Self.folded(pieces[3]) == Self.folded("UNC") {
                guard pieces.count > 5, !pieces[4].isEmpty, !pieces[5].isEmpty else { return nil }
                return (["\\\\", pieces[4], pieces[5]], Self.lexical(pieces.dropFirst(6)))
            }
            return (["\\\\" + pieces[2], pieces[3]], Self.lexical(rest.dropFirst()))
        }
        // `\\server\share\x`
        return (["\\\\", pieces[2], pieces[3]], Self.lexical(pieces.dropFirst(4)))
    }

    /// `C:`: one ASCII letter and a colon.
    private static func isDrive(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        return scalars.count == 2 && scalars[0].isASCII && scalars[0].properties.isAlphabetic && scalars[1] == ":"
    }

    /// The names without the empty ones, `.`, and each `..` with the name before it; a `..` at the root stays there.
    private static func lexical<Names: Sequence<String>>(_ pieces: Names) -> [String] {
        var names: [String] = []
        for piece in pieces where !piece.isEmpty && piece != "." {
            if piece == ".." {
                _ = names.popLast()
            } else {
                names.append(piece)
            }
        }
        return names
    }

    private func same(_ first: String, _ second: String) -> Bool {
        isWindows ? Self.folded(first) == Self.folded(second) : first == second
    }

    /// A Windows name as NTFS compares it: each UTF-16 character in its upper case where that is one character too,
    /// and no other change, so names that differ in their composition stay different.
    private static func folded(_ name: String) -> [Unicode.Scalar] {
        name.unicodeScalars.map { scalar in
            if scalar.isASCII {
                return (0x61...0x7A).contains(scalar.value) ? Unicode.Scalar(UInt8(scalar.value) - 0x20) : scalar
            }
            guard scalar.value <= 0xFFFF else { return scalar }
            let upper = scalar.properties.uppercaseMapping.unicodeScalars
            guard upper.count == 1, let single = upper.first, single.value <= 0xFFFF else { return scalar }
            return single
        }
    }
}
