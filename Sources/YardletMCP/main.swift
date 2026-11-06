import Foundation
import YardletAgentTools

// yardlet-mcp: the Yardlet MCP server a harness starts over stdio when Yardlet injects it into a
// session. It lists Yardlet's tools and forwards each call to the running app, which acts on the
// calling task's browser tab. Everything it needs arrives in its environment.

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
let environment = ProcessInfo.processInfo.environment
let server = MCPServer(
    version: version,
    instructions: AgentToolCatalog.serverInstructions(services: AgentToolEnvironment.services(in: environment)),
    invoker: UnixSocketToolInvoker(environment: environment)
)
await MCPStdioLoop.run(server)
