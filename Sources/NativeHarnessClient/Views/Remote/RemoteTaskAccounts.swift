import SwiftUI
import YardletRemote

/// Only host account labels and opaque IDs enter this picker. Sign-ins stay on the host.
struct RemoteTaskAccounts: View {
    let model: RemoteHostModel
    let session: SessionRecord
    @State private var accounts: [RemoteAccount]?
    @State private var error: String?
    @State private var choosing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("Choose account")).font(.headline)
                    Text(session.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { Task { await refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.string("Refresh usage"))
                Button(L10n.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let accounts, accounts.allSatisfy({ $0.current == true }) {
                Text(AccountListProjection.noOtherAccountText(for: session.harness))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if accounts == nil { ProgressView() }
                    ForEach(accounts ?? [], id: \.id) { account in
                        let choice = Self.choice(account, harness: session.harness)
                        AccountRow(choice: choice, accountLine: account.detail, selected: account.current == true,
                            canChoose: account.available == true && account.state != .unavailable,
                            freshness: account.checkedAt.map {
                                AccountFreshness(checkedAt: Date(timeIntervalSince1970: Double($0) / 1000), status: nil, isChecking: false)
                            },
                            usage: AccountGroupProjection.groups(from: [choice]).first, onSelect: {
                            guard account.available == true && account.state != .unavailable else { return }
                            Task {
                                choosing = true
                                defer { choosing = false }
                                if await model.perform(.taskAction(taskID: session.id.uuidString,
                                    action: .init(.chooseAccount, value: account.id))) { dismiss() }
                                else { error = model.commandError }
                            }
                        })
                        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(maxHeight: 360)
        }
        .lineSpacing(3)
        .padding(20).frame(width: 660).disabled(choosing).task { await refresh() }
    }

    static func choice(_ account: RemoteAccount, harness: HarnessKind) -> AccountChoice {
        let usage = account.usage.enumerated().map { index, window in
            AccountUsageMetric(id: String(index), label: window.label,
                usedFraction: window.usedPercent.map { Double($0) / 100 }, detail: "",
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }, evidence: .exactQuota)
        }
        // Presentation only: no provider connection, account home or credentials are constructed here.
        let snapshot = HarnessAccountSnapshot(id: account.id, harness: harness, providerID: nil,
            state: account.state.flatMap { AccountAuthState(rawValue: $0.rawValue) } ?? .unknown,
            accountLabel: account.name, detail: account.detail ?? "", credentialOwner: "", checkedAt: account.checkedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .distantPast,
            usage: usage, canLogin: false, canLogout: false)
        return AccountChoice(harness: harness, connection: nil, snapshot: snapshot)
    }

    private func refresh(force: Bool = false) async {
        let response = await model.response(to: .taskAccounts(taskID: session.id.uuidString, refresh: force))
        if response.ok { accounts = response.taskAccounts ?? []; error = nil }
        else { error = RemoteHostModel.message(for: response.error, host: model.name) }
    }
}
