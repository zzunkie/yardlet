import Foundation

/// Where the host keeps tasks' own request contexts (docs/BROWSER_SESSION_ISOLATION.md): one folder per
/// profile key, `<root cache>/Task-<key>`, next to the default profile. Chromium opens a profile on disk
/// only in a direct child of the root cache and otherwise falls back to one in memory ("Cannot create
/// profile at path"), which loses the task's sign-ins when the host ends. The app names the key; a key is
/// a task's (or draft's) UUID, so nothing the app sends can point elsewhere.
struct TaskProfiles {
    let rootCache: String
    let defaultProfile: String

    /// A tab's context as the app asked for it: the folder, and for a new one the folder whose cookies it starts with
    /// before the tab's page loads (empty for the default profile). Nil for the default context.
    struct Prepared {
        var path: String
        var seed: String?
    }

    /// The folder for a key; the default profile for nil or a key that is not one.
    func path(forKey key: String?) -> String {
        guard let key, (1...64).contains(key.count),
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return "" }
        return rootCache + "/Task-" + key
    }

    /// Makes a profile folder ready before its context opens. A new one takes the Touch ID passkeys' metadata key of
    /// the default profile into its preferences, so passkeys made with Touch ID work in every task, and starts with
    /// the cookies of the profile it seeds from (the named one when it exists, else the default profile).
    func prepare(_ profile: [String: Any]?) -> Prepared? {
        guard let key = profile?["key"] as? String else { return nil }
        let path = path(forKey: key)
        guard !path.isEmpty else { return nil }
        var prepared = Prepared(path: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            copyPasskeyMetadataKey(to: path)
            let named = self.path(forKey: profile?["seedFrom"] as? String)
            prepared.seed = !named.isEmpty && FileManager.default.fileExists(atPath: named) ? named : ""
        }
        return prepared
    }

    /// Chromium keeps the key that reads its Touch ID passkeys' metadata in each profile's preferences
    /// (`webauthn.touchid.metadata_secret`); a profile with another key does not see them.
    private func copyPasskeyMetadataKey(to folder: String) {
        guard let data = FileManager.default.contents(atPath: defaultProfile + "/Preferences"),
              let preferences = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webauthn = preferences["webauthn"] as? [String: Any],
              let touchID = webauthn["touchid"] as? [String: Any],
              let secret = touchID["metadata_secret"] as? String else { return }
        let seeded: [String: Any] = ["webauthn": ["touchid": ["metadata_secret": secret]]]
        guard let output = try? JSONSerialization.data(withJSONObject: seeded) else { return }
        FileManager.default.createFile(atPath: folder + "/Preferences", contents: output,
                                       attributes: [.posixPermissions: 0o600])
    }
}
