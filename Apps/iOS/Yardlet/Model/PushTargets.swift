import Foundation
import YardletRemote

/// The push target each Mac's relay gave this phone (docs/REMOTE_PROTOCOL.md §14.5). The phone binds its APNs token to
/// the Mac's room on every connection and gives the Mac only the target, so removing the Mac here ends the target on
/// the relay too. A removal the relay did not take is tried again each time the app comes to the front.
///
/// A new target comes in a background push to this phone's token, and the phone takes it only while it registers in
/// that room itself: one sent because someone else registered the token elsewhere is ignored. The token goes only to
/// the relay this build is made for, which holds the app's APNs key, and only for a Mac on that relay: a Mac names its
/// relay itself, and no other relay could push to this app anyway.
@MainActor
enum PushTargets {
    struct Entry: Codable, Equatable {
        var relay: URL
        var room: String
        var target: String
    }

    private static let savedKey = "pushTargets"
    private static let removalsKey = "pushTargetRemovals"
    private static var isRemoving = false
    /// The rooms this phone registers in now, a target that came for one before it was waited for, and those waiting.
    private static var registering: Set<String> = []
    private static var arrived: [String: String] = [:]
    private static var waiting: [String: (id: UUID, continuation: CheckedContinuation<String?, Never>)] = [:]
    /// How often each Mac was removed while the app ran, so a registration still under way then keeps nothing.
    private static var removedCount: [String: Int] = [:]

    /// This build's relay, when `host` uses it.
    static func relay(for host: RemoteSavedHost) -> URL? {
        guard let relay = PhoneAccount.configuredRelay, let named = host.relayURL.flatMap(URL.init(string:)),
              relay.host()?.lowercased() == named.host()?.lowercased(), relay.port == named.port else { return nil }
        return relay
    }

    /// Binds `token` to the Mac's room and keeps the target the relay answers; nil when the relay did not take it. A
    /// target kept before for the Mac that differs (another token, room or relay) is ended, and so is the new one when
    /// the Mac was removed meanwhile: a removal after a registration began wins over it.
    static func register(provider: String, token: String, relay: URL, room: String, hostID: String) async -> String? {
        let removedBefore = removedCount[hostID, default: 0]
        var saved = read([String: Entry].self, savedKey) ?? [:]
        let held = saved[hostID].flatMap { $0.relay == relay && $0.room == room ? $0.target : nil }
        registering.insert(room)
        arrived[room] = nil
        defer { registering.remove(room) }
        let answered: String?
        do {
            answered = try await RemoteAccountClient(baseURL: relay)
                .registerPushTarget(room: room, provider: provider, token: token, held: held)
        } catch {
            return nil
        }
        // No target in the answer: it comes to this phone's token in a push.
        let sent = answered == nil ? await arrival(in: room) : nil
        guard let target = answered ?? sent else { return nil }
        let entry = Entry(relay: relay, room: room, target: target)
        guard removedCount[hostID, default: 0] == removedBefore else {
            write((read([Entry].self, removalsKey) ?? []) + [entry], removalsKey)
            removeWaiting()
            return nil
        }
        saved = read([String: Entry].self, savedKey) ?? [:]
        let earlier = saved.updateValue(entry, forKey: hostID)
        write(saved, savedKey)
        // A removal still waiting for this target would end it under the Mac now holding it.
        var removals = (read([Entry].self, removalsKey) ?? []).filter { $0 != entry }
        if let earlier, earlier != entry { removals.append(earlier) }
        write(removals, removalsKey)
        removeWaiting()
        return target
    }

    /// A background push holding a target the relay sent for `room` (§14.5), taken only while this phone registers there.
    static func received(target: String, room: String) {
        guard registering.contains(room) else { return }
        if let waiter = waiting.removeValue(forKey: room) {
            waiter.continuation.resume(returning: target)
        } else {
            arrived[room] = target
        }
    }

    /// The target the relay sends for `room`, waited for half a minute.
    private static func arrival(in room: String) async -> String? {
        if let target = arrived.removeValue(forKey: room) { return target }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiting[room] = (id, continuation)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard waiting[room]?.id == id else { return }
                waiting.removeValue(forKey: room)?.continuation.resume(returning: nil)
            }
        }
    }

    /// Ends the Mac's target on its relay, now or once the relay can be reached.
    static func remove(hostID: String) {
        removedCount[hostID, default: 0] += 1
        var saved = read([String: Entry].self, savedKey) ?? [:]
        guard let entry = saved.removeValue(forKey: hostID) else { return }
        write(saved, savedKey)
        write((read([Entry].self, removalsKey) ?? []) + [entry], removalsKey)
        removeWaiting()
    }

    /// Tries the removals the relay has not taken yet.
    static func removeWaiting() {
        let waiting = read([Entry].self, removalsKey) ?? []
        guard !waiting.isEmpty, !isRemoving else { return }
        isRemoving = true
        Task {
            var done: [Entry] = []
            for entry in waiting {
                do {
                    try await RemoteAccountClient(baseURL: entry.relay).removePushTarget(room: entry.room, target: entry.target)
                    done.append(entry)
                } catch let failure as RemoteAccountClient.Failure where failure.status == 400 || failure.status == 404 {
                    // Refused as it is, or a relay without targets: trying again would end the same way.
                    done.append(entry)
                } catch {}
            }
            // Removals asked for meanwhile stay, and are tried next time.
            write((read([Entry].self, removalsKey) ?? []).filter { !done.contains($0) }, removalsKey)
            isRemoving = false
        }
    }

    private static func read<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write(_ value: some Encodable, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
