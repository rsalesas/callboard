// What the engine hands over when asked (PD1). The server answers
// tools/list, resources/list and prompts/list out of this and knows no tool
// by name — adding a tool touches the engine only. That was the rule when
// the engine was in another process and it is still the rule now that it is
// not (D54): the day the MCP layer learns a tool's name is the day a tool
// can be added in one place and forgotten in the other.

import CallboardJSON

public struct Catalogue: Sendable, Equatable {
    /// `{name, version}` as the engine gives it, if it gave one.
    public let server: JSON?
    public let instructions: String
    public let tools: [JSON]
    public let resources: [JSON]
    public let prompts: [JSON]
    private let mimeTypes: [String: String]

    /// Each entry is rebuilt rather than passed through: MCP's listings
    /// have a shape, a host may be strict about it, and an engine that one
    /// day carries a private field beside `inputSchema` should not publish
    /// it by accident. The keys go out in MCP's customary order; what is
    /// *inside* a schema keeps the order the engine wrote it in.
    public init(_ raw: JSON) {
        server = raw["server"]?.objectValue == nil ? nil : raw["server"]
        instructions = raw["instructions"]?.stringValue ?? ""

        tools = (raw["tools"]?.arrayValue ?? []).map { tool in
            ["name": tool["name"] ?? "",
             "description": tool["description"] ?? "",
             "inputSchema": tool["inputSchema"] ?? ["type": "object"]]
        }
        let listed = raw["resources"]?.arrayValue ?? []
        resources = listed.map { resource in
            ["uri": resource["uri"] ?? "",
             "name": resource["name"] ?? "",
             "mimeType": resource["mimeType"] ?? "application/json",
             "description": resource["description"] ?? ""]
        }
        var types: [String: String] = [:]
        for resource in listed {
            guard let uri = resource["uri"]?.stringValue else { continue }
            types[uri] = resource["mimeType"]?.stringValue ?? "application/json"
        }
        mimeTypes = types
        prompts = (raw["prompts"]?.arrayValue ?? []).map { prompt in
            ["name": prompt["name"] ?? "",
             "description": prompt["description"] ?? "",
             "arguments": prompt["arguments"] ?? []]
        }
    }

    public func mimeType(for uri: String) -> String { mimeTypes[uri] ?? "application/json" }
}
