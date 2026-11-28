import AppKit
import SwiftUI

/// A backup's recovery key, shown once after the file is written (docs/BROWSER_VAULT_DESIGN.md §8.1): Yardlet keeps
/// no copy. The sheet stays out of screenshots, recordings and screen sharing, so a task that watches the screen does
/// not see it, and the key is neither selectable text nor read out by accessibility, which another process may use;
/// Copy puts it on this Mac's clipboard alone, concealed and cleared after 90 seconds.
struct VaultRecoveryKeySheet: View {
    let export: VaultCenter.BackupExport
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("Save the recovery key"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string("The backup opens only with this key, and Yardlet does not keep it. Save it now, somewhere other than the backup file."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(export.recoveryKey)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.string("Recovery key"))
                Text(summary)
                    .font(SettingsMetrics.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                if copied {
                    Text(L10n.string("Copied. It will be cleared from the clipboard in 90 seconds."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(L10n.string("Copy")) {
                    VaultClipboard.copy(export.recoveryKey, currentHostOnly: true)
                    copied = true
                }
                Button(L10n.string("Done"), action: onDone)
                    .keyboardShortcut(MacShortcut.confirmDialog.binding)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .background(ParityTheme.canvas)
        .background(ScreenCaptureExclusion())
    }

    private var summary: String {
        var lines = [L10n.format("Backed up %lld items. Passkeys stay on this Mac.", Int64(export.count))]
        if export.unreadable > 0 {
            lines.append(L10n.format("%lld could not be read and were left out.", Int64(export.unreadable)))
        }
        return lines.joined(separator: " ")
    }
}

/// The recovery key a backup asks for as it is imported, in a secure field that accessibility does not read out, on a
/// sheet kept out of screen capture as the key's own sheet is. The import says what failed (a mistyped key) and stays
/// open.
struct VaultBackupKeySheet: View {
    let fileName: String
    /// Imports with the key typed; the words to show when it did not.
    let onImport: (String) async -> String?
    let onCancel: () -> Void
    @State private var key = ""
    @State private var importing = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.format("Import “%@”", fileName))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("Enter the recovery key Yardlet showed when it made this backup."))
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(L10n.string("Recovery key"), text: $key)
                    .font(.system(size: 15, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button(L10n.string("Cancel"), action: onCancel)
                    .keyboardShortcut(MacShortcut.dismiss.binding)
                Button(L10n.string("Import"), action: submit)
                    .keyboardShortcut(MacShortcut.confirmDialog.binding)
                    .disabled(VaultBackup.normalized(key) == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .disabled(importing)
        .frame(width: 480)
        .background(ParityTheme.canvas)
        .background(ScreenCaptureExclusion())
    }

    private func submit() {
        guard !importing, VaultBackup.normalized(key) != nil else { return }
        importing = true
        Task {
            failure = await onImport(key)
            importing = false
        }
    }
}

/// Keeps the window that shows it out of screenshots, screen recordings and screen sharing (`NSWindow.sharingType`),
/// for a secret on screen such as a backup's recovery key.
struct ScreenCaptureExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ExcludingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ExcludingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = .none
        }
    }
}
