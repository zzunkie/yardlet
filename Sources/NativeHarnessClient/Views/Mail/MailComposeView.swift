import AppKit
import SwiftUI

/// A message the person writes, in the thread's place: who it goes to, its subject, files and words.
/// It is saved to the account's Drafts as it is written and when it is closed, so nothing of it stays
/// here; Send waits `MailWindowState.undoWindow`, while Undo takes it back.
struct MailComposeView: View {
    let center: MailboxCenter
    @Bindable var window: MailWindowState
    @State private var showsBcc = false
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        if let composition = window.composition {
            VStack(spacing: 0) {
                bar(composition)
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
                if window.sendsAt != nil { undoStrip }
                if let failure = window.writingFailure {
                    Text(failure)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                VStack(spacing: 0) {
                    field(L10n.string("Mail field to"), text: binding(\.to))
                    field(L10n.string("Mail field cc"), text: binding(\.cc)) {
                        if !showsBcc {
                            Button(L10n.string("Bcc")) { showsBcc = true }
                                .buttonStyle(.borderless)
                                .font(.system(size: 12 * scale))
                        }
                    }
                    if showsBcc || !composition.bcc.isEmpty {
                        field(L10n.string("Mail field bcc"), text: binding(\.bcc))
                    }
                    field(L10n.string("Mail field subject"), text: binding(\.subject))
                    attachments(composition)
                    TextEditor(text: binding(\.body))
                        .font(.system(size: 13.5 * scale))
                        .scrollContentBackground(.hidden)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(L10n.string("Message"))
                }
                .frame(maxWidth: MailThreadView.readingWidth)
                .padding(.horizontal, ParityTheme.conversationInset)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .disabled(window.sendsAt != nil)
            }
            // Saved to Drafts ten seconds after the last change.
            .task(id: composition.content) {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await window.save(in: center)
            }
        }
    }

    private func bar(_ composition: MailComposition) -> some View {
        HStack(spacing: 6) {
            Text(L10n.string(Self.title(composition.kind))).font(.system(size: 13 * scale, weight: .semibold))
            Text("·").foregroundStyle(.tertiary)
            fromAccount(composition)
            Spacer(minLength: 12)
            if window.isSaving {
                Text(L10n.string("Saving…")).font(.system(size: 12 * scale)).foregroundStyle(.secondary)
            } else if composition.draftID != nil {
                Text(L10n.string("Saved to Drafts")).font(.system(size: 12 * scale)).foregroundStyle(.secondary)
            }
            ParityIconButton(systemName: "paperclip", help: L10n.string("Attach files…"), action: attach)
            ParityIconButton(systemName: "trash", help: L10n.string("Discard message")) { window.discard(in: center) }
            ParityIconButton(systemName: "xmark", help: L10n.string("Close and keep as draft")) { window.close(in: center) }
            Button { window.send(in: center) } label: {
                Label(L10n.string("Send"), systemImage: "paperplane.fill")
            }
            .buttonStyle(MailPrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(window.sendsAt != nil)
        }
        .padding(.horizontal, 16)
        .frame(height: ParityTheme.paneToolbarHeight)
    }

    /// The account it is sent from: a menu while it is new and there are several.
    @ViewBuilder private func fromAccount(_ composition: MailComposition) -> some View {
        let address = center.account(composition.accountID)?.address ?? ""
        if composition.kind == .new, composition.draftID == nil, center.accounts.count > 1 {
            Menu {
                ForEach(center.accounts) { account in
                    Button(account.address) { window.composition?.accountID = account.id }
                }
            } label: {
                Text(address).font(.system(size: 12.5 * scale))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L10n.string("From"))
            .accessibilityValue(address)
        } else {
            Text(address).font(.system(size: 12.5 * scale)).foregroundStyle(.secondary)
        }
    }

    private var undoStrip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(L10n.string("Sending…")).font(.system(size: 12.5 * scale))
            Spacer(minLength: 8)
            Button(L10n.string("Undo send")) { window.undoSend() }
                .buttonStyle(.link)
                .font(.system(size: 12.5 * scale, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ParityTheme.subtleFill)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    private func field<Trailing: View>(_ label: String, text: Binding<String>,
                                       @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(.secondary)
                    .frame(width: 72 * scale, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13 * scale))
                    .accessibilityLabel(label)
                trailing()
            }
            .padding(.vertical, 8)
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
        }
    }

    @ViewBuilder private func attachments(_ composition: MailComposition) -> some View {
        if !composition.attachments.isEmpty || composition.forwardedMessageID != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(composition.attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                        Text(url.lastPathComponent).lineLimit(1)
                        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).foregroundStyle(.secondary)
                        }
                        Button { window.composition?.attachments.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.format("Remove %@", url.lastPathComponent))
                    }
                }
                if composition.forwardedMessageID != nil {
                    Text(L10n.string("The original's files go with it."))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5 * scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
        }
    }

    private func binding(_ path: WritableKeyPath<MailComposition, String>) -> Binding<String> {
        Binding(get: { window.composition?[keyPath: path] ?? "" },
                set: { window.composition?[keyPath: path] = $0 })
    }

    /// Files the person picks, attached as they are.
    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let chosen = window.composition?.attachments ?? []
            window.composition?.attachments = chosen + panel.urls.filter { !chosen.contains($0) }
        }
    }

    static func title(_ kind: MailComposition.Kind) -> String {
        switch kind {
        case .new: "New message"
        case .reply: "Mail reply"
        case .replyAll: "Mail reply all"
        case .forward: "Mail forward"
        }
    }
}
