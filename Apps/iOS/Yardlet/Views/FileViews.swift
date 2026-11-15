import SwiftUI
import YardletRemote

/// "Outputs" (docs/REMOTE_PROTOCOL.md §15.22): the files the Mac's Outputs card lists for the task, in its order (newest
/// first), each with its size and when it was written. The list is read again when the sheet opens. A file that is gone
/// from the Mac is listed, dimmed, and does not open.
struct OutputsSheet: View {
    let session: HostSession
    let taskID: String
    let open: (RemoteOutput) -> Void
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    private var outputs: [RemoteOutput] { session.outputs[taskID] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if outputs.isEmpty {
                    Group {
                        if isLoading { Text("Loading…") } else { Text("This task hasn't made any files.") }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
                ForEach(outputs, id: \.path) { output in
                    row(output)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Outputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await session.loadOutputs(taskID)
            isLoading = false
        }
    }

    private func row(_ output: RemoteOutput) -> some View {
        let isGone = output.size == nil
        return Button {
            open(output)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(output.name))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.name).lineLimit(1).truncationMode(.middle)
                    Text(line(output)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGone)
        .opacity(isGone ? 0.5 : 1)
    }

    private func line(_ output: RemoteOutput) -> String {
        guard let size = output.size else { return String(localized: "Not on \(session.name)") }
        let parts = [Int64(size).formatted(.byteCount(style: .file)),
                     output.writtenAt.map { session.date($0).formatted(.relative(presentation: .named)) }]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// As the Mac's Outputs card marks a file by its kind.
    static func symbol(_ name: String) -> String {
        switch URL(filePath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": "photo"
        case "mp4", "mov", "webm": "film"
        case "mp3", "wav", "m4a": "waveform"
        case "pdf": "doc.richtext"
        case "csv", "tsv", "xls", "xlsx", "numbers": "tablecells"
        case "zip": "doc.zipper"
        case "html", "htm": "globe"
        default: "doc.text"
        }
    }
}

/// A file on its way from the Mac: its name, how far it came, and a way to stop.
struct FileProgressBar: View {
    let reading: MacFileReading
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: OutputsSheet.symbol(reading.name)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(reading.name).font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(amount).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                if let size = reading.size, size > 0 {
                    ProgressView(value: Double(reading.received), total: Double(size))
                } else {
                    ProgressView(value: 0).opacity(0.4)
                }
            }
            Button("Cancel", action: cancel).font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var amount: String {
        guard let size = reading.size else { return String(localized: "Receiving…") }
        let received = Int64(reading.received).formatted(.byteCount(style: .file))
        return String(localized: "\(received) of \(Int64(size).formatted(.byteCount(style: .file)))")
    }
}

/// Opens a task the way the task list does, onto the Mac's navigation stack.
struct OpenTaskAction {
    let open: (String) -> Void

    func callAsFunction(_ taskID: String) { open(taskID) }
}

extension EnvironmentValues {
    @Entry var openTask = OpenTaskAction { _ in }
}
