import Foundation

/// The navigation buttons an Android panel offers, sent as the device's own keys (`android.view.KeyEvent`).
enum AndroidNavigationButton: String, CaseIterable, Sendable {
    case back
    case home
    case recents

    var keycode: UInt32 {
        switch self {
        case .back: 4 // KEYCODE_BACK
        case .home: 3 // KEYCODE_HOME
        case .recents: 187 // KEYCODE_APP_SWITCH
        }
    }
}

/// The size and density of an Android device's screen, from `wm size; wm density`, which give the screen in its
/// natural orientation and an override, if one is set, after the physical values.
struct AndroidDisplayMetrics: Equatable, Sendable {
    var width: Int
    var height: Int
    /// Dots per inch; 160 is one pixel per dp.
    var density: Int

    /// The adb shell command whose output `parse(_:)` reads.
    static let shellCommand = "wm size; wm density"

    static func parse(_ output: String) -> AndroidDisplayMetrics? {
        var size: (width: Int, height: Int)?
        var density: Int?
        var sizeIsOverride = false
        var densityIsOverride = false
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let isOverride = parts[0].hasPrefix("Override")
            if parts[0].hasSuffix("size"), !sizeIsOverride || isOverride {
                let sides = parts[1].split(separator: "x").compactMap { Int($0) }
                guard sides.count == 2, sides.allSatisfy({ $0 > 0 }) else { continue }
                size = (sides[0], sides[1])
                sizeIsOverride = isOverride
            } else if parts[0].hasSuffix("density"), !densityIsOverride || isOverride,
                      let value = Int(parts[1]), value > 0 {
                density = value
                densityIsOverride = isOverride
            }
        }
        guard let size, let density else { return nil }
        return AndroidDisplayMetrics(width: size.width, height: size.height, density: density)
    }

    /// The screen in dp, turned as a frame of `frameWidth` × `frameHeight` is: the size agent screenshots are given
    /// in, so that their pixels are the coordinates agents use (as an iOS screenshot is given in points).
    func dpSize(frameWidth: Int, frameHeight: Int) -> (width: Int, height: Int) {
        let scale = 160 / Double(density)
        let long = max(1, Int((Double(max(width, height)) * scale).rounded()))
        let short = max(1, Int((Double(min(width, height)) * scale).rounded()))
        return frameWidth > frameHeight ? (long, short) : (short, long)
    }
}

extension ScrcpyPosition {
    /// A point given as fractions of the screen's width and height from its top left corner, in the pixels of a
    /// frame of `frameWidth` × `frameHeight`: the stream's current frame, whose size the server checks.
    init(fractionX x: Double, y: Double, frameWidth: Int, frameHeight: Int) {
        func pixel(_ fraction: Double, _ size: Int) -> Int32 {
            let last = Double(max(size - 1, 0))
            return Int32(min(max((fraction.isFinite ? fraction : 0) * Double(size), 0), last).rounded(.down))
        }
        self.init(x: pixel(x, frameWidth), y: pixel(y, frameHeight),
                  screenWidth: UInt16(clamping: frameWidth), screenHeight: UInt16(clamping: frameHeight))
    }
}

extension ScrcpyServer {
    /// The server file's name in the app's resources (`Contents/Resources` on a Mac, put there by
    /// `scripts/build-app.sh`, which pins the same release).
    static let resourceName = "scrcpy-server"

    static func bundledFile(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: nil)
    }
}
