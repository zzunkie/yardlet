import Foundation
import UWP
@preconcurrency import WindowsFoundation
import WinUI

/// A picture the app carries in its resources (the harnesses' marks, Yardlet's own), read from its file into a bitmap
/// that every place showing it shares. The file is read rather than named by a `file:` URI, which XAML does not load
/// from a folder whose path holds characters beyond ASCII, such as a user folder with a Korean name: there the
/// harnesses' marks were missing.
@MainActor
enum PackagedImage {
    /// Each file's bitmap, looked up and read once.
    private static var bitmaps: [String: BitmapImage?] = [:]

    /// The PNG named `name` in the app's resources, or nil when the app does not carry it. The bitmap shows its
    /// picture once the file has been read.
    static func bitmap(named name: String, subdirectory: String? = nil) -> BitmapImage? {
        let key = (subdirectory.map { $0 + "/" } ?? "") + name
        if let known = bitmaps[key] { return known }
        guard let file = file(named: name, subdirectory: subdirectory) else {
            bitmaps[key] = .some(nil)
            return nil
        }
        let bitmap = BitmapImage()
        bitmaps[key] = bitmap
        Task { await read(file, into: bitmap) }
        return bitmap
    }

    /// A picture from any file, such as an image a message carries, decoded at most `height` pixels high. It is read
    /// as the app's own pictures are, so a file in a folder whose path holds characters beyond ASCII shows too.
    static func thumbnail(of file: URL, height: Int32) -> BitmapImage {
        let bitmap = BitmapImage()
        bitmap.decodePixelHeight = height
        Task { await read(file, into: bitmap) }
        return bitmap
    }

    /// The app's resources first, as on the Mac, then the package's resource bundle beside the executable.
    private static func file(named name: String, subdirectory: String?) -> URL? {
        [Bundle.main, Bundle.module].lazy.compactMap { bundle in
            bundle.url(forResource: name, withExtension: "png", subdirectory: subdirectory)
                ?? bundle.url(forResource: name, withExtension: "png")
        }.first
    }

    private static func read(_ file: URL, into bitmap: BitmapImage) async {
        do {
            guard let opened = try await StorageFile.getFileFromPathAsync(file.nativePath)?.get(),
                  let stream = try await opened.openAsync(.read)?.get() else { return }
            try await bitmap.setSourceAsync(stream)?.get()
        } catch {
            QAEventLog.shared.write("image not read: \(file.lastPathComponent): \(error)")
        }
    }
}
