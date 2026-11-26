import SwiftUI

@MainActor @Observable
final class AppearanceThemeDraft {
    let defaults: UserDefaults
    var draft: MacColorTheme
    private(set) var saved: MacColorTheme
    private(set) var failures: [ThemeContrast.Failure] = []

    init(defaults: UserDefaults = .yardlet) {
        self.defaults = defaults
        let initial = MacColorTheme.current(in: defaults)
        saved = initial
        draft = initial
    }

    /// Preserve fields being edited when another window or the agent changes a different field.
    func refresh() {
        let latest = MacColorTheme.current(in: defaults)
        guard latest != saved else { return }
        // Picking another preset replaces the whole pair, including concurrent color overrides.
        if draft.preset == saved.preset {
            draft.preset = latest.preset
            for mode in ThemeMode.allCases {
                for field in ThemeField.allCases {
                    let key = field.key
                    if draft[overrides: mode][keyPath: key] == saved[overrides: mode][keyPath: key] {
                        draft[overrides: mode][keyPath: key] = latest[overrides: mode][keyPath: key]
                    }
                }
            }
        }
        if draft.font == saved.font { draft.font = latest.font }
        saved = latest
    }

    func select(_ preset: YardletAccentPreference) {
        refresh()
        draft.usePreset(preset)
        failures = []
    }

    func save() {
        refresh()
        failures = ThemeContrast.failures(for: draft)
        guard failures.isEmpty else { return }
        draft.persist(in: defaults)
        saved = draft
    }

    func reset() {
        draft = MacColorTheme()
        draft.persist(in: defaults)
        saved = draft
        failures = []
    }

    func color(_ field: ThemeField, in mode: ThemeMode) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = mode.scheme
        environment.yardletColorTheme = draft
        let color = switch field {
        case .accent: Color(nsColor: draft.accent(in: mode))
        case .background: ParityTheme.canvas
        case .text: draft[mode].text?.color ?? .primary
        }
        var result = color
        NSAppearance(named: mode == .light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            result = Color(color.resolve(in: environment))
        }
        return result
    }

    func set(_ color: Color, for field: ThemeField, in mode: ThemeMode) {
        var environment = EnvironmentValues()
        environment.colorScheme = mode.scheme
        draft[overrides: mode][keyPath: field.key] = ThemeRGB(color.resolve(in: environment))
        if !failures.isEmpty { failures = ThemeContrast.failures(for: draft) }
    }
}

struct AppearanceThemeEditor: View {
    @Environment(\.colorScheme) private var scheme
    @State private var model: AppearanceThemeDraft
    @AppStorage private var data: Data
    @AppStorage private var legacy: String

    init(model: AppearanceThemeDraft) {
        _model = State(initialValue: model)
        _data = AppStorage(wrappedValue: Data(), MacColorTheme.key, store: model.defaults)
        _legacy = AppStorage(wrappedValue: "system", YardletPreferenceKeys.accent, store: model.defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s8) {
            SettingsGroup {
                SettingsRow(title: YardletSetting.accent.title, anchor: YardletSetting.accent.id) {
                    Circle().fill(Color(nsColor: model.draft.accent(in: ThemeMode(scheme))))
                        .overlay { Circle().strokeBorder(ParityTheme.strongSeparator) }
                        .frame(width: 12, height: 12).accessibilityHidden(true)
                    Picker(YardletSetting.accent.title, selection: Binding(get: { model.draft.selectedPreset }, set: {
                        if let preset = $0 { model.select(preset) }
                    })) {
                        if model.draft.selectedPreset == nil {
                            Text(L10n.string("Custom")).tag(nil as YardletAccentPreference?).disabled(true)
                        }
                        Text(YardletAccentPreference.system.title).tag(Optional(YardletAccentPreference.system))
                        Section(L10n.string("Color themes")) {
                            presetOptions(YardletAccentPreference.completePresets)
                        }
                        Section(L10n.string("Accent only")) {
                            presetOptions(YardletAccentPreference.accentOnlyPresets)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(title: L10n.string("Interface font"), anchor: "ui_font") {
                    Picker(L10n.string("Interface font"), selection: $model.draft.font) {
                        ForEach(InterfaceFont.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                HStack {
                    Spacer()
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.title).font(SettingsMetrics.detailFont).foregroundStyle(.secondary)
                            .frame(width: 54)
                    }
                }.padding(.top, ParitySpace.s12)
                ForEach(ThemeField.allCases, id: \.self) { field in
                    SettingsRow(title: field.title, anchor: SettingsSearch.Anchor.themeColor(field.rawValue)) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            let label = L10n.format("%@ · %@", mode.title, field.title)
                            ColorPicker(label, selection: Binding(
                                get: { model.color(field, in: mode) },
                                set: { model.set($0, for: field, in: mode) }), supportsOpacity: false)
                                .labelsHidden().frame(width: 54).accessibilityLabel(label)
                        }
                    }
                    Divider()
                }
                // The group's own end, as its buttons act on every row above them.
                VStack(alignment: .leading, spacing: ParitySpace.s8) {
                    if !model.failures.isEmpty {
                        VStack(alignment: .leading, spacing: ParitySpace.s4) {
                            ForEach(model.failures, id: \.message) { failure in
                                Text(failure.message).font(SettingsMetrics.detailFont)
                                    .foregroundStyle(ParityTheme.warningText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    HStack {
                        Button(L10n.string("Reset to defaults")) { model.reset() }
                            .disabled(model.draft == MacColorTheme() && model.saved == MacColorTheme())
                        Spacer()
                        Button(L10n.string("Save")) { model.save() }
                            .disabled(model.draft == model.saved)
                    }.controlSize(.small)
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            }
        }
        .onChange(of: data) { model.refresh() }
        .onChange(of: legacy) { model.refresh() }
    }

    private func presetOptions(_ presets: [YardletAccentPreference]) -> some View {
        ForEach(presets) { Text($0.title).tag(Optional($0)) }
    }
}
