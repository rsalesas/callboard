// The engine, as far as the MCP layer can tell (D54): something that hands
// over a catalogue, answers a call with an envelope, reads a resource,
// renders a prompt and says what changed. The tests give it a script.
//
// That the whole of the MCP layer can be driven by this — no socket, no
// project on disk, no GPU — is what the `EngineClient` seam is for.

import Foundation
import Testing
import CallboardJSON
@testable import CallboardMCP

actor FakeEngine: EngineClient {
    /// False is an engine that cannot answer yet: under PD1 that was "the
    /// app is not running", and under D54 it is whatever stops the engine
    /// in this process from coming up. Either way the host must not be the
    /// one to find out at `initialize`.
    var ready: Bool
    var envelopes: [String: JSON] = [:]
    var bodies: [String: JSON] = [:]
    private var updates: [String] = []
    private(set) var calls: [(name: String, arguments: JSON)] = []
    private(set) var prompts: [(name: String, arguments: JSON)] = []
    private(set) var drains = 0

    init(ready: Bool = true) { self.ready = ready }

    static let catalogue: JSON = [
        "server": ["name": "example", "version": "9.9"],
        "instructions": "Example is a shot-score server.",
        "tools": [["name": "place", "description": "Place a stand-in.",
                   "inputSchema": ["type": "object", "properties": ["kind": ["type": "string"]]],
                   "private": "not for a host"]],
        "resources": [["uri": "example://project", "name": "project",
                       "mimeType": "application/json", "description": "The project."],
                      ["uri": "example://script", "name": "script",
                       "mimeType": "text/markdown", "description": "The script."]],
        "prompts": [["name": "start_a_scene", "description": "Block a note.",
                     "arguments": [["name": "note", "description": "The note.", "required": true]]]],
    ]

    private static let absent = EngineError("the engine is not ready", hint: "ask again in a moment")

    func answer(_ name: String, with envelope: JSON) { envelopes[name] = envelope }
    func serve(_ uri: String, body: JSON) { bodies[uri] = body }
    func changed(_ uris: String...) { updates += uris }
    func becomeReady() { ready = true }
    var pendingUpdates: Int { updates.count }

    func catalogue() throws -> JSON {
        guard ready else { throw Self.absent }
        return Self.catalogue
    }

    func call(name: String, arguments: JSON) throws -> JSON {
        guard ready else { throw Self.absent }
        calls.append((name, arguments))
        return envelopes[name]
            ?? ["ok": false, "code": "E_UNKNOWN_ID", "error": .string("no tool \"\(name)\""), "hint": "call tools/list"]
    }

    func read(uri: String) throws -> JSON {
        guard ready else { throw Self.absent }
        guard let body = bodies[uri] else {
            throw EngineError("no resource \"\(uri)\"", code: "E_UNKNOWN_ID", hint: "available: example://project")
        }
        return body
    }

    func prompt(name: String, arguments: JSON) throws -> JSON {
        guard ready else { throw Self.absent }
        prompts.append((name, arguments))
        guard name == "start_a_scene" else {
            throw EngineError("no prompt \"\(name)\"", code: "E_UNKNOWN_ID", hint: "available: start_a_scene")
        }
        return ["text": .string("Block this: \(arguments["note"]?.stringValue ?? "")")]
    }

    func drainUpdates() -> [String] {
        drains += 1
        defer { updates = [] }
        return updates
    }
}

/// One request, written the way a host writes it.
func request(_ id: Int, _ method: String, _ params: JSON = [:]) -> String {
    (["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params] as JSON).stringified()
}

/// A server that has been through its handshake.
func initialisedServer(_ engine: FakeEngine) async -> MCPServer {
    let server = MCPServer(engine: engine)
    _ = await server.handle(line: request(0, "initialize", ["protocolVersion": "2025-06-18"]))
    return server
}

func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("example-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
