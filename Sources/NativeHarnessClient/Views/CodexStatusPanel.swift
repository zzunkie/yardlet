import AppKit
import SwiftUI

/// A Codex task's open `/status` panel: the account's rate-limit reading and closing it. The app
/// model owns both; the task builds the rest of the panel from its own thread.
struct CodexStatusPanelState {
    var reading: CodexStatusReading
    var close: @MainActor () -> Void
}

private struct CodexStatusPanelKey: EnvironmentKey {
    static let defaultValue: CodexStatusPanelState? = nil
}

extension EnvironmentValues {
    /// The open `/status` panel of the task drawn below, if any.
    var codexStatusPanel: CodexStatusPanelState? {
        get { self[CodexStatusPanelKey.self] }
        set { self[CodexStatusPanelKey.self] = newValue }
    }
}

/// The Codex app's status panel (`composer.statusPlain`): a tray tucked behind the top of the
/// composer with a "Status" heading, Close, and monospaced label–value rows. A rate-limit row is
/// the shared `LimitWindowRow` in the app's words; from 400 points wide it draws its bar, as the
/// app's container query does.
struct CodexStatusPanel: View {
    let projection: CodexStatusProjection
    let onClose: () -> Void
    /// How far the tray runs under the composer, which covers it.
    var tuck: CGFloat = 0

    /// The composer's top padding and corner radius, which the attached tray runs under.
    static let composerTuck: CGFloat = 6 + 16

    /// The tray as the Codex app's composer rail: inset from the composer's sides by its inline
    /// inset and tucked under its top edge. The composer below it must draw above it.
    func attachedAboveComposer() -> some View {
        var tray = self
        tray.tuck = Self.composerTuck
        return tray
            .padding(.horizontal, 13)
            .frame(maxWidth: ParityTheme.contentWidth)
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, -Self.composerTuck)
            .frame(maxWidth: .infinity)
    }

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var expandedRows: Set<Int> = []

    /// The Codex app lists five thread IDs before its `+N` button.
    private static let visibleIdentifiers = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(words.string("Status panel"))
                    .font(.system(size: 13 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                GhostButton(action: onClose) {
                    Text(words.string("Close"))
                        .font(.system(size: 13 * interfaceScale))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(minHeight: 30 * interfaceScale)

            LimitWindowGrid(wideWidth: LimitWindowGrid.codexStatusWideWidth) {
                ForEach(Array(projection.rows.enumerated()), id: \.offset) { index, row in
                    cells(row, at: index)
                }
            }
            .font(.system(size: 12 * interfaceScale, design: .monospaced)).fontDesign(nil)
            .lineSpacing(3 * interfaceScale)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, tuck)
        .background(ParityTheme.subtleFill, in: tray)
        .background(ParityTheme.canvas, in: tray)
        .overlay { tray.stroke(ParityTheme.separator) }
        .clipShape(tray)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words.string("Status panel"))
    }

    private var words: CodexStatusProjection.Words { projection.words }

    private var tray: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
    }

    /// A row's cells, each tagged with its row and the column it takes.
    @ViewBuilder
    private func cells(_ row: CodexStatusProjection.Row, at index: Int) -> some View {
        switch row {
        case let .identifiers(label, ids):
            labelText(label).statusCell(.label, row: index)
            identifiers(ids, row: index).statusCell(.value, row: index)
        case let .value(label, text, metadata):
            labelText(label).statusCell(.label, row: index)
            valueText(text, metadata: metadata)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .statusCell(.value, row: index)
        case let .rateLimit(label, remaining, text, metadata):
            LimitWindowRow(name: label, remainingPercent: remaining, value: text, reset: metadata, row: index,
                           fontSize: 12 * interfaceScale, marksNearlySpent: false)
        case let .section(title):
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .statusCell(.fullRow, row: index)
        case .spacer:
            Color.clear.frame(height: 12).statusCell(.fullRow, row: index)
                .accessibilityHidden(true)
        }
    }

    private func labelText(_ label: String) -> some View {
        Text(label)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func valueText(_ text: String, metadata: String?) -> Text {
        var value = Text(text).foregroundStyle(.primary)
        if let metadata { value = value + Text(verbatim: " ") + Text(metadata).foregroundStyle(.secondary) }
        return value
    }

    private func identifierList(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ids, id: \.self) { id in
                Text(verbatim: id)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One ID reads on its line; several stack, five at first, with the app's `+N` to show the rest.
    @ViewBuilder
    private func identifiers(_ ids: [String], row: Int) -> some View {
        let expanded = expandedRows.contains(row)
        let shown = expanded ? ids : Array(ids.prefix(Self.visibleIdentifiers))
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if ids.count == 1 {
                Text(verbatim: ids[0])
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            } else if expanded {
                // The whole list scrolls within the app's ten lines.
                ScrollView(.vertical) { identifierList(shown) }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                identifierList(shown)
            }
            if ids.count > Self.visibleIdentifiers {
                let hidden = ids.count - Self.visibleIdentifiers
                GhostButton {
                    if expanded { expandedRows.remove(row) } else { expandedRows.insert(row) }
                } label: {
                    HStack(spacing: 2) {
                        if !expanded { Text(verbatim: "+\(hidden.formatted())") }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9 * interfaceScale, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .accessibilityLabel(expanded ? words.string("Collapse thread list")
                    : hidden == 1 ? words.string("Show 1 more thread") : words.format("Show %lld more threads", Int64(hidden)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The app's ghost button: its label alone, with a fill while the pointer is over it.
private struct GhostButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(isHovered ? ParityTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .parityPointer()
    }
}

private extension View {
    func statusCell(_ column: LimitWindowGrid.Column, row: Int) -> some View {
        limitWindowCell(column, row: row)
    }
}
