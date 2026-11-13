import Foundation
import Glibc
import YardletAgentTools
import YardletRemote

/// What `yardlet host status`, `pair` and `project` ask the running host over its control socket
/// (`LinuxHostPaths.controlSocket`), one JSON request and its JSON reply per connection, through the same private
/// socket the Yardlet MCP server reaches the Mac app on (YardletAgentTools' `UnixSocketListener`): a folder of the
/// person's alone, and connections from another user dropped unread.
struct HostControlRequest: Codable, Equatable {
    enum Command: String, Codable {
        case status
        /// Opens a pairing for five minutes, as Settings › Remote's Pair does.
        case pair
        case cancelPairing
        case addProject
        case projects
        /// Starts signing in to `harness` (`LinuxHostSignIn`).
        case login
        case loginState
        case cancelLogin
        /// Reads `harness`'s login again, once a sign-in in the terminal has ended.
        case checkAccount
    }

    var command: Command
    /// The folder `addProject` adds.
    var path: String?
    /// The harness a sign-in is for, by its id or its command.
    var harness: String?
}

struct HostControlReply: Codable, Equatable {
    var error: String?
    var status: HostStatus?
    var pairing: HostStatus.Pairing?
    var projects: [HostStatus.Project]?
    var signIn: HostSignIn?

    static func failure(_ message: String) -> HostControlReply { HostControlReply(error: message) }
}

/// The running host as `yardlet host status` shows it.
struct HostStatus: Codable, Equatable {
    struct Remote: Codable, Equatable {
        var enabled: Bool
        /// Where the direct-path listener takes connections: `private` (loopback, private and Tailscale addresses) or
        /// `all`, which the person chose with `--every-address`.
        var listensOn: String
        /// Where the remote's keys are: `file` or `keyring`.
        var keys: String
        /// The keys could not be read yet (a keyring still locked), so the remote does not serve.
        var keysUnread: Bool
        /// The direct-path listener: `stopped`, `starting`, `ready` or `failed`.
        var direct: String
        var port: UInt16?
        var directFailure: String?
        /// The `host:port` addresses a pairing link names, in the order a device tries them.
        var addresses: [String]
        /// The relay: `off`, `connecting`, `connected` or `failed`, nil when no relay is configured.
        var relay: String?
        var relayFailure: String?
    }

    struct Device: Codable, Equatable {
        var name: String
        var platform: String?
        var connected: Bool
        /// How it is connected now: `local`, `tailscale`, `loopback` or `relay`.
        var path: String?
        var lastSeenAt: Date?
    }

    struct Harness: Codable, Equatable {
        var id: String
        var name: String
        /// The CLI new tasks start, nil when none was found.
        var runtime: String?
        /// Its login as Yardlet last read it: `signedIn`, `signedOut`, `actionRequired`, `unavailable` or `unknown`.
        var account: String?
    }

    struct Project: Codable, Equatable {
        var name: String
        var folder: String
    }

    struct Pairing: Codable, Equatable {
        /// The link and QR code's contents, nil while the remote cannot pair yet.
        var link: String?
        var expiresAt: Date?
        /// The device the last pairing added.
        var pairedDevice: String?
    }

    var version: String
    var processID: Int32
    var name: String
    var dataFolder: String
    var remote: Remote
    var devices: [Device]
    var harnesses: [Harness]
    var projects: [Project]
    var tasks: Int
    var runningTasks: Int
    var pairing: Pairing?
}

enum HostControlClient {
    enum Failure: Error, CustomStringConvertible {
        /// No host answers on the socket: it is not running.
        case notRunning
        case failed(String)

        var description: String {
            switch self {
            case .notRunning: "The Yardlet host is not running. Start it with `yardlet host start`, or as a service with `yardlet host service install`."
            case let .failed(message): message
            }
        }
    }

    static func send(_ request: HostControlRequest, timeout: TimeInterval = 30) throws -> HostControlReply {
        let body = try JSONEncoder.hostControl.encode(request)
        let data: Data
        do {
            data = try UnixDomainSocket.exchange(path: LinuxHostPaths.controlSocket(), request: body, timeout: timeout,
                                                 maximumReplyLength: 4 * 1024 * 1024)
        } catch let error as UnixSocketError where error.meansNothingIsListening {
            throw Failure.notRunning
        } catch {
            throw Failure.failed("The Yardlet host did not answer: \(error)")
        }
        let reply = try JSONDecoder.hostControl.decode(HostControlReply.self, from: data)
        if let error = reply.error { throw Failure.failed(error) }
        return reply
    }
}

extension JSONEncoder {
    static var hostControl: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var hostControl: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
