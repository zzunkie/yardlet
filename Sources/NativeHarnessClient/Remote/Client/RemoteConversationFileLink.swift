import Foundation

/// A task-relative host file. It can only be resolved by the remote window, never by this Mac's file APIs.
enum RemoteConversationFileLink {
    static func url(_ path: String) -> URL? {
        guard valid(path) else { return nil }
        var components = URLComponents()
        components.scheme = "yardlet-remote-file"
        components.path = "/" + path
        return components.url
    }

    static func path(_ url: URL) -> String? {
        guard url.scheme == "yardlet-remote-file", url.host == nil else { return nil }
        let path = String(url.path(percentEncoded: false).dropFirst())
        return valid(path) ? path : nil
    }

    private static func valid(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\0")
    }
}
