import SwiftUI
import UIKit
import YardletRemote

// What a conversation in full detail adds to the phone's (docs/REMOTE_PROTOCOL.md §15.24, §15.31): the pictures a
// message or a tool line holds, a running command's newest output, what a line holds beyond its words, a subagent's
// card, and the phone's own words for a compaction, a provider's notice and a limit's windows. A Mac that sends §6
// only leaves all of it out, and the screens are as before.

extension RemoteItem {
    /// What the line holds opens at once, without asking the Mac (§15.31): a command's output, a thought process, a
    /// tool's result and error. A file change still reads its diffs with `itemDetail`.
    var showsBody: Bool {
        guard let body, activity != "fileChange" else { return false }
        return [body.output, body.detail, body.error, body.reasoning].contains { $0?.isBlank == false }
            || body.mcp?.isEmpty == false
            || body.widget != nil
    }

    /// Tapping the line opens something: a subagent's card, what the line holds, or what `itemDetail` reads (§15.8).
    var opensDetail: Bool { subagent != nil || hasDetail == true || showsBody }
}

private extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

// MARK: - Pictures

/// Shows a picture's preview whole. The task's screen sets it, so the picture stays open while the conversation
/// under it changes; elsewhere a strip opens its own.
struct OpenPreviewAction {
    let open: (OpenedPreview) -> Void

    func callAsFunction(_ preview: RemoteImagePreview) { open(OpenedPreview(preview: preview)) }
    func callAsFunction(image: UIImage, name: String?) { open(OpenedPreview(image: image, name: name)) }
}

extension EnvironmentValues {
    @Entry var openPreview: OpenPreviewAction?
}

/// A picture opened whole, either from a remote preview payload or a decoded inline Markdown image.
struct OpenedPreview: Identifiable {
    enum Source {
        case preview(RemoteImagePreview)
        case image(UIImage, name: String?)
    }

    let id = UUID()
    let source: Source

    init(preview: RemoteImagePreview) { source = .preview(preview) }
    init(image: UIImage, name: String?) { source = .image(image, name: name) }
}

/// A row of pictures' previews in the message's order; tapping one shows it whole. Previews the phone cannot read are
/// left out, as the count beside the message still says how many were sent.
struct PreviewStrip: View {
    let previews: [RemoteImagePreview]
    @Environment(\.openPreview) private var openPreview
    @State private var opened: OpenedPreview?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .sheet(item: $opened) { PreviewViewer(source: $0.source) }
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
                if let image = PreviewImages.image(preview.data) {
                    Button {
                        if let openPreview { openPreview(preview) } else { opened = OpenedPreview(preview: preview) }
                    } label: {
                        PreviewThumbnail(image: image)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preview.name ?? String(localized: "Picture"))
                }
            }
        }
    }
}

/// A preview 88 points high, as wide as its picture within reason.
private struct PreviewThumbnail: View {
    let image: UIImage

    var body: some View {
        let ratio = image.size.width / max(1, image.size.height)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: min(160, max(56, 88 * ratio)), height: 88)
            // A picture as light as the page (a screenshot) still reads as one.
            .background(YardletPalette.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
    }
}

/// One picture as large as the screen allows, with its name.
struct PreviewViewer: View {
    let source: OpenedPreview.Source
    @Environment(\.dismiss) private var dismiss

    init(preview: RemoteImagePreview) { source = .preview(preview) }
    init(source: OpenedPreview.Source) { self.source = source }

    private var image: UIImage? {
        switch source {
        case let .preview(preview): PreviewImages.image(preview.data)
        case let .image(image, _): image
        }
    }

    private var name: String? {
        switch source {
        case let .preview(preview): preview.name
        case let .image(_, name): name
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(16)
                        .accessibilityLabel(name ?? String(localized: "Picture"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(name ?? String(localized: "Picture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Previews decoded once, by their bytes: a line drawn again does not decode its pictures again.
@MainActor
enum PreviewImages {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let image = cache.object(forKey: key) { return image }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - A line's output and body

/// A running command's newest output under its line (§15.31), its last three lines, as the Mac's command card shows
/// it while it runs.
struct LiveOutputTail: View {
    let output: String

    var body: some View {
        let lines = Self.lines(output)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(YardletPalette.onSurfaceVariant)
            .accessibilityElement(children: .combine)
        }
    }

    /// The last `count` lines, read from the output's end, so a long output costs only what shows; a line a program
    /// wrote over (`\r`) shows what it reads last. Empty when the output has nothing but blank space.
    static func lines(_ output: String, count: Int = 3) -> [String] {
        let scalars = output.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex, scalars[scalars.index(before: end)].properties.isWhitespace {
            end = scalars.index(before: end)
        }
        guard end > scalars.startIndex else { return [] }
        var lines: [String] = []
        var lineEnd = end
        var index = end
        while index > scalars.startIndex, lines.count < count {
            let previous = scalars.index(before: index)
            if scalars[previous] == "\n" {
                lines.append(shown(scalars[index..<lineEnd]))
                lineEnd = previous
            }
            index = previous
        }
        if lines.count < count, index == scalars.startIndex { lines.append(shown(scalars[index..<lineEnd])) }
        return lines.reversed()
    }

    private static func shown(_ line: Substring.UnicodeScalarView) -> String {
        var line = line
        while line.last == "\r" { line.removeLast() }
        if let rewritten = line.lastIndex(of: "\r") { line = line[line.index(after: rewritten)...] }
        return String(line)
    }
}

/// Text that keeps its lines, in a fixed-width face that scrolls sideways: a command, an output, a tool's result.
struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YardletPalette.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5)
        )
    }
}

/// What a line holds in full detail (§15.31), as the Mac's card reads it: the command and its output (the start and
/// the newest part while it runs), the thought process, a tool's result with an MCP tool's words and pictures, and
/// its error. Equal while the line is, so a sheet open on one line is not laid out again for another line's change.
struct LineBodyView: View, @MainActor Equatable {
    let item: RemoteItem

    var body: some View {
        let body = item.body ?? RemoteConversationBody()
        VStack(alignment: .leading, spacing: 18) {
            if let command = shown(body.command) {
                section("Command") { CodeBlock(text: command) }
            }
            if let reasoning = shown(body.reasoning) {
                section("Thought Process") { MarkdownView(text: reasoning, font: .subheadline) }
            }
            if let output = shown(body.output) {
                section("Output", note: body.headBytes != nil
                        ? String(localized: "The start and the newest part of the output so far.") : nil) {
                    CodeBlock(text: output)
                }
            }
            if let result = shown(body.detail) {
                section("Result") { CodeBlock(text: result) }
            }
            if let blocks = body.mcp, !blocks.isEmpty {
                section(shown(body.detail) == nil ? "Result" : nil) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        McpBlockView(block: block)
                    }
                }
            }
            if let widget = body.widget {
                section(nil) {
                    ConversationWidgetCard(id: "\(item.id):detail", widget: widget)
                }
            }
            if let error = shown(body.error) {
                section("Error") {
                    Text(verbatim: error).font(.subheadline).foregroundStyle(YardletPalette.error).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shown(_ text: String?) -> String? {
        guard let text, !text.isBlank else { return nil }
        return text
    }

    private func section(_ title: LocalizedStringKey?, note: String? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(YardletPalette.onSurfaceVariant)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(YardletPalette.onSurfaceVariant)
            }
            content()
        }
    }
}

/// One block of an MCP tool's result (§15.31): its words, a picture, or a link it named, shown as words.
private struct McpBlockView: View {
    let block: RemoteConversationBody.Block

    var body: some View {
        if let image = block.image {
            PreviewStrip(previews: [image])
        } else if block.kind == "resource_link" {
            VStack(alignment: .leading, spacing: 2) {
                if let name = block.title ?? block.name { Text(verbatim: name).font(.subheadline.weight(.medium)) }
                if let uri = block.uri { Text(verbatim: uri).font(.footnote).foregroundStyle(YardletPalette.onSurfaceVariant) }
                if let text = block.text { Text(verbatim: text).font(.footnote) }
            }
            .textSelection(.enabled)
        } else if let text = block.text, !text.isBlank {
            Text(verbatim: text).font(.subheadline).textSelection(.enabled)
        }
    }
}

// MARK: - Subagents

/// A subagent's card (§15.24): what it was asked and what it answered, the harness it runs on, and what the Mac's card
/// offers: the task a Codex subagent runs in, a Claude Code subagent's conversation (`subtask` read, §15.31) and,
/// while it runs, Stop. It follows the line while it is open; why the Mac refused shows here, not under the sheet.
struct SubagentSheet: View {
    let session: HostSession
    let taskID: String
    let item: RemoteItem
    /// Opens the task a Codex subagent runs in, once the sheet has closed.
    let openTask: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var transcript: RemoteSubtaskTranscript?
    @State private var isReading = false
    @State private var isStopping = false
    @State private var refusal: String?

    private var live: RemoteItem { session.conversations[taskID]?.item(item.id) ?? item }

    var body: some View {
        let live = self.live
        let subagent = live.subagent ?? RemoteSubagent()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let about = about(live, subagent) {
                        Text(about).font(.subheadline).foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                    actions(live, subagent)
                    if let refusal {
                        Text(refusal).font(.footnote).foregroundStyle(YardletPalette.error)
                    }
                    SubagentWords(input: subagent.input, output: subagent.output).equatable()
                    if isReading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading…").font(.subheadline).foregroundStyle(YardletPalette.onSurfaceVariant)
                        }
                    }
                    if let transcript { conversation(transcript) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle(live.title ?? String(localized: "Subagent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The harness or model it runs on, whether it runs in the background, and how it ended.
    private func about(_ item: RemoteItem, _ subagent: RemoteSubagent) -> String? {
        let status: String? = switch item.status {
        case "running": String(localized: "Running")
        case "failed": String(localized: "Failed")
        case "stopped": String(localized: "Stopped")
        default: nil
        }
        let parts = [subagent.harnessLabel ?? subagent.model,
                     subagent.background == true ? String(localized: "In the background") : nil, status].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ item: RemoteItem, _ subagent: RemoteSubagent) -> some View {
        let childTask = subagent.taskIds?.first
        let reads = session.subtasks && subagent.activityId != nil && transcript == nil
        let stops = subagent.canStop == true && item.status == "running" && subagent.activityId != nil
        if childTask != nil || reads || stops {
            HStack(spacing: 8) {
                if let childTask {
                    Button("Open Subtask") {
                        openTask(childTask)
                    }
                }
                if reads {
                    Button("View Conversation") { read(subagent) }
                        .disabled(isReading || !session.isConnected)
                }
                if stops {
                    Button("Stop", role: .destructive) { stop(subagent) }
                        .disabled(isStopping || !session.isConnected)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func read(_ subagent: RemoteSubagent) {
        guard let activityID = subagent.activityId else { return }
        isReading = true
        refusal = nil
        Task {
            let result = await session.readSubtask(taskID, activityID: activityID)
            isReading = false
            switch result {
            case let .success(read): transcript = read
            case let .failure(failure): refusal = failure.message
            }
        }
    }

    private func stop(_ subagent: RemoteSubagent) {
        guard let activityID = subagent.activityId else { return }
        isStopping = true
        refusal = nil
        Task {
            refusal = await session.stopSubtask(taskID, activityID: activityID)
            isStopping = false
        }
    }

    private func conversation(_ transcript: RemoteSubtaskTranscript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation").font(.footnote.weight(.semibold)).foregroundStyle(YardletPalette.onSurfaceVariant)
            if transcript.truncated {
                Text("Only the latest turns show here. The rest is on \(session.name).")
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
            if transcript.items.isEmpty {
                Text("No messages yet.").font(.subheadline).foregroundStyle(YardletPalette.onSurfaceVariant)
            } else {
                SubtaskConversation(items: transcript.items)
            }
        }
        .padding(.top, 4)
    }
}

/// What a subagent was asked and what it answered, drawn only when they change.
private struct SubagentWords: View, @MainActor Equatable {
    let input: String?
    let output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let input, !input.isBlank { section("Input", input) }
            if let output, !output.isBlank { section("Output", output) }
        }
    }

    private func section(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(YardletPalette.onSurfaceVariant)
            MarkdownView(text: text, font: .subheadline)
        }
    }
}

/// A Claude Code subagent's conversation as the Mac read it, drawn as the task's own with every turn open and
/// nothing to act on: a request it made shows as what became of it.
struct SubtaskConversation: View {
    let items: [RemoteItem]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(items.filter { $0.kind != .turn && $0.queued != true }) { item in
                switch item.kind {
                case .user: UserMessageView(item: item)
                case .assistant: AssistantView(item: item)
                case .activity: ActivityLine(item: item, openDetail: nil)
                case .approval: AnsweredRequestLine(item: item)
                case .plan: PlanStepsView(item: item)
                case .notice: NoticeView(item: item)
                case .error: ErrorLine(item: item)
                case .turn: EmptyView()
                }
            }
        }
    }
}

/// An error in a conversation that is only read: its title and the provider's words.
private struct ErrorLine: View {
    let item: RemoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.title ?? String(localized: "Something went wrong"), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YardletPalette.error)
            if let message = item.message, !message.isEmpty {
                Text(verbatim: message).font(.subheadline).foregroundStyle(YardletPalette.onSurfaceVariant).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Notices and limits

/// A notice beside a turn (§6.8). In full detail the phone words a compaction itself, and a provider's notice says
/// why on a line of its own (§15.24); otherwise the notice reads in the Mac's words.
struct NoticeView: View {
    let item: RemoteItem

    var body: some View {
        let words = self.words
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: words.symbol).foregroundStyle(words.warns ? YardletPalette.warningText : YardletPalette.onSurfaceVariant)
                Text(verbatim: words.line)
            }
            .font(.footnote)
            if let more = words.more {
                Text(verbatim: more).font(.caption).foregroundStyle(YardletPalette.onSurfaceVariant)
            }
        }
        .foregroundStyle(YardletPalette.onSurfaceVariant)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var words: (line: String, more: String?, symbol: String, warns: Bool) {
        let fallback = item.text ?? item.title ?? ""
        if let compaction = item.compaction {
            switch compaction.phase {
            case "started":
                return (String(localized: "Compacting session…"),
                        compaction.whileIdle == true
                            ? String(localized: "Compacting while idle, before the prompt cache expires") : nil,
                        "rectangle.compress.vertical", false)
            case "failed":
                return (String(localized: "Compaction failed"), compaction.message, "exclamationmark.triangle", true)
            case "completed":
                let line: String
                if let before = compaction.tokensBefore, let after = compaction.tokensAfter, before > after {
                    line = String(localized: "Compacted session · saved \(Formatting.tokens(before - after)) tokens")
                } else if let before = compaction.tokensBefore {
                    line = String(localized: "Compacted session · from \(Formatting.tokens(before)) tokens")
                } else {
                    line = String(localized: "Compacted session")
                }
                return (line, compaction.whileIdle == true
                            ? String(localized: "Compacted while idle, before the prompt cache expired") : nil,
                        "rectangle.compress.vertical", false)
            default:
                return (fallback, nil, "rectangle.compress.vertical", false)
            }
        }
        if let notice = item.providerNotice {
            if notice.kind == "modelRerouted" {
                return (String(localized: "Your request was routed to \(notice.message)."),
                        notice.reason == "highRiskCyberActivity"
                            ? String(localized: "Heads up, your request was re-routed to reduce cyber-abuse risk.") : nil,
                        "arrow.triangle.branch", false)
            }
            let more = [notice.details, notice.path].compactMap { $0?.isBlank == false ? $0 : nil }.joined(separator: "\n")
            return (notice.message.isBlank ? fallback : notice.message, more.isEmpty ? nil : more,
                    "exclamationmark.triangle", true)
        }
        return (fallback, nil, "info.circle", false)
    }
}

/// Each window of a plan limit (§15.24), how much of it is used and when it resets, as the Mac's limit card lists
/// them: "Session 100% · resets 11:41 PM".
struct LimitWindowLines: View {
    let windows: [RemoteLimit.Window]
    let session: HostSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                Text(verbatim: line(window)).fontWeight(window.usedFraction >= 1 ? .semibold : nil)
            }
        }
        .font(.footnote)
        .foregroundStyle(YardletPalette.onSurfaceVariant)
    }

    private func line(_ window: RemoteLimit.Window) -> String {
        let name: String = switch window.window {
        case "session": String(localized: "Session")
        case "weekly": String(localized: "Weekly")
        case "model": window.model.map { String(localized: "Weekly · \($0)") } ?? String(localized: "Weekly")
        case "overage": String(localized: "Extra usage")
        default: window.window
        }
        let used = Int((window.usedFraction * 100).rounded())
        guard let resetsAt = window.resetsAt else { return String(localized: "\(name) \(used)%") }
        return String(localized: "\(name) \(used)% · resets \(Formatting.resetTime(session.date(resetsAt)))")
    }
}

extension View {
    /// Keeps a running line's newest output in view as it comes, from its first drawing on; a line that does not run
    /// opens at its start. Short content stays at the top either way.
    @ViewBuilder
    func followsNewest(_ follows: Bool) -> some View {
        if #available(iOS 18, *) {
            defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(follows ? .bottom : .top, for: .initialOffset)
                .defaultScrollAnchor(follows ? .bottom : .top, for: .sizeChanges)
        } else {
            defaultScrollAnchor(follows ? .bottom : .top)
        }
    }
}

extension Formatting {
    /// "42K", "1.3M": a count of tokens, as the Mac's context ring counts them.
    static func tokens(_ count: UInt64) -> String {
        switch count {
        case 0..<1_000: String(count)
        case 1_000..<1_000_000: String(format: count < 10_000 ? "%.1fK" : "%.0fK", Double(count) / 1_000)
        default: String(format: count < 10_000_000 ? "%.1fM" : "%.0fM", Double(count) / 1_000_000)
        }
    }

    /// When a limit resets: the time today, the day and time otherwise, as the Mac's limit card says it.
    static func resetTime(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
