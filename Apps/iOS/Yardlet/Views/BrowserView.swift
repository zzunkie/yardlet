import SwiftUI
import YardletRemote

/// Which tab the browser screen opens on: the one named (a handoff's), or nil for the one that waits, else the front one.
struct BrowserTarget: Identifiable, Equatable {
    let id = UUID()
    let tabID: String?
}

/// Opens the task's browser tab screen on the tab named, or on the one that waits when nil (§15.25).
struct OpenBrowserTab: Equatable {
    let open: (String?) -> Void

    func callAsFunction(_ tabID: String?) { open(tabID) }

    /// The conversation's own action, whichever closure carries it: a new one draws nothing again.
    static func == (lhs: OpenBrowserTab, rhs: OpenBrowserTab) -> Bool { true }
}

extension EnvironmentValues {
    /// Nil where the Mac shows no tabs to the phone.
    @Entry var openBrowserTab: OpenBrowserTab?
}

/// A task's browser tab on the phone (docs/REMOTE_PROTOCOL.md §15.25), over its conversation: the tab's title and site
/// (which takes a new address where the Mac allows it, §15.30), the bars the Mac's panel shows above the page (the
/// handoff, a site's permission prompt, what waits on the Mac), the picture of the page, and under it Back, Forward,
/// Reload, the phone's own field for typing into the page and the choice to drag. The tab is watched only while this
/// screen shows, and its picture is hidden from the app switcher.
struct BrowserView: View {
    let session: HostSession
    let taskID: String
    let tabID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var typing = TabTyping()
    @State private var isShowingTabs = false
    @State private var isEditingAddress = false
    @State private var address = ""
    @FocusState private var isAddressFocused: Bool
    @State private var isDragging = false
    /// The keyboard is up for the typing field.
    @State private var isTyping = false
    @State private var isAnswering = false
    @State private var barHeight: CGFloat = 0
    @State private var pageBottom: CGFloat = 0
    @State private var barTop: CGFloat = 0

    private var browser: TaskBrowser { session.browser }
    private var tab: RemoteBrowserTab? { browser.watchedTab }
    private var isEnabled: Bool { session.isConnected && tab != nil }
    /// On a phone turned on its side a bar's buttons sit beside its words.
    private var isWide: Bool { verticalSizeClass == .compact }
    /// The Mac shows no tabs to the phone, or the task is gone: back to the conversation.
    private var leaves: Bool { session.hasSnapshot && (!browser.isOffered || session.task(taskID) == nil) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ConnectionBanner(session: session)
                    bars
                    pageArea
                    // The bottom bar's place under the page; the keyboard lifts the bar over the page instead of
                    // resizing it.
                    Color.clear.frame(height: barHeight)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                bottomBar
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        barHeight = frame.height
                        barTop = frame.minY
                    }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
        }
        .onAppear { browser.show(taskID, tabID: tabID) }
        .onDisappear { browser.hide() }
        // Another tab: the field starts empty, and what it held stays with the tab it was typed into.
        .onChange(of: tab?.tabId) { typing.clear() }
        .onChange(of: leaves, initial: true) { _, leaves in
            if leaves { dismiss() }
        }
        .sheet(isPresented: $isShowingTabs) {
            BrowserTabsSheet(session: session) { isShowingTabs = false }
        }
    }

    // MARK: - Top

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isEditingAddress {
            ToolbarItem(placement: .principal) {
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isAddressFocused)
                    .task {
                        isAddressFocused = true
                        // The whole address selected, as Safari's field takes a new one.
                        try? await Task.sleep(for: .milliseconds(100))
                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                    .onSubmit {
                        isEditingAddress = false
                        browser.openAddress(address)
                    }
                    .frame(minWidth: 220)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { isEditingAddress = false }
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .principal) {
                // Tapped, the address field where the Mac takes addresses (§15.30).
                if browser.controlsTabs && isEnabled {
                    Button {
                        address = tab?.url ?? ""
                        isEditingAddress = true
                    } label: {
                        titleLines
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens an address in this tab"))
                } else {
                    titleLines
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingTabs = true
                } label: {
                    Image(systemName: "square.on.square")
                }
                .accessibilityLabel("Tabs")
                .accessibilityValue(Text(browser.tabs.count, format: .number))
                .disabled(browser.tabs.isEmpty)
            }
        }
    }

    private var titleLines: some View {
        VStack(spacing: 1) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let site = tab.flatMap(Self.site) {
                Text(site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        tab.map(Self.title) ?? session.task(taskID).map { $0.title.isEmpty ? String(localized: "Browser") : $0.title }
            ?? String(localized: "Browser")
    }

    /// The page's title, else its site or address.
    static func title(_ tab: RemoteBrowserTab) -> String {
        if let title = tab.title, !title.isEmpty { return title }
        return site(tab) ?? tab.url ?? String(localized: "Untitled tab")
    }

    /// The page's host, as the Mac's bars name the site.
    static func site(_ tab: RemoteBrowserTab) -> String? {
        guard let url = tab.url else { return nil }
        return URL(string: url)?.host(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 } ?? url
    }

    // MARK: - Bars

    @ViewBuilder
    private var bars: some View {
        if let tab, tab.requestId != nil {
            handoffBar(tab)
        }
        if let permission = browser.pendingPermission {
            permissionBar(permission)
        }
        if let line = waitingLine {
            Bar {
                Label(line, systemImage: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let refusal = browser.refusal {
            Bar {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(words(for: refusal)).font(.subheadline)
                    Spacer(minLength: 0)
                    Button {
                        browser.refusal = nil
                    } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
        }
    }

    /// §15.18: the agent handed this tab to the person; its reason, Decline and I'm Done.
    private func handoffBar(_ tab: RemoteBrowserTab) -> some View {
        Bar {
            WordsAndButtons(isWide: isWide) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("The agent handed this tab to you", systemImage: "hand.point.up.left")
                        .font(.subheadline.weight(.semibold))
                    if let reason = tab.reason, !reason.isEmpty {
                        Text(reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            } buttons: {
                Button("Decline") { answerHandoff(tab, .decline) }
                    .buttonStyle(.bordered)
                Button("I'm Done") { answerHandoff(tab, .done) }
                    .prominentButton()
            }
            .controlSize(.small)
            .disabled(isAnswering || !session.isConnected)
        }
    }

    private func answerHandoff(_ tab: RemoteBrowserTab, _ answer: RemoteHandoffAnswer) {
        guard let requestID = tab.requestId else { return }
        typing.commit()
        isAnswering = true
        Task {
            await session.perform(.answerHandoff(taskID: taskID, requestID: requestID, answer: answer))
            isAnswering = false
        }
    }

    /// A site's permission prompt on the tab, as the Mac panel's bar asks it: who asks and for what, Block, Allow, Close.
    private func permissionBar(_ permission: RemoteTabPermission) -> some View {
        Bar {
            WordsAndButtons(isWide: isWide) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PermissionWords.sentence(permission, host: session.name)).font(.subheadline)
                        if let devices = PermissionWords.devices(permission.permissions) {
                            Text("Allowing it uses \(session.name)'s \(devices), not this phone's.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if !isWide { closePermission }
                }
            } buttons: {
                Button("Block") { browser.answerPermission(.block) }
                    .buttonStyle(.bordered)
                Button("Allow") { browser.answerPermission(.allow) }
                    .prominentButton()
                if isWide { closePermission }
            }
            .controlSize(.small)
            .disabled(!session.isConnected)
        }
    }

    private var closePermission: some View {
        Button {
            browser.answerPermission(.dismiss)
        } label: {
            Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Close")
    }

    /// Any other wait, and a permission prompt the phone does not answer, in a line naming the Mac (§15.19's steps that
    /// are not requests).
    private var waitingLine: String? {
        guard let tab, tab.requestId == nil, let waiting = tab.waiting, waiting != "handoff" else { return nil }
        if waiting == "permission", tab.permission != nil, browser.answersPermissions { return nil }
        let site = Self.site(tab) ?? String(localized: "This page")
        let what: String = switch waiting {
        case "passkey": String(localized: "\(site) asks for a passkey")
        case "signIn": String(localized: "\(site) asks you to sign in")
        case "permission": String(localized: "\(site) asks for a permission")
        case "externalApp": String(localized: "\(site) asks to open another app")
        case "javaScriptDialog": String(localized: "\(site) is waiting for an answer to its dialog")
        case "fileChooser": String(localized: "\(site) is waiting for you to choose a file")
        default: String(localized: "\(site) is waiting for you")
        }
        return String(localized: "\(what). Answer it on \(session.name).")
    }

    private func words(for refusal: TaskBrowser.Refusal) -> String {
        switch refusal {
        case .fileOutside: String(localized: "Files outside this task's folders open only on \(session.name).")
        case .permissionGone: String(localized: "This permission request is no longer open.")
        case let .refused(error): Self.words(for: error, host: session.name)
        }
    }

    /// The Mac panel's words for a refusal of input, by its code, and the session's for the rest (§8).
    static func words(for error: RemoteError?, host: String) -> String {
        if error?.reason != nil { return HostSession.message(for: error, host: host) }
        return switch error?.code {
        case .notAllowed?: String(localized: "A window or dialog over this page waits on \(host).")
        case .notFound?: String(localized: "This tab is closed.")
        case .rateLimited?, .busy?: HostSession.message(for: error, host: host)
        default: String(localized: "The page didn't take that.")
        }
    }

    // MARK: - Page

    private var pageArea: some View {
        ZStack {
            if browser.isUnavailable {
                ContentUnavailableView("\(session.name) can't open its browser right now.", systemImage: "globe")
            } else if browser.isListed && browser.tabs.isEmpty {
                ContentUnavailableView("No browser tabs", systemImage: "globe",
                                       description: Text("This task's browser tabs on \(session.name) show here."))
            } else if tab?.url == "file://" {
                ContentUnavailableView("This page shows only on \(session.name).", systemImage: "doc",
                                       description: Text("It is a file outside this task's folders."))
            } else {
                // Hidden from the app switcher's picture of the app.
                let picture = scenePhase == .active ? browser.picture.flatMap { $0.tabID == browser.tabID ? $0 : nil } : nil
                TabPage(tabID: browser.tabID, picture: picture, isDragging: isDragging, covered: max(0, pageBottom - barTop),
                        label: String(localized: "Browser page on \(session.name)"),
                        tap: { x, y, count in
                            // What the keyboard composed goes before the tap moves the page's focus.
                            typing.commit()
                            browser.input(.click(x: x, y: y, clickCount: count > 1 ? count : nil))
                        },
                        scroll: { x, y, deltaX, deltaY in browser.scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY) },
                        mouse: { action, x, y in browser.input(RemoteTabInput(kind: .mouse, x: x, y: y, action: action)) })
                if browser.picture == nil && scenePhase == .active {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YardletPalette.surfaceContainerLow)
        .overlay(alignment: .top) { CommandErrorBanner(session: session).padding(.top, 8) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            pageBottom = frame.maxY
            if let size = TaskBrowser.Size(width: frame.width, height: frame.height, scale: displayScale) {
                browser.setSize(size)
            }
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button {
                    browser.input(RemoteTabInput(kind: .navigate, action: "back"))
                } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Back")
                .disabled(tab?.canGoBack != true)
                Button {
                    browser.input(RemoteTabInput(kind: .navigate, action: "forward"))
                } label: {
                    Image(systemName: "chevron.right").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Forward")
                .disabled(tab?.canGoForward != true)
                Button {
                    browser.input(RemoteTabInput(kind: .navigate, action: "reload"))
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Reload")
                TabTypingField(typing: typing, isPassword: tab?.passwordField == true,
                               placeholder: tab?.passwordField == true ? String(localized: "Password (hidden)")
                                   : String(localized: "Type into the page"),
                               typed: { typed in
                                   switch typed {
                                   case let .text(text): browser.input(.text(text))
                                   case .backspace: browser.input(.key("Backspace"))
                                   }
                               },
                               key: { browser.input(.key($0)) },
                               editing: { isTyping = $0 })
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                    .padding(.horizontal, 12)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .padding(.leading, 4)
                if isTyping {
                    Button {
                        typing.endTyping()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Hide Keyboard")
                } else {
                    Toggle(isOn: $isDragging) {
                        Image(systemName: "hand.draw")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("Drag")
                    .accessibilityHint(Text("One finger drags on the page instead of scrolling it"))
                }
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .disabled(!isEnabled)
        }
        .background(YardletPalette.surface)
    }
}

/// A bar above the page, as the Mac's panel draws them: full width, a line under it.
private struct Bar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YardletPalette.surfaceContainerLow)
            .overlay(alignment: .bottom) { Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5) }
    }
}

/// A bar's words and its buttons: under the words on a phone held upright, beside them on its side.
private struct WordsAndButtons<Words: View, Buttons: View>: View {
    let isWide: Bool
    @ViewBuilder let words: Words
    @ViewBuilder let buttons: Buttons

    var body: some View {
        if isWide {
            HStack(spacing: 12) {
                words.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) { buttons }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                words
                HStack(spacing: 8) { buttons }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// The task's tabs in its panel's order: the one watched marked, a dot for one that waits, Close where the Mac allows it.
private struct BrowserTabsSheet: View {
    let session: HostSession
    let done: () -> Void

    private var browser: TaskBrowser { session.browser }

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.tabs, id: \.tabId) { tab in
                    Button {
                        browser.select(tab.tabId)
                        done()
                    } label: {
                        row(tab)
                    }
                    .swipeActions(edge: .trailing) {
                        if browser.controlsTabs {
                            Button("Close Tab", role: .destructive) { browser.closeTab(tab.tabId) }
                        }
                    }
                    .contextMenu {
                        if browser.controlsTabs {
                            Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.closeTab(tab.tabId) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ tab: RemoteBrowserTab) -> some View {
        let current = tab.tabId == browser.tabID
        return HStack(spacing: 12) {
            Circle()
                .fill(tab.requestId != nil || tab.waiting == "handoff" ? Color.orange
                      : tab.waiting != nil ? Color.green : Color.clear)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(BrowserView.title(tab))
                    .font(.body.weight(current ? .semibold : .regular))
                    .lineLimit(1)
                if let site = BrowserView.site(tab) {
                    Text(site).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}

/// A site's permission prompt in the Mac panel's words: Chromium's names for what it asks, and the Mac's devices it
/// would use.
enum PermissionWords {
    /// "On Mac Studio, meet.google.com wants to: Use your camera, Use your microphone".
    static func sentence(_ permission: RemoteTabPermission, host: String) -> String {
        var seen = Set<String>()
        let wants = permission.permissions.map(name).filter { seen.insert($0).inserted }.joined(separator: ", ")
        return String(localized: "On \(host), \(site(permission.origin)) wants to: \(wants)")
    }

    /// The site as the Mac's bar names it: its host and port, without the scheme.
    static func site(_ origin: String) -> String {
        guard let url = URL(string: origin), let host = url.host(percentEncoded: false), !host.isEmpty else { return origin }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The Mac's words for one of Chromium's names; one it does not know shows as it is.
    static func name(_ permission: String) -> String {
        switch permission {
        case "notifications": String(localized: "Show notifications")
        case "geolocation": String(localized: "Know your location")
        case "clipboard": String(localized: "See text and images copied to the clipboard")
        case "multipleDownloads": String(localized: "Download multiple files")
        case "storageAccess", "topLevelStorageAccess": String(localized: "Use cookies and site data from another site")
        case "localFonts": String(localized: "Use its fonts")
        case "windowManagement": String(localized: "Manage windows on all your displays")
        case "localNetworkAccess", "localNetwork": String(localized: "Connect to devices on your local network")
        case "loopbackNetwork": String(localized: "Connect to apps running on it")
        case "fileSystemAccess": String(localized: "Edit its files")
        case "camera", "videoCapture", "cameraPanTiltZoom": String(localized: "Use your camera")
        case "microphone", "audioCapture": String(localized: "Use your microphone")
        case "midiSysex": String(localized: "Control and reprogram your MIDI devices")
        case "idleDetection": String(localized: "Know when it is in use")
        default: permission
        }
    }

    /// The Mac's devices a prompt asks for (its camera, microphone, location) in one phrase; nil for none.
    static func devices(_ permissions: [String]) -> String? {
        var devices: [String] = []
        if permissions.contains(where: ["camera", "videoCapture", "cameraPanTiltZoom"].contains) {
            devices.append(String(localized: "camera"))
        }
        if permissions.contains(where: ["microphone", "audioCapture"].contains) {
            devices.append(String(localized: "microphone"))
        }
        if permissions.contains("geolocation") { devices.append(String(localized: "location")) }
        return devices.isEmpty ? nil : devices.formatted(.list(type: .and))
    }
}
