import Foundation
import MCP

let server = await PPTXMCPServer()
try await server.run()
