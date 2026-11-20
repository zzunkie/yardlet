import AppKit
import SwiftUI

@MainActor @Observable
final class ShortcutEditor {
    enum Edit: Equatable {
        case recording
        case conflict(MacKeyChord, [MacShortcut])
        case refused(String, systemMenu: Bool)
    }

    let preferences: MacShortcutPreferences
    let isSystemHotKey: @MainActor (MacShortcutEvent) -> Bool
    var query = ""
    var selection: MacShortcut?
    var edit: Edit = .recording
    var confirmsRestore = false
    private var recordedEquivalent: MacKeyChord?
    private(set) var recordingID = 0

    init(preferences: MacShortcutPreferences = .shared, isSystemHotKey: @escaping @MainActor (MacShortcutEvent) -> Bool = isMacSystemHotKey) {
        self.preferences = preferences
        self.isSystemHotKey = isSystemHotKey
    }

    func start(_ command: MacShortcut) {
        recordingID += 1
        selection = command
        edit = .recording
        confirmsRestore = false
        recordedEquivalent = nil
    }

    func cancel() {
        selection = nil
        edit = .recording
        confirmsRestore = false
        recordedEquivalent = nil
    }

    func record(_ event: MacShortcutEvent, for command: MacShortcut, send: SendShortcut) {
        guard let chord = MacKeyChord(event: event) else { return }
        recordedEquivalent = MacKeyChord.shiftedEquivalent(of: event)
        if chord.systemUse == nil, !preferences.snapshot.system.contains(where: { $0.chord.matches(event) }),
           isSystemHotKey(event) {
            edit = .refused(L10n.format("%@ is a macOS keyboard shortcut.", chord.displayText), systemMenu: false)
        } else { set(chord, for: command, send: send) }
    }

    func set(_ chord: MacKeyChord?, for command: MacShortcut, send: SendShortcut,
             replacing: [MacShortcut] = []) {
        selection = command
        switch preferences.assign(chord, to: command, send: send, replacing: replacing, equivalent: recordedEquivalent) {
        case .ready: cancel()
        case let .conflicts(commands):
            if let chord { edit = .conflict(chord, commands) }
        case let .refused(message):
            let systemMenu = preferences.snapshot.system.contains { $0.commands.contains(command) || $0.chord == chord || $0.chord == recordedEquivalent }
            edit = .refused(message, systemMenu: systemMenu)
        }
    }
}

struct KeyboardShortcutsSettings: View {
    @Bindable var editor: ShortcutEditor
    @AppStorage(SendShortcut.preferenceKey) private var send = SendShortcut.return
    private var preferences: MacShortcutPreferences { editor.preferences }
    static let systemPath = "System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts"

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s12) {
            HStack(spacing: ParitySpace.s8) {
                TextField(L10n.string("Search commands"), text: $editor.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string("Search commands"))
                Button(L10n.string("Restore all")) {
                    editor.cancel()
                    editor.confirmsRestore = true
                }
                .disabled(preferences.snapshot.overrides.isEmpty)
            }
            if editor.confirmsRestore {
                VStack(alignment: .leading, spacing: ParitySpace.s8) {
                    Text(L10n.string("Restore all customized shortcuts to their defaults?"))
                    HStack {
                        Button(L10n.string("Restore defaults")) { preferences.restoreAll(); editor.cancel() }
                        Button(L10n.string("Cancel")) { editor.cancel() }
                    }
                }
            }
            let commands = filtered
            let external = preferences.snapshot.system.filter { assignment in
                assignment.commands.isEmpty && (editor.query.isEmpty || assignment.name.localizedStandardContains(editor.query)
                    || assignment.chord.displayText.localizedStandardContains(editor.query))
            }
            if commands.isEmpty && external.isEmpty {
                Text(L10n.string("No matching commands")).foregroundStyle(.secondary)
                Spacer()
            } else {
                let groups = commands.map { $0.definition.scope }.reduce(into: [String]()) {
                    if !$0.contains($1) { $0.append($1) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !external.isEmpty {
                            Text(L10n.string("macOS App Shortcuts")).font(SettingsMetrics.groupTitleFont)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, ParitySpace.s12).padding(.bottom, ParitySpace.s8)
                            ForEach(Array(external.enumerated()), id: \.offset) { _, item in
                                Divider()
                                VStack(alignment: .leading, spacing: ParitySpace.s4) {
                                    HStack {
                                        Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(verbatim: item.chord.displayText).monospaced()
                                    }
                                    systemNotice
                                }
                                .padding(.vertical, ParitySpace.s8)
                            }
                        }
                        ForEach(groups, id: \.self) { group in
                            Text(L10n.string(group)).font(SettingsMetrics.groupTitleFont)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, ParitySpace.s12).padding(.bottom, ParitySpace.s8)
                            ForEach(commands.filter { $0.definition.scope == group }) { command in
                                Divider()
                                row(command)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .font(.parity(.control, scale: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: editor.query) { _, _ in editor.cancel() }
        .onDisappear { editor.cancel() }
    }

    private var filtered: [MacShortcut] {
        let query = editor.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MacShortcut.all }
        return MacShortcut.all.filter { command in
            let item = command.definition
            return [L10n.string(item.title), L10n.string(item.scope), preferences.displayedKeys(for: command, send: send) ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private func row(_ command: MacShortcut) -> some View {
        let name = L10n.string(command.definition.title)
        let keys = preferences.displayedKeys(for: command, send: send)
        let system = preferences.snapshot.system.first { $0.commands.contains(command) }
        return VStack(alignment: .leading, spacing: ParitySpace.s8) {
            HStack(spacing: ParitySpace.s8) {
                Text(name).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let system {
                    Text(verbatim: system.chord.displayText).monospaced()
                } else {
                    Button(keys ?? L10n.string("Unassigned")) { editor.start(command) }
                        .accessibilityLabel(L10n.format("Change shortcut for %@", name))
                        .accessibilityValue(keys ?? L10n.string("Unassigned"))
                }
            }
            if system != nil {
                systemNotice
            } else if editor.selection == command {
                editing(command, assigned: keys != nil)
            }
        }
        .padding(.vertical, ParitySpace.s8)
    }

    private var systemNotice: some View {
        Text(L10n.string("Set in macOS App Shortcuts.") + " " + L10n.string(Self.systemPath))
            .foregroundStyle(.secondary).font(SettingsMetrics.detailFont).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func editing(_ command: MacShortcut, assigned: Bool) -> some View {
        switch editor.edit {
        case .recording:
            Text(L10n.string("Press a shortcut"))
                .fontWeight(.medium)
                .background(ShortcutRecorder { event in
                    editor.record(MacShortcutEvent(event), for: command, send: send)
                }.id(editor.recordingID).frame(width: 1, height: 1))
            Text(L10n.string("macOS may keep ⌘Space (Spotlight), ⌃Space (input sources), and ⌘Tab (app switching). Input methods can also keep keys."))
                .font(SettingsMetrics.detailFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if assigned { Button(L10n.string("Clear")) { editor.set(nil, for: command, send: send) } }
                if preferences.snapshot.overrides[command.id] != nil {
                    Button(L10n.string("Restore default")) {
                        editor.set(MacKeyChord(command.defaultBinding(send: send)), for: command, send: send)
                    }
                }
                Button(L10n.string("Cancel")) { editor.cancel() }
            }
        case let .conflict(chord, commands):
            let names = commands.map { L10n.string($0.definition.scope) + " · " + L10n.string($0.definition.title) }
            Text(L10n.format("%@ is assigned to %@.", chord.displayText, names.joined(separator: ", ")))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.string("Clear and assign")) { editor.set(chord, for: command, send: send, replacing: commands) }
                Button(L10n.string("Cancel")) { editor.cancel() }
            }
        case let .refused(reason, systemMenu):
            Text(reason).fixedSize(horizontal: false, vertical: true)
            if systemMenu { Text(L10n.string(Self.systemPath)).font(SettingsMetrics.detailFont).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.string("Try another key")) { editor.start(command) }
                Button(L10n.string("Cancel")) { editor.cancel() }
            }
        }
    }
}

/// Record only while this row owns the sheet's keyboard. Its event never goes on to a menu, the
/// composer or a second window. No global event tap or accessibility permission is involved.
struct ShortcutRecorder: NSViewRepresentable {
    let receive: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.receive = receive }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var receive: ((NSEvent) -> Void)?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, let window, window.firstResponder === self, event.window === window else { return false }
            if !event.isARepeat { receive?(event) }
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension KeyboardShortcutsSettings {
    /// Each command whose key this page changes, for Settings search: found by its name and its place in either
    /// language, and landing on this page searched for it.
    static var searchItems: [SettingsSearchItem] {
        MacShortcut.all.map { command in
            let item = command.definition
            let name = L10n.string(item.title)
            return SettingsSearchItem(id: "command:\(command.id)", kind: .command,
                                      destination: SettingsDestination(.keyboardShortcuts, shortcutQuery: name),
                                      title: name, words: [item.title, item.scope, L10n.string(item.scope)])
        }
    }
}
