import SwiftUI

/// What the Outputs list asks of the window: opening an output, and reading more of them.
struct PersonalAgentOutputActions {
    let open: (PersonalAgentOutput) -> Void
    let start: () -> Void
    let readEarlier: () -> Void
    let retry: () -> Void
}

/// An output that did not open, and why.
struct PersonalAgentOutputFailure: Equatable {
    let output: PersonalAgentOutput
    let failure: PersonalAgentFailure
}

/// The dot's Outputs beside its conversation, as the provider's app lists them: the newest three,
/// three more at a time, each with its kind, name and when it was made. Below them, what was checked:
/// it never says all when it was not all, and a part that failed says so with Try again.
struct PersonalAgentOutputsList: View {
    let outputs: PersonalAgentOutputs
    let isOpening: Bool
    let actions: PersonalAgentOutputActions
    /// Shown here even while an Activity task covers the conversation.
    var openFailure: PersonalAgentOutputFailure? = nil
    @State private var shown = Self.step

    static let step = 3

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.personalAgentOutputs)
#endif
        VStack(alignment: .leading, spacing: 2) {
            ForEach(outputs.items.prefix(shown)) { output in
                Button { actions.open(output) } label: {
                    SessionRailRow(systemName: Self.symbol(output), title: output.title) {
                        if let date = output.producedAt {
                            Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).parityPointer().disabled(isOpening)
                .help(Self.origin(output))
                .accessibilityLabel(output.title)
                .accessibilityValue(Self.origin(output))
            }
            if outputs.items.count > shown {
                Button(L10n.string("Show more")) { shown += Self.step }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).parityPointer()
                    .padding(.top, 2)
            }
            if let openFailure {
                VStack(alignment: .leading, spacing: 2) {
                    Text(openFailure.failure.message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("Try again")) { actions.open(openFailure.output) }
                        .buttonStyle(.borderless).font(.caption).parityPointer().disabled(isOpening)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
            }
            status.padding(.top, outputs.items.isEmpty ? 0 : 4)
        }
        // A new reading of the Outputs, after a refresh, begins as the first did.
        .task(id: ObjectIdentifier(outputs)) { actions.start() }
    }

    @ViewBuilder
    private var status: some View {
        if outputs.isReading || outputs.scope == .loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Looking for outputs…")).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if outputs.items.isEmpty {
                    Text(L10n.string("No outputs found yet")).foregroundStyle(.secondary)
                }
                if case let .failed(failure) = outputs.scope {
                    failed(failure == .accessDenied ? L10n.string("The dot's tasks are not available to read.")
                                                    : L10n.string("Could not check the dot's tasks."), help: failure.message)
                } else if let failure = outputs.failure {
                    failed(L10n.string("Some outputs could not be checked."), help: failure.message)
                }
                Text(scopeText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if outputs.hasEarlier {
                    Button(L10n.string("Look further back"), action: actions.readEarlier)
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).parityPointer()
                }
            }
        }
    }

    private func failed(_ text: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(.secondary).help(help)
            Button(L10n.string("Try again"), action: actions.retry).buttonStyle(.borderless).parityPointer()
        }
    }

    /// What the list covers: the messages read, and the tasks whose work was looked through.
    private var scopeText: String {
        let all = outputs.checkedAllMessages
        let tasks = Int64(outputs.checkedTasks)
        if tasks == 0 { return all ? L10n.string("Checked all messages.") : L10n.string("Checked the messages read so far.") }
        if outputs.hasEarlier || outputs.failure != nil {
            return all ? L10n.format("Checked all messages and the recent work of the dot's tasks (%lld).", tasks)
                       : L10n.format("Checked the messages read so far and the recent work of the dot's tasks (%lld).", tasks)
        }
        return all ? L10n.format("Checked all messages and all work of the dot's tasks (%lld).", tasks)
                   : L10n.format("Checked the messages read so far and all work of the dot's tasks (%lld).", tasks)
    }

    static func symbol(_ output: PersonalAgentOutput) -> String {
        switch output.kind {
        case let .messageFile(attachment): SessionRailOutputsCard.symbol(URL(filePath: attachment.name.isEmpty ? "file" : attachment.name))
        case let .remoteFile(file, isImage): isImage ? "photo" : SessionRailOutputsCard.symbol(URL(filePath: file.name))
        case .link: "link"
        }
    }

    /// Where the output came from and where it opens.
    static func origin(_ output: PersonalAgentOutput) -> String {
        switch output.kind {
        case .messageFile: L10n.string("Sent in the conversation")
        case let .remoteFile(file, _): L10n.format("On the dot's computer: %@", file.path)
        case let .link(url):
            if case .message = output.source { L10n.format("Sent in the conversation: %@", url.absoluteString) }
            else { L10n.format("Made by a task: %@", url.absoluteString) }
        }
    }
}
