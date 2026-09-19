import Testing
@testable import CallboardMCP

@Suite("MCP") struct MCPSkeletonTests {
    @Test("prefers the newest protocol version") func versions() { #expect(MCP_PROTOCOL_VERSIONS.first == "2025-06-18") }
}
