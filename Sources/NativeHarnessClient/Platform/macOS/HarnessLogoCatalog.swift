import AppKit
import Foundation
import SwiftUI

@MainActor
enum HarnessLogoCatalog {
    private static var cache: [HarnessKind: NSImage] = [:]

    static func image(for harness: HarnessKind) -> NSImage? {
        if let cached = cache[harness] { return cached }
        guard let name = HarnessLogoAsset.name(for: harness) else { return nil }
        // Do not evaluate Bundle.module until the packaged resources have been tried.
        // Its SwiftPM fallback points into the developer's build directory.
        func load(from bundle: Bundle) -> NSImage? {
            let url = bundle.url(
                forResource: name,
                withExtension: "png",
                subdirectory: HarnessLogoAsset.subdirectory
            ) ?? bundle.url(forResource: name, withExtension: "png")
            if let url, let image = NSImage(contentsOf: url) {
                return image
            }
            return nil
        }
        let image = load(from: .main) ?? load(from: .module)
        if let image { cache[harness] = image }
        return image
    }

    /// `image(for:)` with a logical size of `size` points.
    ///
    /// AppKit-backed menus read the NSImage's logical size, ignoring SwiftUI's frame. Copy the
    /// image so menu sizing cannot change the cached mark used by larger surfaces.
    static func icon(for harness: HarnessKind, size: CGFloat) -> NSImage? {
        guard let icon = image(for: harness)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}

struct HarnessIdentityIcon: View {
    let harness: HarnessKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = HarnessLogoCatalog.icon(for: harness, size: size) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: harness.symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A harness name is distinct from its current model or account. Use the catalog's full name
/// with the same packaged mark everywhere the user chooses or identifies a harness.
struct HarnessIdentityLabel: View {
    let harness: HarnessKind
    var size: CGFloat = 16
    /// The mark alone where a header has no room for the name.
    var showsName = true

    var body: some View {
        HStack(spacing: 6) {
            HarnessIdentityIcon(harness: harness, size: size)
            if showsName {
                Text(harness.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(harness.displayName)
        .help(harness.displayName)
    }
}
