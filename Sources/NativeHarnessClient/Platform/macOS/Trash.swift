import Foundation

/// The Trash, where Yardlet puts what it deletes so the person can still restore it.
enum Trash {
    static func move(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
