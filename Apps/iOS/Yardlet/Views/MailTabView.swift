import SwiftUI
import YardletRemote

/// Live Mail tab consuming `mailCalendarV2` over the connected Mac's remote channel.
struct MailTabView: View {
    let session: HostSession
    let store: MailCalendarStore
    let isActive: Bool
    var onOpenConnectors: () -> Void = {}

    @State private var searchInput = ""
    @State private var activeSheet: ActiveSheet?
    @State private var isRefreshingState = false

    private enum ActiveSheet: Identifiable {
        case thread(accountId: String, threadId: String, subject: String)
        case compose

        var id: String {
            switch self {
            case let .thread(accountId, threadId, _): "thread:\(accountId):\(threadId)"
            case .compose: "compose"
            }
        }
    }

    var body: some View {
        Group {
            if store.mailReady {
                readyContent
            } else {
                gateContent
            }
        }
        .background(YardletPalette.background)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case let .thread(accountId, threadId, subject):
                MailThreadDetailSheet(
                    store: store,
                    accountId: accountId,
                    threadId: threadId,
                    initialSubject: subject
                )
            case .compose:
                MailComposeSheet(store: store)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                store.activateMailTab()
            }
        }
        .onChange(of: store.mailReady) { _, ready in
            if !ready {
                activeSheet = nil
                searchInput = ""
            } else if isActive {
                store.activateMailTab()
            }
        }
    }

    // MARK: - Ready State

    private var readyContent: some View {
        VStack(spacing: 0) {
            searchAndComposeBar
            folderChipsRow
            if store.mailAccounts.count >= 2 {
                accountChipsRow
            }
            if let banner = store.mailBanner {
                transientBanner(banner)
            }
            threadList
        }
    }

    private var searchAndComposeBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                TextField("Search mail", text: $searchInput)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurface)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        store.submitMailSearch(searchInput)
                    }
                if !searchInput.isEmpty || !store.mailQuery.isEmpty {
                    Button {
                        searchInput = ""
                        store.clearMailSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )

            Button {
                activeSheet = .compose
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YardletPalette.onPrimary)
                    .frame(width: 38, height: 38)
                    .background(YardletPalette.primary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.mailAccounts.isEmpty)
            .accessibilityLabel("New Message")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var folderChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MailCalendarStore.MailFolder.allCases) { item in
                    let isSelected = store.folder == item
                    Button {
                        store.selectFolder(item)
                    } label: {
                        Text(item.title)
                            .font(.footnote.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? YardletPalette.onPrimary : YardletPalette.onSurfaceVariant)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? YardletPalette.primary : YardletPalette.surfaceContainer,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected ? Color.clear : YardletPalette.outlineVariant,
                                    lineWidth: 0.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var accountChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                accountChip(title: String(localized: "All Accounts"), unreadCount: nil, isSelected: store.selectedMailAccountId == nil) {
                    store.selectMailAccount(nil)
                }
                ForEach(store.mailAccounts, id: \.id) { account in
                    accountChip(
                        title: account.displayName.isEmpty ? account.email : account.displayName,
                        unreadCount: account.unreadCount,
                        isSelected: store.selectedMailAccountId == account.id
                    ) {
                        store.selectMailAccount(account.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    private func accountChip(title: String, unreadCount: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(verbatim: title)
                    .lineLimit(1)
                if let unreadCount, unreadCount > 0 {
                    Text(verbatim: "\(unreadCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? YardletPalette.onPrimary.opacity(0.85) : YardletPalette.onSurfaceVariant)
                }
            }
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? YardletPalette.onPrimary : YardletPalette.onSurfaceVariant)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isSelected ? YardletPalette.primary : YardletPalette.surfaceContainerLow,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : YardletPalette.outlineVariant,
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func transientBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(YardletPalette.Status.connected)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(YardletPalette.onSurface)
            Spacer(minLength: 8)
            Button {
                store.mailBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .task(id: text) {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if store.mailBanner == text { store.mailBanner = nil }
        }
    }

    private var threadList: some View {
        List {
            if let error = store.mailError, !store.threads.isEmpty {
                inlineErrorRow(error) {
                    store.loadThreads(clearExisting: false)
                }
            }

            if store.mailLoading && store.threads.isEmpty {
                loadingRow("Loading mail…")
            } else if let error = store.mailError, store.threads.isEmpty {
                errorStateRow(error) {
                    store.loadThreads(clearExisting: true)
                }
            } else if store.threads.isEmpty {
                emptyStateRow
            } else {
                ForEach(store.threads, id: \.compositeKey) { summary in
                    threadRow(summary)
                }
                if store.canLoadMoreThreads {
                    loadMoreRow
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(YardletPalette.background)
        .refreshable {
            await store.refreshMail()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func threadRow(_ summary: RemoteMailV2ThreadSummary) -> some View {
        Button {
            activeSheet = .thread(
                accountId: summary.accountId,
                threadId: summary.threadId,
                subject: summary.subject
            )
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(summary.unread ? YardletPalette.Status.unread : Color.clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: MailCalendarStore.senderDisplayName(name: summary.fromName, email: summary.fromEmail))
                            .font(.subheadline.weight(summary.unread ? .semibold : .regular))
                            .foregroundStyle(YardletPalette.onSurface)
                            .lineLimit(1)
                        if summary.messageCount > 1 {
                            Text(verbatim: "\(summary.messageCount)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                        }
                        Spacer(minLength: 6)
                        if summary.starred {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                        }
                        if summary.hasAttachments {
                            Image(systemName: "paperclip")
                                .font(.caption2)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                        }
                        Text(Formatting.shortAge(Date(timeIntervalSince1970: Double(summary.dateMs) / 1_000)))
                            .font(.caption)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .monospacedDigit()
                    }

                    Text(summary.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? String(localized: "(No subject)")
                         : summary.subject)
                        .font(.body.weight(summary.unread ? .semibold : .regular))
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineLimit(1)

                    if !summary.snippet.isEmpty {
                        Text(verbatim: summary.snippet)
                            .font(.footnote)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                summary.unread ? YardletPalette.surfaceContainer : YardletPalette.surfaceContainerLow,
                in: RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: summary.unread ? 0.9 : 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            Button {
                store.loadMoreThreads()
            } label: {
                if store.mailLoadingMore {
                    ProgressView().controlSize(.small)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                } else {
                    Text("Load More")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(YardletPalette.onSurface)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
            }
            .background(YardletPalette.surfaceContainer, in: Capsule())
            .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
            .buttonStyle(.plain)
            .disabled(store.mailLoadingMore)
            Spacer()
        }
        .padding(.vertical, 12)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func loadingRow(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            Spacer()
        }
        .padding(.vertical, 36)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var emptyStateRow: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "envelope")
                    .font(.title2)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                Text(store.mailQuery.isEmpty
                     ? String(localized: "No Messages")
                     : String(localized: "No Matching Messages"))
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text(store.mailQuery.isEmpty
                     ? String(localized: "Messages in this folder on \(session.name) will appear here.")
                     : String(localized: "Try a different search term or switch folders."))
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    }

    private func errorStateRow(_ message: String, retry: @escaping () -> Void) -> some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't Load Mail")
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                Button("Retry", action: retry)
                    .prominentButton()
                    .padding(.top, 2)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    }

    private func inlineErrorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        MonochromeCard(fill: YardletPalette.errorContainer, border: YardletPalette.error.opacity(0.35), padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(YardletPalette.error)
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurface)
                Spacer(minLength: 8)
                Button("Retry", action: retry)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YardletPalette.onSurface)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    // MARK: - Gate Cards

    private var gateContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope")
                                .font(.title3)
                                .foregroundStyle(YardletPalette.onSurface)
                                .frame(width: 34, height: 34)
                                .background(YardletPalette.surfaceContainerHigh,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text("Mail")
                                .font(.headline)
                                .foregroundStyle(YardletPalette.onSurface)
                            Spacer(minLength: 8)
                            gateStatusBadge
                        }

                        Text(gateMessage)
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)

                        gateActions
                    }
                }
            }
            .padding(16)
        }
        .background(YardletPalette.background)
        .refreshable {
            if session.isConnected {
                await store.refreshState()
            } else {
                await session.refresh()
            }
        }
    }

    @ViewBuilder
    private var gateStatusBadge: some View {
        if !session.isConnected {
            pillBadge(color: YardletPalette.Status.running, title: "Offline")
        } else if let state = store.v2State {
            if !state.permitted {
                pillBadge(color: YardletPalette.Status.question, title: "Permission Off")
            } else {
                pillBadge(color: YardletPalette.Status.running, title: "Not Set Up")
            }
        } else if store.stateLoading {
            ProgressView().controlSize(.mini)
        } else if store.stateError != nil {
            pillBadge(color: YardletPalette.Status.failed, title: "Unavailable")
        } else {
            pillBadge(color: YardletPalette.Status.running, title: "Unavailable")
        }
    }

    private func pillBadge(color: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 7)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(YardletPalette.surfaceContainer, in: Capsule())
        .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5))
    }

    private var gateMessage: String {
        if !session.isConnected {
            return String(localized: "Connect to \(session.name) to view your mail.")
        }
        if let state = store.v2State {
            if !state.permitted {
                return String(localized: "To use Mail and Calendar from here, allow Mail and Calendar for this device in Settings › Remote › Paired devices on \(session.name).")
            }
            if !state.mailEnabled {
                return String(localized: "Turn on Mail in Yardlet on \(session.name) to view your inbox here.")
            }
            return String(localized: "Connect a mail account in Yardlet on \(session.name) to view your inbox here.")
        }
        if let error = store.stateError {
            return error
        }
        if store.stateLoading {
            return String(localized: "Checking Mail and Calendar access on \(session.name)…")
        }
        return String(localized: "Couldn't check Mail and Calendar status on \(session.name).")
    }

    @ViewBuilder
    private var gateActions: some View {
        if !session.isConnected {
            Button("Retry") { session.reconnectNow() }
                .prominentButton()
        } else if store.v2State == nil && !store.stateLoading {
            Button("Retry") {
                Task { await store.refreshState() }
            }
            .prominentButton()
        } else if let state = store.v2State {
            HStack(spacing: 10) {
                if state.permitted && (!state.mailEnabled || !state.mailConnected) && session.capabilities.hostAccounts {
                    Button("Manage Connectors", action: onOpenConnectors)
                        .prominentButton()
                }
                Button {
                    isRefreshingState = true
                    Task {
                        await store.refreshState()
                        isRefreshingState = false
                    }
                } label: {
                    if isRefreshingState {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh Status")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingState)
            }
        }
    }
}

// MARK: - Thread Detail Sheet

private struct MailThreadDetailSheet: View {
    let store: MailCalendarStore
    let accountId: String
    let threadId: String
    let initialSubject: String

    @Environment(\.dismiss) private var dismiss
    @State private var replyBody = ""
    @State private var pendingReplyConfirmation: PendingReplyConfirmation?

    private struct PendingReplyConfirmation {
        let accountId: String
        let threadId: String
        let replyToMessageId: String?
        let recipientsDisplay: String
        let subjectDisplay: String
        let body: String
    }

    private var thread: RemoteMailV2Thread? {
        guard let current = store.openThread,
              current.accountId == accountId,
              current.threadId == threadId else { return nil }
        return current
    }

    private var displaySubject: String {
        let raw = thread?.subject ?? initialSubject
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "(No subject)") : trimmed
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.openThreadLoading && thread == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading conversation…")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.openThreadError, thread == nil {
                    ScrollView {
                        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Couldn't Load Conversation")
                                    .font(.headline)
                                    .foregroundStyle(YardletPalette.onSurface)
                                Text(verbatim: error)
                                    .font(.subheadline)
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                                Button("Retry") {
                                    store.loadThread(accountId: accountId, threadId: threadId)
                                }
                                .prominentButton()
                            }
                        }
                        .padding(16)
                    }
                } else if let thread {
                    threadMessagesContent(thread)
                }
            }
            .background(YardletPalette.background)
            .navigationTitle(displaySubject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let thread {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            Task {
                                _ = await store.updateOpenThread(action: thread.starred ? .unstar : .star)
                            }
                        } label: {
                            Image(systemName: thread.starred ? "star.fill" : "star")
                        }
                        .disabled(store.mailBusy)
                        .accessibilityLabel(thread.starred ? String(localized: "Unstar") : String(localized: "Star"))

                        Button {
                            Task {
                                _ = await store.updateOpenThread(action: thread.unread ? .markRead : .markUnread)
                            }
                        } label: {
                            Image(systemName: thread.unread ? "envelope.open" : "envelope.badge")
                        }
                        .disabled(store.mailBusy)
                        .accessibilityLabel(thread.unread ? String(localized: "Mark Read") : String(localized: "Mark Unread"))

                        Button {
                            Task {
                                if await store.updateOpenThread(action: .archive) {
                                    dismiss()
                                }
                            }
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .disabled(store.mailBusy)
                        .accessibilityLabel("Archive")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let thread {
                    replyComposer(for: thread)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert(
            "Send Reply?",
            isPresented: Binding(
                get: { pendingReplyConfirmation != nil },
                set: { if !$0 { pendingReplyConfirmation = nil } }
            ),
            presenting: pendingReplyConfirmation
        ) { confirmation in
            Button("Send Reply") {
                Task {
                    let ok = await store.sendReply(
                        accountId: confirmation.accountId,
                        threadId: confirmation.threadId,
                        replyToMessageId: confirmation.replyToMessageId,
                        body: confirmation.body
                    )
                    if ok && replyBody == confirmation.body {
                        replyBody = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            let recipientLine = confirmation.recipientsDisplay.isEmpty
                ? String(localized: "No recipients")
                : confirmation.recipientsDisplay
            Text("To: \(recipientLine)\nSubject: \(confirmation.subjectDisplay)")
        }
        .onAppear {
            store.loadThread(accountId: accountId, threadId: threadId)
        }
        .onDisappear {
            store.closeThread()
        }
        .onChange(of: store.mailReady) { _, ready in
            if !ready { dismiss() }
        }
    }

    private func threadMessagesContent(_ thread: RemoteMailV2Thread) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.mailActionError {
                    MonochromeCard(fill: YardletPalette.errorContainer, border: YardletPalette.error.opacity(0.35), padding: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(YardletPalette.error)
                            Text(verbatim: error)
                                .font(.footnote)
                                .foregroundStyle(YardletPalette.onSurface)
                            Spacer(minLength: 8)
                            Button {
                                store.mailActionError = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss")
                        }
                    }
                }

                if thread.messagesTruncated == true {
                    Text("Showing the latest messages in this conversation.")
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .padding(.horizontal, 4)
                }

                ForEach(Array(thread.messages.enumerated()), id: \.offset) { _, message in
                    messageCard(message)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func messageCard(_ message: RemoteMailV2Message) -> some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: MailCalendarStore.senderDisplayName(name: message.from.name, email: message.from.email))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineLimit(1)
                    if message.isDraft {
                        Text("Draft")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: Double(message.dateMs) / 1_000).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .monospacedDigit()
                }

                if !message.to.isEmpty {
                    let toText = message.to.map(MailCalendarStore.formattedAddress).joined(separator: ", ")
                    Text("To: \(toText)")
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .lineLimit(2)
                }

                if !message.cc.isEmpty {
                    let ccText = message.cc.map(MailCalendarStore.formattedAddress).joined(separator: ", ")
                    Text("Cc: \(ccText)")
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .lineLimit(2)
                }

                Rectangle()
                    .fill(YardletPalette.outlineVariant)
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                let bodyText = message.textBody.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bodyText.isEmpty {
                    Text(verbatim: bodyText)
                        .font(.subheadline)
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if !message.snippet.isEmpty {
                    Text(verbatim: message.snippet)
                        .font(.subheadline)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if message.bodyTruncated {
                    Text("Message truncated. Open Yardlet on your Mac to read the full text.")
                        .font(.caption)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .padding(.top, 2)
                }

                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                    .font(.caption)
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                                Text(verbatim: attachment.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(YardletPalette.onSurface)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if attachment.size > 0 {
                                    Text(verbatim: MailCalendarStore.formatAttachmentSize(attachment.size))
                                        .font(.caption2)
                                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func replyComposer(for thread: RemoteMailV2Thread) -> some View {
        let preview = store.replyPreview(for: thread)
        let trimmedReply = replyBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let tooLong = replyBody.count > RemoteMailCalendarV2Limits.maxSendBodyCharacters
        let canSend = !trimmedReply.isEmpty && !tooLong && !store.mailBusy

        return VStack(alignment: .leading, spacing: 6) {
            if !preview.recipientsDisplay.isEmpty {
                Text("Reply to \(preview.recipientsDisplay)")
                    .font(.caption)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }

            if tooLong {
                Text("Message body must be \(RemoteMailCalendarV2Limits.maxSendBodyCharacters) characters or fewer.")
                    .font(.caption)
                    .foregroundStyle(YardletPalette.error)
                    .padding(.horizontal, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Write a reply…", text: $replyBody, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurface)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
                    )

                Button {
                    guard canSend else { return }
                    pendingReplyConfirmation = PendingReplyConfirmation(
                        accountId: thread.accountId,
                        threadId: thread.threadId,
                        replyToMessageId: preview.replyToMessageId,
                        recipientsDisplay: preview.recipientsDisplay,
                        subjectDisplay: preview.subjectDisplay,
                        body: replyBody
                    )
                } label: {
                    Group {
                        if store.mailBusy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(YardletPalette.onPrimary)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(YardletPalette.onPrimary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(canSend ? YardletPalette.primary : YardletPalette.outline, in: Circle())
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send Reply")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(YardletPalette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5)
        }
    }
}

// MARK: - Compose New Message Sheet

private struct MailComposeSheet: View {
    let store: MailCalendarStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountId = ""
    @State private var toField = ""
    @State private var ccField = ""
    @State private var showCc = false
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var validationError: String?
    @State private var pendingConfirmation: ComposeConfirmation?

    private struct ComposeConfirmation {
        let accountId: String
        let toRaw: String
        let ccRaw: String
        let subject: String
        let body: String
        let recipientsDisplay: String
        let subjectDisplay: String
    }

    private var canAttemptSend: Bool {
        !store.mailBusy
            && !selectedAccountId.isEmpty
            && !MailCalendarStore.parseRecipients(toField).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = validationError ?? store.mailActionError {
                        MonochromeCard(fill: YardletPalette.errorContainer, border: YardletPalette.error.opacity(0.35), padding: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(YardletPalette.error)
                                Text(verbatim: error)
                                    .font(.footnote)
                                    .foregroundStyle(YardletPalette.onSurface)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            if store.mailAccounts.count >= 2 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("From")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                                    Picker("From", selection: $selectedAccountId) {
                                        ForEach(store.mailAccounts, id: \.id) { account in
                                            Text(verbatim: account.email).tag(account.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(YardletPalette.onSurface)
                                }
                                hairline
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("To")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                                    Spacer()
                                    if !showCc {
                                        Button("Add Cc") { showCc = true }
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                                    }
                                }
                                TextField("name@example.com", text: $toField)
                                    .font(.body)
                                    .foregroundStyle(YardletPalette.onSurface)
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            if showCc {
                                hairline
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Cc")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                                    TextField("Optional", text: $ccField)
                                        .font(.body)
                                        .foregroundStyle(YardletPalette.onSurface)
                                        .keyboardType(.emailAddress)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }

                            hairline

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Subject")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                                TextField("Subject", text: $subject)
                                    .font(.body)
                                    .foregroundStyle(YardletPalette.onSurface)
                            }

                            hairline

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Message")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                                TextEditor(text: $bodyText)
                                    .font(.body)
                                    .foregroundStyle(YardletPalette.onSurface)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 180)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(YardletPalette.background)
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(store.mailBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.mailBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Send") {
                            attemptConfirmSend()
                        }
                        .disabled(!canAttemptSend)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert(
            "Send Message?",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button("Send") {
                Task {
                    let ok = await store.sendNewMessage(
                        accountId: confirmation.accountId,
                        toRaw: confirmation.toRaw,
                        ccRaw: confirmation.ccRaw,
                        subject: confirmation.subject,
                        body: confirmation.body
                    )
                    if ok {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text("To: \(confirmation.recipientsDisplay)\nSubject: \(confirmation.subjectDisplay)")
        }
        .onAppear {
            store.mailActionError = nil
            if let preferred = store.selectedMailAccountId,
               store.mailAccounts.contains(where: { $0.id == preferred }) {
                selectedAccountId = preferred
            } else {
                selectedAccountId = store.mailAccounts.first?.id ?? ""
            }
        }
        .onChange(of: store.mailReady) { _, ready in
            if !ready { dismiss() }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(YardletPalette.outlineVariant)
            .frame(height: 0.5)
    }

    private func attemptConfirmSend() {
        if let message = store.validateCompose(
            accountId: selectedAccountId,
            toRaw: toField,
            ccRaw: ccField,
            subject: subject,
            body: bodyText
        ) {
            validationError = message
            return
        }
        validationError = nil
        let toRecipients = MailCalendarStore.parseRecipients(toField)
        let ccRecipients = MailCalendarStore.parseRecipients(ccField)
        var summaryRecipients = toRecipients.joined(separator: ", ")
        if !ccRecipients.isEmpty {
            summaryRecipients += " (Cc: \(ccRecipients.joined(separator: ", ")))"
        }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingConfirmation = ComposeConfirmation(
            accountId: selectedAccountId,
            toRaw: toField,
            ccRaw: ccField,
            subject: subject,
            body: bodyText,
            recipientsDisplay: summaryRecipients,
            subjectDisplay: trimmedSubject.isEmpty ? String(localized: "(No subject)") : trimmedSubject
        )
    }
}
