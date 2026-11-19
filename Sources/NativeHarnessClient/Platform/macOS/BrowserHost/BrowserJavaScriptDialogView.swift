import SwiftUI

/// A page's alert, confirm, prompt or "Leave site?" over its tab's page, as Chrome draws a tab's dialog over the tab
/// rather than over the window: the page under it takes no clicks, while the conversation, the sidebar and the other
/// tasks stay the person's. It waits with its tab (`BrowserTab.javaScriptDialog`): showing another tab or task hides
/// it, and it shows again with the tab. It takes the keyboard only when the page had it (Return answers OK, Escape
/// Cancel), so a dialog the agent's click opened does not take the person's typing elsewhere.
struct BrowserJavaScriptDialogView: View {
    let dialog: BrowserJavaScriptDialog
    @Bindable var controller: BrowserHostPaneController
    @FocusState private var focus: Field?

    private enum Field { case text, buttons }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.08)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(BrowserHostPaneController.dialogTitle(dialog))
                    .font(.headline)
                Text(dialog.kind == .beforeUnload ? L10n.string("Changes you made may not be saved.") : dialog.message)
                    .font(.callout)
                    .lineLimit(16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if dialog.kind == .prompt {
                    TextField("", text: $controller.dialogText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .text)
                        .onSubmit { controller.answerJavaScriptDialog(accept: true) }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if dialog.kind != .alert {
                        Button(L10n.string("Cancel")) { controller.answerJavaScriptDialog(accept: false) }
                            .parityPointer()
                    }
                    Button(acceptTitle) { controller.answerJavaScriptDialog(accept: true) }
                        .parityProminentButton()
                        .parityPointer()
                }
            }
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(ParityTheme.separator) }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .focusable(dialog.kind != .prompt)
            .focusEffectDisabled()
            .focused($focus, equals: .buttons)
            .onKeyPress(MacShortcut.confirmDialog.binding.key) {
                controller.answerJavaScriptDialog(accept: true)
                return .handled
            }
            .onMacShortcutExit { controller.answerJavaScriptDialog(accept: dialog.kind == .alert) }
            .padding(.top, 24)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            if controller.dialogTakesKeyboard { focus = dialog.kind == .prompt ? .text : .buttons }
        }
    }

    private var acceptTitle: String {
        switch dialog.kind {
        case .beforeUnload: dialog.isReload ? L10n.string("Reload") : L10n.string("Leave")
        case .alert, .confirm, .prompt: L10n.string("OK")
        }
    }
}
