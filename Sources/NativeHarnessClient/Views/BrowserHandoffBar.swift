import SwiftUI

/// The agent handed a browser tab to the person (`browser_handoff`): what it asks, and the answers it waits for, in a bar
/// above the page. The Mac's browser panel and a window following another Mac's tasks (docs/REMOTE_PROTOCOL.md §15.25)
/// show the same bar.
struct BrowserHandoffBar: View {
    let reason: String
    let decline: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("The agent handed this tab to you"))
                    .font(.callout.weight(.semibold))
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(L10n.string("Decline")) { decline() }
                .controlSize(.small).parityPointer()
            Button(L10n.string("I'm done")) { done() }
                .controlSize(.small).parityProminentButton().parityPointer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
