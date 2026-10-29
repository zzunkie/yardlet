import Foundation

/// Only the provider API receives an account credential. Signed file downloads
/// use a separate, credential-free request, including on another provider host.
struct DotsAttachmentLocation {
    let url: URL
    let authenticated: Bool

    init(_ raw: String) throws {
        let normalized = raw.hasPrefix("/estuary/") || raw.hasPrefix("/files/") ? "/backend-api" + raw : raw
        guard let value = URL(string: normalized, relativeTo: URL(string: "https://chatgpt.com"))?.absoluteURL,
              value.scheme == "https", value.user == nil, value.password == nil,
              value.port == nil || value.port == 443, let host = value.host?.lowercased() else {
            throw PersonalAgentFailure.attachmentUnavailable
        }
        if host == "chatgpt.com", value.path.hasPrefix("/backend-api/estuary/") || value.path.hasPrefix("/backend-api/files/") {
            authenticated = true
        } else if host == "files.oaiusercontent.com" || host.hasSuffix(".oaiusercontent.com")
                    || host.hasSuffix(".blob.core.windows.net") || host == "cdn.openai.com" {
            // The provider's own pets' sheets are public files on its CDN; that exact host, no other.
            authenticated = false
        } else { throw PersonalAgentFailure.attachmentUnavailable }
        url = value
    }
}
