import Foundation
import YardletRemote

/// The host's mailbox in this window (docs/REMOTE_PROTOCOL.md §15.38): this Mac's own mail views over a mailbox whose
/// accounts are the host's, each call made through the host's connection to the host's own transport. It tells of no new
/// mail here: the host tells its own.
extension RemoteHostModel {
    /// The mailbox shows while the host's is on; it holds the host's accounts, and follows what arrives, while this device
    /// may read them, and none otherwise.
    func followHostMail() async {
        guard offersHostMail, let state = mailCalendarState, state.mailbox else {
            mailbox.setEnabled(false)
            return
        }
        mailbox.setEnabled(true)
        guard state.permitted else {
            mailbox.stopWatching()
            if !mailbox.accounts.isEmpty { mailbox.setAccounts([]) }
            return
        }
        let answer = await response(to: .mail(action: "accounts", data: nil))
        guard answer.ok, let read = try? RemoteMailWire.decode(RemoteMailWire.Accounts.self, answer.data),
              mailbox.isEnabled else { return }
        if read.accounts != mailbox.accounts {
            mailbox.setAccounts(read.accounts.map { account in
                (account, RemoteMailTransport(accountID: account.id) { [weak self] action, data, files in
                    guard let self else { throw MailFailure(kind: .unavailable, message: "") }
                    return try await self.mailCall(action, data, files: files)
                })
            })
            await mailbox.refresh()
        }
        mailbox.startWatching()
    }

    /// One call of the host's mailbox, a draft's files sent up first; a refusal in the mailbox's own words.
    func mailCall(_ action: String, _ data: Data?, files: [URL] = []) async throws -> Data {
        var uploads: [String] = []
        for file in files {
            let mediaType = FileTypes.mimeType(forExtension: file.pathExtension) ?? "application/octet-stream"
            guard let id = await upload(file, mediaType: mediaType) else {
                throw MailFailure(kind: .unavailable, message: commandError ?? L10n.string("The file is too large to send."))
            }
            uploads.append(id)
        }
        let answer = await response(to: .mail(action: action, data: data, files: uploads))
        if answer.ok { return answer.data ?? Data() }
        switch answer.error?.reason {
        case .signIn?:
            throw MailFailure(kind: .signInRequired,
                              message: L10n.format("Sign in to this account again in %@'s Settings › Connectors.", name))
        case .failed?:
            throw MailFailure(kind: .unavailable, message: answer.error?.message ?? "")
        default:
            throw MailFailure(kind: .unavailable, message: Self.message(for: answer.error, host: name))
        }
    }
}

/// One of the host's mail accounts, reached through the host (§15.38).
struct RemoteMailTransport: MailAccountTransport {
    typealias Call = RemoteMailWire.Call
    let accountID: UUID
    let call: @Sendable (String, Data?, [URL]) async throws -> Data

    func folders() async throws -> [MailFolder] {
        try await ask("folders", Call(accountID: accountID))
    }

    func inbox(pageToken: String?) async throws -> MailPage {
        try await ask("inbox", Call(accountID: accountID, pageToken: pageToken))
    }

    func list(_ folder: MailFolder, pageToken: String?) async throws -> MailPage {
        try await ask("list", Call(accountID: accountID, pageToken: pageToken, folder: folder))
    }

    func search(_ query: String, pageToken: String?) async throws -> MailPage {
        try await ask("search", Call(accountID: accountID, pageToken: pageToken, query: query))
    }

    func thread(_ threadID: String) async throws -> MailThread {
        try await ask("thread", Call(accountID: accountID, threadID: threadID))
    }

    func change(_ threadID: String, _ change: MailThreadChange) async throws {
        _ = try await call("change", RemoteMailWire.encode(Call(accountID: accountID, threadID: threadID, change: change)), [])
    }

    func saveDraft(_ composition: MailComposition) async throws -> String {
        let arguments = Call(accountID: accountID, composition: RemoteMailWire.Composition(composition))
        let answer = try await call("saveDraft", RemoteMailWire.encode(arguments), composition.attachments)
        return try decode(RemoteMailWire.Value.self, answer).value
    }

    func sendDraft(_ draftID: String) async throws {
        _ = try await call("sendDraft", RemoteMailWire.encode(Call(accountID: accountID, draftID: draftID)), [])
    }

    func discardDraft(_ draftID: String) async throws {
        _ = try await call("discardDraft", RemoteMailWire.encode(Call(accountID: accountID, draftID: draftID)), [])
    }

    func draftID(forMessage messageID: String) async throws -> String {
        let value: RemoteMailWire.Value = try await ask("draftID", Call(accountID: accountID, messageID: messageID))
        return value.value
    }

    func changeCursor() async throws -> String {
        let value: RemoteMailWire.Value = try await ask("changeCursor", Call(accountID: accountID))
        return value.value
    }

    func changes(since cursor: String) async throws -> MailChanges {
        try await ask("changes", Call(accountID: accountID, cursor: cursor))
    }

    private func ask<Value: Decodable>(_ action: String, _ arguments: Call) async throws -> Value {
        try decode(Value.self, try await call(action, RemoteMailWire.encode(arguments), []))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do { return try RemoteMailWire.decode(type, data) } catch {
            throw MailFailure(kind: .unavailable, message: L10n.string("The mailbox's answer could not be read."))
        }
    }
}
