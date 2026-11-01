import Foundation

enum HarnessCapabilitySurface: Equatable, Sendable {
    case codex
    case liveProvider
    case informational
}

/// Keeps common task presentation and provider attachment decisions on the same
/// descriptor-driven boundary. A transport that cannot expose live selectors may
/// still show an informational capability sheet, but opening it must not wake the
/// runtime or present Codex-only controls.
struct HarnessPresentationPolicy: Equatable, Sendable {
    let harness: HarnessKind
    let capabilitySurface: HarnessCapabilitySurface

    init(harness: HarnessKind) {
        self.harness = harness
        if harness == .codex {
            capabilitySurface = .codex
            return
        }
        switch HarnessCatalog.descriptor(for: harness)?.transport {
        case .claudeStreamJSON, .msp, .acp, .piRPC, .cursorStreamJSON:
            capabilitySurface = .liveProvider
        case .codexAppServer, nil:
            capabilitySurface = .informational
        }
    }

    var usesCodexTimeline: Bool { capabilitySurface == .codex }
    var showsCodexComposerControls: Bool { capabilitySurface == .codex }
    var loadsLiveProviderControls: Bool { capabilitySurface == .liveProvider }
}
