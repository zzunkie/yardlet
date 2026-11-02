import Foundation

/// How a mail account's server is reached: TLS from the first byte (IMAP 993, SMTP 465), or a plain
/// connection the client upgrades with STARTTLS before it signs in (SMTP 587, a local bridge). A plain
/// connection that stays plain is never offered.
enum MailSocketSecurity: String, Codable, Hashable, Sendable {
    case tls
    case startTLS
}

/// A byte stream to a mail server, for the IMAP and SMTP clients. Each platform's layer provides one
/// (`Platform/macOS`); tests give scripted ones.
protocol MailSocket: AnyObject, Sendable {
    /// The next bytes the server sent, waiting for some; empty when the server closed the connection.
    func read() async throws -> Data
    func write(_ data: Data) async throws
    /// Upgrades the connection to TLS in place, after the server agreed to STARTTLS.
    func startTLS() async throws
    func close()
}

/// Opens connections to mail servers.
protocol MailSocketOpening: Sendable {
    /// A connection to `host`, already in TLS when `tls` is true. The server's certificate is checked
    /// against the host's name; a connection that fails the check is not opened.
    func open(host: String, port: Int, tls: Bool) async throws -> any MailSocket
}

/// Why a mail connection failed, in words a person can act on.
enum MailSocketFailure: Error, Equatable, LocalizedError {
    case unreachable(String)
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .unreachable(reason): reason
        case .closed: "The mail server closed the connection."
        case .timedOut: "The mail server did not answer in time."
        }
    }
}
