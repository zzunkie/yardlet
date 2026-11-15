import SwiftUI
import UIKit
import YardletRemote

/// The watched tab's picture (docs/REMOTE_PROTOCOL.md §15.25), fitted to the page area at its top and zoomed and moved
/// with two fingers. A tap is a click at that point of the page, a second tap soon after at the same place a click with
/// `clickCount` 2, and one finger's drag scrolls the page, or drags on it when `isDragging` is on. While the keyboard
/// covers `covered` points of the area's bottom, the picture moves up so the place last tapped stays in sight.
struct TabPage: UIViewRepresentable {
    let tabID: String?
    let picture: TaskBrowser.Picture?
    let isDragging: Bool
    let covered: CGFloat
    let label: String
    let tap: (_ x: Double, _ y: Double, _ count: Int) -> Void
    let scroll: (_ x: Double, _ y: Double, _ deltaX: Double, _ deltaY: Double) -> Void
    let mouse: (_ action: String, _ x: Double, _ y: Double) -> Void

    func makeUIView(context: Context) -> TabPageView {
        TabPageView()
    }

    func updateUIView(_ view: TabPageView, context: Context) {
        view.tap = tap
        view.scroll = scroll
        view.mouse = mouse
        view.isDragging = isDragging
        view.accessibilityLabel = label
        view.show(picture, of: tabID)
        view.covered = covered
    }
}

final class TabPageView: UIView, UIGestureRecognizerDelegate {
    var tap: (Double, Double, Int) -> Void = { _, _, _ in }
    var scroll: (Double, Double, Double, Double) -> Void = { _, _, _, _ in }
    var mouse: (String, Double, Double) -> Void = { _, _, _ in }
    var isDragging = false
    /// How much of the area's bottom the keyboard covers.
    var covered: CGFloat = 0 {
        didSet { if covered != oldValue { moveForKeyboard() } }
    }

    private let imageView = UIImageView()
    private var shown: UIImage?
    private var tabID: String?
    /// The page's visible size in CSS pixels, as the last picture gave it.
    private var viewport = CGSize.zero
    private var laidOut = CGSize.zero
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero
    /// How far the picture moved up for the keyboard.
    private var shift: CGFloat = 0
    /// The last tap's height in the area, before any move for the keyboard.
    private var tappedAt: CGFloat?
    private var lastTap: (time: CFTimeInterval, point: CGPoint)?
    private var lastPinch: CGPoint?
    private var dragsPage = false
    private var lastMove: CFTimeInterval = 0
    private let pinch: UIPinchGestureRecognizer

    static let maxZoom: CGFloat = 5
    /// The place tapped goes about a third down what stays in sight over the keyboard, so the fields under it show too.
    static let keyboardAnchor: CGFloat = 0.35
    static let doubleTapInterval: CFTimeInterval = 0.35
    static let doubleTapDistance: CGFloat = 24
    /// A drag's moves, about twenty a second.
    static let dragInterval: CFTimeInterval = 0.05

    init() {
        pinch = UIPinchGestureRecognizer()
        super.init(frame: .zero)
        clipsToBounds = true
        imageView.contentMode = .scaleToFill
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .allowsDirectInteraction]

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pinch.addTarget(self, action: #selector(pinched(_:)))
        pinch.delegate = self
        [tapRecognizer, pan, pinch].forEach(addGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ picture: TaskBrowser.Picture?, of tabID: String?) {
        let size = picture.map { CGSize(width: $0.viewportWidth, height: $0.viewportHeight) } ?? viewport
        // Another tab, or a page of another size (the phone turned), starts fitted again.
        if tabID != self.tabID {
            self.tabID = tabID
            tappedAt = nil
            lastTap = nil
            shift = 0
            scale = 1
            offset = .zero
        }
        if size != viewport {
            viewport = size
            scale = 1
            offset = .zero
        }
        if picture?.image !== shown {
            shown = picture?.image
            imageView.image = shown
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOut {
            laidOut = bounds.size
            scale = 1
            offset = .zero
        }
        place()
    }

    // MARK: - Geometry

    /// Points per CSS pixel before zooming.
    private var fit: CGFloat {
        guard viewport.width > 0, viewport.height > 0, bounds.width > 0, bounds.height > 0 else { return 0 }
        return min(bounds.width / viewport.width, bounds.height / viewport.height)
    }

    private var baseLeft: CGFloat { (bounds.width - viewport.width * fit) / 2 }

    private var drawn: CGRect {
        CGRect(x: baseLeft + offset.x, y: offset.y - shift, width: viewport.width * fit * scale,
               height: viewport.height * fit * scale)
    }

    private func place() {
        UIView.performWithoutAnimation { imageView.frame = shown == nil || fit <= 0 ? .zero : drawn }
    }

    /// The page's CSS point under a point of the area, or nil off the picture.
    private func page(_ point: CGPoint) -> CGPoint? {
        guard fit > 0, let held = pageHeld(point) else { return nil }
        let rect = drawn
        return rect.contains(point) ? held : nil
    }

    /// As `page`, held to the page's edges: where a drag or a scroll that left the picture is.
    private func pageHeld(_ point: CGPoint) -> CGPoint? {
        guard fit > 0 else { return nil }
        let rect = drawn
        let x = (point.x - rect.minX) / (fit * scale)
        let y = (point.y - rect.minY) / (fit * scale)
        return CGPoint(x: min(max(x, 0), viewport.width), y: min(max(y, 0), viewport.height))
    }

    /// An offset that keeps a zoomed picture over the area, and an unzoomed one in place.
    private func held(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        let width = viewport.width * fit * scale
        let height = viewport.height * fit * scale
        let x = width <= bounds.width ? (bounds.width - width) / 2 - baseLeft
            : min(max(offset.x, bounds.width - width - baseLeft), -baseLeft)
        let y = height <= bounds.height ? 0 : min(max(offset.y, bounds.height - height), 0)
        return CGPoint(x: x, y: y)
    }

    private func moveForKeyboard() {
        let target: CGFloat = if let tappedAt, covered > 0 {
            min(max(tappedAt - (bounds.height - covered) * Self.keyboardAnchor, 0), covered)
        } else {
            0
        }
        guard target != shift else { return }
        shift = target
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.imageView.frame = self.shown == nil || self.fit <= 0 ? .zero : self.drawn
        }
    }

    // MARK: - Gestures

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let target = page(point) else { return }
        let now = CACurrentMediaTime()
        let second = lastTap.map {
            now - $0.time < Self.doubleTapInterval && hypot(point.x - $0.point.x, point.y - $0.point.y) < Self.doubleTapDistance
        } ?? false
        tap(target.x, target.y, second ? 2 : 1)
        // A third tap starts a new pair.
        lastTap = second ? nil : (now, point)
        tappedAt = point.y + shift
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        let pinching = pinch.state == .began || pinch.state == .changed
        switch recognizer.state {
        case .began:
            let moved = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            if isDragging, !pinching, let start = page(CGPoint(x: point.x - moved.x, y: point.y - moved.y)) {
                mouse("down", start.x, start.y)
                dragsPage = true
                lastMove = 0
            } else if !isDragging {
                scrollPage(by: moved, at: point)
            }
        case .changed:
            if pinching {
                endDrag(at: point)
                return
            }
            if dragsPage {
                let now = CACurrentMediaTime()
                guard now - lastMove >= Self.dragInterval, let at = pageHeld(point) else { return }
                lastMove = now
                mouse("move", at.x, at.y)
            } else if !isDragging {
                let moved = recognizer.translation(in: self)
                recognizer.setTranslation(.zero, in: self)
                scrollPage(by: moved, at: point)
            }
        default:
            endDrag(at: point)
        }
    }

    /// A finger moving up scrolls the page down: the movement in CSS pixels, its sign reversed.
    private func scrollPage(by moved: CGPoint, at point: CGPoint) {
        guard fit > 0, let at = pageHeld(point) else { return }
        let perPoint = 1 / (fit * scale)
        scroll(at.x, at.y, -moved.x * perPoint, -moved.y * perPoint)
    }

    private func endDrag(at point: CGPoint) {
        guard dragsPage else { return }
        dragsPage = false
        if let at = pageHeld(point) { mouse("up", at.x, at.y) }
    }

    /// Two fingers zoom the picture about their middle and move it, on the phone alone.
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard fit > 0 else { return }
        let centroid = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPinch = centroid
        case .changed:
            let pan = recognizer.numberOfTouches >= 2 ? lastPinch.map { CGPoint(x: centroid.x - $0.x, y: centroid.y - $0.y) }
                ?? .zero : .zero
            lastPinch = recognizer.numberOfTouches >= 2 ? centroid : nil
            let newScale = min(max(scale * recognizer.scale, 1), Self.maxZoom)
            recognizer.scale = 1
            let base = CGPoint(x: baseLeft, y: -shift)
            let local = CGPoint(x: (centroid.x - base.x - offset.x) / scale, y: (centroid.y - base.y - offset.y) / scale)
            offset = held(CGPoint(x: centroid.x - base.x - local.x * newScale + pan.x,
                                  y: centroid.y - base.y - local.y * newScale + pan.y), scale: newScale)
            scale = newScale
            place()
        default:
            lastPinch = nil
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Lets the screen act on the typing field: commit what the keyboard composes before a tap, empty it, or put the
/// keyboard away.
@MainActor
final class TabTyping {
    fileprivate weak var field: TabTypingTextField?

    /// What the field holds goes to the page now, composing or not, and the field empties: a tap moves on.
    func commit() { field?.commitAll() }

    /// Empties the field without sending what it holds: another tab, or the page's field changed.
    func clear() { field?.clear() }

    /// What was typed goes to the page, and the keyboard goes down.
    func endTyping() {
        field?.commitAll()
        field?.resignFirstResponder()
    }
}

/// The phone's own field under the tab's picture (§15.25), a UIKit field so the keyboard's commits, its composition
/// (`markedTextRange`) and its keys can be told apart: committed text goes to the page as `text`, and Return, Backspace
/// on an empty field and Tab as keys. While the page's focused field is a password field, it hides what it shows, takes
/// no corrections or suggestions, and the keyboard learns nothing from it. It keeps nothing: emptied when it leaves the
/// screen, and never saved.
struct TabTypingField: UIViewRepresentable {
    let typing: TabTyping
    let isPassword: Bool
    let placeholder: String
    let typed: (TypedText.Typed) -> Void
    let key: (String) -> Void
    /// Whether the keyboard is up for the field.
    let editing: (Bool) -> Void

    func makeUIView(context: Context) -> TabTypingTextField {
        let field = TabTypingTextField()
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: TabTypingTextField, context: Context) {
        typing.field = field
        field.typed = typed
        field.key = key
        field.editingChanged = editing
        field.isPassword = isPassword
        field.isEnabled = context.environment.isEnabled
        if field.placeholder != placeholder { field.placeholder = placeholder }
    }

    static func dismantleUIView(_ field: TabTypingTextField, coordinator: ()) {
        field.clear()
    }
}

final class TabTypingTextField: UITextField, UITextFieldDelegate {
    var typed: (TypedText.Typed) -> Void = { _ in }
    var key: (String) -> Void = { _ in }
    var editingChanged: (Bool) -> Void = { _ in }
    var isPassword = false {
        didSet {
            guard isPassword != oldValue else { return }
            clear()
            isSecureTextEntry = isPassword
            if isFirstResponder { reloadInputViews() }
        }
    }

    private var sent = TypedText()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        // What the person types is what the page gets: no capitals, corrections or smart punctuation of the phone's.
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        enablesReturnKeyAutomatically = false
        addTarget(self, action: #selector(edited), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func edited() { read() }

    /// What the field holds now, against what the page has; with `committing`, all of it, composing or not.
    private func read(committing: Bool = false) {
        let text = text ?? ""
        let composing = committing ? nil : markedTextRange.map { offset(from: beginningOfDocument, to: $0.start) }
        // iOS's Korean keyboard marks nothing: it replaces the last syllable as its letters join.
        let inPlace = !committing && textInputMode?.primaryLanguage?.hasPrefix("ko") == true
        for item in sent.changed(text, composingFrom: composing, composesInPlace: inPlace) { typed(item) }
    }

    func commitAll() {
        if markedTextRange != nil { unmarkText() }
        read(committing: true)
        clear()
    }

    func clear() {
        sent.reset()
        if text?.isEmpty == false { text = "" }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // A password field empties itself on the next key once it is left: start from nothing, so the page keeps what
        // it has.
        if isSecureTextEntry { clear() }
        editingChanged(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        editingChanged(false)
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        // The caret stays at the end, where the page's is.
        if markedTextRange == nil, let selected = selectedTextRange,
           offset(from: selected.start, to: endOfDocument) != 0 || offset(from: selected.end, to: endOfDocument) != 0 {
            selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
        }
        read()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commitAll()
        key("Enter")
        return false
    }

    /// Deleting before the start of the field is deleting on the page.
    override func deleteBackward() {
        if text?.isEmpty != false {
            key("Backspace")
        } else {
            super.deleteBackward()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabForward))
        let back = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(tabBackward))
        tab.wantsPriorityOverSystemBehavior = true
        back.wantsPriorityOverSystemBehavior = true
        return [tab, back]
    }

    @objc private func tabForward() {
        commitAll()
        key("Tab")
    }

    @objc private func tabBackward() {
        commitAll()
        key("Shift+Tab")
    }
}
