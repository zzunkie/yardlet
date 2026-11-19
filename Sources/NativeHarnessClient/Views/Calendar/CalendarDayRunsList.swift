import SwiftUI

/// The day's scheduled runs beside its hours, in Day: how many, then those still to come by time, a clock with an
/// arrow around it for a run whose schedule comes due again and a clock for a one-off run. The runs whose time passed
/// fold into one line at the top, which lists them when chosen, as the desk folds the runs that ran. Choosing a run
/// opens its scheduled task. The list takes the keyboard: ↑ and ↓ move through its lines, Return or Space does what
/// the line does. It stands where an event's details stand, which take its place while an event is chosen.
struct CalendarDayRunsList: View {
    /// The day's runs by time.
    let slots: [CalendarScheduleSlot]
    let calendar: Calendar
    let onOpenSchedule: (UUID) -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    /// The line of runs whose time passed was chosen: they show.
    @State private var showsPast = false
    /// The line the keyboard is on.
    @State private var highlighted: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        // The runs move from to come to past as the minutes pass.
        TimelineView(.everyMinute) { context in
            let lines = lines(now: context.date)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.string("Runs this day"))
                        .font(.system(size: 13 * scale, weight: .semibold))
                    Text(verbatim: "\(slots.count)")
                        .font(.system(size: 12 * scale).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16 * scale)
                .frame(height: 40 * scale)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                row(line).id(line.id)
                            }
                        }
                        .padding(.horizontal, 6 * scale)
                        .padding(.bottom, 12 * scale)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: CalendarEventDetail.width * scale)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Rectangle().fill(ParityTheme.separator).frame(width: 1) }
        // Reached with Tab whether or not keyboard navigation is on, as the home's lists are.
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.return) { perform() }
        .onKeyPress(.space) { perform() }
        .onChange(of: isFocused) { _, focused in
            if focused, highlighted == nil { highlighted = lines(now: Date()).first?.id }
        }
        .onChange(of: slots) { _, _ in
            if let id = highlighted, !lines(now: Date()).contains(where: { $0.id == id }) { highlighted = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Runs this day"))
    }

    // MARK: - Lines

    private enum Line: Identifiable {
        case past(count: Int)
        case run(CalendarScheduleSlot, isPast: Bool)

        var id: String {
            switch self {
            case .past: "past"
            case let .run(slot, _): slot.id
            }
        }
    }

    /// The folded line of runs whose time passed, or those runs while they show, then the runs to come.
    private func lines(now: Date) -> [Line] {
        let past = slots.prefix { $0.at < now }
        let toCome = slots.dropFirst(past.count).map { Line.run($0, isPast: false) }
        guard !past.isEmpty else { return toCome }
        return [.past(count: past.count)] + (showsPast ? past.map { .run($0, isPast: true) } : []) + toCome
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        let isHighlighted = isFocused && highlighted == line.id
        switch line {
        case let .past(count):
            CalendarDayRunRow(time: "", symbol: "checkmark",
                              title: showsPast ? L10n.string("Show less") : L10n.format("%lld past runs", count),
                              isPast: true, isHighlighted: isHighlighted) { showsPast.toggle() }
                .accessibilityValue(L10n.string(showsPast ? "Shown" : "Hidden"))
        case let .run(slot, isPast):
            CalendarDayRunRow(time: CalendarText.time(slot.at, calendar: calendar),
                              symbol: slot.isRecurring ? "clock.arrow.circlepath" : "clock", title: slot.name,
                              isPast: isPast, isHighlighted: isHighlighted) { onOpenSchedule(slot.scheduleID) }
                .accessibilityLabel(slot.name + ", " + CalendarText.time(slot.at, calendar: calendar))
                .accessibilityValue(L10n.string(slot.isRecurring ? "Recurring run" : "One-off run"))
                .accessibilityHint(L10n.string("Open the scheduled task"))
        }
    }

    // MARK: - Keyboard

    private func move(by step: Int) -> KeyPress.Result {
        let ids = lines(now: Date()).map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) }
        highlighted = ids[index.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)]
        return .handled
    }

    private func perform() -> KeyPress.Result {
        guard let id = highlighted, let line = lines(now: Date()).first(where: { $0.id == id }) else { return .ignored }
        switch line {
        case .past: showsPast.toggle()
        case let .run(slot, _): onOpenSchedule(slot.scheduleID)
        }
        return .handled
    }
}

/// A line of the day's runs: its time, a mark, and its name; faded once its time passed.
private struct CalendarDayRunRow: View {
    let time: String
    let symbol: String
    let title: String
    let isPast: Bool
    let isHighlighted: Bool
    let action: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * scale) {
                Text(time)
                    .font(.system(size: 11.5 * scale).monospacedDigit())
                    .foregroundStyle(isPast ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .frame(width: 62 * scale, alignment: .leading)
                Image(systemName: symbol)
                    .font(.system(size: 10.5 * scale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15 * scale)
                Text(title)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10 * scale)
            .frame(height: 28 * scale)
            .background(isHighlighted ? ParityTheme.selectedFill : isHovering ? ParityTheme.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
