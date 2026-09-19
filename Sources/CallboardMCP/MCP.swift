// MCP over stdio: what a host speaks to a product's server.
//
// Hand-rolled newline-delimited JSON-RPC 2.0, as it was when this was a
// helper that forwarded every call to an app (PD1). It still knows no tool
// by name — the catalogue is data it is handed — but what hands it over is
// now the engine in the same process, not a socket to another one (D54).
//
// The target, file by file:
//
//   EngineClient     the one seam: what the MCP layer needs from an engine
//   Catalogue        tools/list, resources/list and prompts/list, as data
//   MCPServer        JSON-RPC in, JSON-RPC out, against an EngineClient
//   StdioTransport   a line in, a line out, and nothing else on stdout
//   RemoteEngine     an EngineClient over a running server's local channel
//   MCPInstall       `<command> mcp install|uninstall|status`, for a product

import Foundation
import CallboardTransport

/// The protocol versions this server will agree to, preferred first.
public let MCP_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

/// stdout carries protocol traffic and nothing else. Anything a person might
/// want to read goes to stderr, and only when asked for: a host shows a
/// server's stderr as that server misbehaving. See `Diagnostics`.
public func diagnostic(_ message: @autoclosure () -> String) { Diagnostics.say(message()) }
