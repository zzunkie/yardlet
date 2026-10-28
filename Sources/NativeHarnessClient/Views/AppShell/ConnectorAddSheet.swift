import AppKit
import SwiftUI

/// What setting up a directory service asks of the person, beyond pressing Connect: the steps on
/// the service's side and where to take them (docs/CONNECTORS.md, "UI").
struct ConnectorSetupGuide: Equatable {
    struct Link: Equatable {
        let title: String
        let url: URL
    }

    let steps: [String]
    let links: [Link]

    /// The steps and links for a service, as the setup assistants (`GoogleSetupPage`,
    /// `SlackSetupPage`) or a key's field show them.
    static func guide(for preset: ConnectorPreset) -> ConnectorSetupGuide? {
        switch preset.id {
        case "slack":
            return ConnectorSetupGuide(steps: ConnectorSetupAssistant.slack(opened: [], clientEntered: false, connected: false)
                .steps.map(\.title), links: [
                    Link(title: L10n.string("Create in Slack"), url: SlackAppManifest.createURL),
                    Link(title: L10n.string("Slack's MCP guide"), url: URL(string: "https://docs.slack.dev/ai/mcp-server")!)
                ])
        case "gmail", "google-calendar", "google-drive", "google-analytics", "google-ads":
            return ConnectorSetupGuide(steps: ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 0)
                .steps.map(\.title), links: [
                    Link(title: L10n.string("Enable APIs"), url: ConnectorSetupAssistant.googleAPIs),
                    Link(title: L10n.string("Create client"), url: ConnectorSetupAssistant.googleClients)
                ])
        case "outlook-mail", "outlook-calendar", "onedrive", "microsoft-teams":
            return ConnectorSetupGuide(steps: ConnectorSetupAssistant.microsoft(opened: [], appSaved: false, connectedAccounts: 0)
                .steps.map(\.title), links: [
                    Link(title: L10n.string("App registrations"), url: ConnectorSetupAssistant.microsoftRegistrations)
                ])
        case let id where id.hasPrefix("zoom-"):
            return ConnectorSetupGuide(steps: ConnectorSetupAssistant.zoom(opened: [], products: [preset], clientEntered: false, connected: false)
                .steps.map(\.title), links: [
                    Link(title: L10n.string("Build an app on Zoom"), url: ConnectorSetupAssistant.zoomCreate)
                ])
        case "github":
            return ConnectorSetupGuide(steps: [], links: [
                Link(title: L10n.string("Create a token on GitHub"), url: preset.setupURL!)
            ])
        case "browserbase":
            return ConnectorSetupGuide(steps: [], links: [
                Link(title: L10n.string("Find your API key"), url: preset.setupURL!)
            ])
        case "app-store-connect":
            return ConnectorSetupGuide(steps: ConnectorSetupAssistant.appStoreConnect(opened: [], keyChosen: false)
                .steps.map(\.title), links: [
                    Link(title: L10n.string("Open App Store Connect"), url: ConnectorSetupAssistant.appStoreConnectKeys),
                    Link(title: L10n.string("Apple's guide to API keys"), url: ConnectorSetupAssistant.appStoreConnectKeyGuide)
                ])
        default:
            return nil
        }
    }

    /// The directory, grouped by what connecting asks: nothing beyond the browser sign-in, a key
    /// or token to paste, or an OAuth app the person registers with the service first.
    enum Kind: CaseIterable {
        case oneClick
        case key
        case ownApp

        /// - Parameter gitHubSignIn: the build carries Yardlet's GitHub app, so GitHub signs in
        ///   instead of taking a token.
        static func of(_ preset: ConnectorPreset, gitHubSignIn: Bool = false) -> Kind {
            if gitHubSignIn, preset.id == "github" { return .oneClick }
            return switch preset.signIn {
            case .oauth, .none, .macPermission, .localApp: .oneClick
            case .token, .appStoreConnectKey: .key
            case .registeredClient, .googleAccount, .microsoftAccount: .ownApp
            }
        }

        var presets: [ConnectorPreset] { presets(gitHubSignIn: false) }

        func presets(gitHubSignIn: Bool) -> [ConnectorPreset] {
            ConnectorPreset.all.filter { Kind.of($0, gitHubSignIn: gitHubSignIn) == self }
        }
    }

    /// Whether a directory search names the service: an empty search names all; otherwise its
    /// name or ID holds the text, in any case.
    static func matches(_ preset: ConnectorPreset, query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return preset.name.localizedCaseInsensitiveContains(wanted) || preset.id.localizedCaseInsensitiveContains(wanted)
    }

    /// Google's one row stands for Gmail, Calendar, Drive, Analytics, and Ads, so a search for any of them names it.
    static func matchesGoogle(query: String) -> Bool {
        matches(["Google", "Gmail", "Google Calendar", "Google Drive", "Google Analytics", "Google Ads"], query: query)
    }

    /// Microsoft 365's one row stands for Outlook, OneDrive, and Teams.
    static func matchesMicrosoft(query: String) -> Bool {
        matches(["Microsoft 365", "Outlook", "Outlook Calendar", "OneDrive", "Microsoft Teams", "Office"], query: query)
    }

    /// Zoom's one row stands for Meetings, Team Chat, and Docs.
    static func matchesZoom(query: String) -> Bool {
        matches(["Zoom", "Zoom Meetings", "Zoom Team Chat", "Zoom Docs"], query: query)
    }

    private static func matches(_ names: [String], query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return names.contains { $0.localizedCaseInsensitiveContains(wanted) }
    }

    /// A row's second line in the directory, where it says more than its section does: one-click
    /// services sign in in the browser unless the line says otherwise.
    static func summary(_ preset: ConnectorPreset, gitHubSignIn: Bool = false) -> String? {
        if gitHubSignIn, preset.id == "github" { return L10n.string("Sign in with GitHub") }
        switch preset.id {
        case "figma-desktop": return L10n.string("Needs the Figma desktop app")
        case "xcode": return L10n.string("Needs Xcode open with a project")
        case "apple-calendar", "apple-reminders", "apple-contacts": return L10n.string("On this Mac · macOS asks once")
        case "app-store-connect": return L10n.string("API key (.p8 file)")
        case "github": return L10n.string("Personal access token")
        case "browserbase": return L10n.string("API key")
        case "slack": return L10n.string("A Slack app made from Yardlet's manifest")
        case "mercury", "ramp", "brex", "apollo-io": return L10n.string("Read-only")
        case "twilio-docs": return L10n.string("Public API docs · no account data")
        case "gmail", "google-calendar", "google-drive", "google-analytics", "google-ads":
            return L10n.string("Your own Google OAuth app · personal and Workspace accounts")
        case "outlook-mail", "outlook-calendar", "onedrive", "microsoft-teams":
            return L10n.string("Your own Microsoft app · personal and work accounts")
        case let id where id.hasPrefix("zoom-"):
            return L10n.string("A Zoom app of your own · reads only")
        default: break
        }
        return preset.signIn == ConnectorPreset.SignIn.none ? L10n.string("No sign-in") : nil
    }
}

/// Where a service's key or OAuth app is made, as links that open in the browser.
struct ConnectorGuideLinks: View {
    let preset: ConnectorPreset

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ConnectorSetupGuide.guide(for: preset)?.links ?? [], id: \.url) { link in
                Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    Label(link.title, systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

/// "Add connector": Yardlet's directory, grouped by what connecting asks of the person, and a
/// custom server by its address. Services that sign in in the browser connect with one click;
/// those that need a key open a field with a link to where to get it; those that need an OAuth app
/// of the person's own (Slack, Google) sit under a heading folded by default, and each opens its
/// own page with the steps, as the Claude app's "Connect {server}" dialog asks for an app's
/// credentials (2.42304.0 `AVwmlMn2LM`). It says plainly that Gmail, Calendar, and Drive do not
/// connect with a plain Google sign-in, and offers claude.ai's account connectors for Claude tasks
/// instead.
///
/// The same calls as before the redesign: `ConnectorCenter.add` with the preset (and a token or
/// client when one is entered), then `connect`.
struct ConnectorAddSheet: View {
    enum Start: Identifiable, Equatable {
        case directory
        case preset(ConnectorPreset)
        /// A program found in another app's settings, at its own page.
        case program(ConnectorProgramDraft)

        var id: String {
            switch self {
            case .directory: "directory"
            case .preset(let preset): preset.id
            case .program(let draft): draft.id
            }
        }
    }

    let center: ConnectorCenter
    let start: Start
    let onClose: () -> Void

    /// The service whose own page is open: one that needs a key or an OAuth app.
    @State private var focused: ConnectorPreset?
    /// The program whose page is open, before the person runs it.
    @State private var program: ConnectorProgramDraft?
    /// The directory row whose field is open: a preset ID, or `custom`.
    @State private var expanded: String?
    @State private var showsOwnApps = false
    @State private var busy: String?
    @State private var error: (row: String, message: String)?
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var customName = ""
    @State private var customAddress = ""
    @State private var showsCustomAuth = false
    /// Narrows the directory to services whose name holds it.
    @State private var query = ""
    /// The Google OAuth app's steps start open on the Gmail page even with an app saved.
    private let showsGoogleSteps: Bool
    @AppStorage(ClaudeAIConnectorPreference.key) private var claudeAIConnectors = false

    static let customID = "custom"
    private static let ownAppsID = "own-apps"

    /// - Parameters:
    ///   - showsOwnApps: the "Needs an OAuth app of your own" heading starts open (review renders).
    ///   - expandedRow: a directory row whose field starts open, a preset ID or `customID`.
    ///   - query: the directory search starts with this (review renders).
    init(center: ConnectorCenter, start: Start, showsOwnApps: Bool = false, expandedRow: String? = nil,
         showsGoogleSteps: Bool = false, query: String = "", onClose: @escaping () -> Void) {
        self.center = center
        self.start = start
        self.onClose = onClose
        self.showsGoogleSteps = showsGoogleSteps
        _query = State(initialValue: query)
        _showsOwnApps = State(initialValue: showsOwnApps)
        _expanded = State(initialValue: expandedRow)
        // Opened for one service (from "You use these elsewhere" or a setup tile): its own page at once.
        if case .preset(let preset) = start,
           ConnectorSetupGuide.Kind.of(preset, gitHubSignIn: center.canSignInToGitHub) != .oneClick {
            _focused = State(initialValue: preset)
        }
        if case .program(let draft) = start { _program = State(initialValue: draft) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Add connector"))
                    .font(.title3.weight(.semibold))
                Text(L10n.string("Pick a service. Sign-ins and keys stay in your keychain."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if let program {
                            ConnectorProgramPage(center: center, draft: program, onBack: {
                                if case .program = start { onClose() } else { self.program = nil }
                            }, onAdded: onClose)
                            .id(program.id)
                        } else if let focused {
                            servicePage(focused)
                        } else {
                            directory
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Opening the OAuth-app heading brings what it holds into view.
                .task(id: showsOwnApps && focused == nil) {
                    guard showsOwnApps, focused == nil else { return }
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.ownAppsID, anchor: .top) }
                }
                // So does opening a row's field.
                .task(id: expanded) {
                    guard let expanded, focused == nil else { return }
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(expanded) }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("Done"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 660)
        .background(ParityTheme.canvas)
    }

    private var directory: some View {
        let gitHubSignIn = center.canSignInToGitHub
        let oneClick = ConnectorSetupGuide.Kind.oneClick.presets(gitHubSignIn: gitHubSignIn)
            .filter { ConnectorSetupGuide.matches($0, query: query) && center.isAvailable($0) }
        let keys = ConnectorSetupGuide.Kind.key.presets(gitHubSignIn: gitHubSignIn)
            .filter { ConnectorSetupGuide.matches($0, query: query) }
        let googleSignsIn = googleBuiltIn && ConnectorSetupGuide.matchesGoogle(query: query)
        let microsoftSignsIn = microsoftBuiltIn && ConnectorSetupGuide.matchesMicrosoft(query: query)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("Search services"), text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.string("Search services"))
                if searching {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .parityCard(cornerRadius: 8)
            if !oneClick.isEmpty || googleSignsIn || microsoftSignsIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("Connect in one click")).font(.headline)
                    Text(L10n.string("Yardlet adds the service at once. For one with a sign-in, your browser opens: sign in and allow, and that is all."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A build with Yardlet's own Google app signs in to Google without a setup.
                    if googleSignsIn {
                        googleRow
                            .padding(.horizontal, 12)
                            .parityCard()
                            .padding(.top, 2)
                    }
                    if microsoftSignsIn {
                        microsoftRow
                            .padding(.horizontal, 12)
                            .parityCard()
                            .padding(.top, 2)
                    }
                    // Two to a row, as a directory of cards: one press each, nothing to fill in.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(oneClick) { preset in
                            oneClickTile(preset)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            if !keys.isEmpty {
                section(L10n.string("Paste a key or token"),
                        caption: L10n.string("Create one with the service, paste it, and Yardlet connects.")) {
                    rows(keys)
                }
            }
            if !searching || ownAppMatches {
                ownAppSection
            }
            if searching, oneClick.isEmpty, keys.isEmpty, !googleSignsIn, !microsoftSignsIn, !ownAppMatches {
                Text(L10n.string("No service in the directory has that name. Add it by its address below."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ConnectorRegistrySection(center: center, query: query, onProgram: { program = $0 }, onAdded: onClose)
            section(L10n.string("Another MCP server"), caption: nil) {
                customRow
            }
        }
        .task { await center.registry.loadIfNeeded() }
        // A search asks the registries once typing pauses.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await center.registry.search(query)
        }
    }

    /// The build carries Yardlet's own Google app, so Google signs in without an app of the person's own.
    private var googleBuiltIn: Bool { center.googleBuiltInApp != nil }
    /// The same for Yardlet's own Microsoft app.
    private var microsoftBuiltIn: Bool { center.microsoftBuiltInApp != nil }

    /// The services under "Needs an OAuth app of your own" that the search names.
    private var ownAppMatches: Bool {
        (!googleBuiltIn && ConnectorSetupGuide.matchesGoogle(query: query))
            || (!microsoftBuiltIn && ConnectorSetupGuide.matchesMicrosoft(query: query))
            || ConnectorPreset.preset(id: "slack").map { ConnectorSetupGuide.matches($0, query: query) } == true
            || ConnectorSetupGuide.matchesZoom(query: query)
    }

    /// The names under "Needs an OAuth app of your own", for its folded heading.
    private var ownAppNames: String {
        var names: [String] = []
        if !googleBuiltIn { names.append(L10n.string("Google (Gmail, Calendar, Drive)")) }
        if !microsoftBuiltIn { names.append("Microsoft 365") }
        names += ["Slack", "Zoom"]
        return names.joined(separator: ", ")
    }

    // MARK: Sections

    private func section<Rows: View>(_ title: String, caption: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) { rows() }
                .padding(.horizontal, 12)
                .parityCard()
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func rows(_ presets: [ConnectorPreset]) -> some View {
        ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
            if index > 0 { Divider().padding(.leading, 34) }
            presetRow(preset)
        }
    }

    /// Slack and Google: folded by default, marked as needing an OAuth app of the person's own.
    private var ownAppSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showsOwnApps.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsOwnApps ? 90 : 0))
                        .frame(width: 12)
                    Text(L10n.string("Needs an OAuth app of your own")).font(.headline)
                    Text(ownAppNames)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(L10n.string("Needs an OAuth app of your own"))
            .accessibilityValue(showsOwnApps ? L10n.string("Expanded") : L10n.string("Collapsed"))
            Text(L10n.string("These don't connect with a plain sign-in. A setup assistant takes you through registering the app with the service, then you paste its client ID here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A search that names one of these opens the heading.
            if showsOwnApps || !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !googleBuiltIn {
                    googleNote
                        .padding(.top, 2)
                }
                VStack(spacing: 0) {
                    if !googleBuiltIn {
                        googleRow
                        Divider().padding(.leading, 34)
                    }
                    if !microsoftBuiltIn {
                        microsoftRow
                        Divider().padding(.leading, 34)
                    }
                    if let slack = ConnectorPreset.preset(id: "slack") { presetRow(slack) }
                    Divider().padding(.leading, 34)
                    zoomRow
                }
                .padding(.horizontal, 12)
                .parityCard()
                .padding(.top, 2)
            }
        }
        .id(Self.ownAppsID)
    }

    /// Said where the person meets Google: no plain Google sign-in, and what to use instead.
    private var googleNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(L10n.string("Gmail, Google Calendar, and Google Drive can't be connected with a plain Google sign-in."))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.orange)
            }
            Text(L10n.string("Register one Google OAuth app in your own Google Cloud project, then sign in once with each account; Yardlet runs its own Gmail, Calendar, and Drive servers with it. For Claude tasks you can instead turn on “Use claude.ai account connectors”, and each Claude account's tasks use what it connected on claude.ai."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.string("Use claude.ai account connectors"), isOn: $claudeAIConnectors)
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
                .font(.caption.weight(.medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25)) }
    }

    // MARK: Rows

    /// A service added already; Gmail takes any number of accounts and App Store Connect any
    /// number of keys, so neither is ever "added". Xcode and the Mac's data are once per Mac.
    private func isAdded(_ preset: ConnectorPreset) -> Bool {
        guard preset.signIn != .googleAccount, preset.signIn != .microsoftAccount, preset.signIn != .appStoreConnectKey else { return false }
        if let service = preset.localService { return center.connectors.contains { $0.localService == service } }
        let address = MCPServerAddress.canonical(preset.serverURL)
        return center.connectors.contains { MCPServerAddress.canonical($0.serverURL) == address }
    }

    private func presetRow(_ preset: ConnectorPreset) -> some View {
        let kind = ConnectorSetupGuide.Kind.of(preset, gitHubSignIn: center.canSignInToGitHub)
        let isOpen = expanded == preset.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ConnectorIcon(name: preset.name, presetID: preset.id, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.callout.weight(.medium))
                    if let summary = rowSummary(preset) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // A service with a setup assistant opens it even once added: it shows how far along it is.
                if isAdded(preset), kind != .ownApp {
                    Text(L10n.string("Added"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if busy == preset.id {
                    ProgressView().controlSize(.small)
                } else {
                    switch kind {
                    case .oneClick:
                        Button(L10n.string("Connect")) { addOneClick(preset) }
                            .controlSize(.small)
                    case .key where preset.signIn == .appStoreConnectKey:
                        Button(L10n.string("Set up…")) { open(preset) }
                            .controlSize(.small)
                    case .key:
                        Button(isOpen ? L10n.string("Cancel") : L10n.string("Connect")) { toggle(preset.id) }
                            .controlSize(.small)
                    case .ownApp:
                        Button(L10n.string("Set up…")) { open(preset) }
                            .controlSize(.small)
                    }
                }
            }
            if let error, error.row == preset.id, !isOpen {
                Text(error.message).font(.caption).foregroundStyle(.red)
            }
            if isOpen, kind == .key, !isAdded(preset) {
                keyEntry(preset)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 8)
        .id(preset.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preset.name)
    }

    /// A Google service says how many accounts there are once there are some.
    private func rowSummary(_ preset: ConnectorPreset) -> String? {
        if preset.signIn == .googleAccount, !center.googleAccounts.isEmpty {
            return L10n.format("%lld Google accounts", Int64(center.googleAccounts.count))
        }
        if preset.signIn == .microsoftAccount, !center.microsoftAccounts.isEmpty {
            return L10n.format("%lld Microsoft accounts", Int64(center.microsoftAccounts.count))
        }
        let keys = center.connectors.filter { $0.localService == .appStoreConnect }.count
        if preset.signIn == .appStoreConnectKey, keys > 0 { return L10n.format("%lld keys", Int64(keys)) }
        return ConnectorSetupGuide.summary(preset, gitHubSignIn: center.canSignInToGitHub)
    }

    /// Gmail, Calendar, and Drive in one row: one Google OAuth app and one page sets up all three.
    private var googleRow: some View {
        HStack(spacing: 10) {
            ConnectorIcon(name: "Google", sources: .google, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Google · Gmail, Calendar, Drive")).font(.callout.weight(.medium))
                Text(googleBuiltIn && center.googleAccounts.isEmpty
                     ? L10n.string("Sign in with Google · personal and Workspace accounts")
                     : ConnectorPreset.preset(id: "gmail").flatMap(rowSummary) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(googleBuiltIn ? L10n.string("Connect") : L10n.string("Set up…")) { open(ConnectorPreset.preset(id: "gmail")) }
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .id("google")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Google · Gmail, Calendar, Drive"))
    }

    /// Outlook, OneDrive, and Teams in one row: one Microsoft app and one page sets up all four.
    private var microsoftRow: some View {
        HStack(spacing: 10) {
            ConnectorIcon(name: "Microsoft 365", presetID: "outlook-mail", size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Microsoft 365 · Outlook, OneDrive, Teams")).font(.callout.weight(.medium))
                Text(microsoftBuiltIn && center.microsoftAccounts.isEmpty
                     ? L10n.string("Sign in with Microsoft · personal and work accounts")
                     : ConnectorPreset.preset(id: "outlook-mail").flatMap(rowSummary) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(microsoftBuiltIn ? L10n.string("Connect") : L10n.string("Set up…")) { open(ConnectorPreset.preset(id: "outlook-mail")) }
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .id("microsoft")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Microsoft 365 · Outlook, OneDrive, Teams"))
    }

    /// Zoom's products in one row: one Zoom app serves them all.
    private var zoomRow: some View {
        let added = center.connectors.filter { $0.preset?.isZoom == true }.count
        return HStack(spacing: 10) {
            ConnectorIcon(name: "Zoom", presetID: "zoom-meetings", size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Zoom · Meetings, Team Chat, Docs")).font(.callout.weight(.medium))
                Text(added > 0 ? L10n.format("%lld products added", Int64(added)) : L10n.string("A Zoom app of your own · reads only"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(L10n.string("Set up…")) { open(ConnectorPreset.preset(id: "zoom-meetings")) }
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .id("zoom")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Zoom · Meetings, Team Chat, Docs"))
    }

    private func oneClickTile(_ preset: ConnectorPreset) -> some View {
        HStack(spacing: 8) {
            ConnectorIcon(name: preset.name, presetID: preset.id, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let summary = ConnectorSetupGuide.summary(preset, gitHubSignIn: center.canSignInToGitHub) {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isAdded(preset) {
                Text(L10n.string("Added"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if busy == preset.id {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.string("Connect")) { addOneClick(preset) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .parityCard(cornerRadius: 10)
        .overlay(alignment: .bottomLeading) {
            if let error, error.row == preset.id {
                Text(error.message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .offset(y: 14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preset.name)
    }

    /// One service's own page: what it needs, its steps and links, and its fields.
    private func servicePage(_ preset: ConnectorPreset) -> some View {
        let kind = ConnectorSetupGuide.Kind.of(preset, gitHubSignIn: center.canSignInToGitHub)
        return VStack(alignment: .leading, spacing: 16) {
            Button {
                open(nil)
            } label: {
                Label(L10n.string("All services"), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .parityPointer()
            let google = preset.signIn == .googleAccount
            let microsoft = preset.signIn == .microsoftAccount
            HStack(spacing: 12) {
                ConnectorIcon(name: google ? "Google" : preset.name, presetID: google ? nil : preset.id, sources: google ? .google : nil, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(google ? L10n.string("Connect Google") : microsoft ? L10n.string("Connect Microsoft 365")
                         : preset.isZoom ? L10n.string("Connect Zoom") : L10n.format("Connect %@", preset.name))
                        .font(.title3.weight(.semibold))
                    if google {
                        Text(googleBuiltIn ? L10n.string("Gmail, Google Calendar, and Google Drive with one sign-in per account")
                             : L10n.string("Gmail, Google Calendar, and Google Drive with one Google OAuth app"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if microsoft {
                        Text(microsoftBuiltIn ? L10n.string("Outlook, OneDrive, and Teams with one sign-in per account")
                             : L10n.string("Outlook, OneDrive, and Teams with one Microsoft app"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if kind == .ownApp {
                        Text(L10n.string("Needs an OAuth app of your own"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if let summary = ConnectorSetupGuide.summary(preset, gitHubSignIn: center.canSignInToGitHub) {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if google {
                GoogleSetupPage(center: center, showsSteps: showsGoogleSteps, service: preset.localService)
            } else if microsoft {
                MicrosoftSetupPage(center: center, service: preset.localService)
            } else if preset.isZoom {
                ZoomSetupPage(center: center, product: preset)
            } else if preset.signIn == .appStoreConnectKey {
                AppStoreConnectSetupPage(center: center)
            } else if preset.id == "slack" {
                SlackSetupPage(center: center)
            } else if isAdded(preset) {
                Text(L10n.string("This service is added already."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if kind == .key {
                keyEntry(preset)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func keyEntry(_ preset: ConnectorPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                let prompt = preset.tokenQueryParameter == nil ? L10n.string("Paste a personal access token")
                    : L10n.string("Paste your API key")
                SecureField(prompt, text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(prompt)
                    .onSubmit { addWithToken(preset) }
                if busy == preset.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.string("Connect")) { addWithToken(preset) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .controlSize(.small)
            guideLinks(preset)
            if preset.acceptsRegisteredClient {
                Text(L10n.string("You can also use an OAuth app of your own from the connector's menu after adding it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            entryError(preset.id)
        }
    }

    private func guideLinks(_ preset: ConnectorPreset) -> some View {
        ConnectorGuideLinks(preset: preset)
    }

    @ViewBuilder
    private func entryError(_ row: String) -> some View {
        if let error, error.row == row {
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Any other server, by its address; a token or an OAuth client only when the server has no
    /// sign-in Yardlet can use.
    private var customRow: some View {
        let isOpen = expanded == Self.customID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string("Add by URL")).font(.callout.weight(.medium))
                    Text(L10n.string("A remote MCP server (Streamable HTTP)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(isOpen ? L10n.string("Cancel") : L10n.string("Add…")) { toggle(Self.customID) }
                    .controlSize(.small)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text(L10n.string("Name")).font(.caption)
                            TextField(L10n.string("Name"), text: $customName)
                        }
                        GridRow {
                            Text(L10n.string("MCP server URL")).font(.caption)
                            TextField("https://", text: $customAddress)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .controlSize(.small)
                    DisclosureGroup(isExpanded: $showsCustomAuth) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("Only for a server without a sign-in Yardlet can use: an access token, or an OAuth client you registered with it."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            SecureField(L10n.string("Access token"), text: $token)
                            HStack(spacing: 6) {
                                TextField(L10n.string("OAuth client ID"), text: $clientID)
                                SecureField(L10n.string("Client secret (optional)"), text: $clientSecret)
                            }
                            RedirectURIField()
                        }
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .padding(.top, 6)
                    } label: {
                        Text(L10n.string("Sign-in details (optional)")).font(.caption)
                    }
                    HStack {
                        entryError(Self.customID)
                        Spacer()
                        Button(L10n.string("Add and connect"), action: addCustom)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.small)
                            .disabled(customURL == nil)
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 8)
        .id(Self.customID)
    }

    // MARK: Adding

    private func open(_ preset: ConnectorPreset?) {
        resetEntry()
        expanded = nil
        focused = preset
    }

    private func toggle(_ row: String) {
        expanded = expanded == row ? nil : row
        resetEntry()
        if error?.row != row { error = nil }
    }

    private func resetEntry() {
        token = ""
        clientID = ""
        clientSecret = ""
    }

    private var customURL: URL? {
        let text = customAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isLoopback(url.host())),
              url.host() != nil
        else { return nil }
        return url
    }

    /// Plain http only for a server on this Mac.
    private static func isLoopback(_ host: String?) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "")
    }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func addOneClick(_ preset: ConnectorPreset) {
        add(row: preset.id, name: preset.name, serverURL: preset.serverURL, preset: preset)
    }

    private func addWithToken(_ preset: ConnectorPreset) {
        guard let token = Self.trimmed(token) else { return }
        add(row: preset.id, name: preset.name, serverURL: preset.serverURL, token: token, preset: preset)
    }

    private func addCustom() {
        guard let url = customURL else { return }
        let client = Self.trimmed(clientID).map { (id: $0, secret: Optional(clientSecret)) }
        add(row: Self.customID, name: customName, serverURL: url, token: Self.trimmed(token), client: client, preset: nil)
    }

    private func add(row: String, name: String, serverURL: URL, token: String? = nil,
                     client: (id: String, secret: String?)? = nil, preset: ConnectorPreset?) {
        busy = row
        error = nil
        Task {
            do {
                let record = try await center.add(name: name, serverURL: serverURL, token: token, client: client,
                                                  preset: preset)
                center.connect(record.id)
                busy = nil
                onClose()
            } catch {
                busy = nil
                self.error = (row, error.localizedDescription)
            }
        }
    }
}
