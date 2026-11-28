import Foundation
import YardletAgentTools

/// Only these endpoints may receive a Workspace account's bearer token. Persist the endpoint
/// identifier beside the discovered tool so a cached Drive tool still reaches its own API.
enum GoogleWorkspaceEndpoint: String, Codable, Sendable {
    case gmail, calendar, drive, docs, sheets, slides

    var url: URL { URL(string: "https://\(rawValue)mcp.googleapis.com/mcp/v1")! }

    struct Listing: Sendable {
        var endpoint: GoogleWorkspaceEndpoint
        var result: Result<[ToolJSON], Error>
    }

    static func mayUseCachedTools(after error: Error) -> Bool {
        if error is URLError { return true }
        if case MCPHTTPError.http(let status, _) = error { return status == 408 || (500..<600).contains(status) }
        if case GoogleWorkspaceMCPError.quota = error { return true }
        return false
    }

    static func discover(_ endpoints: [Self], session: OAuthAPISession,
                         transport: any ConnectorHTTPTransport) async throws -> [Listing] {
        let token = try await session.accessToken()
        return await withTaskGroup(of: Listing.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let client = GoogleWorkspaceMCPClient(endpoint: endpoint.url, transport: transport)
                    do {
                        let tools = try await client.listTools(token: token) { rejected in
                            try await session.refreshedAccessToken(replacing: rejected)
                        }
                        return Listing(endpoint: endpoint, result: .success(tools))
                    } catch {
                        return Listing(endpoint: endpoint, result: .failure(error))
                    }
                }
            }
            var listings: [Listing] = []
            for await listing in group { listings.append(listing) }
            return endpoints.compactMap { endpoint in listings.first { $0.endpoint == endpoint } }
        }
    }
}

extension LocalConnectorService {
    var workspaceEndpoints: [GoogleWorkspaceEndpoint] {
        switch self {
        case .gmail: [.gmail]
        case .googleCalendar: [.calendar]
        case .googleDrive: [.drive, .docs, .sheets, .slides]
        default: []
        }
    }

    var usesWorkspaceMCP: Bool { !workspaceEndpoints.isEmpty }
}
