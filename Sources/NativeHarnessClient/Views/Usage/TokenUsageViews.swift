import AppKit
import SwiftUI

/// The usage views' colours. Bars of one series are the accent. The four token kinds are one blue
/// ramp ordered by price per token, cheapest the quietest: light to dark on a light canvas, dark
/// to light on a dark one (both validated as ordinal ramps against their surface).
enum TokenUsageColors {
    static func kind(_ kind: TokenUsageKind) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex: Int = switch (kind, dark) {
            case (.cacheRead, false): 0x86B6EF
            case (.freshInput, false): 0x3987E5
            case (.cacheWrite, false): 0x1C5CAB
            case (.output, false): 0x0D366B
            case (.cacheRead, true): 0x184F95
            case (.freshInput, true): 0x2A78D6
            case (.cacheWrite, true): 0x6DA7EC
            case (.output, true): 0xB7D3F6
            }
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Day bars

/// Days as bars, oldest left: each day's API-equivalent cost, or its tokens where no day has a
/// price. The last `highlighted` days are the accent and the earlier ones quieter, so a range
/// reads against the month around it. Each bar names its day and amounts on hover.
struct TokenUsageDayBars: View {
    let days: [TokenUsageDay]
    var highlighted: Int
    var height: CGFloat
    /// The first day's date and "Today" under the bars, and the tallest bar's amount over them.
    var showsAxis = false
    /// What the bars are, under them on the left, with "Today" on the right.
    var caption: String? = nil
    var scale: CGFloat = 1

    private var usesCost: Bool { days.contains { $0.amount.cost != nil } }

    private func value(_ day: TokenUsageDay) -> Double {
        usesCost ? day.amount.cost ?? 0 : Double(day.amount.total)
    }

    private func amountText(_ value: Double) -> String {
        usesCost ? TokenUsageFormat.cost(value) : TokenUsageFormat.tokens(Int64(value))
    }

    var body: some View {
        let peak = max(days.map(value).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: ParitySpace.s4) {
            if showsAxis {
                Text(amountText(peak))
                    .font(.parity(.caption, scale: scale).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let count = CGFloat(max(days.count, 1))
                let slot = geometry.size.width / count
                let gap = max(2, (slot * 0.28).rounded())
                let width = max(1, slot - gap)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        let isHighlighted = index >= days.count - highlighted
                        let barHeight = max(2, CGFloat(value(day) / peak) * geometry.size.height)
                        UnevenRoundedRectangle(topLeadingRadius: min(3, width / 2), topTrailingRadius: min(3, width / 2))
                            .fill(isHighlighted ? AnyShapeStyle(ParityTheme.accent)
                                                : AnyShapeStyle(ParityTheme.accent.opacity(0.28)))
                            .frame(width: width, height: barHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                            .help(tooltip(day))
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ParityTheme.separator).frame(height: 1)
                }
            }
            .frame(height: height)
            if showsAxis || caption != nil, let first = days.first {
                HStack {
                    Text(caption ?? first.start.formatted(.dateTime.month(.abbreviated).day()))
                    Spacer()
                    Text(L10n.string("Today"))
                }
                .font(.parity(.caption, scale: scale))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Daily usage"))
        .accessibilityValue(days.suffix(highlighted).map(tooltip).joined(separator: "; "))
    }

    private func tooltip(_ day: TokenUsageDay) -> String {
        let date = day.start.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
        var parts = [date, L10n.format("%@ tokens", TokenUsageFormat.tokens(day.amount.total))]
        if let cost = day.amount.cost { parts.append(L10n.format("%@ API equivalent", TokenUsageFormat.cost(cost))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Limits with their pace

/// Limit windows on the grid every limit uses, each with what is left and, quieter, when it
/// resets, or when it runs out first at the last hour's pace. A heading row names an account over
/// its windows; one grid for every account keeps their bars in line.
struct TokenUsageLimitRows: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        var harness: HarnessKind? = nil
        var window: AccountLimitWindow? = nil
        var runsOutAt: Date? = nil
        /// A line naming the account and its harness over the windows after it.
        var isHeading = false
    }

    let rows: [Row]
    var fontSize: CGFloat = ParityType.caption.size
    var scale: CGFloat = 1
    var now = Date()
    /// Home's few words: the pace without "at this pace", and no reset; both stay in the tooltip.
    var isCompact = false

    var body: some View {
        let scaledSize = fontSize * scale
        LimitWindowGrid(barMinimum: AccountLimitWindowList.barMinimum(fontSize: scaledSize),
                        columnSpacing: ParitySpace.s12, rowSpacing: ParitySpace.s8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if row.isHeading {
                    HStack(spacing: ParitySpace.s8) {
                        if let harness = row.harness { HarnessIdentityIcon(harness: harness, size: 14) }
                        Text(row.name).font(.parity(.control, weight: .medium, scale: scale)).lineLimit(1)
                        if let harness = row.harness {
                            Text(harness.displayName).font(.parity(.caption, scale: scale)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, index == 0 ? 0 : ParitySpace.s8)
                    .limitWindowCell(.fullRow, row: index)
                } else if let window = row.window {
                    HStack(spacing: ParitySpace.s4) {
                        if let harness = row.harness {
                            HarnessIdentityIcon(harness: harness, size: 12)
                                .accessibilityLabel(harness.displayName)
                        }
                        Text(row.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .fixedSize()
                    .limitWindowCell(.label, row: index)
                    LimitWindowBar(percent: window.remainingPercent, fontSize: scaledSize,
                                   tint: (window.remainingPercent ?? 100) <= 10 ? .orange : nil)
                        .limitWindowCell(.bar, row: index)
                    value(window, runsOutAt: row.runsOutAt)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help([row.runsOutAt.map { L10n.format("At the last hour's pace this limit runs out %@.",
                                                                ProviderNoticeText.resetTime($0)) },
                               window.resetsAt.map { L10n.format("Resets %@", ProviderNoticeText.resetTime($0)) }]
                            .compactMap { $0 }.joined(separator: "\n"))
                        .limitWindowCell(.rateValue, row: index)
                }
            }
        }
        .font(.system(size: scaledSize))
        .monospacedDigit()
    }

    private func value(_ window: AccountLimitWindow, runsOutAt: Date?) -> Text {
        let left = window.remainingPercent.map { L10n.format("%.0f%% remaining", $0) } ?? "—"
        let spent = (window.remainingPercent ?? 100) <= 10
        var text = Text(left).foregroundStyle(spent ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        if let runsOutAt {
            let duration = TokenUsageFormat.duration(runsOutAt.timeIntervalSince(now))
            text = text + Text(verbatim: isCompact ? " · " : " ")
                + Text(L10n.format(isCompact ? "runs out in %@" : "runs out in %@ at this pace", duration))
                .foregroundStyle(Color.orange)
        } else if let reset = window.resetsAt, !isCompact {
            text = text + Text(verbatim: " ")
                + Text(L10n.format("Resets %@", ProviderNoticeText.resetTime(reset))).foregroundStyle(.secondary)
        }
        return text
    }

    /// Every account's windows under a heading naming the account, as Settings › Usage lists them.
    static func accounts(_ lines: [TokenUsageLimitLine]) -> [Row] {
        lines.flatMap { line in
            [Row(id: line.id, name: line.account, harness: line.harness, isHeading: true)]
                + line.windows.map { metric in
                    Row(id: line.id + metric.id, name: metric.label, window: AccountLimitWindow(metric: metric),
                        runsOutAt: line.runsOutAt[metric.id])
                }
        }
    }

    /// The `limit` windows closest to running out, each named by its account's address and its
    /// harness's mark, as the Home band lists them.
    static func closest(_ lines: [TokenUsageLimitLine], limit: Int) -> [Row] {
        let all = lines.flatMap { line in
            line.windows.map { metric in
                Row(id: line.id + metric.id, name: "\(line.address) · \(metric.label)", harness: line.harness,
                    window: AccountLimitWindow(metric: metric), runsOutAt: line.runsOutAt[metric.id])
            }
        }
        return Array(all.sorted { lhs, rhs in
            switch (lhs.runsOutAt, rhs.runsOutAt) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return (lhs.window?.remainingPercent ?? 100) < (rhs.window?.remainingPercent ?? 100)
            }
        }.prefix(limit))
    }
}

// MARK: - Home band

/// Usage on Home, over the projects: today's tokens and their API-equivalent cost, the last two
/// weeks as bars, and the limits closest to running out with the pace they are used at. The
/// header opens Settings › Usage.
struct TokenUsageHomeBand: View {
    /// Read in the body, so a new count redraws the band and nothing around it.
    let overview: () -> TokenUsageOverview
    let columns: Int
    let onOpen: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let overview = overview()
        VStack(alignment: .leading, spacing: ParitySpace.s4) {
            Button(action: onOpen) {
                header(overview)
                    .padding(.horizontal, ParitySpace.s12)
                    .frame(minHeight: 32, alignment: .leading)
                    .background(isHovering ? ParityTheme.hoverFill : .clear,
                                in: RoundedRectangle(cornerRadius: ParityRadius.row))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(L10n.string("Open Settings › Usage"))
            .accessibilityAddTraits(.isHeader)

            let limits = TokenUsageLimitRows.closest(overview.limits, limit: 3)
            Group {
                if columns > 1 {
                    HStack(alignment: .top, spacing: NewTaskHomeLayout.columnSpacing) {
                        bars(overview).frame(width: columns > 2 ? 360 : 260)
                        if !limits.isEmpty {
                            TokenUsageLimitRows(rows: limits, scale: interfaceScale, isCompact: true)
                                .frame(maxWidth: 560, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: ParitySpace.s12) {
                        bars(overview)
                        if !limits.isEmpty {
                            TokenUsageLimitRows(rows: limits, scale: interfaceScale, isCompact: true)
                        }
                    }
                }
            }
            .padding(.leading, 34)
            .padding(.trailing, ParitySpace.s12)
        }
    }

    private func header(_ overview: TokenUsageOverview) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ParitySpace.s8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.parity(.caption, weight: .medium, scale: interfaceScale))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(L10n.string("Usage"))
                .font(.parity(.body, weight: .semibold, scale: interfaceScale))
                .lineLimit(1)
                .layoutPriority(1)
            Text(overview.days.isEmpty ? L10n.string("Counting this Mac's transcripts…")
                 : TokenUsageFormat.today(overview.today))
                .font(.parity(.caption, scale: interfaceScale).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: ParitySpace.s8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10 * interfaceScale, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func bars(_ overview: TokenUsageOverview) -> some View {
        if !overview.days.isEmpty {
            TokenUsageDayBars(days: Array(overview.days.suffix(14)), highlighted: 1, height: 34,
                              caption: L10n.string("Last 14 days, API equivalent"), scale: interfaceScale)
                .padding(.top, 2)
        }
    }
}

// MARK: - Settings › Usage

/// Settings › Usage: the plan limits as the stock apps' usage pages show them, then what this
/// Mac's transcripts say about tokens, by day, by kind and by model, project, task or account.
struct TokenUsagePage: View {
    /// Read in the body, so a new count redraws the page and nothing around it. Its days are empty
    /// while nothing is counted.
    let overview: () -> TokenUsageOverview
    /// Counting is on; the first read of the transcripts may still be under way.
    let isCounting: () -> Bool
    let limitsCheckedAt: () -> Date?
    /// The switch that turns counting on and off, as Settings draws its rows.
    let switchRow: AnyView
    @State var range: TokenUsageRange = .week
    @State var grouping: TokenUsageGrouping = .project
    @State private var showsAllRows = false

    var body: some View {
        let overview = overview()
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            if !overview.limits.isEmpty { limits(overview) }
            if isCounting() {
                if !overview.limits.isEmpty { Divider() }
                if overview.days.isEmpty {
                    Text(L10n.string("Counting this Mac's transcripts…"))
                        .font(.parity(.caption, scale: 1)).foregroundStyle(.secondary)
                } else {
                    tokens(overview)
                }
            }
            switchRow
        }
    }

    // MARK: Limits

    private func limits(_ overview: TokenUsageOverview) -> some View {
        VStack(alignment: .leading, spacing: ParitySpace.s12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("Plan limits")).font(SettingsMetrics.groupTitleFont)
                Spacer()
                if let limitsCheckedAt = limitsCheckedAt() {
                    Text(L10n.format("Updated %@", limitsCheckedAt.formatted(.relative(presentation: .named))))
                        .font(.parity(.caption, scale: 1)).foregroundStyle(.secondary)
                }
            }
            TokenUsageLimitRows(rows: TokenUsageLimitRows.accounts(overview.limits))
        }
    }

    // MARK: Tokens

    private func tokens(_ overview: TokenUsageOverview) -> some View {
        let amount = overview.amount(over: range)
        return VStack(alignment: .leading, spacing: ParitySpace.s20) {
            HStack(alignment: .center) {
                Text(L10n.string("Token usage")).font(SettingsMetrics.groupTitleFont)
                Spacer()
                Picker(L10n.string("Range"), selection: $range) {
                    ForEach(TokenUsageRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack(alignment: .top, spacing: ParitySpace.s32) {
                stat(L10n.string("Tokens"), TokenUsageFormat.tokens(amount.total))
                stat(L10n.string("API equivalent"), TokenUsageFormat.cost(amount.cost))
                stat(L10n.string("Requests"), TokenUsageFormat.tokens(Int64(amount.requests)))
                if let share = amount.cacheReadShare {
                    stat(L10n.string("Read from cache"), TokenUsageFormat.percent(share))
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: ParitySpace.s8) {
                Text(L10n.string("API equivalent by day"))
                    .font(.parity(.caption, weight: .medium, scale: 1)).foregroundStyle(.secondary)
                TokenUsageDayBars(days: overview.days, highlighted: range.days, height: 92, showsAxis: true)
            }

            kinds(amount)
            breakdown(overview.rows(range, grouping), total: amount)
            footnote
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.parity(.caption, scale: 1)).foregroundStyle(.secondary)
            Text(value).font(.parity(.section, scale: 1).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    /// The range's tokens and cost split by kind: two bars over the same four colours, then each
    /// kind's tokens and cost with their shares.
    private func kinds(_ amount: TokenUsageAmount) -> some View {
        let total = Double(max(amount.total, 1))
        let cost = max(amount.cost ?? 0, 0.000_001)
        return VStack(alignment: .leading, spacing: ParitySpace.s8) {
            Text(L10n.string("By kind"))
                .font(.parity(.caption, weight: .medium, scale: 1)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: ParitySpace.s12, verticalSpacing: ParitySpace.s8) {
                GridRow {
                    Text(L10n.string("Tokens")).font(.parity(.caption, scale: 1)).foregroundStyle(.secondary)
                    shareBar { Double($0.tokens(in: amount)) / total }
                }
                if amount.cost != nil {
                    GridRow {
                        Text(L10n.string("API equivalent")).font(.parity(.caption, scale: 1)).foregroundStyle(.secondary)
                        shareBar { (amount.kindCost[$0] ?? 0) / cost }
                    }
                }
            }
            Grid(alignment: .trailing, horizontalSpacing: ParitySpace.s16, verticalSpacing: ParitySpace.s4) {
                ForEach(TokenUsageKind.allCases) { kind in
                    let tokens = kind.tokens(in: amount)
                    GridRow {
                        HStack(spacing: ParitySpace.s8) {
                            RoundedRectangle(cornerRadius: 2).fill(TokenUsageColors.kind(kind)).frame(width: 9, height: 9)
                            Text(kind.title)
                        }
                        .gridColumnAlignment(.leading)
                        Text(TokenUsageFormat.tokens(tokens))
                        Text(TokenUsageFormat.percent(Double(tokens) / total)).foregroundStyle(.secondary)
                        if amount.cost != nil {
                            Text(TokenUsageFormat.cost(amount.kindCost[kind] ?? 0))
                            Text(TokenUsageFormat.percent((amount.kindCost[kind] ?? 0) / cost)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.parity(.caption, scale: 1).monospacedDigit())
                }
            }
            .padding(.top, ParitySpace.s4)
        }
    }

    private func shareBar(_ share: @escaping (TokenUsageKind) -> Double) -> some View {
        GeometryReader { geometry in
            let kinds = TokenUsageKind.allCases
            let gap: CGFloat = 2
            let room = geometry.size.width - gap * CGFloat(kinds.count - 1)
            HStack(spacing: gap) {
                ForEach(kinds) { kind in
                    let width = room * CGFloat(share(kind))
                    if width >= 0.5 {
                        Rectangle().fill(TokenUsageColors.kind(kind)).frame(width: max(2, width))
                    }
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
    }

    // MARK: Breakdown

    private func breakdown(_ rows: [TokenUsageRow], total: TokenUsageAmount) -> some View {
        let shown = showsAllRows ? rows : Array(rows.prefix(6))
        let peak = Double(max(rows.map { $0.amount.cost ?? Double($0.amount.total) }.max() ?? 1, 0.000_001))
        return VStack(alignment: .leading, spacing: ParitySpace.s8) {
            HStack(alignment: .center) {
                Text(L10n.string("Where it went"))
                    .font(.parity(.caption, weight: .medium, scale: 1)).foregroundStyle(.secondary)
                Spacer()
                Picker(L10n.string("Group by"), selection: $grouping) {
                    ForEach(TokenUsageGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: ParitySpace.s12, verticalSpacing: ParitySpace.s8) {
                ForEach(shown) { row in
                    GridRow {
                        HStack(spacing: ParitySpace.s8) {
                            if let harness = row.harness { HarnessIdentityIcon(harness: harness, size: 13) }
                            Text(row.title).font(.parity(.control, scale: 1)).lineLimit(1).truncationMode(.middle)
                            if let detail = row.detail {
                                Text(detail).font(.parity(.caption, scale: 1)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geometry in
                            let value = row.amount.cost ?? Double(row.amount.total)
                            Capsule().fill(ParityTheme.accent)
                                .frame(width: max(2, geometry.size.width * CGFloat(value / peak)), height: 5)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: 96, height: 12)
                        Text(TokenUsageFormat.tokens(row.amount.total))
                            .font(.parity(.caption, scale: 1).monospacedDigit())
                            .gridColumnAlignment(.trailing)
                        Text(TokenUsageFormat.cost(row.amount.cost))
                            .font(.parity(.caption, scale: 1).monospacedDigit())
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if rows.count > 6 {
                Button(showsAllRows ? L10n.string("Show less") : L10n.format("Show %lld more", rows.count - 6)) {
                    showsAllRows.toggle()
                }
                .buttonStyle(.plain)
                .font(.parity(.caption, scale: 1))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footnote: some View {
        let tables = TokenUsagePrices.tables.map { table in
            let copied = (try? Date(table.copied, strategy: .iso8601.year().month().day()))
                .map { $0.formatted(date: .numeric, time: .omitted) } ?? table.copied
            return "\(table.provider) \(copied)"
        }.joined(separator: ", ")
        return Text(L10n.format("API equivalent is an estimate at public API prices (%@), not what a subscription pays.", tables))
            .font(.parity(.caption, scale: 1))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
