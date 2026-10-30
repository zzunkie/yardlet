import SwiftUI

struct TranscriptErrorCard: View {
    let harness: HarnessKind
    /// A plain heading for a known failure category; the generic heading otherwise.
    var title: String? = nil
    let message: String
    let recoverable: Bool
    var onRetry: (() -> Void)? = nil
    var onEditRequest: (() -> Void)? = nil
    var onShowHarnessSettings: (() -> Void)? = nil
    @State private var showsDetails = false

    var body: some View {
        let summary = TranscriptRecoveryProjection.errorSummary(message)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title ?? L10n.format("%@ could not complete the request", harness.displayName))
                        .font(.callout.weight(.semibold))
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Buttons, as the Codex app draws its Retry: a bare label here read as a heading.
            if onRetry != nil || onEditRequest != nil || onShowHarnessSettings != nil {
                ControlRowLayout(spacing: 8, rowSpacing: 8) {
                    recoveryActions
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            DisclosureGroup(L10n.string("Error details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(recoverable ? L10n.string("Action failed") : L10n.string("Session failed"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    TranscriptCopyButton(title: L10n.string("Copy error details")) { message }
                }
                .padding(.top, 8)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.red.opacity(0.18)) }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if let onRetry {
            Button(L10n.string("Retry"), action: onRetry)
                .parityPointer()
        }
        if let onEditRequest {
            Button(L10n.string("Edit request"), action: onEditRequest)
                .parityPointer()
                .help(L10n.string("Restore this request to the composer without sending"))
        }
        if let onShowHarnessSettings {
            Button(L10n.string("Harness settings"), action: onShowHarnessSettings)
                .parityPointer()
        }
    }
}
