import SwiftUI

/// The composer's model menu for every harness, in the task composer and the new-task composer
/// alike. Opening it never submits a draft; a menu without a list loads one first.
struct ComposerModelControl: View {
    let menu: ComposerModelMenu
    let onPrepare: () async -> Void
    let onSetOption: (String, String) -> Void
    /// The Model and Reasoning slash commands open this same menu at their own list.
    var openRequest: CodexModelPickerRequest? = nil
    var isDisabled = false
    /// The composer's control takes the task's model focus; the session rail's copy does not.
    var registersTaskFocus = true

    @Environment(\.taskKeyboardFocus) private var taskFocus
    @State private var isPresented = false
    @State private var isLoading = false
    @State private var opensModelList = false
    @FocusState private var isTriggerFocused: Bool

    var body: some View {
        Button { open(atModels: false) } label: {
            ParityComposerControl(title: menu.triggerTitle, detail: menu.triggerDetail, showsChevron: true, isActive: isPresented)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(isDisabled)
        .focused($isTriggerFocused)
        .taskFocus(.intelligence, isFocused: $isTriggerFocused, enabled: registersTaskFocus)
        .accessibilityLabel(L10n.string("Model"))
        .accessibilityValue(menu.accessibilityValue)
        // Task › Select model opens the composer's menu, not the session rail's copy.
        .help(ShortcutHelp.text(L10n.string("Select model"),
                                registersTaskFocus ? TaskCommandShortcut.openModelMenu : nil))
        // Above the control, over the conversation: the composer sits at the window's bottom, and
        // a menu asked to open below it was pushed back up over the composer's own row.
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Group {
                if menu.canChoose, !menu.isEmpty {
                    HarnessIntelligencePicker(
                        modelSelector: menu.model, reasoningSelector: menu.effort, isAttached: true,
                        onSetOption: onSetOption, onDismiss: { isPresented = false },
                        speedSelector: menu.speed, opensModelList: opensModelList
                    )
                } else if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                } else {
                    VStack(spacing: 8) {
                        Text(L10n.string("Models unavailable")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.string("Retry")) { Task { await load() } }.parityPointer()
                    }
                    .frame(maxWidth: .infinity).padding(12)
                }
            }
            .frame(width: 284)
            .onExitCommand { isPresented = false }
        }
        .onChange(of: isPresented) { _, shown in
            guard !shown, ParityInteraction.currentEventIsKeyboard else { return }
            DispatchQueue.main.async { if !isPresented { isTriggerFocused = true } }
        }
        .onChange(of: openRequest) { _, request in
            guard let request else { return }
            open(atModels: request.list == .models)
        }
        // ⌃⇧M from the Task menu: the composer's copy opens, at the effort as the Codex app's does.
        .task(id: taskFocus?.request) {
            guard registersTaskFocus, !isDisabled, let request = taskFocus?.request, request.target == .modelMenu else { return }
            await Task.yield()
            guard !Task.isCancelled, taskFocus?.consume(request) == true else { return }
            open(atModels: false)
        }
    }

    private func open(atModels: Bool) {
        opensModelList = atModels
        isPresented = true
        if !menu.canChoose || menu.isEmpty { Task { await load() } }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        await onPrepare()
        isLoading = false
    }
}

/// One request to open the composer's model menu; each request has its own identity so the
/// same command chosen twice opens the menu twice.
struct CodexModelPickerRequest: Equatable {
    enum List: Equatable { case effort, models }
    let id = UUID()
    let list: List
}
