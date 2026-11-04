import SwiftUI

/// Imports the schedules the Claude app and the Codex app keep, styled as the other-app conversation
/// import (`OtherAppImportSheet`). It lists what it found per app, checks the ones on and still ahead,
/// and copies the chosen ones into Yardlet. The originals stay in their apps, untouched; after the
/// import the sheet says how to keep them from running twice.
struct ScheduleImportSheet: View {
    let listing: ScheduleImportListing?
    let now: Date
    let onImport: ([ImportableSchedule]) -> Int
    let onDismiss: () -> Void

    @State private var selection: Set<String>
    @State private var importedCount: Int?

    init(listing: ScheduleImportListing?, now: Date = Date(), selection: Set<String>? = nil, importedCount: Int? = nil,
         onImport: @escaping ([ImportableSchedule]) -> Int, onDismiss: @escaping () -> Void) {
        self.listing = listing
        self.now = now
        self.onImport = onImport
        self.onDismiss = onDismiss
        _selection = State(initialValue: selection ?? listing?.preselected(now: now) ?? [])
        _importedCount = State(initialValue: importedCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.string("Import Schedules from Other Apps")).font(.headline)
                Spacer()
                Button(L10n.string("Done"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Text(L10n.string("Scheduled tasks in the Claude app and Codex automations. Importing copies them; the originals stay as they are."))
                .font(.callout).foregroundStyle(.secondary)
            list
            if let importedCount { doneNote(importedCount) }
            footer
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .onChange(of: listing) { _, listing in
            selection = listing?.preselected(now: now) ?? []
        }
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let listing {
                    if listing.all.isEmpty {
                        Text(L10n.string("Neither the Claude app nor the Codex app has scheduled tasks on this Mac."))
                            .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity)
                    }
                    section(L10n.string("Claude app"), listing.claude, listing: listing)
                    section(L10n.string("Codex app"), listing.codex, listing: listing)
                } else {
                    ProgressView().padding(24).frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .background(ParityTheme.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(L10n.string("Import Schedules from Other Apps"))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ImportableSchedule], listing: ScheduleImportListing) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { row($0, listing: listing) }
        }
    }

    private func row(_ item: ImportableSchedule, listing: ScheduleImportListing) -> some View {
        let imported = listing.isImported(item)
        let notes = OtherAppScheduleImport.notes(for: item, linkedTask: listing.linkedTasks[item.id], isImported: imported)
        let detail = [
            item.trigger.map { ScheduleText.summary($0, now: now) } ?? item.rule ?? "",
            item.workspacePath.map { ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: $0)) }
                ?? (listing.linkedTasks[item.id] != nil ? L10n.string("Continues its task") : L10n.string("Chat (no project)")),
            stateText(item),
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 10) {
            Toggle(item.name, isOn: Binding(
                get: { imported || selection.contains(item.id) },
                set: { value in
                    if value { selection.insert(item.id) } else { selection.remove(item.id) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(imported || !item.canImport)
            HarnessIdentityIcon(harness: item.harness)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(notes, id: \.self) { note in
                    Text(note).font(.system(size: 11))
                        .foregroundStyle(imported ? Color.secondary : Color.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .opacity(item.canImport || imported ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([item.name, item.harness.displayName, detail] + notes).joined(separator: ", "))
        .help(item.name)
    }

    /// On or off in its app, and whether a one-off's moment has passed.
    private func stateText(_ item: ImportableSchedule) -> String {
        if case let .once(moment)? = item.trigger, moment <= now { return L10n.string("Past") }
        return item.isEnabled ? L10n.string("On") : L10n.string("Off")
    }

    private func doneNote(_ count: Int) -> some View {
        Label {
            Text(L10n.format("Imported %lld.", Int64(count)) + " " + L10n.string(
                "To keep them from running twice, turn the originals off in the Claude app or the Codex app, or keep those apps closed. They run schedules only while they are open."))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        let chosen = (listing?.all ?? []).filter { selection.contains($0.id) && $0.canImport && listing?.isImported($0) == false }
        return HStack(spacing: 10) {
            Text(L10n.format("%lld selected", Int64(chosen.count)))
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.string("Import")) {
                importedCount = onImport(chosen)
                selection = []
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
    }
}
