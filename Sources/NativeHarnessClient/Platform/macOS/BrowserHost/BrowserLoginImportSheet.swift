import AppKit
import SwiftUI

/// The sheet of "Import from Another Browser…" (docs/BROWSER_SESSION_ISOLATION.md 10): a browser's profile with the
/// browser app's icon, the sites it has cookies for to choose from (the page's own chosen first) with a search, the
/// profile's visit history, and Import. Only the sites the person ticks bring their sign-ins; for a Chromium browser
/// Import then reads its keychain item, which macOS asks about. The history is the whole profile's, checked at first as
/// in Chrome's import dialog. A browser whose folder macOS keeps from Yardlet is named, not listed.
struct BrowserLoginImportSheet: View {
    let request: BrowserLoginImportRequest
    /// Where the browsers' folders are; a made-up one in tests.
    var applicationSupport = BrowserLoginImport.applicationSupport
    /// Imports the chosen sites from a profile, and its visit history when asked; the sheet shows what it throws.
    let onImport: (BrowserLoginImport.Profile, [String], Bool) async throws -> Void
    let onDone: () -> Void
    @State private var profiles: [BrowserLoginImport.Profile]?
    @State private var unreadable: [BrowserLoginImport.Browser] = []
    @State private var icons: [String: NSImage] = [:]
    @State private var profileID: String?
    @State private var sites: [BrowserLoginImport.Site]?
    @State private var chosen: Set<String> = []
    @State private var search = ""
    @State private var failure: String?
    @State private var isImporting = false
    @State private var importsHistory = true

    private var profile: BrowserLoginImport.Profile? { profiles?.first { $0.id == profileID } }
    private var withHistory: Bool { importsHistory && profile?.history != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("Import from Another Browser"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let profiles, profiles.isEmpty {
                    Text(L10n.string("No browser to import from was found on this Mac. Sign-ins import from Chromium and Firefox browsers such as Whale, Chrome, Arc, Comet and Zen."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker(L10n.string("Browser"), selection: $profileID) {
                        ForEach(profiles ?? []) { profile in
                            Label { Text(profile.title) } icon: { icon(for: profile.browser) }
                                .tag(Optional(profile.id))
                        }
                    }
                    .fixedSize()
                    Text(request.forTask
                         ? L10n.string("The sites you choose open signed in, in this task and in new tasks. Their cookies already in Yardlet are replaced.")
                         : L10n.string("The sites you choose open signed in, in new tasks. Their cookies already in Yardlet are replaced."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(L10n.string("Search sites"), text: $search)
                        .textFieldStyle(.roundedBorder)
                    siteList
                    if !chosen.isEmpty, let service = profile?.browser.keychainService {
                        Text(L10n.format("When you import, macOS asks whether Yardlet may use “%@” in your keychain. Allow it to import.", service))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if profile?.history != nil { historyChoice }
                }
                if !unreadable.isEmpty {
                    Text(L10n.format("macOS lets only apps with Full Disk Access read %@'s data, so it is not listed.",
                                     unreadable.map(\.name).joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 520)
        .background(ParityTheme.canvas)
        .task {
            let support = applicationSupport
            let found = await Task.detached { BrowserLoginImport.find(in: support) }.value
            for browser in Set(found.profiles.map(\.browser)) {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { continue }
                let image = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
                image.size = NSSize(width: 16, height: 16)
                icons[browser.name] = image
            }
            unreadable = found.unreadable
            profiles = found.profiles
            profileID = found.profiles.first?.id
        }
        .task(id: profileID) { await loadSites() }
    }

    /// The whole profile's visit history, apart from the sites chosen above.
    private var historyChoice: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L10n.string("Import visit history"), isOn: $importsHistory)
                .toggleStyle(.checkbox)
            Text(L10n.format("The profile's whole history from the last %lld days, up to %lld pages, not only the sites above. The address field suggests pages from it.",
                             Int64(BrowserAddressHistory.keptDays), Int64(BrowserAddressHistory.maxPages)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .padding(.top, 4)
    }

    /// The browser app's icon, or a globe when its app is not on this Mac.
    private func icon(for browser: BrowserLoginImport.Browser) -> Image {
        icons[browser.name].map { Image(nsImage: $0) } ?? Image(systemName: "globe")
    }

    private var shownSites: [BrowserLoginImport.Site] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (sites ?? []).filter { text.isEmpty || $0.domain.contains(text) }
    }

    @ViewBuilder
    private var siteList: some View {
        let shown = shownSites
        if sites == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if shown.isEmpty {
            Text(search.isEmpty ? L10n.string("This profile has no sites with cookies.") : L10n.string("No sites match."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            List(shown) { site in
                Toggle(site.domain, isOn: Binding(
                    get: { chosen.contains(site.domain) },
                    set: { if $0 { chosen.insert(site.domain) } else { chosen.remove(site.domain) } }))
                    .toggleStyle(.checkbox)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 240)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isImporting {
                ProgressView().controlSize(.small)
            } else if !chosen.isEmpty {
                Text(chosen.count == 1 ? L10n.string("1 site chosen") : L10n.format("%lld sites chosen", Int64(chosen.count)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.string("Cancel"), role: .cancel, action: onDone)
                .keyboardShortcut(.cancelAction)
            Button(L10n.string("Import"), action: start)
                .keyboardShortcut(.defaultAction)
                .disabled((chosen.isEmpty && !withHistory) || profile == nil || isImporting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The profile's sites, the page's own first and chosen.
    private func loadSites() async {
        sites = nil
        chosen = []
        failure = nil
        guard let profile else { return }
        do {
            var found = try await Task.detached { try BrowserLoginImport.sites(in: profile) }.value
            if let site = request.site, let index = found.firstIndex(where: { $0.domain == site }) {
                found.insert(found.remove(at: index), at: 0)
                chosen = [site]
            }
            sites = found
        } catch {
            sites = []
            failure = error.localizedDescription
        }
    }

    private func start() {
        guard let profile else { return }
        let picked = (sites ?? []).map(\.domain).filter(chosen.contains)
        let history = withHistory
        isImporting = true
        failure = nil
        Task {
            do {
                try await onImport(profile, picked, history)
                onDone()
            } catch {
                failure = error.localizedDescription
            }
            isImporting = false
        }
    }
}
