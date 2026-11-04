import AppKit
import SwiftUI

struct PiConnectionProviderPicker: View {
    @Binding var selection: String
    private let providers = ["anthropic", "openai-codex", "github-copilot", "openai", "google", "openrouter"]
    var body: some View {
        Picker(L10n.string("Model provider"), selection: $selection) {
            Text(L10n.string("Choose provider")).tag("")
            Text("Anthropic").tag("anthropic")
            Text("OpenAI / ChatGPT").tag("openai-codex")
            Text("GitHub Copilot").tag("github-copilot")
            Text("OpenAI API").tag("openai")
            Text("Google Gemini").tag("google")
            Text("OpenRouter").tag("openrouter")
            if !selection.isEmpty && !providers.contains(selection) { Text(selection).tag(selection) }
        }
    }
}

/// A task's account sheet: the accounts the task may continue under, in the shared account list.
struct TaskAccountSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let session: SessionRecord
    @Bindable var store: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
    let onSelect: (ProviderConnection) -> Void

    var body: some View {
        AccountList(mode: .switchTask(session), store: store, runtimeSelections: runtimeSelections,
            onChoose: { choice in if let connection = choice.connection { onSelect(connection) } },
            onDone: { dismiss() }, maxListHeight: 360)
            .padding(20).frame(width: 660)
    }
}

/// The new-task account chip: the account the next task starts on, or Automatic, and the shared
/// account list to choose another, add one or manage them.
struct ProviderConnectionPicker: View {
    @Bindable var store: ProviderConnectionStore
    let harness: HarnessKind
    let runtimeSelections: RuntimeSelectionStore
    let onManage: () -> Void
    let onAdd: () -> Void
    let onConnect: (AccountChoice) -> Void
    @State private var isPresented = false

    private var selectedChoice: AccountChoice? {
        store.choices(for: [harness]).first { $0.connection?.id == store.selection[harness] }
    }
    private var display: ProviderConnectionDisplay {
        ProviderConnectionDisplay(choice: selectedChoice, automatic: store.startsNewTasksAutomatically(for: harness))
    }
    var body: some View {
        ProviderConnectionControl(title: display.title, accessibilityTitle: display.accessibilityTitle) { isPresented.toggle() }
        .popover(isPresented: $isPresented) {
            AccountList(mode: .newTask(harness), store: store, runtimeSelections: runtimeSelections,
                onChoose: { store.choose($0); isPresented = false },
                onChooseAutomatic: { store.chooseAutomaticNewTaskAccount(for: harness); isPresented = false },
                onConnect: { isPresented = false; onConnect($0) },
                onAdd: { _ in isPresented = false; onAdd() },
                onManage: { isPresented = false; onManage() },
                maxListHeight: 330)
                .padding(16).frame(width: 610)
        }
        .task(id: harness) {
            await store.checkNewTaskAccounts(for: harness, runtimeSelections: runtimeSelections)
        }
    }
}

/// The account chip shared by local and remote composers; its menu supplies only the actions available there.
struct ProviderConnectionControl: View {
    let title: String
    let accessibilityTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
        }
        .font(.caption).buttonStyle(.borderless).parityPointer()
        .frame(maxWidth: 190, alignment: .leading)
        .help(accessibilityTitle)
        .accessibilityLabel(L10n.string("Choose account"))
        .accessibilityValue(accessibilityTitle)
    }
}

/// A single step inside the connection window. Storage paths and aliases are optional advanced choices.
struct AddProviderConnectionView: View {
    let store: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
    let initialHarness: HarnessKind?
    var existingChoice: AccountChoice? = nil
    @Binding var showsAdvanced: Bool
    let closesOnCancel: Bool
    let onCancel: () -> Void
    let onLogin: (HarnessKind, ProviderConnection?) -> Void
    @State private var harness: HarnessKind
    @State private var name = ""
    @State private var provider = ""
    @State private var home: URL?
    @State private var error: String?

    init(store: ProviderConnectionStore, runtimeSelections: RuntimeSelectionStore, initialHarness: HarnessKind?,
         existingChoice: AccountChoice? = nil, showsAdvanced: Binding<Bool>, closesOnCancel: Bool,
         onCancel: @escaping () -> Void,
         onLogin: @escaping (HarnessKind, ProviderConnection?) -> Void) {
        self.store = store; self.runtimeSelections = runtimeSelections; self.initialHarness = initialHarness
        self.existingChoice = existingChoice; self.onCancel = onCancel; self.onLogin = onLogin
        self._showsAdvanced = showsAdvanced; self.closesOnCancel = closesOnCancel
        _provider = State(initialValue: existingChoice?.connection?.providerID ?? existingChoice?.snapshot?.providerID ?? "")
        _harness = State(initialValue: existingChoice?.harness ?? initialHarness
            ?? HarnessCatalog.builtIns.first { HarnessConnectionCapabilities.capabilities(for: $0.id).supportsSeparateHome && runtimeSelections.selectedURL(for: $0.id) != nil }?.id ?? .codex)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button(action: onCancel) {
                Label(L10n.string(closesOnCancel ? "Cancel" : "Back"), systemImage: closesOnCancel ? "xmark" : "chevron.left")
            }.buttonStyle(.plain)
            Text(L10n.string(existingChoice == nil ? "Add another account" : "Connect account"))
                .font(.system(size: 20, weight: .semibold))
            if initialHarness == nil && existingChoice == nil {
                Picker(L10n.string("Harness"), selection: $harness) {
                    ForEach(HarnessCatalog.builtIns.filter { HarnessConnectionCapabilities.capabilities(for: $0.id).supportsSeparateHome
                        && runtimeSelections.selectedURL(for: $0.id) != nil }) { Text($0.displayName).tag($0.id) }
                }
            } else { HarnessIdentityLabel(harness: harness) }
            if harness == .pi { PiConnectionProviderPicker(selection: $provider) }
            if existingChoice == nil {
                DisclosureGroup(L10n.string("Advanced"), isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField(L10n.string("Account name (optional)"), text: $name)
                        Button(L10n.string("Choose existing account folder…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            panel.canCreateDirectories = false
                            if panel.runModal() == .OK { home = panel.url }
                        }
                        if let home {
                            Text(home.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Button(L10n.string("Use a new account")) { self.home = nil }
                        }
                    }.padding(.top, 12)
                }.font(.callout)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.string(home == nil ? "Continue to sign in" : "Use this account")) { add() }
                    .parityProminentButton()
                    .disabled(runtimeSelections.selectedURL(for: harness) == nil || (harness == .pi && provider.isEmpty && home == nil))
                    .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: harness) { _, _ in home = nil; provider = "" }
    }

    private func add() {
        do {
            if let existingChoice {
                let connection = harness == .pi ? ProviderConnection(id: existingChoice.connection?.id ?? "pi-configured",
                    name: existingChoice.connection?.name ?? "Pi", harness: .pi, providerID: provider,
                    homePath: existingChoice.connection?.homePath, credentialSelector: nil) : existingChoice.connection
                onLogin(harness, connection)
                return
            }
            let isNew = home == nil
            let root = try home ?? store.makeAccountHome(for: harness)
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let connection = try store.add(name: label.isEmpty ? L10n.format("%@ account %lld", harness.displayName, Int64(store.connections(for: harness).count + 1)) : label,
                harness: harness, home: root, providerID: harness == .pi && !provider.isEmpty ? provider : nil)
            if isNew { onLogin(harness, connection) } else {
                store.selection[harness] = connection.id
                Task { await store.check(defaultsOf: [], savedOf: [harness], connectionIDs: [connection.id],
                    runtimeSelections: runtimeSelections) }
                onCancel()
            }
        } catch { self.error = error.localizedDescription }
    }
}
