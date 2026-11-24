import SwiftUI

/// Send Feedback: one field for the note, an optional email for a reply, and what is sent with it, listed
/// before the person sends (`PrivateFeedbackContext`). Send is off while a note is going; a failed send
/// keeps the note and offers Send Again; closing with an unsent note asks first.
struct PrivateFeedbackSheet: View {
    static let width: CGFloat = 460

    @Bindable var form: PrivateFeedbackForm
    let close: () -> Void
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(form.context.kind == .problem ? L10n.string("Send Problem Report") : L10n.string("Send Feedback"))
                .font(.headline)
            if form.state == .sent {
                sent
            } else {
                editor
            }
            footer
        }
        .padding(20)
        .frame(width: Self.width)
        .onAppear { isMessageFocused = true }
        .confirmationDialog(L10n.string("Discard this note?"), isPresented: $form.confirmsDiscard) {
            Button(L10n.string("Discard"), role: .destructive, action: close)
            Button(L10n.string("Keep Editing"), role: .cancel) {}
        } message: {
            Text(L10n.string("What you wrote will not be sent."))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $form.message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($isMessageFocused)
                    .disabled(form.state == .sending)
                    .accessibilityLabel(L10n.string("Where did you get stuck, or what bothered you?"))
                if form.message.isEmpty {
                    Text(L10n.string("Where did you get stuck, or what bothered you?"))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(6)
            .frame(height: 130)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(ParityTheme.separator) }
            if form.isTooLong {
                Text(L10n.format("Keep the note under %@ characters.",
                                 PrivateFeedbackSubmission.maximumMessageLength.formatted()))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle(L10n.string("Add an email for a reply"), isOn: $form.addsEmail)
                .toggleStyle(.checkbox)
                .disabled(form.state == .sending)
            if form.addsEmail {
                TextField(L10n.string("Email"), text: $form.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disabled(form.state == .sending)
                if !form.emailIsValid {
                    Text(L10n.string("Enter an email address, or leave it empty."))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            included
        }
    }

    /// What goes with the note, and what does not.
    private var included: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Sent privately to the Yardlet team, with:"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(form.context.includedLines, id: \.label) { line in
                    GridRow {
                        Text(line.label).foregroundStyle(.secondary)
                        Text(line.value).textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
            .padding(.leading, 8)
            Text(L10n.string("Conversations, file paths, accounts, logs and screenshots are not included."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sent: some View {
        Label(L10n.string("Feedback sent. Thank you."), systemImage: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.multicolor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case let .failed(reason) = form.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if form.state == .sending {
                ProgressView().controlSize(.small)
                Text(L10n.string("Sending…")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if form.state == .sent {
                Button(L10n.string("Done"), action: close)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.string("Cancel")) {
                    if form.mayClose() { close() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(form.state == .sending)
                Button(isRetry ? L10n.string("Send Again") : L10n.string("Send")) {
                    form.startSending()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canSend)
            }
        }
        .parityPointer()
    }

    private var isRetry: Bool {
        if case .failed = form.state { return true }
        return false
    }
}

/// "Send problem report" under an error line, for a report naming that error's kind; nothing where
/// Send Feedback cannot open.
struct SendProblemReportLink: View {
    let surface: PrivateFeedbackContext.Surface
    var harness: HarnessKind? = nil
    let failure: PrivateFeedbackContext.Failure
    @Environment(\.yardletSendFeedback) private var sendFeedback

    var body: some View {
        if let sendFeedback {
            Button(L10n.string("Send problem report")) {
                sendFeedback(.problem(surface: surface, harness: harness, failure: failure))
            }
            .buttonStyle(.link)
            .font(.caption)
            .parityPointer()
            .help(L10n.string("Tell the Yardlet team privately what happened"))
        }
    }
}
