import AppKit
import SwiftUI

/// Add connector's "From MCP registries": the GitHub MCP Registry's servers that run at the
/// service, the service's own first, and with a search both registries' matches, programs that
/// run on this Mac included (docs/CONNECTORS.md, "Registries"). A server at an address connects
/// like one added by its URL; one that takes a key opens a field; a program opens its own page,
/// where the person sees what runs before anything does.
struct ConnectorRegistrySection: View {
    let center: ConnectorCenter
    let query: String
    let onProgram: (ConnectorProgramDraft) -> Void
    let onAdded: () -> Void

    @State private var expanded: String?
    @State private var key = ""
    @State private var busy: String?
    @State private var error: (row: String, message: String)?

    init(center: ConnectorCenter, query: String, onProgram: @escaping (ConnectorProgramDraft) -> Void,
         onAdded: @escaping () -> Void) {
        self.center = center
        self.query = query
        self.onProgram = onProgram
        self.onAdded = onAdded
    }

    private var registry: MCPRegistryDirectory { center.registry }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The directory's own services show above, so their registry entries do not show again.
    private var directoryAddresses: Set<String> {
        Set(ConnectorPreset.all.map { MCPServerAddress.canonical($0.serverURL) })
    }

    var body: some View {
        let entries = registry.entries(query: query, excludingAddresses: directoryAddresses)
        let phase = searching ? registry.searchPhase : registry.browsePhase
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.string("From MCP registries")).font(.headline)
                if phase == .loading { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            Text(searching
                 ? L10n.string("Matches in the GitHub MCP Registry and the official MCP Registry. A program that runs on this Mac shows what it runs before you add it.")
                 : L10n.string("Servers listed in the GitHub MCP Registry that run at the service, those the service publishes itself first. Search to find more, including programs that run on this Mac."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !entries.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 34) }
                        row(entry)
                    }
                    if !searching, registry.hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .onAppear { Task { await registry.loadMore() } }
                    }
                }
                .padding(.horizontal, 12)
                .parityCard()
                .padding(.top, 2)
            }
            if case .failed(let message) = phase {
                HStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.string("Try again")) {
                        Task {
                            if searching { await registry.search(query) } else { await registry.loadIfNeeded() }
                        }
                    }
                    .parityLinkButton()
                    .font(.caption)
                }
            } else if entries.isEmpty, phase == .loaded, searching {
                Text(L10n.string("No registry server has that name."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Rows

    private func isAdded(_ entry: MCPRegistryEntry) -> Bool {
        guard let url = entry.remote?.url else { return false }
        let address = MCPServerAddress.canonical(url)
        return center.connectors.contains { MCPServerAddress.canonical($0.serverURL) == address }
    }

    private func row(_ entry: MCPRegistryEntry) -> some View {
        let isOpen = expanded == entry.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ConnectorIcon(name: entry.title,
                              sources: .make(serverURL: entry.remote?.url, serverIcons: entry.icons, preset: nil), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                        if entry.isPublishedByService(), let domain = entry.publisherDomain {
                            Text("· " + domain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(entry.summary)
                    }
                    if let need = Self.need(entry) {
                        Text(need)
                            .font(.caption)
                            .foregroundStyle(entry.reach.isUnavailable ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                            .help(need)
                    }
                }
                Spacer(minLength: 8)
                action(entry, isOpen: isOpen)
                    .padding(.top, 1)
            }
            if let error, error.row == entry.id, !isOpen {
                Text(error.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if isOpen, case .key(let url, let header) = entry.reach {
                keyEntry(entry, url: url, header: header)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 8)
        .id("registry|" + entry.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.title)
    }

    @ViewBuilder
    private func action(_ entry: MCPRegistryEntry, isOpen: Bool) -> some View {
        if isAdded(entry) {
            Text(L10n.string("Added")).font(.caption).foregroundStyle(.secondary)
        } else if busy == entry.id {
            ProgressView().controlSize(.small)
        } else {
            switch entry.reach {
            case .signIn(let url):
                Button(L10n.string("Connect")) { add(entry, url: url) }
                    .controlSize(.small)
            case .key:
                Button(isOpen ? L10n.string("Cancel") : L10n.string("Connect")) {
                    expanded = isOpen ? nil : entry.id
                    key = ""
                    error = nil
                }
                .controlSize(.small)
            case .local(let package):
                Button(L10n.string("Review…")) { onProgram(.registry(entry, package: package)) }
                    .controlSize(.small)
            case .unavailable:
                EmptyView()
            }
        }
    }

    /// The row's last line: what connecting needs beyond a click, or why it cannot be connected.
    static func need(_ entry: MCPRegistryEntry) -> String? {
        switch entry.reach {
        case .signIn:
            return nil
        case .key(_, let header):
            return header.isBearer ? L10n.string("API key") : L10n.format("API key in the %@ header", header.name)
        case .local(let package):
            let runtime = switch package.kind {
            case .npm: "npx"
            case .pypi: "uvx"
            case .oci: "Docker"
            }
            return L10n.format("Runs on this Mac with %@ · %@", runtime, package.identifier)
        case .unavailable(let limitation):
            return switch limitation {
            case .oldTransport: L10n.string("Uses the old SSE transport, which Yardlet doesn't support")
            case .addressPerAccount: L10n.string("Each account has its own address: add yours by URL below")
            case .headers: L10n.string("Needs several headers: add it by URL below with a token")
            case .packageKind: L10n.string("A kind of program Yardlet doesn't run; use it in its own app")
            case .dockerOptions: L10n.string("Needs Docker options Yardlet doesn't use, such as mounting folders")
            case .nothingToRun: L10n.string("The registry gives nothing Yardlet can connect")
            }
        }
    }

    private func keyEntry(_ entry: MCPRegistryEntry, url: URL, header: MCPRegistryEntry.KeyHeader) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SecureField(L10n.string("Paste your API key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string("Paste your API key"))
                    .onSubmit { add(entry, url: url, header: header) }
                Button(L10n.string("Connect")) { add(entry, url: url, header: header) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            if !header.input.summary.isEmpty {
                Text(header.input.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let site = entry.website ?? entry.repository {
                Button {
                    NSWorkspace.shared.open(site)
                } label: {
                    Label(L10n.string("Find your API key"), systemImage: "arrow.up.right.square")
                }
                .parityLinkButton()
                .font(.caption)
            }
            if let error, error.row == entry.id {
                Text(error.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add(_ entry: MCPRegistryEntry, url: URL, header: MCPRegistryEntry.KeyHeader? = nil) {
        let token = header == nil ? nil : key.trimmingCharacters(in: .whitespacesAndNewlines)
        if header != nil, token?.isEmpty != false { return }
        busy = entry.id
        error = nil
        Task {
            do {
                let record = try await center.add(name: entry.title, serverURL: url, token: token,
                                                  tokenHeader: header.flatMap { $0.isBearer ? nil : $0.name })
                center.connect(record.id)
                busy = nil
                onAdded()
            } catch {
                busy = nil
                self.error = (entry.id, error.localizedDescription)
            }
        }
    }
}

private extension MCPRegistryEntry.Reach {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// A program's own page: where it comes from, exactly what will run, the values it needs, and
/// one button that runs it. Nothing runs before the person presses it.
struct ConnectorProgramPage: View {
    let center: ConnectorCenter
    let draft: ConnectorProgramDraft
    let onBack: () -> Void
    let onAdded: () -> Void

    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var started = false

    init(center: ConnectorCenter, draft: ConnectorProgramDraft, onBack: @escaping () -> Void, onAdded: @escaping () -> Void) {
        self.center = center
        self.draft = draft
        self.onBack = onBack
        self.onAdded = onAdded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onBack) {
                Label(L10n.string("All services"), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .parityPointer()
            HStack(alignment: .top, spacing: 12) {
                ConnectorIcon(name: draft.name, sources: registryIcons, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("Run %@ on this Mac?", draft.name))
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(L10n.format("From %@", draft.origin))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let repository = draft.repository {
                            Button {
                                NSWorkspace.shared.open(repository)
                            } label: {
                                Label(L10n.string("Source"), systemImage: "arrow.up.right.square")
                            }
                            .parityLinkButton()
                            .font(.caption)
                        }
                    }
                }
            }
            Text(L10n.string("This is a program, not a server at the service. It runs on this Mac with your access to files, the network, and other apps, so add only one you trust."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("What runs")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(draft.commandLine(values))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(L10n.string("What runs"))
            }
            if !draft.inputs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("Values it needs")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(draft.inputs) { input in
                        inputField(input)
                    }
                    Text(L10n.string("Kept in your keychain. Yardlet gives them to this program only."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(lifetime)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(L10n.string("Cancel"), action: onBack)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.string("Run on this Mac"), action: run)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isReady(values))
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            values = draft.initialValues
        }
        .accessibilityElement(children: .contain)
    }

    private var registryIcons: ConnectorIconSources? {
        guard case .registry(let entry, _) = draft.source else { return nil }
        return .make(serverURL: entry.website, serverIcons: entry.icons, preset: nil)
    }

    private var lifetime: String {
        switch draft.runtime {
        case .docker:
            L10n.string("Yardlet starts it when a task first uses one of its tools and stops it when Yardlet quits. Docker keeps the image after you remove the connector; remove it in Docker if you no longer want it.")
        case .npx, .uvx:
            L10n.string("Yardlet starts it when a task first uses one of its tools and stops it when Yardlet quits. Removing the connector also deletes what was downloaded for it.")
        case .command:
            L10n.string("Yardlet starts it when a task first uses one of its tools and stops it when Yardlet quits. The settings it came from stay as they are.")
        }
    }

    private func inputField(_ input: MCPRegistryEntry.Input) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        let label = input.isRequired ? input.name : L10n.format("%@ (optional)", input.name)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption.monospaced())
                    .frame(width: 190, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(input.name)
                Group {
                    if input.isSecret {
                        SecureField(input.name, text: binding)
                    } else {
                        TextField(input.name, text: binding)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(input.name)
            }
            if !input.summary.isEmpty {
                Text(input.summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.leading, 198)
                    .help(input.summary)
            }
        }
    }

    private func run() {
        guard draft.isReady(values) else { return }
        busy = true
        error = nil
        let (program, spec) = draft.plan(values)
        Task {
            do {
                _ = try await center.addProgram(name: draft.name, program: program, spec: spec)
                busy = false
                onAdded()
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
