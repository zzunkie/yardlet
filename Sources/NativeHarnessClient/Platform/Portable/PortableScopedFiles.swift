import Foundation

// File access that must not follow a link swapped in beneath a folder. Each platform builds it on
// its own no-follow primitives (Platform/macOS: openat with O_NOFOLLOW; Platform/Windows: names
// opened as themselves, reparse points refused). Foundation alone cannot promise that, so here
// nothing is read through them.

/// Files beneath `root`, reached without following links: none here.
struct ScopedFiles {
    let root: URL
    func isDirectory(_ path: [String]) -> Bool { false }
    func isRegularFile(_ path: [String]) -> Bool { false }
    func directories(_ path: [String], limit: Int) throws -> [String] { [] }
    func names(_ path: [String], limit: Int) throws -> [String] { [] }
    func openRegularFile(_ path: [String]) -> OpenFile? { nil }
}
