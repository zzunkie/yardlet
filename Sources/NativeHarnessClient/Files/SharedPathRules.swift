import Foundation
import YardletRemote

/// The engine's path rules are the remote protocol's (`YardletRemote/PathRules.swift`), so every engine file reads
/// them under this name without importing that module.
typealias PathRules = YardletRemote.PathRules

extension URL {
    /// This file URL's path as this platform writes it (`PathRules.nativePath(of:)`), for a file API, a program's
    /// argument or environment, or a file another program reads. `path()` escapes it as a URL does
    /// (`Application%20Support`, a non-ASCII name in `%XX`), which names no file, and on Windows a URL's path starts
    /// `/C:/`, which no program there reads as absolute; this path is `C:\Users\me` there and `/Users/me` elsewhere.
    var nativePath: String { PathRules.current.nativePath(of: self) }
}
