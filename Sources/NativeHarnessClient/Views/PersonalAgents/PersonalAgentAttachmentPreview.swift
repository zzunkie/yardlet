import AppKit
import Quartz
import SwiftUI

/// A preview owns only its private temporary copy. Closing it never removes the
/// provider's attachment or a copy the person explicitly saved elsewhere.
final class PersonalAgentPreviewFile: Identifiable {
    let id = UUID()
    let url: URL
    private let directory: URL

    init(download: PersonalAgentDownload) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "yardlet-dot-" + UUID().uuidString)
        let name = URL(filePath: download.name).lastPathComponent
        url = directory.appending(path: name.isEmpty || name == "." || name == ".." ? "attachment" : name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try StateFile.write(download.data, to: url, isPrivate: true)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct PersonalAgentAttachmentPreview: View {
    let file: PersonalAgentPreviewFile
    let close: () -> Void
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.url.lastPathComponent).lineLimit(1)
                Spacer()
                Button(L10n.string("Save…")) {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = file.url.lastPathComponent
                    if panel.runModal() == .OK, let destination = panel.url {
                        do { try Data(contentsOf: file.url).write(to: destination, options: .atomic) }
                        catch { saveFailed = true }
                    }
                }
                Button(L10n.string("Done"), action: close).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
            .background(ParityTheme.canvas)
            if saveFailed { Text(L10n.string("The attachment could not be saved.")).font(.caption).padding(8) }
            NativeAttachmentPreview(url: file.url).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(ParityTheme.canvas)
    }
}

private struct NativeAttachmentPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
