import SwiftUI

/// Chrome's permission bubble, as a bar above the page: Block, Allow, or close it unanswered. The Mac's browser panel
/// and a window following another Mac's tasks (docs/REMOTE_PROTOCOL.md §15.25) show the same bar.
struct BrowserPermissionBar: View {
    let text: String
    let answer: (BrowserPermissionResult) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            // Whole, however narrow the panel: what Allow gives is never cut off.
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.string("Block")) { answer(.block) }
                .controlSize(.small)
            Button(L10n.string("Allow")) { answer(.allow) }
                .controlSize(.small)
            ParityIconButton(systemName: "xmark", help: L10n.string("Close")) { answer(.dismiss) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    /// The bar's sentence, in Chrome's words: who asks, and for what. With `host`, the Mac whose camera, microphone,
    /// location and the rest the page asks for, named for a window that shows another Mac's tab.
    static func text(_ prompt: BrowserPermissionPrompt, host: String? = nil) -> String {
        var names: [String: String] = [
            "notifications": "Show notifications", "geolocation": "Know your location",
            "clipboard": "See text and images copied to the clipboard", "multipleDownloads": "Download multiple files",
            "storageAccess": "Use cookies and site data from another site",
            "topLevelStorageAccess": "Use cookies and site data from another site",
            "localFonts": "Use the fonts on this Mac", "windowManagement": "Manage windows on all your displays",
            "localNetworkAccess": "Connect to devices on your local network",
            "localNetwork": "Connect to devices on your local network",
            "loopbackNetwork": "Connect to apps on this Mac", "fileSystemAccess": "Edit files on this Mac",
            "camera": "Use your camera", "microphone": "Use your microphone",
            "midiSysex": "Control and reprogram your MIDI devices", "idleDetection": "Know when you're using this Mac"
        ]
        if host != nil {
            // "This Mac" is the one the window is on: the sentence names the host instead, and these say "it".
            names.merge([
                "localFonts": "Use its fonts", "loopbackNetwork": "Connect to apps running on it",
                "fileSystemAccess": "Edit its files", "idleDetection": "Know when it is in use"
            ]) { $1 }
        }
        var seen = Set<String>()
        let wants = prompt.permissions.map { names[$0].map(L10n.string) ?? $0 }.filter { seen.insert($0).inserted }
        let origin = URL(string: prompt.origin).map { url in
            (url.host() ?? prompt.origin) + (url.port.map { ":\($0)" } ?? "")
        } ?? prompt.origin
        guard let host else { return L10n.format("%@ wants to: %@", origin, wants.joined(separator: ", ")) }
        return L10n.format("On %1$@, %2$@ wants to: %3$@", host, origin, wants.joined(separator: ", "))
    }
}
