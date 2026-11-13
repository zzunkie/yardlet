import Foundation
import Glibc
import YardletRemote

/// The Linux host's remote keys (docs/LINUX_HOST.md, "Keys"): in the desktop's keyring, the Secret Service, when the
/// host runs in a session that has one unlocked, and otherwise in a file the person alone may read
/// (`RemoteFileIdentityStore`). A headless server usually has no keyring, and a systemd service starts at boot before
/// any keyring is unlocked, so a host started as a service keeps new keys in the file. Where the keys are does not
/// change once they exist: a key file is read first, and keys made in the keyring leave a marker beside the file
/// (`identity.keyring`, which holds no secret) so a keyring that cannot be read yet (still locked after a reboot) makes
/// the host wait for it rather than make new keys, which would unpair every device.
struct LinuxRemoteIdentityStore: RemoteIdentityStoring {
    struct KeyringUnavailable: Error, CustomStringConvertible {
        var reason: String
        var description: String { "The keys are in the keyring, which cannot be read now: \(reason)" }
    }

    let file: RemoteFileIdentityStore
    let marker: URL
    let keyring: LinuxSecretService?
    /// Whether new keys go to the keyring: not for a systemd service (`INVOCATION_ID`), which starts before any login.
    let keepsNewKeysInKeyring: Bool

    static let attributes = ["application": "com.zzunkie.yardlet", "item": "remote-identity"]

    static func live(folder: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        LinuxRemoteIdentityStore(
            file: RemoteFileIdentityStore(fileURL: folder.appending(path: "identity.json")),
            marker: folder.appending(path: "identity.keyring"),
            keyring: environment["DBUS_SESSION_BUS_ADDRESS"] == nil ? nil : LinuxSecretService.load(),
            keepsNewKeysInKeyring: environment["INVOCATION_ID"] == nil)
    }

    func load() throws -> RemoteIdentity? {
        if let identity = try file.load() { return identity }
        guard FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else { return nil }
        guard let keyring else { throw KeyringUnavailable(reason: "this session has no keyring (no D-Bus session or libsecret)") }
        switch keyring.lookup(Self.attributes) {
        case let .success(text?): return try RemoteIdentity(stored: Data(text.utf8))
        case .success(nil): throw KeyringUnavailable(reason: "the keyring no longer holds them")
        case let .failure(error): throw KeyringUnavailable(reason: error.message)
        }
    }

    func save(_ identity: RemoteIdentity) throws {
        if keepsNewKeysInKeyring, let keyring,
           case .success = keyring.store(Self.attributes, label: "Yardlet host remote keys",
                                         secret: String(decoding: identity.stored, as: UTF8.self)) {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data("The Yardlet host's remote keys are in the keyring (Secret Service).\n".utf8).write(to: marker)
            return
        }
        try file.save(identity)
    }

    /// Where the keys are, for the host's status.
    var place: String {
        FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
            && !FileManager.default.fileExists(atPath: file.fileURL.path(percentEncoded: false))
            ? "keyring" : "file"
    }
}

/// libsecret, loaded when the system has it (`libsecret-1.so.0`, with GLib), for one secret string under a set of
/// attributes in the default collection: the same calls `secret-tool` makes. Nothing links it, so a server without it
/// runs as before. The calls block, so they are made off the main thread (the remote's identity loader is an actor).
final class LinuxSecretService: @unchecked Sendable {
    struct Failure: Error {
        var message: String
    }

    private typealias HashTableNew = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> OpaquePointer?
    private typealias HashTableInsert = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias HashTableUnref = @convention(c) (OpaquePointer?) -> Void
    private typealias ErrorFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Lookup = @convention(c) (UnsafeRawPointer?, OpaquePointer?, UnsafeRawPointer?,
                                               UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutablePointer<CChar>?
    private typealias Store = @convention(c) (UnsafeRawPointer?, OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                              UnsafePointer<CChar>?, UnsafeRawPointer?,
                                              UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias PasswordFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let hashTableNew: HashTableNew
    private let hashTableInsert: HashTableInsert
    private let hashTableUnref: HashTableUnref
    private let errorFree: ErrorFree
    private let strHash: UnsafeRawPointer
    private let strEqual: UnsafeRawPointer
    private let lookupv: Lookup
    private let storev: Store
    private let passwordFree: PasswordFree

    private init?(secret: UnsafeMutableRawPointer, glib: UnsafeMutableRawPointer) {
        func symbol(_ library: UnsafeMutableRawPointer, _ name: String) -> UnsafeMutableRawPointer? { dlsym(library, name) }
        guard let hashTableNew = symbol(glib, "g_hash_table_new"), let hashTableInsert = symbol(glib, "g_hash_table_insert"),
              let hashTableUnref = symbol(glib, "g_hash_table_unref"), let errorFree = symbol(glib, "g_error_free"),
              let strHash = symbol(glib, "g_str_hash"), let strEqual = symbol(glib, "g_str_equal"),
              let lookupv = symbol(secret, "secret_password_lookupv_sync"),
              let storev = symbol(secret, "secret_password_storev_sync"),
              let passwordFree = symbol(secret, "secret_password_free") else { return nil }
        self.hashTableNew = unsafeBitCast(hashTableNew, to: HashTableNew.self)
        self.hashTableInsert = unsafeBitCast(hashTableInsert, to: HashTableInsert.self)
        self.hashTableUnref = unsafeBitCast(hashTableUnref, to: HashTableUnref.self)
        self.errorFree = unsafeBitCast(errorFree, to: ErrorFree.self)
        self.strHash = UnsafeRawPointer(strHash)
        self.strEqual = UnsafeRawPointer(strEqual)
        self.lookupv = unsafeBitCast(lookupv, to: Lookup.self)
        self.storev = unsafeBitCast(storev, to: Store.self)
        self.passwordFree = unsafeBitCast(passwordFree, to: PasswordFree.self)
    }

    /// libsecret and GLib, or nil when the system does not have them.
    static func load() -> LinuxSecretService? {
        guard let secret = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL),
              let glib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_LOCAL) else { return nil }
        return LinuxSecretService(secret: secret, glib: glib)
    }

    /// The secret stored under `attributes`, nil when there is none.
    func lookup(_ attributes: [String: String]) -> Result<String?, Failure> {
        withAttributes(attributes) { table in
            var error: UnsafeMutableRawPointer?
            let found = lookupv(nil, table, nil, &error)
            if let failure = take(error) { return .failure(failure) }
            guard let found else { return .success(nil) }
            defer { passwordFree(found) }
            return .success(String(cString: found))
        }
    }

    func store(_ attributes: [String: String], label: String, secret: String) -> Result<Void, Failure> {
        withAttributes(attributes) { table in
            var error: UnsafeMutableRawPointer?
            let stored = storev(nil, table, nil, label, secret, nil, &error)
            if let failure = take(error) { return .failure(failure) }
            return stored != 0 ? .success(()) : .failure(Failure(message: "the keyring did not store it"))
        }
    }

    /// A GLib string table of `attributes` for the call; the strings are the call's own until it returns.
    private func withAttributes<T>(_ attributes: [String: String], _ body: (OpaquePointer?) -> T) -> T {
        let strings = attributes.flatMap { [strdup($0.key), strdup($0.value)] }
        defer { strings.forEach { free($0) } }
        let table = hashTableNew(strHash, strEqual)
        defer { hashTableUnref(table) }
        for index in stride(from: 0, to: strings.count, by: 2) {
            _ = hashTableInsert(table, UnsafeMutableRawPointer(strings[index]), UnsafeMutableRawPointer(strings[index + 1]))
        }
        return body(table)
    }

    /// A GError's message (`struct GError { GQuark domain; gint code; gchar *message; }`), freed.
    private func take(_ error: UnsafeMutableRawPointer?) -> Failure? {
        guard let error else { return nil }
        defer { errorFree(error) }
        let message = error.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self).map { String(cString: $0) }
        return Failure(message: message ?? "the keyring refused")
    }
}
