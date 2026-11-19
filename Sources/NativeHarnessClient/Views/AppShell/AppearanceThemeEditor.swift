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
        for mode in ThemeMode.allCases {
            for field in ThemeField.allCases where draft[mode][keyPath: field.key] == saved[mode][keyPath: field.key] {
                draft[mode][keyPath: field.key] = latest[mode][keyPath: field.key]
            }
        }
        if draft.font == saved.font { draft.font = latest.font }
        if draft.preset == saved.preset { draft.preset = latest.preset }
        saved = latest
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
        draft[mode][keyPath: field.key] = ThemeRGB(color.resolve(in: environment))
        if !failures.isEmpty { failures = ThemeContrast.failures(for: draft) }
    }
}

struct AppearanceThemeEditor: View {
    @State private var model: AppearanceThemeDraft
    @AppStorage private var data: Data
    @AppStorage private var legacy: String

    init(model: AppearanceThemeDraft) {
        _model = State(initialValue: model)
        _data = AppStorage(wrappedValue: Data(), MacColorTheme.key, store: model.defaults)
        _legacy = AppStorage(wrappedValue: "system", YardletPreferenceKeys.accent, store: model.defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup {
                SettingsRow(title: L10n.string("Accent preset")) {
                    Circle().fill(Color(nsColor: ParityTheme.accentColor(for: model.draft.preset)))
                        .overlay { Circle().strokeBorder(ParityTheme.strongSeparator) }
                        .frame(width: 12, height: 12).accessibilityHidden(true)
                    Picker(YardletSetting.accent.title, selection: Binding(get: { model.draft.preset }, set: {
                        model.draft.usePreset($0)
                    })) {
                        ForEach(YardletAccentPreference.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(title: L10n.string("Interface font")) {
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
                }.padding(.top, 8)
                ForEach(ThemeField.allCases, id: \.self) { field in
                    SettingsRow(title: field.title) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            let label = L10n.format("%@ · %@", mode.title, field.title)
                            ColorPicker(label, selection: Binding(
                                get: { model.color(field, in: mode) },
                                set: { model.set($0, for: field, in: mode) }), supportsOpacity: false)
                                .labelsHidden().frame(width: 54).accessibilityLabel(label)
                        }
                    }
                    if field != .text { Divider() }
                }
            }
            if !model.failures.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.failures, id: \.message) { failure in
                        Text(failure.message).font(SettingsMetrics.detailFont).fixedSize(horizontal: false, vertical: true)
                    }
                }.accessibilityElement(children: .combine)
            }
            HStack {
                Button(L10n.string("Reset to defaults")) { model.reset() }
                    .disabled(model.draft == MacColorTheme() && model.saved == MacColorTheme())
                Spacer()
                Button(L10n.string("Save")) { model.save() }.disabled(model.draft == model.saved)
            }.controlSize(.small)
        }
        .onChange(of: data) { model.refresh() }
        .onChange(of: legacy) { model.refresh() }
    }

}
