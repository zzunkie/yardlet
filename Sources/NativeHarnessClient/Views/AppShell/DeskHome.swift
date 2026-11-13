import AppKit
import SwiftUI

/// Which view the home shows: the desk ("Now") or the projects. The home opens on the one chosen last.
enum NewTaskHomeView: String, CaseIterable, Sendable {
    case now
    case projects

    /// Where the choice is kept.
    static let key = "YardletHomeView"
}

/// The desk shows only while this development switch is on, until it becomes the home's first view:
/// `defaults write com.zzunkie.yardlet YardletDeskPreview -bool true` turns it on, `defaults delete` off.
/// With it on, the home's header offers "Now | Projects".
enum DeskPreview {
    static let key = "YardletDeskPreview"
}

/// Where the home's header stands, the same in both views so it stays put as they switch: over the
/// columns of a wide home, over the single column of a narrow one.
struct DeskHeaderPlacement: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        if width < DeskLayout.twoColumnWidth {
            content
                .frame(maxWidth: NewTaskHomeLayout.composerWidth)
                .padding(.horizontal, NewTaskHomeLayout.inset)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 10)
        } else {
            content
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .padding(.bottom, 10)
        }
    }
}

/// The home's header: today's date, what the view counts, and the view switch.
struct DeskHeader<Trailing: View>: View {
    let date: Date
    var summary: String?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(date, format: .dateTime.month(.wide).day().weekday(.wide))
                    .font(.system(size: 18 * interfaceScale, weight: .semibold))
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                if let summary {
                    Text(summary)
                        .font(.system(size: 13 * interfaceScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
    }
}

/// "Now | Projects", the home's two views.
struct NewTaskHomeViewSwitch: View {
    @Binding var selection: NewTaskHomeView

    var body: some View {
        Picker(L10n.string("Home view"), selection: $selection) {
            Text(L10n.string("Now")).tag(NewTaskHomeView.now)
            Text(L10n.string("Projects")).tag(NewTaskHomeView.projects)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The desk, the home's "Now" view: what waits on the person, what runs and what just finished, and
/// today, from what the home already reads (`DeskProjection`). Choosing a line that waits on the person
/// or holds a result answers it in the composer's place (`NewTaskHomeAction.reply`); a family opens its
/// task, a scheduled run its schedule. The lines keep their places while the desk shows, and a new one
/// joins the end of its zone. The layout follows the home's own width (`DeskLayout.choose`) and changes
/// only with it. The keyboard goes through the zones as it goes through the projects
/// (`NewTaskHomeListKeyboard`).
struct DeskHome<Switch: View, Bottom: View>: View {
    let activity: NewTaskHomeActivity
    /// The home's own size.
    let size: CGSize
    var calendarOn = false
    /// The task the composer answers now, whose line stays marked.
    var replyTaskID: UUID?
    let onAction: (NewTaskHomeAction) -> Void
    @Binding var keyboard: NewTaskHomeListKeyboard
    var focus: FocusState<NewTaskHomeLists.Part?>.Binding
    /// The lines the desk lists now, in the keyboard's order.
    let onListed: ([NewTaskHomeListKeyboard.Entry]) -> Void
    let onReturnToComposer: () -> Void
    @ViewBuilder let viewSwitch: () -> Switch
    /// What stands under the desk: the notices, the folder's rows, the title and the composer, or the
    /// composer answering a task.
    @ViewBuilder let bottom: () -> Bottom

    @Environment(TaskPullRequestMonitor.self) private var pullRequests: TaskPullRequestMonitor?
    /// Each zone's lines in the places they had since the desk appeared.
    @State private var places: [DeskZone: [String]] = [:]
    /// This screen's own set of tasks in the pull request lookup.
    @State private var screenID = UUID()
    /// "Show more" under the results just finished was chosen.
    @State private var showsAllFinished = false

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.desk)
#endif
        let desk = kept(DeskProjection.desk(
            sessions: activity.sessions, details: activity.details, shellBusy: activity.shellBusy,
            archivedParents: activity.archivedParents, agents: activity.agents,
            pullRequest: activity.pullRequest ?? { pullRequests?.pullRequest(for: $0) }, schedules: activity.schedules,
            now: activity.now))
        let layout = DeskLayout.choose(width: size.width, calendarOn: calendarOn)
        let entries = entries(desk)
        Group {
            if desk.isQuiet {
                quiet(desk)
            } else {
                switch layout {
                case .one: one(desk)
                case .two, .zones: two(desk)
                }
            }
        }
        .onChange(of: entries, initial: true) { _, entries in onListed(entries) }
        .onChange(of: DeskPlaces(desk), initial: true) { _, listed in
            for (zone, ids) in listed.zones { places[zone] = NewTaskHomeListsProjection.places(places[zone] ?? [], listing: ids) }
        }
        .task(id: pullRequestTargets) { pullRequests?.showHome(pullRequestTargets, screen: screenID) }
        .onDisappear { pullRequests?.showHome([], screen: screenID) }
    }

    // MARK: - Layouts

    private func header(_ desk: Desk) -> some View {
        DeskHeader(date: activity.now, summary: Self.summary(desk), trailing: viewSwitch)
    }

    /// Two columns: what waits over the composer, and beside them today, what runs and what finished.
    private func two(_ desk: Desk) -> some View {
        VStack(spacing: 0) {
            header(desk)
                .modifier(DeskHeaderPlacement(width: size.width))
            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 0) {
                    DeskScroll { keyboardZones(desk) { waitingZone(desk, detailLines: 2) } }
                    bottomPane
                }
                .frame(maxWidth: .infinity)
                DeskScroll {
                    VStack(alignment: .leading, spacing: 20) {
                        todayZone(desk)
                        runningZone(desk, showsMembers: true)
                    }
                    .padding(.bottom, 16)
                }
                .frame(width: max(300, (size.width * 0.27).rounded()))
            }
            .padding(.horizontal, 30)
        }
    }

    /// One column: the zones over the composer, families without their members.
    private func one(_ desk: Desk) -> some View {
        VStack(spacing: 0) {
            header(desk)
                .modifier(DeskHeaderPlacement(width: size.width))
            DeskScroll {
                keyboardZones(desk) {
                    VStack(alignment: .leading, spacing: 18) {
                        waitingZone(desk, detailLines: 1)
                        runningZone(desk, showsMembers: false)
                        todayZone(desk)
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: NewTaskHomeLayout.composerWidth)
            .padding(.horizontal, NewTaskHomeLayout.inset)
            .frame(maxWidth: .infinity)
            bottomPane
                .padding(.horizontal, NewTaskHomeLayout.inset)
        }
    }

    /// A quiet day: nothing waits, runs or is unread. Today and the composer, as the two apps' homes.
    private func quiet(_ desk: Desk) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(desk)
                    keyboardZones(desk) { todayZone(desk) }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, NewTaskHomeLayout.inset)
                .padding(.top, max(28, size.height * 0.18))
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            bottomPane
        }
    }

    private var bottomPane: some View {
        VStack(spacing: 10) { bottom() }
            .frame(maxWidth: NewTaskHomeLayout.composerWidth)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
    }

    /// The part of the desk that holds the keyboard: the zones the person goes through with ↑ and ↓.
    private func keyboardZones<Content: View>(_ desk: Desk, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable(!entries(desk).isEmpty, interactions: .edit)
            .focused(focus, equals: .desk)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { handle(.up) }
            .onKeyPress(.downArrow) { handle(.down) }
            .onKeyPress(.return) { handle(.return) }
            .onKeyPress(keys: [.tab, KeyEquivalent(Character(UnicodeScalar(NSBackTabCharacter)!))]) { _ in handle(.tab) }
    }

    // MARK: - Zones

    private func waitingZone(_ desk: Desk, detailLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            DeskSectionTitle(title: L10n.string("Waiting on you (home)"),
                             count: desk.waiting.isEmpty ? nil : "\(desk.waiting.count)")
            if desk.waiting.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                    Text(L10n.string("Nothing is waiting on you"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
            }
            ForEach(desk.waiting) { item in
                let entry = NewTaskHomeListKeyboard.Entry.row(.desk(.waiting), item.id.uuidString)
                DeskWaitingRow(
                    item: item, place: place(of: item.session), detailLines: detailLines,
                    isHighlighted: isHighlighted(entry), isAnswering: replyTaskID == item.id,
                    answerLine: activity.answerLine, requestLine: activity.requestLine,
                    onChoose: { opens in onAction(Self.action(item.session, opens: opens || replyTaskID == item.id)) },
                    onMarkRead: item.canMarkRead ? { activity.onMarkRead([item.id]) } : nil)
                    .equatable()
            }
        }
    }

    @ViewBuilder
    private func runningZone(_ desk: Desk, showsMembers: Bool) -> some View {
        if !desk.families.isEmpty || !desk.finished.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !desk.families.isEmpty {
                    DeskSectionTitle(title: L10n.string("Running (home)"), count: "\(desk.running)")
                    ForEach(desk.families) { family in
                        let entry = NewTaskHomeListKeyboard.Entry.row(.desk(.running), family.id.uuidString)
                        DeskFamilyView(
                            family: family, place: place(of: family.root), showsMembers: showsMembers,
                            isHighlighted: isHighlighted(entry), latestTurn: activity.latestTurn,
                            onOpen: { onAction(.openTask($0)) })
                            .equatable()
                    }
                }
                if !desk.finished.isEmpty {
                    DeskSectionTitle(title: L10n.string("Just finished"), count: "\(desk.finished.count)")
                        .padding(.top, desk.families.isEmpty ? 0 : 14)
                    ForEach(shownFinished(desk)) { session in
                        let entry = NewTaskHomeListKeyboard.Entry.row(.desk(.finished), session.id.uuidString)
                        DeskFinishedRow(
                            session: session, place: place(of: session), isHighlighted: isHighlighted(entry),
                            isAnswering: replyTaskID == session.id, answerLine: activity.answerLine,
                            onChoose: { opens in onAction(Self.action(session, opens: opens || replyTaskID == session.id)) },
                            onMarkRead: { activity.onMarkRead([session.id]) })
                            .equatable()
                    }
                    if desk.finished.count > DeskLines.finished {
                        NewTaskHomeRow(isHighlighted: isHighlighted(.toggle(.desk(.finished))), showsChevron: false,
                                       action: { showsAllFinished.toggle() }) {
                            Text(showsAllFinished ? L10n.string("Show less")
                                 : L10n.format("Show %lld more", desk.finished.count - DeskLines.finished))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 21)
                        }
                    }
                }
            }
        }
    }

    private func todayZone(_ desk: Desk) -> some View {
        DeskTodayZone(runs: desk.today, now: activity.now,
                      highlighted: focus.wrappedValue == .desk ? keyboard.highlightedEntry : nil,
                      onOpenSchedule: activity.onOpenSchedule)
    }

    // MARK: - Lines and keyboard

    /// Where a task is listed, and "Subtask" for one started from another.
    private func place(of session: SessionRecord) -> String {
        let name = activity.placeName(session)
        return session.parentTaskID == nil ? name : name + " · " + L10n.string("Subtask")
    }

    /// A task that waits or holds a result is answered in the composer's place unless `opens`.
    static func action(_ session: SessionRecord, opens: Bool) -> NewTaskHomeAction {
        opens ? .openTask(session.id) : .reply(session.id)
    }

    /// The results just finished the desk lists: the most recent few, all once "Show more" is chosen.
    private func shownFinished(_ desk: Desk) -> [SessionRecord] {
        showsAllFinished ? desk.finished : Array(desk.finished.prefix(DeskLines.finished))
    }

    /// The desk's lines in the keyboard's order: the zones as they stand, today's runs last.
    private func entries(_ desk: Desk) -> [NewTaskHomeListKeyboard.Entry] {
        desk.waiting.map { .row(.desk(.waiting), $0.id.uuidString) }
            + desk.families.map { .row(.desk(.running), $0.id.uuidString) }
            + shownFinished(desk).map { .row(.desk(.finished), $0.id.uuidString) }
            + (desk.finished.count > DeskLines.finished ? [.toggle(.desk(.finished))] : [])
            + desk.today.map { .row(.desk(.today), $0.id) }
    }

    private func isHighlighted(_ entry: NewTaskHomeListKeyboard.Entry) -> Bool {
        focus.wrappedValue == .desk && keyboard.highlightedEntry == entry
    }

    private func handle(_ key: NewTaskHomeListKeyboard.Key) -> KeyPress.Result {
        switch keyboard.press(key) {
        case .handled:
            if let entry = keyboard.highlightedEntry, entry.part != .desk { focus.wrappedValue = entry.part }
            return .handled
        case .ignored:
            return .ignored
        case .returnToComposer:
            onReturnToComposer()
            return .handled
        case .perform(.toggle(.desk(.finished))):
            showsAllFinished.toggle()
            return .handled
        case let .perform(entry):
            guard case let .row(.desk(zone), id) = entry else { return .ignored }
            switch zone {
            case .waiting, .finished:
                guard let taskID = UUID(uuidString: id) else { return .ignored }
                onAction(taskID == replyTaskID ? .openTask(taskID) : .reply(taskID))
            case .running:
                guard let taskID = UUID(uuidString: id) else { return .ignored }
                onAction(.openTask(taskID))
            case .today:
                guard let scheduleID = id.split(separator: ":").first.flatMap({ UUID(uuidString: String($0)) }) else {
                    return .ignored
                }
                onAction(.openSchedule(scheduleID))
            }
            return .handled
        }
    }

    /// The zones' lines in the places they had since the desk appeared.
    private func kept(_ desk: Desk) -> Desk {
        var desk = desk
        desk.waiting = NewTaskHomeListsProjection.keepingPlaces(places[.waiting] ?? [], of: desk.waiting) { $0.id.uuidString }
        desk.families = NewTaskHomeListsProjection.keepingPlaces(places[.running] ?? [], of: desk.families) { $0.id.uuidString }
        desk.finished = NewTaskHomeListsProjection.keepingPlaces(places[.finished] ?? [], of: desk.finished) { $0.id.uuidString }
        return desk
    }

    /// The tasks the pull request lookup is asked about while the desk shows: the most recent ones.
    private var pullRequestTargets: [TaskPullRequestTarget] {
        NewTaskHomeListsProjection.pullRequestCandidates(folder: nil, sessions: activity.sessions)
            .map { TaskPullRequestTarget(session: $0) }
    }

    // MARK: - Words

    /// "3 waiting · 4 running · 2 left today": the header's counts, each the zone's own.
    static func summary(_ desk: Desk) -> String {
        var parts = [desk.waiting.isEmpty ? L10n.string("Nothing waiting") : L10n.format("%lld waiting", desk.waiting.count)]
        if desk.running > 0 { parts.append(L10n.format("%lld running now", desk.running)) }
        if desk.remainingToday > 0 { parts.append(L10n.format("%lld left today", desk.remainingToday)) }
        return parts.joined(separator: " · ")
    }
}

/// A zone's scroll area, faded at its foot where more of it scrolls, so a cut line reads as one that goes on.
private struct DeskScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView { content() }
            .defaultScrollAnchor(.top)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [ParityTheme.canvas.opacity(0), ParityTheme.canvas], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                    .allowsHitTesting(false)
            }
    }
}

/// How many lines the desk gives what could grow long.
enum DeskLines {
    /// The members a family lists; its counts say all of them.
    static let members = 4
    /// The unread threads the today zone names; its count says all of them.
    static let mail = 3
    /// The results just finished it lists before "Show more", as a project lists its lines.
    static let finished = 5
}

/// The ids each zone lists, which the desk keeps the places of.
private struct DeskPlaces: Equatable {
    let zones: [DeskZone: [String]]

    init(_ desk: Desk) {
        zones = [
            .waiting: desk.waiting.map(\.id.uuidString),
            .running: desk.families.map(\.id.uuidString),
            .finished: desk.finished.map(\.id.uuidString),
        ]
    }
}

/// A zone's title and its count.
struct DeskSectionTitle: View {
    let title: String
    var count: String?
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 14 * interfaceScale, weight: .semibold))
            if let count {
                Text(count).font(.system(size: 13 * interfaceScale).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Lines

/// A line of "Waiting on you": the state, the task and where it is, then what it needs on its own line
/// (the question, the command to approve, the error, the report's first line). A long command ends in
/// an ellipsis; its approval card in the composer's place shows it whole. Equal when it would show the
/// same line, so a home redraw that changed nothing it shows leaves it alone.
struct DeskWaitingRow: View, @MainActor Equatable {
    let item: DeskWaitingItem
    let place: String
    var detailLines = 2
    var isHighlighted = false
    var isAnswering = false
    let answerLine: (UUID) -> String?
    let requestLine: (SessionRecord) -> String?
    /// Chosen: true to open the task rather than answer it in place (a double-click).
    let onChoose: (Bool) -> Void
    let onMarkRead: (() -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.place == rhs.place && lhs.detailLines == rhs.detailLines
            && lhs.isHighlighted == rhs.isHighlighted && lhs.isAnswering == rhs.isAnswering
            && (lhs.onMarkRead != nil) == (rhs.onMarkRead != nil)
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.deskRow)
#endif
        NewTaskHomeRow(isHighlighted: isHighlighted, isAnswering: isAnswering, symbol: "arrowshape.turn.up.left",
                       markRead: onMarkRead, action: { onChoose((NSApp.currentEvent?.clickCount ?? 1) > 1) }) {
            VStack(alignment: .leading, spacing: 3) {
                // The place goes before the title is cut.
                ViewThatFits(in: .horizontal) {
                    firstLine(showsPlace: true)
                    firstLine(showsPlace: false)
                }
                if let detail {
                    detailText(detail)
                        .padding(.leading, 21)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityAddTraits(isAnswering ? .isSelected : [])
    }

    private func firstLine(showsPlace: Bool) -> some View {
        HStack(spacing: 7) {
            mark.accessibilityHidden(true)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            HarnessIdentityIcon(harness: item.session.harness, size: 14)
                .accessibilityLabel(item.session.harness.displayName)
            Text(item.session.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if showsPlace {
                Text(place)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            NewTaskHomeTime(date: item.session.updatedAt)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let status = item.status {
            SidebarTaskStatusView(status: status)
        } else {
            Image(systemName: "xmark.circle")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 14, height: 14)
        }
    }

    private var label: String {
        switch item.kind {
        case let .request(status), let .stopped(status): status.homeName
        case .checksFailed: L10n.string("Checks failed")
        case .report: L10n.string("Coordinator report")
        }
    }

    /// What the line says under the title.
    private var detail: (text: String, isCommand: Bool)? {
        switch item.kind {
        case .request(.awaitingApproval):
            return requestLine(item.session).map { ($0, true) }
        case .request:
            return requestLine(item.session).map { ($0, false) }
        case let .stopped(status):
            return status.homeDetail.map { ($0, false) }
        case let .checksFailed(pullRequest):
            return (L10n.format("Pull request #%lld: checks failed", pullRequest.number), false)
        case .report:
            return answerLine(item.session.id).map { ($0, false) }
        }
    }

    @ViewBuilder
    private func detailText(_ detail: (text: String, isCommand: Bool)) -> some View {
        if detail.isCommand {
            Text(detail.text)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(detail.text)
                .font(.system(size: 13))
                .lineLimit(detailLines)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A family in "Running": its top task, what its tasks do by state ("2 running · 1 to approve"), and,
/// with room, its members with their marks and how long each has run. A task running alone says how
/// long it has run instead.
struct DeskFamilyView: View, @MainActor Equatable {
    let family: DeskFamily
    let place: String
    var showsMembers = true
    var isHighlighted = false
    let latestTurn: (UUID) -> TaskLatestTurn?
    let onOpen: (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.family == rhs.family && lhs.place == rhs.place && lhs.showsMembers == rhs.showsMembers
            && lhs.isHighlighted == rhs.isHighlighted
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.deskRow)
#endif
        VStack(alignment: .leading, spacing: 0) {
            NewTaskHomeRow(isHighlighted: isHighlighted, action: { onOpen(family.root.id) }) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        familyMark.accessibilityHidden(true)
                        HarnessIdentityIcon(harness: family.root.harness, size: 14)
                            .accessibilityLabel(family.root.harness.displayName)
                        Text(family.root.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if family.members.isEmpty, family.status.map(DeskProjection.runs) == true,
                           let since = latestTurn(family.root.id)?.startedAt {
                            NewTaskHomeElapsed(since: since)
                        }
                    }
                    Text(([place] + Self.facts(family)).joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 21)
                }
                .padding(.vertical, 4)
            }
            if showsMembers, !family.members.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(family.members.prefix(DeskLines.members)) { member in
                        memberLine(member)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Rectangle().fill(ParityTheme.separator).frame(width: 1).padding(.leading, 17).padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var familyMark: some View {
        if let status = family.status {
            SidebarTaskStatusView(status: status)
        } else {
            // The top task does nothing itself while its family works.
            Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 7, height: 7).frame(width: 14, height: 14)
        }
    }

    private func memberLine(_ member: DeskFamily.Member) -> some View {
        Button { onOpen(member.id) } label: {
            HStack(spacing: 7) {
                SidebarTaskStatusView(status: member.status).accessibilityHidden(true)
                Text(member.session.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(member.status.homeName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .trailing)
                if DeskProjection.runs(member.status), let since = latestTurn(member.id)?.startedAt {
                    NewTaskHomeElapsed(since: since)
                }
            }
            .padding(.leading, 31)
            .padding(.trailing, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel(member.session.title + ", " + member.status.accessibilityName)
    }

    /// What the family's tasks do, by state; a task alone, its state's name. Then its agents.
    static func facts(_ family: DeskFamily) -> [String] {
        var facts: [String] = []
        func count(_ value: Int, _ key: String.LocalizationValue) { if value > 0 { facts.append(L10n.format(key, value)) } }
        if family.members.isEmpty {
            if let status = family.status { facts.append(status.homeName) }
        } else {
            let statuses = family.members.map(\.status) + [family.status].compactMap { $0 }
            count(family.running, "%lld running in the family")
            count(statuses.filter { $0 == .awaitingApproval }.count, "%lld to approve")
            count(statuses.filter { $0 == .needsInput }.count, "%lld to answer")
            count(statuses.filter { $0 == .waitingInBrowser }.count, "%lld in the browser")
        }
        if family.agents == 1 { facts.append(L10n.string("1 agent")) } else { count(family.agents, "%lld agents") }
        return facts
    }
}

/// A line of "Just finished": a result that asks nothing, with its answer's first line.
struct DeskFinishedRow: View, @MainActor Equatable {
    let session: SessionRecord
    let place: String
    var isHighlighted = false
    var isAnswering = false
    let answerLine: (UUID) -> String?
    let onChoose: (Bool) -> Void
    let onMarkRead: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session && lhs.place == rhs.place && lhs.isHighlighted == rhs.isHighlighted
            && lhs.isAnswering == rhs.isAnswering
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.deskRow)
#endif
        NewTaskHomeRow(isHighlighted: isHighlighted, isAnswering: isAnswering, symbol: "arrowshape.turn.up.left",
                       markRead: onMarkRead, action: { onChoose((NSApp.currentEvent?.clickCount ?? 1) > 1) }) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    SidebarTaskStatusView(status: .unread).accessibilityHidden(true)
                    HarnessIdentityIcon(harness: session.harness, size: 14)
                        .accessibilityLabel(session.harness.displayName)
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    NewTaskHomeTime(date: session.updatedAt)
                }
                Text(([place] + [answerLine(session.id)].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 21)
            }
            .padding(.vertical, 4)
        }
        .accessibilityAddTraits(isAnswering ? .isSelected : [])
    }
}

/// "Today": today's scheduled runs in time order, then the inboxes' unread threads while the mailbox is
/// on. It reads the mailbox in its own body, so new mail redraws this zone alone. Empty, it is not there.
struct DeskTodayZone: View {
    let runs: [DeskScheduledRun]
    let now: Date
    var highlighted: NewTaskHomeListKeyboard.Entry?
    let onOpenSchedule: (UUID) -> Void
    @Environment(\.mailbox) private var mailbox

    var body: some View {
        let mail = mailbox?.isEnabled == true ? DeskProjection.unreadMail(mailbox?.threads ?? []) : []
        if !runs.isEmpty || !mail.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DeskSectionTitle(title: L10n.string("Today"),
                                 count: runs.contains { $0.kind == .upcoming }
                                     ? L10n.format("%lld left", runs.filter { $0.kind == .upcoming }.count) : nil)
                ForEach(runs) { run in runLine(run) }
                if !mail.isEmpty { mailBlock(mail).padding(.top, runs.isEmpty ? 0 : 8) }
            }
        }
    }

    private func runLine(_ run: DeskScheduledRun) -> some View {
        let isPast = run.kind != .upcoming
        return NewTaskHomeRow(isHighlighted: highlighted == .row(.desk(.today), run.id), showsChevron: false,
                              action: { onOpenSchedule(run.schedule.id) }) {
            Text(Self.time(run.at))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(isPast ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: 40, alignment: .leading)
            Image(systemName: "clock")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(run.schedule.name)
                .font(.system(size: 13))
                .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(Self.note(run.kind))
                .font(.system(size: 12))
                .foregroundStyle(run.kind == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .fixedSize()
        }
    }

    private func mailBlock(_ mail: [MailThreadSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(L10n.string("Unread mail")).font(.system(size: 13, weight: .medium))
                Text(verbatim: "\(mail.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .accessibilityElement(children: .combine)
            ForEach(mail.prefix(DeskLines.mail)) { thread in
                HStack(spacing: 8) {
                    Text(thread.senders.first.map { $0.name ?? $0.address } ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                    Text(thread.subject)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 30)
                .padding(.trailing, 10)
                .frame(height: 24)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "17:40": the run's time on the day's clock.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func note(_ kind: DeskScheduledRun.Kind) -> String {
        switch kind {
        case .ran: L10n.string("Ran")
        case .failed: L10n.string("Failed")
        case .upcoming: L10n.string("Scheduled")
        }
    }
}
