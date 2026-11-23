import SwiftUI
import UIKit
import YardletRemote

/// A turn's message being edited (docs/REMOTE_PROTOCOL.md §15.23): its words go into the composer, and sending them
/// goes as the turn's Edit Message.
struct MessageEdit: Equatable {
    let turnID: String
    let text: String
}

/// What a turn offers on a long press (§15.23): Edit Message and Fork from Here, on the person's message that opened it,
/// or Fork from Here on its header when no message of the person's opened it.
struct TurnOffer: Equatable {
    let turnID: String
    let canEdit: Bool
    let canFork: Bool
    /// The message that opened the turn: the last one the person sent before its header (one steered into the turn comes
    /// after it), not one someone else sent (§6.2 `sender`), which the Mac never edits.
    let messageID: String?

    init?(_ items: [RemoteItem]) {
        guard let index = items.firstIndex(where: { $0.kind == .turn }) else { return nil }
        let options = items[index].options ?? []
        canEdit = options.contains("edit")
        canFork = options.contains("fork")
        guard canEdit || canFork else { return nil }
        turnID = items[index].turnId
        messageID = items[..<index].last { $0.kind == .user && $0.queued != true && $0.sender == nil }?.id
    }
}

/// The task's slash commands as the composer offers them (§15.23).
enum SlashCommands {
    /// What follows a `/` the draft starts with, while it is one word: the slash list is open.
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    /// The commands a typed query names, in the list's order: by the start of the name, or anywhere in the title.
    static func matching(_ commands: [RemoteComposerCommand], query: String) -> [RemoteComposerCommand] {
        commands.filter { command in
            command.name.lowercased().hasPrefix(query.lowercased())
                || command.title?.localizedCaseInsensitiveContains(query) == true
        }
    }

    /// The draft's first word names one of the commands: it, and the words after it.
    static func typed(_ draft: String, in commands: [RemoteComposerCommand]) -> (RemoteComposerCommand, String?)? {
        guard draft.hasPrefix("/") else { return nil }
        let first = draft.prefix { !$0.isWhitespace }
        guard let command = commands.first(where: { $0.name == first.dropFirst() }) else { return nil }
        let arguments = draft.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, arguments.isEmpty ? nil : arguments)
    }

    /// Runs of commands under the same heading, as the Mac's list groups them.
    static func groups(_ commands: [RemoteComposerCommand]) -> [(heading: String?, commands: [RemoteComposerCommand])] {
        var groups: [(heading: String?, commands: [RemoteComposerCommand])] = []
        for command in commands {
            if let last = groups.last, last.heading == command.group {
                groups[groups.count - 1].commands.append(command)
            } else {
                groups.append((command.group, [command]))
            }
        }
        return groups
    }
}

/// The commands a typed `/` names, above the message field, as the Claude and ChatGPT apps list them.
struct SlashList: View {
    let commands: [RemoteComposerCommand]
    let choose: (RemoteComposerCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SlashCommands.groups(commands).enumerated()), id: \.offset) { _, group in
                    if let heading = group.heading {
                        Text(heading)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                    }
                    ForEach(group.commands, id: \.name) { command in
                        Button {
                            choose(command)
                        } label: {
                            SlashCommandRow(command: command)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 232)
        .fixedSize(horizontal: false, vertical: true)
        .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
        )
    }
}

/// A command as the Mac's list shows it: its title or `/name`, the words it takes, and what it does.
struct SlashCommandRow: View {
    let command: RemoteComposerCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(command.title ?? "/\(command.name)").foregroundStyle(.primary)
                + Text(command.argumentHint.map { " " + $0 } ?? "").font(.footnote).foregroundStyle(.secondary))
                .lineLimit(1)
            if let description = command.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Over the message field while a turn's message is edited (§15.23): what the field holds goes as the edit.
struct EditingBar: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
            Text("Editing message")
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .font(.footnote.weight(.semibold))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

/// A message's words, whole, to select any part of them.
struct SelectTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Text that can be selected by range, which a SwiftUI `Text` cannot.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.attributedText = YardletTypography.attributedProse(text)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.attributedText = YardletTypography.attributedProse(text)
        }
    }
}
