import AppKit

extension NSTextView {
    /// Lets go of what TextKit 2 built in the text view, for the view that owns it to call as it goes
    /// away. On macOS 27 a TextKit 2 text view that is let go leaves behind the views it draws its
    /// lines, selection and rendering surfaces in, and with them its layout manager and every line it
    /// laid out: each message of a conversation opened again was built anew and left its laid-out text,
    /// so the app grew by gigabytes over a long session. Parted from its container first, the layout
    /// goes with the text view. The text view's own `deinit` is too late for it.
    func releaseTextKitLayout() {
        textLayoutManager?.textContainer = nil
    }
}
