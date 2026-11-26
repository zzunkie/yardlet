import AppKit
import Foundation
import SwiftUI

@MainActor
enum HarnessLogoCatalog {
    private static var cache: [String: NSImage] = [:]

    /// The harness's packaged mark, the light one.
    static func image(for harness: HarnessKind) -> NSImage? {
        image(for: harness, isDark: false)
    }

    /// The harness's mark for a light or dark appearance. A harness whose app has a dark mark shows it on a dark
    /// appearance, where its light plate would stand out as a bright tile; any other keeps one mark for both.
    static func image(for harness: HarnessKind, isDark: Bool) -> NSImage? {
        if isDark, let darkName = HarnessLogoAsset.darkName(for: harness), let dark = packagedImage(named: darkName) {
            return dark
        }
        return HarnessLogoAsset.name(for: harness).flatMap(packagedImage(named:))
    }

    /// The harness's mark for a SwiftUI color scheme.
    static func image(for harness: HarnessKind, colorScheme: ColorScheme) -> NSImage? {
        image(for: harness, isDark: colorScheme == .dark)
    }

    /// A mark that picks the light or dark one when AppKit draws it, for a menu or the menu bar, whose
    /// appearance the caller does not know when it makes the image.
    static func adaptiveImage(for harness: HarnessKind) -> NSImage? {
        guard let light = image(for: harness, isDark: false) else { return nil }
        guard let dark = image(for: harness, isDark: true), dark !== light else { return light }
        return NSImage(size: light.size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
    }

    private static func packagedImage(named name: String) -> NSImage? {
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
        if let cached = cache[name] { return cached }
        let image = load(from: .main) ?? load(from: .module)
        if let image { cache[name] = image }
        return image
    }

    /// The mark with a logical size of `size` points: for `isDark`, or, without it, the adaptive mark a menu draws.
    ///
    /// AppKit-backed menus read the NSImage's logical size, ignoring SwiftUI's frame. Copy the
    /// image so menu sizing cannot change the cached mark used by larger surfaces.
    static func icon(for harness: HarnessKind, size: CGFloat, isDark: Bool? = nil) -> NSImage? {
        let image = isDark.map { self.image(for: harness, isDark: $0) } ?? adaptiveImage(for: harness)
        guard let icon = image?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}

struct HarnessIdentityIcon: View {
    let harness: HarnessKind
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = HarnessLogoCatalog.icon(for: harness, size: size, isDark: colorScheme == .dark) {
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
