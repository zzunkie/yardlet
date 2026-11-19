import SwiftUI

/// A task's harness settings (plan B6): one sheet with the same layout for every harness. The
/// header names the harness and the task; the sections are those the provider reports
/// (`HarnessSettingsSheetContent.sections`), switched with a segmented control when there is more
/// than one. Controls are cards with the control at the trailing edge; skills and plugins are
/// divided lists, with a switch at a row's trailing edge where the harness turns the item on and
/// off, and a line above them saying whose tasks a switch reaches and from when. Errors and the
/// last action's message sit under the sections. Only the
/// provider's own options and values differ between harnesses; what differs is decided in
/// `HarnessSettingsSheetProjection`, not here.
struct HarnessSettingsSheet: View {
    let session: SessionRecord
    let content: HarnessSettingsSheetContent
    let onRefresh: () -> Void
    let onCommand: (HarnessSettingsCommand) -> Void
    let onDismiss: () -> Void
    /// A section to open on (`controls`, `skills`, `plugins`); a DEBUG fixture selector.
    var initialSection: String? = nil

    @State private var section: HarnessSettingsSection = .controls
    @State private var focusedSection: HarnessSettingsSection?
    @State private var didApplyInitialPresentation = false
    /// A choice that asks before it applies (Claude Code's Bypass permissions).
    @State private var confirming: HarnessSettingsChoice?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsSectionPicker { sectionPicker }

            Group {
                switch visibleSection {
                case .controls:
                    controls
                case .skills:
                    list(content.skills ?? [], emptyTitle: L10n.string("No skills found"),
                         emptySymbol: "wand.and.stars")
                case .plugins:
                    list(content.plugins ?? [], emptyTitle: L10n.string("No plugins found"),
                         emptySymbol: "puzzlepiece.extension")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !content.errors.isEmpty || content.actionMessage != nil {
                Divider()
                footer
            }
        }
        .frame(width: 680, height: 520)
        .background(ParityTheme.canvas)
        .onAppear(perform: applyInitialPresentationIfNeeded)
        .alert(confirming?.confirmation?.title ?? "", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { choice in
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(choice.confirmation?.confirm ?? choice.title, role: .destructive) { onCommand(choice.command) }
        } message: { choice in
            Text(choice.confirmation?.message ?? "")
        }
    }

    private var showsSectionPicker: Bool { content.sections.count > 1 }

    /// The chosen section, or Controls when the provider no longer reports it.
    private var visibleSection: HarnessSettingsSection {
        content.sections.contains(section) ? section : .controls
    }

    private func applyInitialPresentationIfNeeded() {
        guard !didApplyInitialPresentation else { return }
        didApplyInitialPresentation = true
        let initial = content.section(named: initialSection)
        section = initial
        focusedSection = initial
    }

    private func moveSection(by offset: Int) {
        guard let targetID = CodexCapabilitySectionNavigationProjection.targetSectionID(
            in: content.sections.map(\.rawValue),
            focusedID: focusedSection?.rawValue,
            offset: offset
        ), let target = HarnessSettingsSection(rawValue: targetID) else { return }
        section = target
        focusedSection = target
    }

    // MARK: - Header and sections

    private var header: some View {
        HStack(spacing: 12) {
            HarnessIdentityIcon(harness: session.harness, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.harness.displayName)
                    .font(.headline)
                Text(verbatim: "\(session.title) · \(session.workspaceURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if content.isLoading {
                ProgressView().controlSize(.small)
            }
            ParityIconButton(
                systemName: "arrow.clockwise",
                help: L10n.string("Refresh capabilities"),
                action: onRefresh
            )
            Button(L10n.string("Done"), action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(content.sections) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .focusable()
        .accessibilityLabel(L10n.string("Harness settings sections"))
        .accessibilityValue(visibleSection.title)
        .accessibilityHint(L10n.string("Use the left and right arrow keys to switch sections."))
        .onKeyPress(.leftArrow) {
            moveSection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSection(by: 1)
            return .handled
        }
        .onChange(of: section) { _, value in
            focusedSection = value
        }
    }

    /// Space above the first row when no section picker sits there.
    private var contentTopInset: CGFloat { showsSectionPicker ? 0 : 18 }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if content.controls.isEmpty && !content.isLoading {
                    ContentUnavailableView(
                        L10n.string("No live controls exposed"),
                        systemImage: "slider.horizontal.below.rectangle"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 55)
                }
                if !content.controls.isEmpty {
                    // The provider's controls as rows of one group, as Settings draws its rows.
                    SettingsGroup {
                        ForEach(Array(content.controls.enumerated()), id: \.element.id) { index, control in
                            if index > 0 { Divider() }
                            controlRow(control)
                        }
                    }
                }
                if !content.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(content.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, contentTopInset)
            .padding(.bottom, 20)
        }
    }

    private func list(
        _ items: [HarnessSettingsListItem],
        emptyTitle: String,
        emptySymbol: String
    ) -> some View {
        ScrollView {
            if items.isEmpty && !content.isLoading {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
                    .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = content.switchNote, items.contains(where: { $0.switchState != nil }) {
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            listRow(item)
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, contentTopInset)
                .padding(.bottom, 20)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(content.errors, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let message = content.actionMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func controlRow(_ control: HarnessSettingsControl) -> some View {
        SettingsRow(title: control.title, detail: control.description.flatMap { $0.isEmpty ? nil : $0 }) {
            trailingControl(control)
        }
    }

    @ViewBuilder
    private func trailingControl(_ control: HarnessSettingsControl) -> some View {
        switch control.kind {
        case let .selector(currentTitle, choices):
            Menu {
                ForEach(choices) { choice in
                    if choice.startsGroup { Divider() }
                    Button(choice.title) {
                        if choice.confirmation != nil { confirming = choice } else { onCommand(choice.command) }
                    }
                }
            } label: {
                // The menu draws its own indicator after the current value.
                Text(currentTitle)
            }
            .menuStyle(.borderlessButton)
            .parityPointer()
            .fixedSize()
            .accessibilityLabel(control.title)
            .accessibilityValue(currentTitle)
        case let .action(buttonTitle, command):
            Button(buttonTitle) { onCommand(command) }
                .accessibilityLabel(control.title)
                .accessibilityHint(control.description ?? "")
        }
    }

    private func listRow(_ item: HarnessSettingsListItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.title).font(SettingsMetrics.titleFont)
                    ForEach(item.badges, id: \.text) { badge in
                        statusBadge(badge)
                    }
                }
                if let description = item.description {
                    Text(description).font(SettingsMetrics.detailFont).foregroundStyle(.secondary)
                }
                Text(item.detail).font(SettingsMetrics.detailFont).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let state = item.switchState {
                // The switch shows what the harness last reported; choosing asks the harness, and the
                // row follows its answer.
                Toggle(item.title, isOn: Binding(
                    get: { state.isOn },
                    set: { onCommand(.setSwitch(state.target, enabled: $0)) }))
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
                    .accessibilityHint(content.switchNote ?? "")
            }
        }
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }

    private func statusBadge(_ badge: HarnessSettingsListItem.Badge) -> some View {
        let tint: Color = switch badge.tone {
        case .positive: .green
        case .neutral: .secondary
        case .warning: .orange
        }
        return Text(badge.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
    }
}
