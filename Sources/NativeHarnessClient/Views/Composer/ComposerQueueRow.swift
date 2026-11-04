import SwiftUI

/// The queue row shared by host and remote composers; actions stay with their owner.
struct ComposerQueueRow: View {
    let title: String
    let failed: Bool
    let fromTask: Bool
    let chip: ComposerQueueChip
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var retry: (() -> Void)?
    var sendNow: (() -> Void)?
    var stopAndSend: (() -> Void)?
    var edit: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: fromTask && !failed ? "bubble.left.and.bubble.right" : chip.icon)
                .frame(width: 14)
            Text(title)
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // When the turn ends, or at Claude's next step.
            Text(chip.status)
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: 4) {
            if chip.canMoveUp {
                Button {
                    moveUp?()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(L10n.string("Move up"))
                .help(L10n.string("Move up"))
            }
            if chip.canMoveDown {
                Button {
                    moveDown?()
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(L10n.string("Move down"))
                .help(L10n.string("Move down"))
            }
            if failed, let retry {
                Button {
                    retry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(L10n.string("Retry"))
                .help(L10n.string("Retry"))
            } else if let send = chip.send, let sendQueuedNow = sendNow {
                // In words, as the Codex app's queued message offers its Steer: the message goes
                // now and the turn goes on.
                Button {
                    sendQueuedNow()
                } label: {
                    Label(send.label, systemImage: send.icon)
                        .labelStyle(.titleAndIcon)
                        .fontWeight(.medium)
                        .fixedSize()
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(send.label)
                .accessibilityHint(send.help)
                .help(send.help)
            }
            if let editQueued = edit, !fromTask {
                Button {
                    editQueued()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(L10n.string("Edit message"))
                .help(L10n.string("Edit message"))
            }
            Button {
                remove?()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .accessibilityLabel(chip.removeLabel)
            .help(chip.removeLabel)
            }
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(failed ? .red : .secondary)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        .help(chip.help ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(L10n.string("Queue")), \(chip.status)")
        .accessibilityValue(title)
        .contextMenu {
            if chip.canMoveUp {
                Button(L10n.string("Move up")) {
                    moveUp?()
                }
            }
            if chip.canMoveDown {
                Button(L10n.string("Move down")) {
                    moveDown?()
                }
            }
            if failed, let retry {
                Button(L10n.string("Retry")) {
                    retry()
                }
            } else if let send = chip.send, let sendQueuedNow = sendNow {
                Button(send.label) {
                    sendQueuedNow()
                }
            }
            if let stop = chip.stopAndSend, let stopAndSend = stopAndSend {
                // The one queue action that stops the running turn, named for it.
                Button(stop) {
                    stopAndSend()
                }
            }
            if let editQueued = edit, !fromTask {
                Button(L10n.string("Edit message")) {
                    editQueued()
                }
            }
            Button(chip.removeLabel, role: .destructive) {
                remove?()
            }
        }
    }
}

/// The same paused-queue explanation in either window.
struct ComposerQueuePausedRow: View {
    var resume: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle")
            Text(L10n.string("Queue paused because you interrupted")).lineLimit(1)
            Spacer(minLength: 8)
            if let resume {
                Button(action: resume) { Label(L10n.string("Resume"), systemImage: "play.fill") }
                    .buttonStyle(.borderless)
                    .parityPointer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .padding(.top, 9)
        .accessibilityElement(children: .contain)
    }
}
