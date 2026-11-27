import AppKit
import SwiftUI

/// An item's current two-factor code as authenticator apps show it (docs/BROWSER_VAULT_DESIGN.md §14):
/// the code in two groups, a ring with the seconds it has left, and a button that copies it.
struct VaultLiveCode: View {
    let vault: VaultCenter
    let secret: OneTimeCodeSecret
    @State private var copiedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = vault.code(for: secret, at: context.date)
            let remaining = secret.period - Int(context.date.timeIntervalSince1970) % secret.period
            HStack(spacing: 8) {
                Text(verbatim: Self.grouped(code))
                    .font(.system(.body, design: .monospaced).weight(.medium)).fontDesign(nil)
                VaultCodeTimer(remaining: remaining, period: secret.period)
                Button {
                    Self.copy(code)
                    copiedAt = context.date
                } label: {
                    Image(systemName: copiedAt.map { context.date.timeIntervalSince($0) < 2 } == true ? "checkmark" : "doc.on.doc")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Copy Code"))
                .accessibilityLabel(L10n.string("Copy Code"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.format("Code %@, %lld seconds left", Self.grouped(code), Int64(remaining)))
        }
    }

    /// "123 456", "1234 5678".
    static func grouped(_ code: String) -> String {
        guard code.count >= 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return String(code[..<middle]) + " " + String(code[middle...])
    }

    static func copy(_ code: String) {
        VaultClipboard.copy(code)
    }
}

/// What the password manager puts on the clipboard (a code, a password the person copies from an item sheet), as
/// password managers do: marked concealed (nspasteboard.org), so clipboard history apps leave it out and the agent's
/// paste does not take it, and cleared after 90 seconds unless something else was copied since, as 1Password clears
/// what it copied. Universal Clipboard still carries it to the person's own devices.
@MainActor
enum VaultClipboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let clearAfter: Duration = .seconds(90)
    /// What is to be cleared: the pasteboard and its change count once the value went on it.
    private static var pending: (pasteboard: NSPasteboard, count: Int)?
    private static var quitObserver: NSObjectProtocol?

    /// `currentHostOnly` keeps it off Universal Clipboard too, for a value that opens the whole vault (a backup's
    /// recovery key).
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general, currentHostOnly: Bool = false) {
        if currentHostOnly {
            pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        clearLater(pasteboard)
    }

    /// After the person's Copy or Cut in a field that shows a secret: what they copied, when it is part of one of
    /// `secrets`, is marked and cleared as `copy` does.
    static func conceal(ifPartOf secrets: [String], on pasteboard: NSPasteboard = .general) {
        guard !holdsConcealed(pasteboard), let copied = pasteboard.string(forType: .string),
              copied.count >= VaultScrubList.shortest,
              secrets.contains(where: { $0.contains(copied) }) else { return }
        pasteboard.addTypes([concealedType], owner: nil)
        pasteboard.setData(Data(), forType: concealedType)
        clearLater(pasteboard)
    }

    static func holdsConcealed(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.types?.contains(concealedType) == true
    }

    private static func clearLater(_ pasteboard: NSPasteboard) {
        let count = pasteboard.changeCount
        pending = (pasteboard, count)
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                  object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { clearPending() }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            if pending?.pasteboard === pasteboard, pending?.count == count { clearPending() }
        }
    }

    private static func clearPending() {
        guard let pending else { return }
        self.pending = nil
        if pending.pasteboard.changeCount == pending.count { pending.pasteboard.clearContents() }
    }
}

/// The seconds a code has left, as a ring that empties and the number beside it.
private struct VaultCodeTimer: View {
    let remaining: Int
    let period: Int

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(ParityTheme.separator, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(period, 1)))
                    .stroke(remaining <= 5 ? Color.orange : ParityTheme.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(verbatim: "\(remaining)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}
