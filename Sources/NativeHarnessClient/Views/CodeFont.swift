import AppKit
import CoreText
import SwiftUI

/// The code font Settings › Appearance chose (`CodeFontPreference`), which code blocks, diffs, command output, open
/// files and the terminal draw their code in. A view keeps the size it drew code at with the standard font and asks
/// here for it at the chosen size, so the default, the system's monospaced face at 12 points, draws everything as
/// before. A window reads the preference once and hands it down (`yardletCodeFont`), as it does the interface size.
struct YardletCodeFont: Equatable {
    /// A font family's name; empty for the system's monospaced face.
    var name = ""
    var points = CodeFontPreference.standardSize

    static let standard = YardletCodeFont()

    /// `points`, a size a view drew code at with the standard font, at the chosen size and the interface scale.
    func size(_ standardPoints: CGFloat, scale: CGFloat = 1) -> CGFloat {
        standardPoints * CGFloat(points) / CGFloat(CodeFontPreference.standardSize) * scale
    }

    /// The chosen face at `size`, or the system's monospaced one where none is chosen or the chosen one is not
    /// installed.
    func nsFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard !name.isEmpty else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: name, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        // A family that is not installed comes back as another face; that one is not the code font.
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == name else {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return font
    }

    func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        guard !name.isEmpty else { return .system(size: size, weight: Font.Weight(weight), design: .monospaced) }
        return Font(nsFont(ofSize: size, weight: weight) as CTFont)
    }

    /// The monospaced families installed on this Mac, as the code font menu lists them after the system's face.
    /// Core Text matches them in a few milliseconds; reading each family's members from `NSFontManager` took
    /// most of a second.
    static func installedFamilies() -> [String] {
        let monospaced = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]
        ] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([monospaced] as CFArray, nil)
        let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        return Set(matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight.rawValue {
        case ..<NSFont.Weight.light.rawValue: self = .thin
        case ..<NSFont.Weight.regular.rawValue: self = .light
        case ..<NSFont.Weight.medium.rawValue: self = .regular
        case ..<NSFont.Weight.semibold.rawValue: self = .medium
        case ..<NSFont.Weight.bold.rawValue: self = .semibold
        default: self = .bold
        }
    }
}

private struct YardletCodeFontKey: EnvironmentKey {
    static let defaultValue = YardletCodeFont.standard
}

extension EnvironmentValues {
    var yardletCodeFont: YardletCodeFont {
        get { self[YardletCodeFontKey.self] }
        set { self[YardletCodeFontKey.self] = newValue }
    }
}
