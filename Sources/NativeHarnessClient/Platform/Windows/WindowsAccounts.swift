import Foundation
import WinSDK

extension HarnessAccountBroker {
    /// The Antigravity CLI keeps its browser sign-in in Windows Credential Manager, through the keyring library it
    /// shares with the Mac's (`gemini` and `antigravity` there): a generic credential named `gemini:antigravity`.
    /// Only whether it exists is asked; its value is never read.
    static func antigravityCredentialState() -> AccountAuthState {
        switch WindowsCredential.exists("gemini:antigravity") {
        case true?: .signedIn
        case false?: .signedOut
        case nil: .unknown
        }
    }

    /// Claude Code on Windows keeps its login in `.credentials.json` in its config folder, for `AccountCheckLog`:
    /// whether the file is there, never what it holds.
    static func claudeCredentialItem(configDirectory: String?) -> String {
        let folder = configDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
        let file = folder.appending(path: ".credentials.json").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: file) ? "found" : "missing"
    }
}

extension WindowsCredential {
    /// Whether this user has the generic credential `target`; nil when Credential Manager cannot say. The call
    /// hands back the credential with its value, which is freed at once without being read.
    static func exists(_ target: String) -> Bool? {
        target.withCString(encodedAs: UTF16.self) { target in
            var credential: PCREDENTIALW?
            guard CredReadW(target, DWORD(CRED_TYPE_GENERIC), 0, &credential) else {
                return GetLastError() == DWORD(ERROR_NOT_FOUND) ? false : nil
            }
            if let credential { CredFree(credential) }
            return true
        }
    }
}
