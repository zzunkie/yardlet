import AppKit
import SwiftUI

struct PersonalAgentsSidebar: View {
    @Bindable var center: PersonalAgentCenter
    let accounts: [AccountChoice]
    @Binding var accountID: String
    let accountMenu: SidebarAccountMenuContext
    /// The sidebar's top, the same as over the tasks: Home, Scheduled tasks and the Tasks word that
    /// switches the list back.
    let onHome: () -> Void
    var onShowSchedules: (() -> Void)?
    let onShowTasks: () -> Void
    let onAccounts: () -> Void
    let onRefresh: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            SidebarPlacesHeader(onHome: onHome, onShowSchedules: onShowSchedules, section: .personalAgents,
                                onSelectSection: { if $0 == .tasks { onShowTasks() } })

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    accountHeading
                        .padding(.horizontal, 13 - SidebarMetrics.rowInset)
                        .padding(.bottom, 2)
                    ForEach(center.agents) { agent in
                        Button { Task { await center.select(agent.id) } } label: {
                            HStack(spacing: 8) {
                                PersonalAgentAvatarView(name: agent.name, data: center.avatar(for: agent),
                                                        sheet: center.spriteSheet(for: agent), size: 22)
                                Text(agent.name).font(.system(size: 13 * scale)).lineLimit(1)
                                Spacer(minLength: 4)
                                if agent.isPaused {
                                    Text(L10n.string("Paused")).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 32 * scale)
                            .background(center.selectedID == agent.id ? ParityTheme.selectedFill : .clear,
                                        in: SidebarMetrics.rowShape())
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .parityPointer()
                        .accessibilityLabel(agent.name)
                        .accessibilityValue(agent.isPaused ? L10n.string("Paused") : "")
                        .accessibilityAddTraits(center.selectedID == agent.id ? .isSelected : [])
                    }
                    if center.hasLoaded, center.agents.isEmpty, center.failure == nil {
                        Text(L10n.string("No dots in this account"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.horizontal, SidebarMetrics.rowInset)
                // The heading starts where Projects does over the tasks, below their search field.
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            Rectangle().fill(ParityTheme.separator).frame(height: 1)
            SidebarAccountButton(context: accountMenu).padding(.horizontal, 4).padding(.vertical, 5)
        }
        .background(ParityTheme.sidebar)
    }

    /// The account the dots are read from, as a section heading like Projects: a menu of the accounts
    /// when there are several, its name alone otherwise, and the refresh button where Projects has Add.
    private var accountHeading: some View {
        HStack(spacing: 8) {
            let title = accounts.first { $0.id == accountID }?.title ?? "ChatGPT"
            if accounts.count > 1 {
                Menu {
                    ForEach(accounts) { account in
                        Button(account.title) { accountID = account.id }
                    }
                    Divider()
                    Button(L10n.string("Accounts…"), action: onAccounts)
                } label: {
                    HStack(spacing: 4) {
                        Text(title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.string("ChatGPT account"))
                .accessibilityValue(title)
            } else {
                Text(title).lineLimit(1)
            }
            Spacer()
            Group {
                if center.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .parityPointer()
                    .help(L10n.string("Refresh"))
                    .accessibilityLabel(L10n.string("Refresh personal agents"))
                }
            }
            .frame(width: 22, height: 22)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// A dot's profile picture: its pet, where a sheet is given, playing or, beside a message and with
/// Reduce Motion, still on its first frame; else the provider's static snapshot, or its initial while
/// there is none. The bytes are bounded by the transport; a picture larger than any avatar is not drawn.
struct PersonalAgentAvatarView: View {
    let name: String
    let data: Data?
    var sheet: PersonalAgentSpriteSheet? = nil
    /// Whether the pet plays here; a message's picture holds its first frame.
    var plays = true
    let size: CGFloat
    @State private var image: NSImage?
    @State private var frames: PersonalAgentSpriteFrames?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maximumPixels = 2_048

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.personalAgentAvatar)
#endif
        Group {
            // The pet stands in its square uncut, with nothing behind it, as the provider's app shows it.
            if let frames, plays, !reduceMotion {
                PersonalAgentSpriteAvatar(frames: frames, size: size)
            } else if let frames {
                Image(decorative: frames.still, scale: 1).resizable().interpolation(.medium)
            } else {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Circle().fill(ParityTheme.selectedFill)
                        Text(name.first.map { String($0).uppercased() } ?? "·")
                            .font(.system(size: size * 0.46, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: data) { image = data.flatMap(Self.decode) }
        .task(id: sheet.map(ObjectIdentifier.init)) {
            // A sheet that comes in place of another shows nothing of the old one while it decodes, and
            // a decoding that ends after the sheet was replaced (its task cancelled) shows nothing.
            frames = nil
            guard let sheet else { return }
            let decoded = await PersonalAgentSpriteFrames.decoded(sheet)
            guard !Task.isCancelled else { return }
            frames = decoded
        }
    }

    static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), let rep = image.representations.first,
              (1...maximumPixels).contains(rep.pixelsWide), (1...maximumPixels).contains(rep.pixelsHigh) else { return nil }
        return image
    }
}

struct PersonalAgentsContent: View {
    @Bindable var center: PersonalAgentCenter
    /// The account the dots belong to, as the account menu names it.
    var accountTitle: String? = nil
    let onRetry: () -> Void
    let onAccounts: () -> Void
    @State private var preview: PersonalAgentPreviewFile?
    @State private var attachmentFailure: PersonalAgentFailure?
    @State private var loadingAttachment = false
    @State private var width: CGFloat = 0
    /// The person hid the details beside a conversation wide enough for them.
    @State private var hidesDetails = false
    /// The person raised the details over a conversation too narrow to keep them beside it.
    @State private var raisesDetails = false

    /// The details sit beside the conversation only where both keep their width, as the session rail does.
    private var detailsFit: Bool {
        width >= SessionRailPlacement.minimumAloneWidth + PersonalAgentDetailsPanel.width
    }
    private var showsDetailsBeside: Bool { detailsFit && !hidesDetails }
    private var showsDetailsRaised: Bool { !detailsFit && raisesDetails }

    var body: some View {
        Group {
            if let agent = center.selected, let conversation = center.conversation {
                HStack(spacing: 0) {
                    PersonalAgentConversationView(agent: agent, conversation: conversation,
                        avatar: center.avatar(for: agent),
                        sheet: center.spriteSheet(for: agent),
                        reconnecting: center.isReconnecting,
                        connectionFailure: center.failure,
                        showsDetails: showsDetailsBeside || showsDetailsRaised,
                        isLoadingAttachment: loadingAttachment,
                        attachmentFailure: attachmentFailure,
                        send: { Task { await center.send() } },
                        files: PersonalAgentComposerFiles(
                            target: { center.fileTarget() },
                            attach: { sources, target in Task { await center.attach(sources, to: target) } },
                            attachImage: { encode, target in Task { await center.attachImage(to: target, encode: encode) } },
                            retry: { center.retryUploads() },
                            remove: { center.removeFile($0) }),
                        open: open,
                        refresh: {
                            if center.failure != nil { onRetry() }
                            else {
                                Task { await center.refreshConversation() }
                                center.refreshDetails()
                            }
                        },
                        loadOlder: { Task { await center.refreshConversation(older: true) } },
                        toggleDetails: toggleDetails)
                        .id(agent.id)
                    if showsDetailsBeside {
                        Rectangle().fill(ParityTheme.separator).frame(width: 1)
                        details(agent: agent, conversation: conversation)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Below the conversation's header, whose button still hides them.
                    if showsDetailsRaised {
                        details(agent: agent, conversation: conversation, close: toggleDetails)
                            .overlay(alignment: .leading) { Rectangle().fill(ParityTheme.separator).frame(width: 1) }
                            .overlay(alignment: .top) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
                            .shadow(color: .black.opacity(0.12), radius: 12, x: -2)
                            .padding(.top, PersonalAgentConversationView.headerHeight)
                            .onExitCommand(perform: toggleDetails)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "circle.dotted").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("Dots").font(.title2.weight(.medium))
                    if center.isLoading {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Loading your dots…")).foregroundStyle(.secondary)
                    } else if let failure = center.failure {
                        Text(failure.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        if failure == .signInRequired || failure == .runtimeUnavailable {
                            Button(L10n.string("Open Accounts"), action: onAccounts)
                        } else {
                            Button(failure == .accountChanged ? L10n.string("Reconnect") : L10n.string("Try again"),
                                   action: onRetry)
                        }
                    } else if center.hasLoaded {
                        Text(L10n.string("Create your dot in ChatGPT, then refresh here."))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .font(.system(size: 13))
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ParityTheme.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: detailsFit) { _, _ in raisesDetails = false }
        .sheet(item: $preview) { file in
            PersonalAgentAttachmentPreview(file: file) { preview = nil }
        }
    }

    private func details(agent: PersonalAgent, conversation: PersonalAgentConversation,
                         close: (() -> Void)? = nil) -> some View {
        PersonalAgentDetailsPanel(agent: agent, avatar: center.avatar(for: agent), sheet: center.spriteSheet(for: agent),
                                  accountTitle: accountTitle,
            details: center.details, attachments: PersonalAgentDetailsPanel.attachments(in: conversation.visibleMessages),
            isLoadingAttachment: loadingAttachment, open: open,
            retry: { center.refreshDetails() },
            loadMoreActivity: { Task { await center.loadMoreActivity() } },
            close: close)
    }

    private func toggleDetails() {
        withAnimation(.easeInOut(duration: 0.18)) {
            if detailsFit { hidesDetails.toggle() } else { raisesDetails.toggle() }
        }
    }

    /// Reads a file attachment and shows it in a native preview; saving it stays the person's action.
    private func open(_ attachment: PersonalAgentAttachment) {
        guard let agent = center.selected, !loadingAttachment else { return }
        loadingAttachment = true
        attachmentFailure = nil
        Task {
            defer { loadingAttachment = false }
            do { preview = try PersonalAgentPreviewFile(download: await center.download(attachment, for: agent.id)) }
            catch { attachmentFailure = error as? PersonalAgentFailure ?? .attachmentUnavailable }
        }
    }
}

/// Opens a dot's own surfaces when the person asks: the dot's page on the provider's website, and the
/// Dots home in the provider's app where it is installed (`DotsApp`). Renders put in one that opens nothing.
@MainActor
struct PersonalAgentOriginalOpener {
    var appLocation: @MainActor () -> URL?
    /// Whether the address was handed on.
    var openWeb: @MainActor (URL) -> Bool
    var openApp: @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void

    static let live = PersonalAgentOriginalOpener(appLocation: DotsApp.location, openWeb: DotsApp.openWeb,
                                                  openApp: DotsApp.openHome)
}

private struct PersonalAgentOriginalOpenerKey: EnvironmentKey {
    static let defaultValue: PersonalAgentOriginalOpener? = nil
}

extension EnvironmentValues {
    var personalAgentOriginalOpener: PersonalAgentOriginalOpener? {
        get { self[PersonalAgentOriginalOpenerKey.self] }
        set { self[PersonalAgentOriginalOpenerKey.self] = newValue }
    }
}

struct PersonalAgentConversationView: View {
    let agent: PersonalAgent
    @Bindable var conversation: PersonalAgentConversation
    var avatar: Data?
    /// The pet the header's picture plays; each message's picture holds its first frame.
    var sheet: PersonalAgentSpriteSheet?
    var reconnecting = false
    var connectionFailure: PersonalAgentFailure?
    var showsDetails = false
    var isLoadingAttachment = false
    var attachmentFailure: PersonalAgentFailure?
    let send: () -> Void
    var files = PersonalAgentComposerFiles()
    let open: (PersonalAgentAttachment) -> Void
    let refresh: () -> Void
    let loadOlder: () -> Void
    var toggleDetails: () -> Void = {}
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.personalAgentOriginalOpener) private var opener
    /// The provider's app, where it is installed, looked up once the conversation shows.
    @State private var dotsApp: URL?
    @State private var openFailed = false

    static let headerHeight: CGFloat = 46

    private var original: PersonalAgentOriginalOpener { opener ?? .live }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                PersonalAgentAvatarView(name: agent.name, data: avatar, sheet: sheet, size: 24)
                Text(agent.name).font(.system(size: 14 * scale, weight: .semibold)).lineLimit(1)
                if reconnecting { Text(L10n.string("Reconnecting")).font(.caption).foregroundStyle(.secondary) }
                else if agent.isPaused { Text(L10n.string("Paused")).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                originalMenu
                Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).parityPointer().disabled(conversation.isLoading)
                    .help(L10n.string("Refresh")).accessibilityLabel(L10n.string("Refresh conversation"))
                Button(action: toggleDetails) {
                    Image(systemName: "sidebar.right").frame(width: 26, height: 26)
                        .foregroundStyle(showsDetails ? Color.primary : Color.secondary)
                }
                .buttonStyle(.borderless).parityPointer()
                .help(L10n.string(showsDetails ? "Hide dot details" : "Show dot details"))
                .accessibilityLabel(L10n.string(showsDetails ? "Hide dot details" : "Show dot details"))
            }
            .padding(.horizontal, 20).frame(height: Self.headerHeight)
            if let failure = conversation.failure ?? connectionFailure {
                HStack { Text(failure.message); Spacer(); Button(L10n.string("Try again"), action: refresh) }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: ParityTheme.contentWidth)
                    .padding(.horizontal, ParityTheme.conversationInset).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ConversationLayout.turnSpacing) {
                    if conversation.before != nil || conversation.olderFailure != nil {
                        olderMessages
                    }
                    if !conversation.loaded, conversation.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    let messages = conversation.visibleMessages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        messageRow(message, startsRun: index == 0 || messages[index - 1].author != message.author)
                            .id(message.id)
                    }
                    if conversation.loaded, messages.isEmpty {
                        Text(L10n.string("No messages yet")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: ParityTheme.contentWidth)
                .padding(.horizontal, ParityTheme.conversationInset)
                .padding(.top, 8)
                .padding(.bottom, ConversationLayout.bottomPadding)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: $conversation.anchor)
            if isLoadingAttachment || attachmentFailure != nil || openFailed {
                HStack(spacing: 6) {
                    if isLoadingAttachment { ProgressView().controlSize(.small) }
                    if let attachmentFailure { Text(attachmentFailure.message) }
                    else if openFailed { Text(L10n.string("Dots could not be opened.")) }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }
            PersonalAgentComposer(draft: conversation.draft, send: send, files: files,
                                  allowsFiles: conversation.allowsAttachments)
                .frame(maxWidth: ParityTheme.contentWidth)
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .background(ParityTheme.canvas)
        .task { dotsApp = original.appLocation() }
    }

    /// The dot where the provider shows it: its page on the web, which opens this dot, and, with the
    /// provider's app installed, the app's Dots home, which names no dot. Each opens with the sign-in
    /// its browser or app already has.
    private var originalMenu: some View {
        Menu {
            if let page = DotsLinks.web(for: agent) {
                Button(L10n.string("Open This Dot on the Web")) { openWeb(page) }
            }
            if let dotsApp {
                Button(L10n.string("Open Dots Home in ChatGPT")) {
                    openFailed = false
                    original.openApp(dotsApp) { openFailed = !$0 }
                }
            }
        } label: {
            // The words name the menu to accessibility; only the symbol shows.
            Label(L10n.string("Open in Dots"), systemImage: "arrow.up.right.square")
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .parityPointer()
        .help(L10n.string("Open in Dots"))
    }

    private func openWeb(_ page: URL) {
        openFailed = !original.openWeb(page)
    }

    /// Under something Yardlet does not show yet, a way to it on the dot's page.
    @ViewBuilder
    private func unsupportedLink(_ message: PersonalAgentMessage) -> some View {
        if !message.isDeleted, message.isUnsupported || message.attachments.contains(where: { !$0.opensHere }),
           let page = DotsLinks.web(for: agent) {
            Button(L10n.string("Open This Dot on the Web")) { openWeb(page) }
                .buttonStyle(.link)
                .font(.system(size: 12 * scale))
                .parityPointer()
        }
    }

    /// The top of the loaded history: earlier pages load when it comes into view, once each time, and
    /// stay where the person was reading; a failure waits for the person to try again.
    private var olderMessages: some View {
        HStack(spacing: 8) {
            if conversation.isLoading, conversation.loaded {
                ProgressView().controlSize(.small)
                Text(L10n.string("Loading earlier messages…"))
            } else if let failure = conversation.olderFailure {
                Text(L10n.string("Earlier messages could not be loaded."))
                    .help(failure.message)
                Button(L10n.string("Try again"), action: readEarlier).buttonStyle(.borderless).parityPointer()
            } else {
                Button(L10n.string("Load earlier messages"), action: readEarlier).buttonStyle(.borderless).parityPointer()
            }
        }
        .font(.system(size: 12 * scale))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .onAppear { if conversation.olderFailure == nil { readEarlier() } }
    }

    private func readEarlier() {
        guard !conversation.isLoading else { return }
        // Prepending keeps the message read first in its place.
        conversation.anchor = conversation.visibleMessages.first?.id
        loadOlder()
    }

    @ViewBuilder
    private func messageRow(_ message: PersonalAgentMessage, startsRun: Bool) -> some View {
        if message.author == .person {
            VStack(alignment: .trailing, spacing: 6) {
                SentUserMessage(copyText: message.isDeleted ? "" : message.text, images: [],
                                minimumLeadingSpace: ConversationLayout.sentMessageLeadingSpace) {
                    Group {
                        if message.isDeleted {
                            Text(L10n.string("Message deleted")).italic().foregroundStyle(.secondary)
                        } else {
                            Text(message.text).textSelection(.enabled)
                        }
                    }
                    .font(ParityTheme.conversationFont(scale: scale))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(ConversationLayout.sentBubblePadding)
                    .background(ParityTheme.selectedFill,
                                in: RoundedRectangle(cornerRadius: ConversationLayout.sentBubbleCornerRadius))
                    .frame(maxWidth: ConversationLayout.sentBubbleMaximumWidth, alignment: .trailing)
                }
                attachments(of: message)
                unsupportedLink(message)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(message.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("You"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if startsRun {
                    HStack(spacing: 7) {
                        PersonalAgentAvatarView(name: author(message.author),
                                                data: message.author == .agent ? avatar : nil,
                                                sheet: message.author == .agent ? sheet : nil, plays: false, size: 20)
                        Text(author(message.author)).font(.system(size: 12.5 * scale, weight: .semibold))
                        if let time = message.createdAt {
                            Text(time.formatted(date: Calendar.current.isDateInToday(time) ? .omitted : .abbreviated,
                                                time: .shortened))
                                .font(.system(size: 11.5 * scale)).foregroundStyle(.secondary)
                        }
                    }
                }
                if message.isDeleted {
                    Text(L10n.string("Message deleted")).foregroundStyle(.secondary).italic()
                } else if !message.text.isEmpty {
                    TranscriptMarkdownText(text: message.text)
                        .font(ParityTheme.conversationFont(scale: scale))
                        .textSelection(.enabled)
                }
                attachments(of: message)
                unsupportedLink(message)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func attachments(of message: PersonalAgentMessage) -> some View {
        if !message.isDeleted, !message.attachments.isEmpty {
            VStack(alignment: message.author == .person ? .trailing : .leading, spacing: 4) {
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    if attachment.opensHere {
                        Button { open(attachment) } label: {
                            Label(attachment.name, systemImage: "paperclip").lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.borderless).parityPointer().disabled(isLoadingAttachment)
                    } else {
                        Label(attachment.name, systemImage: "paperclip").foregroundStyle(.secondary)
                            .help(L10n.string("This attachment cannot be opened here yet."))
                    }
                }
            }
            .font(.system(size: 12.5 * scale))
        }
    }

    private func author(_ value: PersonalAgentMessage.Author) -> String {
        switch value {
        case .person: L10n.string("You")
        case .agent: agent.name
        case let .other(name): name
        case .unknown: L10n.string("Unknown sender")
        }
    }
}

/// What the stock app shows beside a dot's conversation, as far as Yardlet reads it: the dot, its
/// Activity, its schedules, the computers its root thread can use, and the files in the conversation
/// loaded here. Every part reads only; none starts work, connects a computer or changes the dot.
struct PersonalAgentDetailsPanel: View {
    static let width: CGFloat = SessionRailPlacement.width

    let agent: PersonalAgent
    let avatar: Data?
    var sheet: PersonalAgentSpriteSheet?
    let accountTitle: String?
    let details: PersonalAgentDetails?
    let attachments: [PersonalAgentAttachment]
    let isLoadingAttachment: Bool
    let open: (PersonalAgentAttachment) -> Void
    let retry: () -> Void
    let loadMoreActivity: () -> Void
    /// Hides the details raised over a narrow conversation.
    var close: (() -> Void)? = nil
    @Environment(\.yardletInterfaceScale) private var scale

    /// The openable files of the loaded messages, newest first, each once.
    static func attachments(in messages: [PersonalAgentMessage]) -> [PersonalAgentAttachment] {
        var seen = Set<String>()
        return messages.reversed().filter { !$0.isDeleted }.flatMap(\.attachments).filter { attachment in
            guard attachment.type == "file", let id = attachment.fileID else { return false }
            return seen.insert(id).inserted
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                profile
                section(L10n.string("Activity")) { activity }
                section(L10n.string("Scheduled")) { schedules }
                if agent.rootThreadID != nil {
                    section(L10n.string("Computers")) { computers }
                }
                section(L10n.string("Conversation attachments")) { conversationFiles }
            }
            .font(.system(size: 12 * scale))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(width: Self.width, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ParityTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Dot details"))
    }

    private var profile: some View {
        HStack(spacing: 12) {
            PersonalAgentAvatarView(name: agent.name, data: avatar, sheet: sheet, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.system(size: 14 * scale, weight: .semibold)).lineLimit(1)
                if let accountTitle {
                    Text(accountTitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if agent.isPaused { Text(L10n.string("Paused")).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let close {
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).parityPointer()
                    .help(L10n.string("Hide dot details"))
                    .accessibilityLabel(L10n.string("Hide dot details"))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12 * scale, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func state<Value: Equatable, Rows: View>(_ part: PersonalAgentDetails.Part<Value>?, empty: String,
                                                     isEmpty: (Value) -> Bool,
                                                     @ViewBuilder rows: (Value) -> Rows) -> some View {
        switch part ?? .loading {
        case .loading:
            ProgressView().controlSize(.small)
        case let .failed(failure):
            HStack(spacing: 6) {
                Text(L10n.string("Could not load this.")).foregroundStyle(.secondary).help(failure.message)
                Button(L10n.string("Try again"), action: retry).buttonStyle(.borderless).parityPointer()
            }
        case let .loaded(value):
            if isEmpty(value) { Text(empty).foregroundStyle(.secondary) } else { rows(value) }
        }
    }

    private var activity: some View {
        state(details?.activity, empty: L10n.string("No activity yet"), isEmpty: \.isEmpty) { items in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    SessionRailRow(systemName: Self.symbol(item), title: item.title) {
                        if let date = item.updatedAt {
                            Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .help(item.preview ?? item.title)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Self.statusText(item))
                }
                if details?.activityCursor != nil {
                    Button(L10n.string("Show more"), action: loadMoreActivity)
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).parityPointer()
                        .disabled(details?.isLoadingMoreActivity == true)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var schedules: some View {
        state(details?.schedules, empty: L10n.string("No scheduled tasks."), isEmpty: \.isEmpty) { items in
            SessionRailLimitedList(items: items, limit: 5) { item in
                SessionRailRow(systemName: "clock", title: item.title ?? L10n.string("Scheduled task")) {
                    if item.isEnabled == false {
                        Text(L10n.string("Off")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var computers: some View {
        state(details?.computers, empty: L10n.string("No computers"), isEmpty: \.isEmpty) { items in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { computer in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: computer.isCloud ? "cloud" : "desktopcomputer")
                            .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(computer.name).lineLimit(1).truncationMode(.middle)
                            if let status = Self.statusText(computer) {
                                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(minHeight: 24)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var conversationFiles: some View {
        VStack(alignment: .leading, spacing: 2) {
            if attachments.isEmpty {
                Text(L10n.string("No files in the loaded messages")).foregroundStyle(.secondary)
            } else {
                SessionRailLimitedList(items: attachments.map(IdentifiedAttachment.init), limit: 6) { item in
                    Button { open(item.attachment) } label: {
                        SessionRailRow(systemName: SessionRailOutputsCard.symbol(URL(filePath: item.attachment.name.isEmpty ? "file" : item.attachment.name)),
                                       title: item.attachment.name)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).parityPointer().disabled(isLoadingAttachment)
                }
            }
            Text(L10n.string("Only files in the messages loaded here."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
    }

    private struct IdentifiedAttachment: Identifiable {
        let attachment: PersonalAgentAttachment
        var id: String { attachment.fileID ?? attachment.name }
    }

    static func symbol(_ item: PersonalAgentActivity) -> String {
        switch (item.status, item.outcome) {
        case (.running, _): "circle.dotted"
        case (_, .succeeded): "checkmark.circle"
        case (_, .failed): "xmark.circle"
        case (_, .interrupted): "pause.circle"
        default: "circle"
        }
    }

    static func statusText(_ item: PersonalAgentActivity) -> String {
        switch (item.status, item.outcome) {
        case (.running, _): L10n.string("Running")
        case (_, .succeeded): L10n.string("Completed")
        case (_, .failed): L10n.string("Failed")
        case (_, .interrupted): L10n.string("Interrupted")
        default: ""
        }
    }

    /// The provider's availability when it gives one; otherwise only whether the dot may use the computer.
    static func statusText(_ computer: PersonalAgentComputer) -> String? {
        switch computer.availability {
        case .connected: L10n.string("Connected")
        case .disconnected: L10n.string("Not connected")
        case .offline: L10n.string("Offline")
        case .unknown: computer.isAttached ? L10n.string("Allowed for this dot") : nil
        }
    }
}

/// What the dot's composer does with files: each goes to the dot the conversation shows.
struct PersonalAgentComposerFiles {
    /// Where the files go, taken before choosing or reading them.
    var target: () -> PersonalAgentFileTarget? = { nil }
    var attach: ([PersonalAgentFileSource], PersonalAgentFileTarget) -> Void = { _, _ in }
    /// A pasted picture, as what makes its PNG bytes.
    var attachImage: (@escaping @Sendable () -> Data?, PersonalAgentFileTarget) -> Void = { _, _ in }
    var retry: () -> Void = {}
    var remove: (UUID) -> Void = { _ in }
}

private struct PersonalAgentComposer: View {
    @Bindable var draft: PersonalAgentDraft
    let send: () -> Void
    var files = PersonalAgentComposerFiles()
    /// The room takes files; otherwise the file button and drops are off, and files already here wait.
    var allowsFiles = true
    @FocusState private var focused: Bool
    @State private var confirmsEditing = false
    @State private var confirmsRecovery = false

    /// Words or files: a file alone is a message, and Send waits for one still uploading.
    private var hasMessage: Bool {
        !draft.editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.storageFailed {
                HStack {
                    Text(draft.needsRecovery
                         ? L10n.string("The saved draft could not be read. Keep it as a backup to start a new draft.")
                         : PersonalAgentFailure.draftStorage.message)
                    Spacer()
                    if draft.needsRecovery {
                        Button(L10n.string("Start a new draft")) { confirmsRecovery = true }
                    } else {
                        Button(L10n.string("Try again")) { draft.save() }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if let failure = draft.failure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.message).fixedSize(horizontal: false, vertical: true)
                    if draft.pending != nil, !draft.isSending {
                        HStack {
                            Button(L10n.string("Retry message"), action: submit)
                            Button(L10n.string("Edit message")) { confirmsEditing = true }
                        }
                    } else if failure == .attachmentsIncomplete, draft.hasFailedUploads, allowsFiles {
                        Button(L10n.string("Retry upload"), action: files.retry)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if draft.waitsForUploads {
                Text(L10n.string("Sending when the files finish uploading…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let failure = draft.files.lazy.compactMap(\.failure).first, draft.pending == nil {
                HStack {
                    Text(failure.message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if allowsFiles { Button(L10n.string("Retry upload"), action: files.retry) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ComposerEditor(draft: draft.editor, placeholder: L10n.string("Message your dot…"),
                accessibilityHint: L10n.string("Press Return to send"), metrics: .task(),
                input: nil, onExternalInput: externalInput, mentionRoots: [], commands: nil,
                isCommandMenuOpen: false, isMenuOpen: false, showsChips: !draft.files.isEmpty,
                isFocused: $focused, onSubmit: submit) {
                    EmptyView()
                } chips: {
                    ForEach(draft.files) { file in
                        PersonalAgentFileChip(file: file) { files.remove(file.id) }
                    }
                } footer: {
                    HStack {
                        ParityIconButton(systemName: "plus", help: L10n.string("Add files or photos"), action: chooseFiles)
                            .accessibilityLabel(L10n.string("Add files or photos"))
                            .disabled(!allowsFiles || draft.files.count >= PersonalAgentFileRules.maximumCount)
                        Spacer()
                        if draft.isSending { ProgressView().controlSize(.small) }
                        if draft.pending == nil {
                            ParityIconButton(systemName: "arrow.up", help: L10n.string("Send"), isProminent: true,
                                             action: submit)
                                .accessibilityLabel(L10n.string("Send message"))
                                .disabled(draft.isSending || draft.isAddingFiles || draft.storageFailed || !hasMessage)
                        }
                        else { Color.clear.frame(width: 28, height: 28) }
                    }
                    .padding(.leading, 10).padding(.trailing, 9).padding(.bottom, 9)
                }
                // A pending result is resolved with the original request, text and files.
                .disabled(draft.isSending || draft.pending != nil)
                .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        }
        .alert(L10n.string("Return to editing?"), isPresented: $confirmsEditing) {
            Button(L10n.string("Cancel"), role: .cancel) { }
            Button(L10n.string("Edit message")) { if draft.resumeEditing() { focused = true } }
        } message: {
            Text(L10n.string("The earlier message may already have arrived. Check the conversation before sending it again. Your text will stay here."))
        }
        .alert(L10n.string("Start a new draft?"), isPresented: $confirmsRecovery) {
            Button(L10n.string("Cancel"), role: .cancel) { }
            Button(L10n.string("Start a new draft")) { if draft.recoverStorage() { focused = true } }
        } message: {
            Text(L10n.string("The unreadable draft will be kept as a backup. The text currently in this editor will become the new draft."))
        }
    }

    private var externalInput: ((ComposerExternalInput) -> Void)? {
        guard allowsFiles else { return nil }
        return { receive($0) }
    }

    /// A paste or drop on the composer: files as they are, a picture as PNG, made off the main thread.
    private func receive(_ input: ComposerExternalInput) {
        guard draft.pending == nil, !draft.isSending, let target = files.target() else { return }
        switch input {
        case let .files(urls):
            files.attach(urls.map(PersonalAgentFileTypes.source), target)
        case let .image(data, type):
            files.attachImage({ ComposerExternalInput.pngData(data, type: type) }, target)
        }
    }

    private func chooseFiles() {
        guard let target = files.target() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Add")
        guard panel.runModal() == .OK else { return }
        files.attach(panel.urls.map(PersonalAgentFileTypes.source), target)
    }

    private func submit() {
        guard !draft.isSending, !draft.isAddingFiles, !draft.storageFailed, hasMessage || draft.pending != nil else { return }
        send()
    }
}

/// A file in the dot's composer: a picture as its thumbnail, anything else by name, each with its
/// upload shown over it (a spinner while it goes up, a warning when it did not) and a remove button.
private struct PersonalAgentFileChip: View {
    let file: PersonalAgentDraftFile
    let onRemove: () -> Void

    var body: some View {
        Group {
            if file.isImage {
                ComposerImageChip(url: file.copy, name: file.shownName, onRemove: onRemove)
                    .overlay {
                        if file.isInProgress {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if file.failure != nil {
                            Image(systemName: "exclamationmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                                .font(.system(size: 13))
                                .padding(3)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                HStack(spacing: 4) {
                    if file.isInProgress { ProgressView().controlSize(.mini) }
                    else if file.failure != nil {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    } else {
                        Image(systemName: "doc")
                    }
                    Text(file.shownName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
                    Button(action: onRemove) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .accessibilityLabel(L10n.string("Remove attachment"))
                    .help(L10n.string("Remove attachment"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(ParityTheme.subtleFill, in: Capsule())
            }
        }
        .help(status.map { file.shownName + " · " + $0 } ?? file.shownName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.map { file.shownName + ", " + $0 } ?? file.shownName)
    }

    private var status: String? {
        switch file.state {
        case .queued, .uploading: L10n.string("Uploading")
        case .uploaded: nil
        case let .failed(failure): failure == .uploadInterrupted ? L10n.string("Not uploaded") : L10n.string("Upload failed")
        }
    }
}
