import Foundation

/// What a window's sidebar and content show: the coding tasks, or the personal agents, switched by the
/// words below Scheduled tasks.
enum ShellSection: String, CaseIterable, Identifiable {
    case tasks, personalAgents
    var id: Self { self }
}

/// A cloud agent is not a coding task. Its account, profile and messaging room
/// remain provider-owned and are never inserted into the local session index.
struct PersonalAgentIdentity: Hashable, Codable, Sendable {
    let accountID: String
    let userID: String
    let agentID: String
    let roomID: String
}

struct PersonalAgent: Identifiable, Equatable, Sendable {
    let id: PersonalAgentIdentity
    let name: String
    let rootThreadID: String?
    let isPaused: Bool
    let isPrimary: Bool
    var avatar: PersonalAgentAvatar? = nil
    /// The pet whose sprite sheet is the dot's animated form, as its profile's avatar manifest names it.
    var petID: String? = nil
}

/// A pet as the account's pet list names it. The sheet location is a signed provider URL: only the
/// transport reads it, and it never appears in a description, a log or a saved file.
struct PersonalAgentPet: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let location: String
    /// What tells one sheet from the next: the pet's artwork revision and when it last changed.
    let version: String

    var description: String { "PersonalAgentPet(\(version))" }
    var debugDescription: String { description }
}

/// A dot's sprite sheet as read, one per pet version in a window, shared by every view that shows the
/// dot. Its identity is what the screen's decoding of it is kept by, and released with.
final class PersonalAgentSpriteSheet: Sendable {
    let data: Data
    let version: String

    init(data: Data, version: String) {
        self.data = data
        self.version = version
    }
}

/// How a pet's sheet is laid out: eight 192 x 208 cells across, a row per motion, nine rows in the
/// first version of the sheet and eleven in the second. A dot shows two of them.
enum PersonalAgentSpriteLayout {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208
    static let sheetWidth = columns * cellWidth
    static let sheetHeights: Set<Int> = [9 * cellHeight, 11 * cellHeight]
    /// The most the pet is enlarged to fill its frame.
    static let maximumScale = 1.5

    enum Motion: CaseIterable, Sendable {
        case idle, working

        var row: Int {
            switch self {
            case .idle: 0
            case .working: 7
            }
        }

        /// Each frame's time on screen, in seconds, left to right from the row's first cell.
        var durations: [Double] {
            switch self {
            case .idle: [1.68, 0.66, 0.66, 0.84, 0.84, 1.92]
            case .working: [0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
            }
        }
    }
}

/// A dot's static picture as its profile names it. The location is a signed provider URL: only the
/// transport reads it, and it never appears in a description, a log or a saved file.
struct PersonalAgentAvatar: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let location: String
    /// What tells one picture from the next: its snapshot's content hash when the profile has one.
    let version: String

    var description: String { "PersonalAgentAvatar(\(version))" }
    var debugDescription: String { description }
}

/// A dot's task in its Activity: running first, then by when it last changed.
struct PersonalAgentActivity: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case running, completed, unknown }
    enum Outcome: Equatable, Sendable { case succeeded, failed, interrupted, unknown }
    let id: String
    let title: String
    let status: Status
    let outcome: Outcome
    let updatedAt: Date?
    let preview: String?
}

struct PersonalAgentActivityPage: Equatable, Sendable {
    let items: [PersonalAgentActivity]
    let cursor: String?
}

/// One of a dot's schedules, as far as its list names it.
struct PersonalAgentSchedule: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let isEnabled: Bool?
}

/// A computer the dot's root thread can work on. Being attached is the dot's permission to use it;
/// whether it is reachable is a separate provider status, unknown when the provider gives none.
struct PersonalAgentComputer: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable { case connected, disconnected, offline, unknown }
    let id: String
    let name: String
    let isCloud: Bool
    let isAttached: Bool
    let availability: Availability
}

struct PersonalAgentMessage: Identifiable, Equatable, Sendable {
    enum Author: Equatable, Sendable { case person, agent, other(String), unknown }
    let id: String
    let author: Author
    let text: String
    let createdAt: Date?
    let isDeleted: Bool
    let attachments: [PersonalAgentAttachment]
    var requestID: String? = nil
    /// The provider sent something here that Yardlet does not show yet; the dot's own page does.
    var isUnsupported = false
    /// The input request the message carries (`content.elicitation`), exactly as the provider sent it.
    var inputRequest: JSONValue? = nil
    /// The message's own metadata (`message_metadata`): an option question, or the option a reply chose.
    var metadata: JSONValue? = nil
    /// The message this one replies to.
    var replyToMessageID: String? = nil
}

struct PersonalAgentAttachment: Equatable, Sendable {
    let fileID: String?
    let name: String
    let type: String

    /// A file Yardlet can read and preview; any other attachment is named only.
    var opensHere: Bool { type == "file" && fileID != nil }
}

/// Where a dot's own surfaces are, outside Yardlet: the dot's page on the provider's website, and the
/// Dots home of the provider's app, which names no dot. Neither transfers a credential or switches the
/// sign-in where it opens: each opens with whatever sign-in its browser or app already has.
enum DotsLinks {
    static let appBundleIdentifier = "com.openai.codex"
    /// The app takes exactly this address, with nothing after it.
    static let appHome = URL(string: "codex://dots")!

    /// The dot's page, its profile identity as one escaped path component.
    static func web(for agent: PersonalAgent) -> URL? {
        let id = agent.id.agentID
        guard !id.isEmpty, let component = id.addingPercentEncoding(withAllowedCharacters: componentCharacters)
        else { return nil }
        return URL(string: "https://chatgpt.com/dots/" + component)
    }

    /// What a URI component keeps unescaped (`encodeURIComponent`).
    private static let componentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}

/// A message as it is sent, fixed once its request is saved: a retry sends these same words and
/// file IDs under the same request ID, never files uploaded again.
struct PersonalAgentSubmission: Codable, Equatable, Sendable {
    let requestID: String
    let text: String
    let timezoneOffsetMinutes: Int
    /// Files the room already accepted for this message, in the order they were added.
    let attachments: [PersonalAgentUploadedFile]
    /// The question this message answers, with the option chosen there; nil for an ordinary message.
    var replyToMessageID: String? = nil
    var optionSelection: Int? = nil

    init(text: String, attachments: [PersonalAgentUploadedFile] = [], requestID: String = UUID().uuidString) {
        self.requestID = requestID
        self.text = text
        self.attachments = attachments
        timezoneOffsetMinutes = -TimeZone.current.secondsFromGMT() / 60
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, text, timezoneOffsetMinutes, attachments, replyToMessageID, optionSelection
    }

    /// A request saved before attachments or option replies existed carries neither.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        text = try container.decode(String.self, forKey: .text)
        timezoneOffsetMinutes = try container.decode(Int.self, forKey: .timezoneOffsetMinutes)
        attachments = try container.decodeIfPresent([PersonalAgentUploadedFile].self, forKey: .attachments) ?? []
        replyToMessageID = try container.decodeIfPresent(String.self, forKey: .replyToMessageID)
        optionSelection = try container.decodeIfPresent(Int.self, forKey: .optionSelection)
    }

    /// Words or a file: an attachment alone is a message.
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

/// A file the dot's room accepted (`POST /messaging/rooms/{room}/files`): its ID there, with the name,
/// type and size of the bytes that were sent. The ID belongs to that account's room and nowhere else.
struct PersonalAgentUploadedFile: Codable, Equatable, Sendable {
    let fileID: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
}

/// The bytes that go up for one attachment, after the provider's image preparation.
struct PersonalAgentPreparedFile: Sendable {
    let data: Data
    let name: String
    let mimeType: String
}

/// The provider composer's rules for what a file attachment may be (`addFiles`): at most eight in a
/// message, each of 1 byte to 20 MiB, named by its last path component without control characters.
enum PersonalAgentFileRules {
    static let maximumCount = 8
    static let maximumBytes = 20 * 1024 * 1024

    static func accepts(size: Int) -> Bool { size >= 1 && size <= maximumBytes }

    static func displayName(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let last = cleaned.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let name = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Attachment" : name
    }

    /// A declared type is kept unless it says nothing (`application/octet-stream`); otherwise the
    /// provider names a few extensions it recognizes, and anything else is octet-stream.
    static func mimeType(name: String, declared: String?) -> String {
        if let declared = declared?.lowercased(), !declared.isEmpty, declared != "application/octet-stream" { return declared }
        let known = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                     "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "pdf": "application/pdf",
                     "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                     "txt": "text/plain", "zip": "application/zip"]
        let ext = name.split(separator: ".").count > 1 ? name.split(separator: ".").last.map { $0.lowercased() } : nil
        return ext.flatMap { known[$0] } ?? "application/octet-stream"
    }
}

/// What turns a saved copy of a chosen file into the bytes to upload. The platform's version prepares
/// pictures as the provider's composer does; this one sends the copy as it is.
protocol PersonalAgentFilePreparing: Sendable {
    func prepare(_ file: URL, name: String, mimeType: String) async throws -> PersonalAgentPreparedFile
}

struct PersonalAgentUnchangedFiles: PersonalAgentFilePreparing {
    func prepare(_ file: URL, name: String, mimeType: String) async throws -> PersonalAgentPreparedFile {
        let data = try await Task.detached { try Data(contentsOf: file) }.value
        return .init(data: data, name: name, mimeType: mimeType)
    }
}

struct PersonalAgentDownload: Sendable {
    let data: Data
    let name: String
}

struct PersonalAgentPage: Equatable, Sendable {
    let messages: [PersonalAgentMessage]
    let before: String?
    /// The room's lifecycle when the page was read, if it named one the provider knows.
    var roomLifecycle: String? = nil
}

enum PersonalAgentFailure: Error, Equatable, Sendable {
    case runtimeUnavailable, signInRequired, accountChanged, accessDenied
    case unavailable, invalidResponse, network, stopped
    case deliveryUnknown, sendRejected, verificationRequired, draftStorage, attachmentUnavailable
    case attachmentLimit, uploadFailed, uploadInterrupted, filePreparation, attachmentsIncomplete, attachmentsNotAllowed

    var message: String {
        switch self {
        case .runtimeUnavailable: L10n.string("Connect Codex in Accounts to use your dots.")
        case .signInRequired: L10n.string("Sign in with ChatGPT in Accounts to use your dots.")
        case .accountChanged: L10n.string("The ChatGPT account changed. Reconnect to load its dots.")
        case .accessDenied: L10n.string("Dots are not available for this ChatGPT account.")
        case .unavailable: L10n.string("Dots could not be reached. Try again.")
        case .invalidResponse: L10n.string("This Dots response cannot be displayed yet.")
        case .network: L10n.string("Could not connect to Dots. Check your connection and try again.")
        case .stopped: L10n.string("Disconnected")
        case .deliveryUnknown: L10n.string("Delivery could not be confirmed. Refresh the conversation or retry the same message.")
        case .sendRejected: L10n.string("The message was not accepted. Your draft is still here.")
        case .verificationRequired: L10n.string("ChatGPT requires verification before this message can be sent. Your draft is still here.")
        case .draftStorage: L10n.string("The draft could not be saved. Nothing new will be sent until it is saved.")
        case .attachmentUnavailable: L10n.string("This attachment cannot be opened here yet.")
        case .attachmentLimit: L10n.string("Add up to 8 files, each up to 20 MB.")
        case .uploadFailed: L10n.string("A file could not be uploaded. Retry it or remove it.")
        case .uploadInterrupted: L10n.string("A file upload stopped before it finished. Retry it or remove it.")
        case .filePreparation: L10n.string("This photo could not be prepared for upload. Convert it to JPEG and try again.")
        case .attachmentsIncomplete: L10n.string("Nothing was sent because a file did not upload. Retry it or remove it.")
        case .attachmentsNotAllowed: L10n.string("Files cannot be sent in this conversation. Remove them to send the message.")
        }
    }
}

enum PersonalAgentUpdate: Sendable {
    case changed, reconnecting, connected, failed(PersonalAgentFailure)
}

protocol PersonalAgentClient: Actor {
    func agents() async throws -> [PersonalAgent]
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate>
    /// The dot's room as its provider observes it: each bound state, nil while there is none. Asking
    /// for another dot's ends the first; ending the stream ends the observation.
    func liveState(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentLiveUpdate>
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage
    /// One file into the dot's room, for a later message to name by its returned ID.
    func upload(_ file: PersonalAgentPreparedFile, to agent: PersonalAgent) async throws -> PersonalAgentUploadedFile
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload
    /// The bytes of the dot's profile picture, bounded; never read with an account credential on storage hosts.
    func avatar(for agent: PersonalAgent) async throws -> Data
    /// The pet `id` among the account's, which a dot's profile names; nil when the account has none such.
    func pet(_ id: String, for agent: PersonalAgent) async throws -> PersonalAgentPet?
    /// The bytes of a pet's sprite sheet, bounded and read as the picture is.
    func spriteSheet(_ pet: PersonalAgentPet, for agent: PersonalAgent) async throws -> Data
    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage
    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule]
    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer]
    /// What the provider says now of the input request in a message, read without answering it.
    func inspectRequest(in messageID: String, for agent: PersonalAgent) async throws -> DotsRequestInspection
    /// Sends one answer to the input request in a message, once: it is never retried (`DotsResponseFailure`).
    func respond(_ result: DotsInputResult, fingerprint: String, in messageID: String,
                 for agent: PersonalAgent) async throws -> DotsResponseOutcome
    func stop() async
}

extension PersonalAgentClient {
    /// A reader that observes no room shows every dot idle.
    func liveState(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentLiveUpdate> { AsyncStream { $0.finish() } }

    func inspectRequest(in messageID: String, for agent: PersonalAgent) async throws -> DotsRequestInspection {
        throw PersonalAgentFailure.unavailable
    }

    func respond(_ result: DotsInputResult, fingerprint: String, in messageID: String,
                 for agent: PersonalAgent) async throws -> DotsResponseOutcome {
        throw DotsResponseFailure.notDispatched(.unavailable)
    }
}

/// What the provider answered to a response it received.
enum DotsResponseOutcome: Equatable, Sendable {
    case applied
    /// Any other status: the answer may or may not have taken effect, and nothing is resent.
    case unconfirmed
}

/// Why an answer did not return applied: either it was certainly never sent, or it may have been.
enum DotsResponseFailure: Error, Equatable, Sendable {
    case notDispatched(PersonalAgentFailure)
    case uncertain(PersonalAgentFailure)
}

enum DotsProjection {
    static func agents(catalog: JSONValue, primary: JSONValue, accountID: String, userID: String) throws -> [PersonalAgent] {
        guard case let .array(items)? = catalog["items"] else { throw PersonalAgentFailure.invalidResponse }
        let selected = primary["selection"]?["aeon_id"]?.stringValue ?? primary["profile"]?["id"]?.stringValue
        return try items.filter { $0["aeon_kind"]?.stringValue == "orbit" && $0["status"]?.stringValue != "deleting" }.map { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty,
                  let room = item["messaging_room_id"]?.stringValue, !room.isEmpty else {
                throw PersonalAgentFailure.invalidResponse
            }
            return PersonalAgent(id: .init(accountID: accountID, userID: userID, agentID: id, roomID: room),
                name: item["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Dots",
                rootThreadID: item["active_root_thread_id"]?.stringValue,
                isPaused: item["is_paused"] == .bool(true), isPrimary: id == selected, avatar: avatar(item),
                petID: item["avatar_manifest"]?["pet_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// A page of the account's pets that have a sheet to read: an HTTPS location, versioned by its
    /// artwork revision and last change.
    static func pets(_ page: JSONValue) throws -> (pets: [PersonalAgentPet], cursor: String?) {
        guard case let .array(items)? = page["pets"] else { throw PersonalAgentFailure.invalidResponse }
        let pets = items.compactMap { item -> PersonalAgentPet? in
            guard let id = item["id"]?.stringValue, !id.isEmpty,
                  let raw = item["spritesheet_url"]?.stringValue, URL(string: raw)?.scheme == "https" else { return nil }
            let revision = item["artwork_revision"].map(versionPart) ?? ""
            let updated = item["updated_at"].map(versionPart) ?? ""
            return .init(id: id, location: raw, version: revision + "|" + updated)
        }
        return (pets, page["cursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func versionPart(_ value: JSONValue) -> String {
        switch value {
        case let .string(text): text
        case let .integer(number): String(number)
        case let .number(number): String(number)
        default: ""
        }
    }

    /// The profile's static snapshot. `avatar_file_id` and the snapshot's `sediment://` pointer are
    /// provider asset pointers, not URLs; only an HTTPS `avatar_url` is a picture to read.
    static func avatar(_ profile: JSONValue) -> PersonalAgentAvatar? {
        guard let raw = profile["avatar_url"]?.stringValue, URL(string: raw)?.scheme == "https" else { return nil }
        let snapshot = profile["avatar_manifest"]?["snapshot"]
        let version = snapshot?["content_sha256"]?.stringValue ?? snapshot?["asset_pointer"]?.stringValue
            ?? profile["updated_at"]?.stringValue ?? ""
        return .init(location: raw, version: version)
    }

    static func activity(_ page: JSONValue) throws -> PersonalAgentActivityPage {
        guard case let .array(items)? = page["data"] else { throw PersonalAgentFailure.invalidResponse }
        let values = items.compactMap { item -> PersonalAgentActivity? in
            guard let id = item["thread_id"]?.stringValue, !id.isEmpty else { return nil }
            let status: PersonalAgentActivity.Status = switch item["status"]?.stringValue ?? "" {
            case "in_progress": .running
            case "completed": .completed
            default: .unknown
            }
            let outcome: PersonalAgentActivity.Outcome = switch item["outcome"]?.stringValue ?? "" {
            case "succeeded": .succeeded
            case "failed": .failed
            case "interrupted": .interrupted
            default: .unknown
            }
            return .init(id: id, title: item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                            ?? L10n.string("Untitled task"),
                         status: status, outcome: outcome, updatedAt: epoch(item["updated_at"] ?? item["created_at"]),
                         preview: item["preview"]?["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
        return .init(items: sortedActivity(values), cursor: page["next_cursor"]?.stringValue)
    }

    /// The provider's order: running tasks first, interrupted ones after the rest, then the newest change.
    static func sortedActivity(_ items: [PersonalAgentActivity]) -> [PersonalAgentActivity] {
        func rank(_ item: PersonalAgentActivity) -> Int {
            item.status == .running ? 0 : item.outcome == .interrupted ? 2 : 1
        }
        return items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (da, db) = (a.element.updatedAt ?? .distantPast, b.element.updatedAt ?? .distantPast)
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    static func schedules(_ page: JSONValue) throws -> [PersonalAgentSchedule] {
        guard case let .array(items)? = page["items"] else { throw PersonalAgentFailure.invalidResponse }
        return items.compactMap { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            let enabled: Bool? = if case let .bool(value)? = item["is_enabled"] { value } else { nil }
            return .init(id: id, title: item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }, isEnabled: enabled)
        }
    }

    /// The computers bound to the root thread the request named; a reply for another thread is not this dot's.
    static func computers(_ value: JSONValue, rootThreadID: String) throws -> [PersonalAgentComputer] {
        guard value["thread_id"]?.stringValue == rootThreadID, case let .array(items)? = value["computers"] else {
            throw PersonalAgentFailure.invalidResponse
        }
        return items.enumerated().map { index, item in
            let kind = item["kind"]?.stringValue ?? ""
            let attached = item["is_attached"] == .bool(true)
            let availability: PersonalAgentComputer.Availability = switch item["status"]?.stringValue ?? "" {
            case "offline": .offline
            case "connected": attached ? .connected : .disconnected
            default: .unknown
            }
            let name = item["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            // The provider's own client treats `user` as a person's computer and every other kind as its cloud.
            let isCloud = kind != "user"
            return .init(id: item["environment_id"]?.stringValue ?? "\(index)-\(kind)",
                         name: name ?? (isCloud ? L10n.string("Cloud computer") : L10n.string("Computer")),
                         isCloud: isCloud, isAttached: attached, availability: availability)
        }
    }

    private static func epoch(_ value: JSONValue?) -> Date? {
        switch value {
        case let .integer(seconds)?: Date(timeIntervalSince1970: Double(seconds))
        case let .number(seconds)?: Date(timeIntervalSince1970: seconds)
        default: nil
        }
    }

    /// The lifecycle states the provider's room normalizer knows; any other value says nothing.
    static let roomLifecycles: Set<String> = ["share_only", "pending_request", "connected", "accepted"]

    /// The room's lifecycle under the names the provider reads, in its order, if it is a known one.
    static func roomLifecycle(_ room: JSONValue) -> String? {
        let raw = [room["dmLifecycleState"], room["dm_lifecycle_state"], room["lifecycleState"]]
            .lazy.compactMap { $0?.stringValue }.first { !$0.isEmpty }
        return raw.flatMap { roomLifecycles.contains($0) ? $0 : nil }
    }

    /// The provider's gate for files and replies (`mayAttachOrReply`): a room only shared with the
    /// person, or waiting on a message request in either direction, takes none. A room whose
    /// lifecycle is unknown is not refused, as the provider's own composer does not refuse it.
    static func allowsAttachments(lifecycle: String?) -> Bool {
        lifecycle != "share_only" && lifecycle != "pending_request"
    }

    /// The room a file is written to, checked as the provider's room reader checks it: this dot's
    /// room, a direct messaging room, and one that takes files now.
    static func attachmentRoom(_ room: JSONValue, agent: PersonalAgent) throws {
        _ = try messages(.object(["items": .array([])]), room: room, agent: agent)
        guard room["type"]?.stringValue == "DM", room["app_source"]?.stringValue == "chatgpt:messaging" else {
            throw PersonalAgentFailure.invalidResponse
        }
        guard allowsAttachments(lifecycle: roomLifecycle(room)) else { throw PersonalAgentFailure.attachmentsNotAllowed }
    }

    static func messages(_ page: JSONValue, room: JSONValue, agent: PersonalAgent) throws -> PersonalAgentPage {
        guard room["id"]?.stringValue == agent.id.roomID, room["aeon_id"]?.stringValue == agent.id.agentID,
              case let .array(members)? = room["members"], case let .array(items)? = page["items"] else {
            throw PersonalAgentFailure.invalidResponse
        }
        let messages = try items.map { item -> PersonalAgentMessage in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { throw PersonalAgentFailure.invalidResponse }
            let sender = item["account_user_id"]?.stringValue
            let member = members.first { sender != nil && $0["account_user_id"]?.stringValue == sender }
            let author: PersonalAgentMessage.Author
            // Both a dot and a person can have role=user. Messaging membership
            // is distinct from the OAuth workspace-membership identifier.
            if member?["aeon_id"]?.stringValue == agent.id.agentID { author = .agent }
            else if sender == agent.id.userID { author = .person }
            else if let name = member?["name"]?.stringValue { author = .other(name) }
            else { author = .unknown }
            let deleted = item["deleted_at"] != nil && item["deleted_at"] != .null
            var text = item["content"]?["text"]?.stringValue ?? ""
            let attachments: [PersonalAgentAttachment]
            if case let .array(values)? = item["content"]?["attachments"] {
                attachments = values.map { value in
                    let fileID = value["file_id"]?.stringValue ?? value["file"]?["file_id"]?.stringValue ?? value["file"]?["id"]?.stringValue
                    return .init(fileID: fileID,
                          name: value["name"]?.stringValue ?? value["file"]?["name"]?.stringValue
                              ?? value["file"]?["file_name"]?.stringValue ?? value["filename"]?.stringValue ?? L10n.string("Attachment"),
                          type: value["type"]?.stringValue ?? (fileID == nil ? "unknown" : "file"))
                }
            } else { attachments = [] }
            let request = item["content"]?["elicitation"].flatMap { $0 == .null ? nil : $0 }
            // A request whose identity cannot be read is shown as something Yardlet cannot display yet.
            let unsupported = !deleted && text.isEmpty && attachments.isEmpty && request.flatMap(DotsInputRequest.init) == nil
            if unsupported { text = L10n.string("This message cannot be displayed yet.") }
            return PersonalAgentMessage(id: id, author: author, text: deleted ? "" : text,
                createdAt: date(item["created_at"]?.stringValue), isDeleted: deleted, attachments: deleted ? [] : attachments,
                requestID: item["request_id"]?.stringValue, isUnsupported: unsupported,
                inputRequest: deleted ? nil : request,
                metadata: item["message_metadata"].flatMap { $0 == .null ? nil : $0 },
                replyToMessageID: item["reply_to"]?["message_id"]?.stringValue)
        }
        guard Set(messages.map(\.id)).count == messages.count else { throw PersonalAgentFailure.invalidResponse }
        // The provider's room client also uses the oldest item when prev_cursor
        // is absent; an empty page ends backfill.
        return .init(messages: messages, before: messages.isEmpty ? nil : page["prev_cursor"]?.stringValue ?? messages.first?.id,
                     roomLifecycle: roomLifecycle(room))
    }

    static func merge(_ existing: [PersonalAgentMessage], with incoming: [PersonalAgentMessage], older: Bool) -> [PersonalAgentMessage] {
        let replacements = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let known = Set(existing.map(\.id))
        let new = incoming.filter { !known.contains($0.id) }
        let updated = existing.map { replacements[$0.id] ?? $0 }
        return older ? new + updated : updated + new
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
