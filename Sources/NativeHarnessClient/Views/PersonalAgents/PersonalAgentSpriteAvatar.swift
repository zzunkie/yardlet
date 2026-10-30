import AppKit
import ImageIO
import QuartzCore
import SwiftUI

/// A dot's animated form: its pet's idle or working row played by Core Animation on one layer, in the
/// square its still picture fills. SwiftUI lays it out once; no view state changes as it plays. The
/// working row plays only while the dot's room says it is at work; a motion given again does not
/// restart it.
struct PersonalAgentSpriteAvatar: NSViewRepresentable {
    let frames: PersonalAgentSpriteFrames
    var motion: PersonalAgentSpriteLayout.Motion = .idle
    let size: CGFloat

    func makeNSView(context: Context) -> PersonalAgentSpriteView { PersonalAgentSpriteView() }

    func updateNSView(_ view: PersonalAgentSpriteView, context: Context) {
        view.show(frames, motion: motion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PersonalAgentSpriteView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// The two rows a dot plays, cut from its sheet once and shared by every view of it, with where the pet
/// sits in its frame. The pet's place is measured once, on the idle row's first cell, and kept for
/// every frame so it does not shift from one to the next.
final class PersonalAgentSpriteFrames: @unchecked Sendable {
    /// The idle row over the working row, at the sheet's resolution.
    let atlas: CGImage
    /// Where a 192 x 208 frame's cell is drawn, in that frame's points from its top left: the pet
    /// enlarged up to 1.5 times and centred.
    let placement: CGRect
    /// The idle row's first frame, placed as it plays, in a 208-pixel square: the still pet beside
    /// each message and with Reduce Motion, one image for every view of it.
    let still: CGImage

    private static let motions = PersonalAgentSpriteLayout.Motion.allCases

    /// Reads a sheet of one of the two known sizes; anything else is not decoded.
    init?(data: Data) {
        typealias Layout = PersonalAgentSpriteLayout
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == Layout.sheetWidth,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, Layout.sheetHeights.contains(height),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              sheet.width == Layout.sheetWidth, sheet.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let cell = (width: Layout.cellWidth, height: Layout.cellHeight)
        let width = Layout.sheetWidth, rows = Self.motions.count
        guard let context = CGContext(data: nil, width: width, height: rows * cell.height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (index, motion) in Self.motions.enumerated() {
            guard let row = sheet.cropping(to: CGRect(x: 0, y: motion.row * cell.height, width: width, height: cell.height))
            else { return nil }
            context.draw(row, in: CGRect(x: 0, y: (rows - 1 - index) * cell.height, width: width, height: cell.height))
        }
        guard let atlas = context.makeImage(), let pixels = context.data else { return nil }
        self.atlas = atlas

        // The idle row's first cell: the first rows of the bitmap, which holds the image's top first.
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        var minX = cell.width, minY = cell.height, maxX = -1, maxY = -1
        for y in 0..<cell.height {
            for x in 0..<cell.width where bytes[y * width * 4 + x * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let bounds = maxX < 0 ? CGRect(x: 0, y: 0, width: cell.width, height: cell.height)
            : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let scale = min(CGFloat(cell.height) / max(bounds.width, bounds.height), Layout.maximumScale)
        let placement = CGRect(x: CGFloat(cell.width) / 2 - scale * bounds.midX,
                               y: CGFloat(cell.height) / 2 - scale * bounds.midY,
                               width: CGFloat(cell.width) * scale, height: CGFloat(cell.height) * scale)
        self.placement = placement
        let side = cell.height
        guard let first = atlas.cropping(to: CGRect(x: 0, y: 0, width: cell.width, height: cell.height)),
              let square = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        square.interpolationQuality = .none
        // The square counts up from its bottom; the placement counts down from the frame's top.
        square.draw(first, in: CGRect(x: CGFloat(side - cell.width) / 2 + placement.minX,
                                      y: CGFloat(side) - placement.maxY, width: placement.width, height: placement.height))
        guard let still = square.makeImage() else { return nil }
        self.still = still
    }

    /// The part of the atlas each of the motion's frames shows, in the atlas's unit square.
    func cells(for motion: PersonalAgentSpriteLayout.Motion) -> [CGRect] {
        typealias Layout = PersonalAgentSpriteLayout
        let index = Self.motions.firstIndex(of: motion) ?? 0
        let width = 1 / CGFloat(Layout.columns), height = 1 / CGFloat(Self.motions.count)
        // A layer's contents rectangle counts up from the image's bottom edge.
        let y = CGFloat(Self.motions.count - 1 - index) * height
        return motion.durations.indices.map { CGRect(x: CGFloat($0) * width, y: y, width: width, height: height) }
    }

    /// The motion's frames in turn, each for its own time, for as long as the layer has it.
    func animation(for motion: PersonalAgentSpriteLayout.Motion) -> CAKeyframeAnimation {
        let total = motion.durations.reduce(0, +)
        var start = 0.0
        var times: [NSNumber] = []
        for duration in motion.durations {
            times.append(NSNumber(value: start / total))
            start += duration
        }
        times.append(1)
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.values = cells(for: motion).map { NSValue(rect: $0) }
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// The frames for `sheet`, decoded once off the main thread and shared by every view of it; nil
    /// when the sheet is not one this reads. The decoding is held by the sheet itself, so it goes when
    /// the window lets the sheet go (another version, another account), and nothing else keeps it.
    @MainActor static func decoded(_ sheet: PersonalAgentSpriteSheet) async -> PersonalAgentSpriteFrames? {
        if let held = objc_getAssociatedObject(sheet, &decodingKey) as? Decoding { return await held.task.value }
        let data = sheet.data
        let decoding = Decoding(task: Task.detached(priority: .utility) { PersonalAgentSpriteFrames(data: data) })
        objc_setAssociatedObject(sheet, &decodingKey, decoding, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return await decoding.task.value
    }

    /// The one decoding of a sheet, finished or under way; a sheet it could not read stays nil.
    private final class Decoding {
        let task: Task<PersonalAgentSpriteFrames?, Never>
        init(task: Task<PersonalAgentSpriteFrames?, Never>) { self.task = task }
    }
}

@MainActor private var decodingKey: UInt8 = 0

/// The square a dot's frames play in, as the provider's app plays them: uncut, nothing behind them,
/// enlarged pixel by pixel. It plays only while it can be seen: in a window that is on
/// screen and not covered, with the app active, not hidden and not scrolled out of its list.
/// Otherwise the layer holds the motion's first frame and Core Animation does nothing for it. Its
/// frames change on the layer alone; SwiftUI sees nothing of them.
final class PersonalAgentSpriteView: NSView {
    private static let playKey = "Yardlet.sprite"
    private let sprite = CALayer()
    private var frames: PersonalAgentSpriteFrames?
    private(set) var motion: PersonalAgentSpriteLayout.Motion = .idle
    private var observers: [NSObjectProtocol] = []
    /// Whether the window can be seen now. Replaced only to check playback in a window that is not shown.
    var isOnScreen: (NSWindow) -> Bool = { window in
        NSApp.isActive && window.occlusionState.contains(.visible)
    }

    private var isSeen: Bool {
        guard let window, isOnScreen(window), !isHiddenOrHasHiddenAncestor else { return false }
        // Inside every list around it, not scrolled out of any.
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView, convert(bounds, to: clip).intersection(clip.bounds).isEmpty { return false }
            ancestor = view.superview
        }
        return true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.contentsGravity = .resize
        sprite.magnificationFilter = .nearest
        sprite.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ frames: PersonalAgentSpriteFrames, motion: PersonalAgentSpriteLayout.Motion) {
        guard frames !== self.frames || motion != self.motion else { return }
        self.frames = frames
        self.motion = motion
        sprite.contents = frames.atlas
        sprite.contentsRect = frames.cells(for: motion)[0]
        sprite.removeAnimation(forKey: Self.playKey)
        needsLayout = true
        updatePlayback()
    }

    var isPlaying: Bool { sprite.animation(forKey: Self.playKey) != nil }

    /// The frame's height fills the square and its width is centred; the pet sits where its placement puts it.
    override func layout() {
        super.layout()
        guard let frames else { return }
        let side = min(bounds.width, bounds.height)
        let unit = side / CGFloat(PersonalAgentSpriteLayout.cellHeight)
        let inset = (bounds.width - CGFloat(PersonalAgentSpriteLayout.cellWidth) * unit) / 2
        let place = frames.placement
        // The backing layer counts up from the bottom; the placement counts down from the top.
        let height = place.height * unit
        sprite.frame = CGRect(x: inset + place.minX * unit, y: bounds.height - place.minY * unit - height,
                              width: place.width * unit, height: height)
        updatePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let center = NotificationCenter.default
            let update: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: update),
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: update),
                center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: update),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: update)
            ]
            // A list scrolling the view out of sight, or back.
            var scrollView = enclosingScrollView
            while let clip = scrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                    queue: .main, using: update))
                scrollView = scrollView?.enclosingScrollView
            }
        }
        updatePlayback()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePlayback()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePlayback()
    }

    func updatePlayback() {
        guard let frames, isSeen else {
            sprite.removeAnimation(forKey: Self.playKey)
            return
        }
        guard !isPlaying else { return }
        sprite.add(frames.animation(for: motion), forKey: Self.playKey)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
