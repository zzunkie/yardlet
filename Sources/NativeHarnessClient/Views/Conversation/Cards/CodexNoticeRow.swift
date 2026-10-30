import SwiftUI

/// A provider notice the App Server sent during the turn, as one quiet line.
struct CodexNoticeRow: View {
    let notice: CodexNoticeItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let details {
                    Text(details)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11.5))
        .help(notice.path ?? "")
        .accessibilityElement(children: .combine)
    }

    private var message: String { notice.displayMessage }

    private var details: String? {
        switch notice.kind {
        case .modelRerouted:
            notice.reason == "highRiskCyberActivity"
                ? L10n.string("Heads up, your request was re-routed to reduce cyber-abuse risk.") : nil
        case .warning, .configWarning, .deprecationNotice:
            notice.details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
    }

    private var symbolName: String {
        switch notice.kind {
        case .modelRerouted: "arrow.triangle.branch"
        case .warning, .configWarning, .deprecationNotice: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .modelRerouted: Color.secondary
        case .warning, .configWarning, .deprecationNotice: Color.orange
        }
    }
}

