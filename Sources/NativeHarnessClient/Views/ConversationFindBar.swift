import AppKit
import SwiftUI

private struct ConversationFindKey: EnvironmentKey {
    static let defaultValue: ConversationFindModel? = nil
}

private struct ConversationFindSlotKey: EnvironmentKey {
    static let defaultValue: ConversationFindSlot? = nil
}

extension EnvironmentValues {
    /// The find of the task whose conversation is drawn below.
    var conversationFind: ConversationFindModel? {
        get { self[ConversationFindKey.self] }
        set { self[ConversationFindKey.self] = newValue }
    }

    /// The marks of the message being drawn. Only sent and assistant messages carry one.
    var conversationFindSlot: ConversationFindSlot? {
        get { self[ConversationFindSlotKey.self] }
        set { self[ConversationFindSlotKey.self] = newValue }
    }
}

/// The Codex app's find bar: a field with a close button, and, once there is a query, previous and
/// next buttons with the count. It floats over the top trailing corner of the conversation.
struct ConversationFindBar: View {
    @Bindable var find: ConversationFindModel
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        if find.isPresented {
            card
                .transition(.opacity)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if find.isSearching {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                TextField(L10n.string("Search chat…"), text: $find.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFieldFocused)
                    .accessibilityLabel(L10n.string("Find in chat"))
                    .onSubmit {
                        // Shift-Return reaches here too if the key press handler below did not see it.
                        find.submit(backward: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift), !fieldHasMarkedText else { return .ignored }
                        find.submit(backward: true)
                        return .handled
                    }
                    .onExitCommand(perform: close)
                Rectangle()
                    .fill(ParityTheme.strongSeparator)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)
                iconButton("xmark", label: L10n.string("Close find"), action: close)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)

            if !find.normalizedQuery.isEmpty {
                HStack(spacing: 6) {
                    iconButton("chevron.up", label: L10n.string("Previous result"),
                               shortcut: ConversationFindShortcut.previous, action: find.previous)
                        .disabled(!find.hasMatches)
                    iconButton("chevron.down", label: L10n.string("Next result"),
                               shortcut: ConversationFindShortcut.next, action: find.next)
                        .disabled(!find.hasMatches)
                    Spacer(minLength: 8)
                    Text(statusText)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .padding(.leading, 9)
                .padding(.trailing, 14)
                .frame(height: 34)
                .overlay(alignment: .top) {
                    Rectangle().fill(ParityTheme.separator).frame(height: 1)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 340)
        .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(ParityTheme.strongSeparator, lineWidth: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .animation(ParityMotion.easeOut(reduceMotion: reduceMotion), value: find.normalizedQuery.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Find in chat"))
        .task(id: find.focusRequest) {
            // The field joins the window's focus system after the bar appears.
            await Task.yield()
            guard !Task.isCancelled, find.isPresented else { return }
            isFieldFocused = true
            await Task.yield()
            // ⌘F again selects the query to type over, as a find field does.
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
               editor.string == find.query {
                editor.selectAll(nil)
            }
        }
    }

    private var statusText: String {
        guard let result = find.currentResult else { return "" }
        guard !result.matches.isEmpty else { return L10n.string("0 results") }
        let active = Int64((find.activeIndex ?? 0) + 1)
        let count = Int64(result.matches.count)
        return result.isCapped
            ? L10n.format("%lld / %lld+ results", active, count)
            : L10n.format("%lld / %lld results", active, count)
    }

    private var fieldHasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private func close() {
        if !find.close() { keyboardFocus?.move(to: .chat) }
    }

    private func iconButton(_ systemName: String, label: String, shortcut: KeyboardShortcut? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .parityPointer()
        .accessibilityLabel(label)
        .help(ShortcutHelp.text(label, shortcut))
    }
}

/// Marks a query in a drawn text: every hit in yellow and the current one in orange, as the Codex
/// app does, keeping the text's own color.
enum ConversationFindStyle {
    static func matchColor(_ scheme: ColorScheme) -> Color {
        Color.yellow.opacity(scheme == .dark ? 0.34 : 0.42)
    }

    static func activeColor(_ scheme: ColorScheme) -> Color {
        Color.orange.opacity(scheme == .dark ? 0.78 : 0.62)
    }

    /// `matchColor` and `activeColor` for a message's text view.
    static func matchNSColor(isDark: Bool) -> NSColor {
        NSColor.systemYellow.withAlphaComponent(isDark ? 0.34 : 0.42)
    }

    static func activeNSColor(isDark: Bool) -> NSColor {
        NSColor.systemOrange.withAlphaComponent(isDark ? 0.78 : 0.62)
    }

    /// Marks `query` in `text` and returns where the current match sits, as a fraction of the text's
    /// height, when this text holds it. `byLine` places it by line, for code.
    static func mark(_ text: inout AttributedString, query: String?, active: ConversationFindLocation?,
                     key: ConversationFindSegmentKey, scheme: ColorScheme, byLine: Bool = false) -> Double? {
        guard let query, !query.isEmpty else { return nil }
        let plain = String(text.characters)
        let ranges = ConversationFindEngine.occurrences(of: query, in: plain)
        guard !ranges.isEmpty else { return nil }
        let current = active?.key == key ? active?.occurrence : nil
        var fraction: Double?
        for (index, range) in ranges.enumerated() {
            guard let marked = Range<AttributedString.Index>(range, in: text) else { continue }
            let isCurrent = index == current
            text[marked][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] =
                isCurrent ? activeColor(scheme) : matchColor(scheme)
            if isCurrent { fraction = position(of: range, in: plain as NSString, byLine: byLine) }
        }
        return fraction
    }

    private static func position(of range: NSRange, in text: NSString, byLine: Bool) -> Double {
        guard text.length > 0 else { return 0.5 }
        guard byLine else { return (Double(range.location) + Double(range.length) / 2) / Double(text.length) }
        let before = text.substring(to: range.location)
        let line = before.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
        let lines = (text as String).reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        return (Double(line) + 0.5) / Double(lines)
    }
}

enum ConversationFindAnchor {
    /// The one point in the conversation the find scrolls to: the current match.
    static let activeMatch = "conversation-find-active-match"
}

extension View {
    /// Places the scroll target for the current match at `fraction` of this view's height. The target
    /// also brings itself to the middle of the conversation when find goes to it, since a turn's
    /// views are out of the conversation's `ScrollViewReader`'s reach (`ConversationTurnHost`).
    func conversationFindAnchor(_ fraction: Double?) -> some View {
        modifier(ConversationFindAnchorModifier(fraction: fraction))
    }
}

private struct ConversationFindAnchorModifier: ViewModifier {
    @Environment(\.conversationFind) private var find
    let fraction: Double?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let fraction {
                let token = find?.scrollRequest?.token
                GeometryReader { proxy in
                    let height = max(1, proxy.size.height)
                    ConversationFindAnchorMarker(token: token, find: find)
                        .frame(width: 1, height: 1)
                        .position(x: 0.5, y: min(max(0.5, height * fraction), height - 0.5))
                        .id(ConversationFindAnchor.activeMatch)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// The current match's point, which centers the conversation's scroll view on itself once per find
/// request.
private struct ConversationFindAnchorMarker: NSViewRepresentable {
    let token: Int?
    let find: ConversationFindModel?

    func makeNSView(context: Context) -> ConversationFindCenteringView { ConversationFindCenteringView() }

    func updateNSView(_ view: ConversationFindCenteringView, context: Context) {
        guard let token, let find, find.claimCentering(token) else { return }
        view.centerSoon(for: token, in: find) { [weak view] in
            guard let view else { return nil }
            return view.convert(view.bounds, to: nil)
        }
    }
}

/// Brings a match's rectangle to the middle of the scroll view around it: right after find asks,
/// after the conversation has brought the match's turn into view, and again once a fold or a longer
/// text has opened.
class ConversationFindCenteringView: NSView {
    func centerSoon(for token: Int, in find: ConversationFindModel, rect: @escaping @MainActor () -> CGRect?) {
        DispatchQueue.main.async { [weak self] in self?.center(rect()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self, weak find] in
            guard let self, find?.scrollRequest?.token == token else { return }
            center(rect())
        }
    }

    /// `rect` is in window coordinates.
    private func center(_ rect: CGRect?) {
        guard let rect, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let match = document.convert(rect, from: nil)
        let height = scroll.contentView.bounds.height
        document.scrollToVisible(CGRect(x: match.minX, y: match.midY - height / 2, width: max(1, match.width),
                                        height: height))
    }
}

/// Hands the open find the conversation it searches, only while the bar is open.
struct ConversationFindFeeder: View {
    let find: ConversationFindModel
    let source: ConversationFindSource

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: source, initial: true) { _, source in find.updateSource(source) }
    }
}

/// Moves the conversation to the current match: its row first (a lazy list may not have drawn the
/// message yet), then the match itself. Reaching a match stops following the latest output.
struct ConversationFindScrollDriver: View {
    let find: ConversationFindModel?
    let proxy: ScrollViewProxy
    let pauseFollowing: () -> Void

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: find?.scrollRequest) { _, request in
                guard let request, let find else { return }
                pauseFollowing()
                proxy.scrollTo(request.scrollID, anchor: .center)
                Task { @MainActor in
                    // The row lays out, and folded work or a longer text window opens, before the
                    // match can be found.
                    for delay in [0, 80] {
                        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) } else { await Task.yield() }
                        guard find.scrollRequest == request else { return }
                        proxy.scrollTo(ConversationFindAnchor.activeMatch, anchor: .center)
                    }
                }
            }
    }
}
