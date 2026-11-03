import CryptoKit
import Darwin
import Foundation

/// The readings of Personal agents kept between launches, in private files under the user's Caches:
/// one folder per account and user, named by a digest, holding the list, each listed room's newest
/// page and the pictures' bytes. No credential, signed location, draft or answer claim is written.
/// Deleting any of it loses only what a window shows before its first read.
///
///     <root>/<account digest>/list.json             the dots, the sources read as this account, pet versions
///     <root>/<account digest>/rooms/<digest>.json   a room's newest messages
///     <root>/<account digest>/pictures/<digest>     a profile picture's or a sheet's bytes
actor PersonalAgentCacheFiles: PersonalAgentReadingCache {
    static let live = PersonalAgentCacheFiles(directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/Yardlet/personal-agents", directoryHint: .isDirectory))

    /// The transport's own bounds on a picture and on a sheet.
    static let avatarLimit = 4 * 1024 * 1024
    static let sheetLimit = 20 * 1024 * 1024

    private struct List: Codable {
        var version = 1
        /// Digests of the sources last read as this account.
        var sources: [String]
        var agents: [PersonalAgent]
        /// Each pet's sheet version kept, by pet.
        var sheets: [String: String] = [:]
    }

    private struct Room: Codable {
        var version = 1
        let room: PersonalAgentReading.Room
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    func reading(source: String) -> PersonalAgentReading? {
        let digest = Self.digest(source)
        guard let (folder, list) = lists().first(where: { $0.list.sources.contains(digest) }),
              let identity = list.agents.first?.id,
              list.agents.allSatisfy({ $0.id.accountID == identity.accountID && $0.id.userID == identity.userID }),
              folder.lastPathComponent == Self.digest(account: identity.accountID, user: identity.userID) else { return nil }
        var reading = PersonalAgentReading(accountID: identity.accountID, userID: identity.userID, agents: list.agents)
        for agent in list.agents {
            if let data = try? Data(contentsOf: roomFile(agent.id.roomID, in: folder)),
               let room = try? JSONDecoder().decode(Room.self, from: data), room.version == 1 {
                reading.rooms[agent.id.roomID] = room.room
            }
            if let avatar = agent.avatar, let data = picture(avatarName(agent.id.agentID, avatar.version), in: folder) {
                reading.avatars[PersonalAgentReading.pictureKey(agentID: agent.id.agentID, version: avatar.version)] = data
            }
        }
        for (pet, version) in list.sheets {
            if let data = picture(sheetName(pet, version), in: folder) {
                reading.sheets[pet] = PersonalAgentSpriteSheet(data: data, version: version)
            }
        }
        return reading
    }

    func saveList(_ agents: [PersonalAgent], accountID: String, userID: String, source: String) {
        let digest = Self.digest(source)
        let target = directory.appending(path: Self.digest(account: accountID, user: userID), directoryHint: .isDirectory)
        // The source is now this account's alone; an account no source names any more is deleted.
        for (folder, var list) in lists() where folder.lastPathComponent != target.lastPathComponent && list.sources.contains(digest) {
            list.sources.removeAll { $0 == digest }
            if list.sources.isEmpty { remove(folder) } else { write(list, in: folder) }
        }
        var list = read(in: target) ?? List(sources: [], agents: [])
        if !list.sources.contains(digest) { list.sources.append(digest) }
        list.agents = agents
        let pets = Set(agents.compactMap(\.petID))
        list.sheets = list.sheets.filter { pets.contains($0.key) }
        guard prepare(target) else { return }
        write(list, in: target)
        prune(target, list: list)
    }

    func saveRoom(_ room: PersonalAgentReading.Room, of identity: PersonalAgentIdentity) {
        let folder = folder(of: identity)
        guard let list = read(in: folder), list.agents.contains(where: { $0.id == identity }),
              let data = try? JSONEncoder().encode(Room(room: room)), prepare(folder.appending(path: "rooms")) else { return }
        writeFile(data, to: roomFile(identity.roomID, in: folder))
    }

    func saveAvatar(_ data: Data, of agent: PersonalAgent) {
        let folder = folder(of: agent.id)
        guard data.count <= Self.avatarLimit, let avatar = agent.avatar, let list = read(in: folder),
              list.agents.contains(where: { $0.id == agent.id && $0.avatar?.version == avatar.version }) else { return }
        savePicture(data, named: avatarName(agent.id.agentID, avatar.version), in: folder)
    }

    func saveSheet(_ data: Data?, version: String, pet: String, of identity: PersonalAgentIdentity) {
        let folder = folder(of: identity)
        guard var list = read(in: folder), list.agents.contains(where: { $0.petID == pet }) else { return }
        if let data {
            guard data.count <= Self.sheetLimit else { return }
            savePicture(data, named: sheetName(pet, version), in: folder)
            list.sheets[pet] = version
        } else {
            list.sheets[pet] = nil
        }
        write(list, in: folder)
        prune(folder, list: list)
    }

    func forgetAll() {
        remove(directory)
        removeEmptyRoot()
    }

    func forget(source: String) {
        let digest = Self.digest(source)
        for (folder, list) in lists() where list.sources.contains(digest) { remove(folder) }
        removeEmptyRoot()
    }

    /// The root and the `Yardlet` folder above it go once nothing is kept in them.
    private func removeEmptyRoot() {
        rmdir(directory.path)
        rmdir(directory.deletingLastPathComponent().path)
    }

    // MARK: - Files

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(account: String, user: String) -> String { digest("account\u{0}" + account + "\u{0}" + user) }

    private func folder(of identity: PersonalAgentIdentity) -> URL {
        directory.appending(path: Self.digest(account: identity.accountID, user: identity.userID), directoryHint: .isDirectory)
    }

    private func roomFile(_ roomID: String, in folder: URL) -> URL {
        folder.appending(path: "rooms").appending(path: Self.digest("room\u{0}" + roomID) + ".json")
    }

    private func avatarName(_ agentID: String, _ version: String) -> String { Self.digest("avatar\u{0}" + agentID + "\u{0}" + version) }
    private func sheetName(_ pet: String, _ version: String) -> String { Self.digest("sheet\u{0}" + pet + "\u{0}" + version) }

    private func picture(_ name: String, in folder: URL) -> Data? {
        try? Data(contentsOf: folder.appending(path: "pictures").appending(path: name))
    }

    private func savePicture(_ data: Data, named name: String, in folder: URL) {
        let pictures = folder.appending(path: "pictures", directoryHint: .isDirectory)
        let file = pictures.appending(path: name)
        // A picture is named by its version: one already there is the same bytes.
        guard !FileManager.default.fileExists(atPath: file.path), prepare(pictures) else { return }
        writeFile(data, to: file)
    }

    /// Deletes the rooms and pictures the list no longer names.
    private func prune(_ folder: URL, list: List) {
        let rooms = Set(list.agents.map { roomFile($0.id.roomID, in: folder).lastPathComponent })
        var pictures = Set(list.agents.compactMap { agent in agent.avatar.map { avatarName(agent.id.agentID, $0.version) } })
        pictures.formUnion(list.sheets.map { sheetName($0.key, $0.value) })
        for (name, kept) in [("rooms", rooms), ("pictures", pictures)] {
            let child = folder.appending(path: name, directoryHint: .isDirectory)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? [] where !kept.contains(file) {
                unlink(child.appending(path: file).path)
            }
        }
    }

    private func lists() -> [(folder: URL, list: List)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            return read(in: folder).map { (folder, $0) }
        }
    }

    private func read(in folder: URL) -> List? {
        guard let data = try? Data(contentsOf: folder.appending(path: "list.json")),
              let list = try? JSONDecoder().decode(List.self, from: data), list.version == 1 else { return nil }
        return list
    }

    private func write(_ list: List, in folder: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        writeFile(data, to: folder.appending(path: "list.json"))
    }

    private func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Makes `folder` and the folders above it up to the root, each private to the user.
    private func prepare(_ folder: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var current = folder.standardizedFileURL
            let root = directory.standardizedFileURL.path
            while current.path.hasPrefix(root) {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
                if current.path == root { break }
                current = current.deletingLastPathComponent()
            }
            return true
        } catch {
            return false
        }
    }

    /// Writes through a private temporary file renamed into place, so a reader sees the old file or
    /// the new one, never half of one.
    private func writeFile(_ data: Data, to file: URL) {
        let temporary = file.deletingLastPathComponent().appending(path: "." + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == data.count, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return
        }
    }
}
