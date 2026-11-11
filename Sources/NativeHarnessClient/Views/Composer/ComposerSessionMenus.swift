import SwiftUI

// The menus and indicators `ComposerSessionControls` opens and draws, shared by every harness.

/// The context ring beside the model menu, the Claude app's Code composer ring (`KF` in `s1`): 12 pt,
/// a 2 pt arc from twelve o'clock, warning from 75% and critical from 90%. Hovering names the
/// numbers ("Context 45.2k / 200k (23%)"); clicking opens the context window above it.
struct ComposerContextUsageIndicator: View {
    let summary: ComposerContextSummary
    var usage: HarnessProtocolUsage? = nil
    var breakdowns: [ComposerUsageBreakdown] = []
    var compact: ComposerContextUsageDetails.Compact? = nil
    var limit: ComposerContextUsageDetails.Limit? = nil

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ComposerContextRing(summary: summary, isActive: isPresented)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(summary.help)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ComposerContextUsageDetails(summary: summary, usage: usage, breakdowns: breakdowns,
                                        compact: compact.map { compact in
                                            .init(isAvailable: compact.isAvailable,
                                                  unavailableReason: compact.unavailableReason) {
                                                isPresented = false
                                                compact.run()
                                            }
                                        }, limit: limit)
                .onExitCommand { isPresented = false }
        }
        .accessibilityLabel(L10n.string("Context window"))
        .accessibilityValue(summary.summaryText ?? L10n.string("Unavailable"))
        .accessibilityHint(L10n.string("Show usage details"))
    }
}

/// The ring itself: the share of the window, coloured by severity.
struct ComposerContextRing: View {
    let summary: ComposerContextSummary
    var isActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? ParityTheme.selectedFill : .clear)
                .frame(width: 24, height: 24)
            ZStack {
                // The Claude app's track is its strong border colour, so an empty ring reads as a
                // gauge and not as a spinner that has not started.
                Circle()
                    .stroke(Color.primary.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: summary.fraction ?? 0)
                    .stroke(ComposerContextUsageDetails.tint(summary.severity),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
        }
        .frame(width: 24, height: 24)
        .animation(ParityMotion.easeOut(reduceMotion: reduceMotion, duration: 0.3), value: summary.fraction)
    }
}

/// The context window the ring opens, the Claude app's (`d1`/`f1`): "Context window" with its numbers,
/// a bar, then — where the harness breaks the window down — a meter of what fills it and its legend,
/// and how far auto-compact is with "Compact session" from half full. Below, the token counts and
/// cost the harness reported for its turns (D5).
struct ComposerContextUsageDetails: View {
    struct Compact {
        var isAvailable: Bool
        /// Why "Compact session" waits, while it does.
        var unavailableReason: String?
        var run: () -> Void
    }

    /// The task's own context limit.
    struct Limit {
        var slot: ComposerContextLimitSlot
        var choose: (String) -> Void

        static func make(_ slot: ComposerContextLimitSlot?, onChoose: @escaping (ComposerSessionChoice) -> Void) -> Limit? {
            slot.map { slot in
                Limit(slot: slot) { onChoose(.providerOption(id: slot.selector.id, value: $0)) }
            }
        }
    }

    let summary: ComposerContextSummary
    var usage: HarnessProtocolUsage? = nil
    var breakdowns: [ComposerUsageBreakdown] = []
    var compact: Compact? = nil
    var limit: Limit? = nil
    /// Inside the session rail's Context card (the Claude app's `presentation: "inline"`): the card's
    /// width and background rather than the window's.
    var isInline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.string("Context window"))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if let text = summary.summaryText {
                    Text(text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(summary.severity == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                        .monospacedDigit()
                }
            }

            if let fraction = summary.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ParityTheme.selectedFill)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                }
                .frame(height: 4)
            } else {
                Text(L10n.string("Send a message to see context usage."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.legend.isEmpty {
                breakdownCard
            }

            if summary.autoCompactHint != nil || (compact != nil && summary.offersCompact) {
                compactRow
            }

            if let limit {
                limitRow(limit)
            }

            ForEach(Array(breakdowns.enumerated()), id: \.offset) { _, breakdown in
                Divider()
                HStack {
                    Text(breakdown.title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if let total = breakdown.total {
                        Text(ComposerContextSummary.tokenText(total))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                ForEach(Array(breakdown.counts.enumerated()), id: \.offset) { _, count in
                    metric(count.label, value: ComposerContextSummary.tokenText(count.tokens))
                }
                if let cacheHit = breakdown.cacheHitFraction {
                    metric(L10n.string("Cache hit"), value: L10n.format("%.1f%% of input", cacheHit * 100))
                }
            }
            if let cost = usage?.totalCostUSD {
                if breakdowns.isEmpty { Divider() }
                metric(L10n.string("Cost"), value: String(format: "$%.4f", cost))
            }
        }
        .padding(isInline ? 0 : 14)
        .frame(width: isInline ? nil : 320)
        .background(isInline ? Color.clear : ParityTheme.elevated)
    }

    private var tint: Color { Self.tint(summary.severity) }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(summary.meter.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(Self.color(segment.kind))
                            .frame(width: max(2, proxy.size.width * segment.fraction))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .background(ParityTheme.selectedFill)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(summary.legend) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.color(row.kind))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.secondary.opacity(0.35),
                                                                                    lineWidth: row.kind == .free ? 1 : 0))
                            .frame(width: 8, height: 8)
                        Text(row.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.tokensText)
                            .monospacedDigit()
                        Text(row.shareText)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(row.kind == .deferred ? .tertiary : .secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(10)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            if let hint = summary.autoCompactHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let compact, summary.offersCompact {
                Button(L10n.string("Compact session"), action: compact.run)
                    .controlSize(.small)
                    .disabled(!compact.isAvailable)
                    .help(compact.isAvailable ? "" : compact.unavailableReason ?? "")
            }
        }
    }

    private func limitRow(_ limit: Limit) -> some View {
        let selector = limit.slot.selector
        let name = Text(selector.name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        // A menu, as Default names the limit it stands for and four segments would not fit the rail. A menu is
        // as wide as its longest item, so where it leaves the name no room the name goes above it.
        let menu = Picker(selector.name, selection: Binding(get: { selector.currentValue }, set: limit.choose)) {
            ForEach(selector.choices) { choice in
                Text(choice.name).tag(choice.value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help(selector.description ?? "")
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 8)
                    menu
                }
                VStack(alignment: .leading, spacing: 4) {
                    name
                    menu
                }
            }
            if let note = limit.slot.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Yardlet's colours on the Claude app's steps: the usual tint, orange from 75%, red from 90%.
    static func tint(_ severity: ComposerContextSummary.Severity) -> Color {
        switch severity {
        case .normal: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    private static let categoryColors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]

    static func color(_ kind: ComposerContextSummary.LegendRow.Kind) -> Color {
        switch kind {
        case let .used(index): categoryColors[index % categoryColors.count]
        case .buffer: .secondary.opacity(0.45)
        case .free: .clear
        case .deferred: .secondary.opacity(0.2)
        }
    }

    static func color(_ kind: ComposerContextSummary.MeterSegment.Kind) -> Color {
        switch kind {
        case let .used(index): categoryColors[index % categoryColors.count]
        case .other: .gray
        case .buffer: .secondary.opacity(0.45)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The heading of every harness's permissions menu: what the next turn runs with.
struct ComposerPermissionHeader: View {
    let value: String
    let hasPendingPermission: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasPendingPermission ? "exclamationmark.shield.fill" : "checkmark.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hasPendingPermission ? .orange : .secondary)
            Text(L10n.string("Permissions"))
                .font(.callout.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(hasPendingPermission ? .orange : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Under a menu whose choices apply only to a running session.
struct ComposerDetachedNotice: View {
    var body: some View {
        Label(L10n.string("Resume the task to change live settings."), systemImage: "pause.circle")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }
}

/// The composer's model menu for every harness, in the Codex app's frame (26.1016): the model at the
/// top opens the model list in place; under it, the effort is a stepped slider — the Codex app's
/// Power slider, the Claude app's "Faster … Smarter" effort control — and the speed a switch. The
/// choices, their names, and what they do are the harness's own.
///
/// Keys: ← → step the effort, Return closes, and in the model list 1–9 choose a model as the Claude
/// app's menu numbers its models. It takes only the selectors and what choosing does, so any popover
/// that sets a model and effort can show it.
struct HarnessIntelligencePicker: View {
    private enum PickerView {
        case effort
        case models
    }

    let modelSelector: ProviderCapabilitySelector?
    let reasoningSelector: ProviderCapabilitySelector?
    let isAttached: Bool
    let onSetOption: (String, String) -> Void
    let onDismiss: () -> Void
    var speedSelector: ProviderCapabilitySelector? = nil
    /// Open at the model list rather than the effort, as the Model slash command does.
    var opensModelList = false

    /// Nil until the reader moves between the two views, so each opening starts where it asked.
    @State private var pickerView: PickerView?
    /// The effort just chosen, shown until the harness reports it.
    @State private var pendingEffort: String?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsModels: Bool {
        (pickerView ?? (opensModelList ? .models : .effort)) == .models || reasoningSelector == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsModels {
                    modelList
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    effortPicker
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }

            if let speed = speedSelector {
                Divider()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                speedRow(speed)
            }
            if !isAttached { ComposerDetachedNotice() }
        }
        .padding(.vertical, 6)
        .background(ParityTheme.elevated)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard !showsModels, let reasoningSelector else { return .ignored }
            stepEffort(reasoningSelector, by: press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(.return) {
            onDismiss()
            return .handled
        }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard showsModels, let modelSelector, let digit = Int(press.characters), digit >= 1,
                  digit <= min(9, modelSelector.choices.count) else { return .ignored }
            pickModel(modelSelector.choices[digit - 1], in: modelSelector)
            return .handled
        }
        .animation(ParityMotion.easeInOut(reduceMotion: reduceMotion), value: pickerView)
        .onAppear { isFocused = true }
        .onDisappear {
            pickerView = nil
        }
        .onChange(of: reasoningSelector?.currentValue) { _, _ in pendingEffort = nil }
        .task(id: pendingEffort) {
            // A choice the harness never reports goes back to what it reports.
            guard pendingEffort != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            pendingEffort = nil
        }
    }

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let modelSelector {
                IntelligencePickerRow {
                    withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
                        pickerView = .models
                    }
                } content: {
                    HStack(spacing: 8) {
                        Text(selectedName(for: modelSelector))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityLabel(L10n.string("Model"))
                .accessibilityValue(selectedName(for: modelSelector))
            }

            if let reasoningSelector {
                if modelSelector != nil {
                    Divider()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                }
                IntelligenceEffortSlider(
                    selector: reasoningSelector,
                    shownValue: pendingEffort ?? reasoningSelector.currentValue,
                    isEnabled: isAttached,
                    onPick: { pickEffort($0, in: reasoningSelector) })
            }
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if reasoningSelector != nil {
                    Button {
                        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
                            pickerView = .effort
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .accessibilityLabel(L10n.string("Back"))
                }

                Text(L10n.string("Model"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 4)

            if let modelSelector {
                IntelligencePickerList(rowCount: modelSelector.choices.count, maxHeight: 280) {
                    ForEach(Array(modelSelector.choices.enumerated()), id: \.element.id) { index, choice in
                        let isSelected = choice.value == modelSelector.currentValue
                        IntelligencePickerRow(
                            isEnabled: isAttached || isSelected,
                            action: { pickModel(choice, in: modelSelector) }
                        ) {
                            Text(choice.name)
                                .lineLimit(1)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(ParityTheme.accent)
                            } else if index < 9 {
                                // The Claude app's menu numbers its models; the number chooses one.
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .help(choice.description ?? "")
                        .accessibilityLabel(choice.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            } else {
                Text(L10n.string("Unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(7)
            }
        }
    }

    /// Both apps' speed row: a bolt, the name and what it costs, and a switch; the menu stays open.
    private func speedRow(_ speed: ProviderCapabilitySelector) -> some View {
        let isOn = speed.currentValue == "on"
        return IntelligencePickerRow(isEnabled: isAttached) {
            onSetOption(speed.id, isOn ? "off" : "on")
        } content: {
            Image(systemName: "bolt")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(speed.name)
                if let description = speed.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 5)
            Spacer()
            Toggle(speed.name, isOn: Binding(get: { isOn }, set: { onSetOption(speed.id, $0 ? "on" : "off") }))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.mini)
                .disabled(!isAttached)
        }
        .accessibilityLabel(speed.name)
        .accessibilityValue(isOn ? L10n.string("On") : L10n.string("Off"))
    }

    private func pickModel(_ choice: ProviderCapabilityChoice, in selector: ProviderCapabilitySelector) {
        let isSelected = choice.value == selector.currentValue
        guard isAttached || isSelected else { return }
        if isAttached && !isSelected {
            onSetOption(selector.id, choice.value)
        }
        if reasoningSelector == nil {
            onDismiss()
        } else {
            withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
                pickerView = .effort
            }
        }
    }

    private func pickEffort(_ value: String, in selector: ProviderCapabilitySelector) {
        guard isAttached, value != (pendingEffort ?? selector.currentValue) else { return }
        pendingEffort = value
        onSetOption(selector.id, value)
    }

    private func stepEffort(_ selector: ProviderCapabilitySelector, by offset: Int) {
        let levels = IntelligenceEffortSlider.levels(of: selector)
        guard !levels.isEmpty else { return }
        let current = levels.firstIndex { $0.value == (pendingEffort ?? selector.currentValue) }
        let next = current.map { min(max($0 + offset, 0), levels.count - 1) } ?? (offset > 0 ? 0 : levels.count - 1)
        pickEffort(levels[next].value, in: selector)
    }

    private func selectedName(for selector: ProviderCapabilitySelector) -> String {
        ProviderCapabilityAccessibility.selectedChoiceName(for: selector)
    }
}

/// The effort as a stepped slider: the harness's levels from least to most, a stop for each that
/// a click chooses, dragging between them, and the level's name above. A "Default" the harness
/// offers (Claude Code's own default) is not a step on the scale and sits before it. Each stop is a
/// button named for its level, so every level is one press away for VoiceOver too.
struct IntelligenceEffortSlider: View {
    let selector: ProviderCapabilitySelector
    /// The level to show: the harness's, or one just chosen.
    let shownValue: String
    let isEnabled: Bool
    let onPick: (String) -> Void

    @State private var dragIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func levels(of selector: ProviderCapabilitySelector) -> [ProviderCapabilityChoice] {
        ConversationSessionStatusProjection.orderedReasoningChoices(selector.choices).filter { !isDefault($0) }
    }

    static func isDefault(_ choice: ProviderCapabilityChoice) -> Bool {
        choice.value.lowercased() == "default"
    }

    private var levels: [ProviderCapabilityChoice] { Self.levels(of: selector) }
    private var defaultChoice: ProviderCapabilityChoice? { selector.choices.first(where: Self.isDefault) }
    private var selectedIndex: Int? { levels.firstIndex { $0.value == shownValue } }
    private var shownIndex: Int? { dragIndex ?? selectedIndex }

    private var shownName: String {
        if let index = shownIndex { return levels[index].name }
        return selector.choices.first { $0.value == shownValue }?.name ?? shownValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("Reasoning effort"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(shownName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isMaximum ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(.primary))
                    .contentTransition(.opacity)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                if let defaultChoice {
                    defaultButton(defaultChoice)
                }
                if !levels.isEmpty {
                    track
                }
            }
            if levels.count > 1 {
                HStack {
                    Text(L10n.string("Faster"))
                    Spacer()
                    Text(L10n.string("Smarter"))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, defaultChoice == nil ? 0 : defaultWidth + 10)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Reasoning effort"))
    }

    /// The Claude app's Max in its accent: the most the model does.
    private var isMaximum: Bool {
        guard let index = shownIndex else { return false }
        return levels.count > 2 && index == levels.count - 1
    }

    private let defaultWidth: CGFloat = 58

    private func defaultButton(_ choice: ProviderCapabilityChoice) -> some View {
        let isSelected = choice.value == shownValue && dragIndex == nil
        return Button { onPick(choice.value) } label: {
            Text(choice.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: defaultWidth, height: 22)
                .background(isSelected ? ParityTheme.selectedFill : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? .clear : ParityTheme.strongSeparator))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .parityPointer()
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var track: some View {
        GeometryReader { proxy in
            let count = levels.count
            let inset: CGFloat = 8
            let width = max(proxy.size.width - inset * 2, 1)
            let step = count > 1 ? width / CGFloat(count - 1) : 0
            let x = { (index: Int) in inset + (count > 1 ? CGFloat(index) * step : width / 2) }
            let midY = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: width, height: 4)
                    .position(x: inset + width / 2, y: midY)
                if let index = shownIndex {
                    Capsule()
                        .fill(ParityTheme.accent)
                        .frame(width: max(x(index) - inset, 4), height: 4)
                        .position(x: inset + max(x(index) - inset, 4) / 2, y: midY)
                }
                // A dot for each step not reached yet; the filled part needs none.
                ForEach(0..<count, id: \.self) { index in
                    if shownIndex.map({ index > $0 }) ?? true {
                        Circle()
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 4, height: 4)
                            .position(x: x(index), y: midY)
                    }
                }
                if let index = shownIndex {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.06)))
                        .frame(width: 16, height: 16)
                        .position(x: x(index), y: midY)
                        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.82), value: index)
                }
                // A button for each stop over its share of the track: a click chooses it.
                HStack(spacing: 0) {
                    ForEach(Array(levels.enumerated()), id: \.element.id) { index, level in
                        let isSelected = index == selectedIndex
                        Button { onPick(level.value) } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: count > 1 ? (index == 0 || index == count - 1 ? step / 2 + inset : step) : proxy.size.width)
                        .disabled(!isEnabled)
                        .accessibilityLabel(level.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .frame(height: proxy.size.height)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard isEnabled, count > 0 else { return }
                        dragIndex = nearest(value.location.x, inset: inset, step: step, count: count)
                    }
                    .onEnded { value in
                        guard isEnabled, count > 0 else { return }
                        let index = nearest(value.location.x, inset: inset, step: step, count: count)
                        dragIndex = nil
                        onPick(levels[index].value)
                    }
            )
            .parityPointer()
        }
        .frame(height: 22)
    }

    private func nearest(_ x: CGFloat, inset: CGFloat, step: CGFloat, count: Int) -> Int {
        guard count > 1, step > 0 else { return 0 }
        return min(max(Int(((x - inset) / step).rounded()), 0), count - 1)
    }
}

/// The rows of one of the model menu's lists. The list's height comes from its rows: a popover
/// takes its content's ideal height, and a scroll view whose rows have not been laid out yet
/// offers none, so a list left to the scroll view stayed empty when the menu's choices arrived
/// after it opened. Every row is laid out, so each is in the accessibility tree; a list longer
/// than `maxHeight` scrolls.
private struct IntelligencePickerList<Rows: View>: View {
    let rowCount: Int
    let maxHeight: CGFloat
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        let height = CGFloat(rowCount) * IntelligencePickerRowMetrics.height
        if height <= maxHeight {
            VStack(alignment: .leading, spacing: 0) { rows() }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { rows() }
            }
            .frame(height: maxHeight)
        }
    }
}

enum IntelligencePickerRowMetrics {
    /// Each row's height; a list's height is a multiple of it.
    static let height: CGFloat = 32
}

struct IntelligencePickerRow<Content: View>: View {
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: IntelligencePickerRowMetrics.height, alignment: .leading)
            .background(
                isHovering && isEnabled ? ParityTheme.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .font(.callout)
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
        .parityPointer()
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
        .animation(ParityMotion.easeOut(reduceMotion: reduceMotion, duration: 0.1), value: isHovering)
    }
}
