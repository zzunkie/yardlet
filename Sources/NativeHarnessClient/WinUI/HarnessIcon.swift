import Foundation
import WinUI

/// A harness's packaged mark (`HarnessLogoAsset`, the PNGs the Mac shows), beside its name in New task and at the
/// start of its tasks' rows, as the Mac's sidebar and harness menu show it. A harness without a mark shows none.
@MainActor
enum HarnessIcon {
    static func element(for harness: HarnessKind, size: Double = 16) -> ImageIcon? {
        guard let name = HarnessLogoAsset.name(for: harness),
              let bitmap = PackagedImage.bitmap(named: name, subdirectory: HarnessLogoAsset.subdirectory) else { return nil }
        let icon = ImageIcon()
        icon.source = bitmap
        icon.width = size
        icon.height = size
        return icon
    }
}
