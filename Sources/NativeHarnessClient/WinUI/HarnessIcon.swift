import Foundation
import WindowsFoundation
import WinUI

/// A harness's packaged mark (`HarnessLogoAsset`, the PNGs the Mac shows), beside its name in New task and at the
/// start of its tasks' rows, as the Mac's sidebar and harness menu show it. A harness without a mark shows none.
@MainActor
enum HarnessIcon {
    /// Each harness's file, looked up once.
    private static var files: [HarnessKind: URL?] = [:]

    static func element(for harness: HarnessKind, size: Double = 16) -> BitmapIcon? {
        guard let file = file(for: harness) else { return nil }
        let icon = BitmapIcon()
        icon.showAsMonochrome = false
        icon.uriSource = Uri(file.absoluteString)
        icon.width = size
        icon.height = size
        return icon
    }

    /// The app's resources first, as on the Mac, then the package's resource bundle beside the executable.
    private static func file(for harness: HarnessKind) -> URL? {
        if let known = files[harness] { return known }
        let file = HarnessLogoAsset.name(for: harness).flatMap { name in
            [Bundle.main, Bundle.module].lazy.compactMap { bundle in
                bundle.url(forResource: name, withExtension: "png", subdirectory: HarnessLogoAsset.subdirectory)
                    ?? bundle.url(forResource: name, withExtension: "png")
            }.first
        }
        files[harness] = file
        return file
    }
}
