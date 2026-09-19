// `app/Helper`'s tests, brought over with the sources they test (N3). The
// names and the reasons are the old ones; what changed is what stands in
// for the engine — a `FakeEngine` rather than a socket nobody is listening
// on — and that a config file is an ordered `JSONObject` rather than a
// dictionary.

import Foundation
import Testing
import CallboardJSON
@testable import CallboardMCP

// The server edits another application's configuration file. That is the
// part most worth testing: everything in the file that is not ours has to
// survive, and a file we did not create has to be recoverable.

@Suite("MCP registration")
struct RegistrationTests {
    @Test("keeps every server and setting that is not ours")
    func preservesTheHostsFile() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("host.json")
        try Data(#"{"zebra":1,"mcpServers":{"theirs":{"command":"/bin/true"}},"theirSetting":42}"#.utf8)
            .write(to: config)

        let document = try MCPServerRegistration.read(config)
        let updated = MCPServerRegistration.installing(document, executablePath: "/bin/example", dev: false, product: example)
        try MCPServerRegistration.write(updated, to: config, product: example)

        let after = try MCPServerRegistration.read(config)
        let servers = try #require(after["mcpServers"]?.objectValue)
        #expect(servers["theirs"] != nil)
        #expect(servers["example"] != nil)
        #expect(after["theirSetting"]?.numberValue == 42)
        // And in the order its owner had them. The old helper wrote with
        // `.sortedKeys`, which handed a host its own file back rearranged.
        #expect(after.keys == ["zebra", "mcpServers", "theirSetting"])
        #expect(servers.keys == ["theirs", "example"])
    }

    @Test("leaves a one-time backup of a file it did not create")
    func backsUpOnce() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("host.json")
        try Data(#"{"original":true}"#.utf8).write(to: config)

        try MCPServerRegistration.write(
            MCPServerRegistration.installing(try MCPServerRegistration.read(config),
                                             executablePath: "/bin/a", dev: false, product: example), to: config, product: example)
        let backup = config.appendingPathExtension("example-backup")
        let first = try Data(contentsOf: backup)
        #expect(String(decoding: first, as: UTF8.self).contains("original"))

        // A second install must not overwrite the backup with our own
        // output — that would lose the one copy of what was there before.
        try MCPServerRegistration.write(
            MCPServerRegistration.installing(try MCPServerRegistration.read(config),
                                             executablePath: "/bin/b", dev: false, product: example), to: config, product: example)
        #expect(try Data(contentsOf: backup) == first)
    }

    @Test("refuses to overwrite a file that is not a JSON object")
    func refusesGarbage() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("host.json")
        try Data("this is not json".utf8).write(to: config)
        #expect(throws: MCPConfigError.self) { try MCPServerRegistration.read(config) }
        // Valid JSON that is not an object is no more ours to replace.
        try Data("[1, 2, 3]".utf8).write(to: config)
        #expect(throws: MCPConfigError.self) { try MCPServerRegistration.read(config) }
    }

    @Test("an absent file reads as empty rather than failing")
    func absentIsEmpty() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try MCPServerRegistration.read(dir.appendingPathComponent("nope.json")).isEmpty)
    }

    @Test("reports where it is registered, and where it points somewhere else")
    func reportsStatus() throws {
        var document = JSONObject()
        #expect(MCPServerRegistration.status(in: document, executablePath: "/bin/a", product: example) == .notRegistered)

        document = MCPServerRegistration.installing(document, executablePath: "/bin/a", dev: false, product: example)
        #expect(MCPServerRegistration.status(in: document, executablePath: "/bin/a", product: example) == .registered)
        #expect(MCPServerRegistration.status(in: document, executablePath: "/bin/b", product: example)
                == .registeredElsewhere("/bin/a"))

        document = MCPServerRegistration.removing(document, product: example)
        #expect(MCPServerRegistration.status(in: document, executablePath: "/bin/a", product: example) == .notRegistered)
    }

    @Test("--dev points the server at a socket, and a normal install does not")
    func devEntry() {
        let plain = MCPServerRegistration.entry(executablePath: "/bin/example", dev: false, product: example)
        #expect(plain["env"] == nil)
        #expect(plain["command"]?.stringValue == "/bin/example")
        #expect(plain["args"] == [])
        let dev = MCPServerRegistration.entry(executablePath: "/bin/example", dev: true, product: example)
        #expect(dev["env"]?["EXAMPLE_DEV"]?.stringValue == "1")
        #expect(dev["env"]?["EXAMPLE_SOCKET"]?.stringValue != nil)
    }
}

@Suite("MCP protocol")
struct ProtocolTests {
    /// No engine: the handshake must still succeed. A host that gets an
    /// error from initialize gives up on the server entirely rather than
    /// retrying, so "the engine is not ready yet" has to be a fact the
    /// first tool call reports, not a failed handshake.
    @Test("answers initialize and ping with no engine ready")
    func handshakeWithoutEngine() async throws {
        let engine = FakeEngine(ready: false)
        // With no catalogue to say otherwise, serverInfo is what the product passed in.
        let server = MCPServer(engine: engine, name: example.command, version: "1.0")
        let initialize = try #require(await server.handle(line:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let result = try #require(initialize["result"])
        #expect(result["protocolVersion"]?.stringValue == "2025-06-18")
        for capability in ["tools", "resources", "prompts", "logging"] {
            #expect(result["capabilities"]?[capability] != nil, "missing capability \(capability)")
        }
        #expect(result["capabilities"]?["resources"]?["subscribe"] == true)
        #expect(result["instructions"]?.stringValue == "")
        #expect(result["serverInfo"]?["name"]?.stringValue == "example")
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)?["result"] == [:])

        // And the first real call says why, as a result the model can read.
        let call = try #require(await server.handle(line: request(3, "tools/call", ["name": "place"])))
        #expect(call["result"]?["isError"] == true)
        #expect(call["result"]?["content"]?[0]?["text"]?.stringValue?.contains("not ready") == true)

        // An engine that arrives later is found by the next request that
        // needs it: the failure to fetch a catalogue was not remembered.
        await engine.becomeReady()
        let tools = try #require(await server.handle(line: request(4, "tools/list")))
        #expect(tools["result"]?["tools"]?[0]?["name"]?.stringValue == "place")
    }

    @Test("falls back to its own version when the client asks for one it does not know")
    func unknownProtocolVersion() async throws {
        let server = MCPServer(engine: FakeEngine(ready: false))
        let reply = try #require(await server.handle(line:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(reply["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    }

    @Test("agrees to an older version it knows, rather than insisting on the newest")
    func olderProtocolVersion() async throws {
        let server = MCPServer(engine: FakeEngine())
        let reply = try #require(await server.handle(line:
            request(1, "initialize", ["protocolVersion": "2024-11-05"])))
        #expect(reply["result"]?["protocolVersion"]?.stringValue == "2024-11-05")
    }

    @Test("answers nothing to a notification")
    func notificationsGetNoReply() async {
        let server = MCPServer(engine: FakeEngine(ready: false))
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("reports a parse error rather than dying on a malformed line")
    func malformedLine() async throws {
        let server = MCPServer(engine: FakeEngine(ready: false))
        let reply = try #require(await server.handle(line: "{not json"))
        #expect(reply["error"]?["code"]?.numberValue == -32700)
        #expect(reply["id"] == .null)
    }

    @Test("refuses an unsupported method by name")
    func unsupportedMethod() async throws {
        let server = MCPServer(engine: FakeEngine(ready: false))
        let reply = try #require(await server.handle(line:
            #"{"jsonrpc":"2.0","id":9,"method":"sampling/createMessage"}"#))
        #expect(reply["error"]?["code"]?.numberValue == -32601)
        #expect(reply["error"]?["message"]?.stringValue?.contains("sampling/createMessage") == true)
    }

    @Test("gives an id back as it came, a string as much as a number")
    func echoesTheID() async throws {
        let server = MCPServer(engine: FakeEngine())
        let reply = try #require(await server.handle(line: #"{"jsonrpc":"2.0","id":"req-7","method":"ping"}"#))
        #expect(reply["id"]?.stringValue == "req-7")
        #expect(reply.stringified() == #"{"jsonrpc":"2.0","id":"req-7","result":{}}"#)
    }
}

@Suite("Catalogue")
struct CatalogueTests {
    /// The server knows no tool by name (PD1): everything it publishes
    /// comes out of this reply.
    @Test("serves tools, resources and prompts out of what the engine sent")
    func decodesWhatTheEngineSends() {
        let catalogue = Catalogue([
            "instructions": "Example is a shot-score server.",
            "tools": [["name": "place", "description": "Place a stand-in.",
                       "inputSchema": ["type": "object"]]],
            "resources": [["uri": "example://project", "name": "project",
                           "mimeType": "application/json", "description": "The project."]],
            "prompts": [["name": "start_a_scene", "description": "Block a note.", "arguments": []]],
        ])
        #expect(catalogue.instructions.contains("shot-score"))
        #expect(catalogue.tools.first?["name"]?.stringValue == "place")
        #expect(catalogue.resources.first?["uri"]?.stringValue == "example://project")
        #expect(catalogue.prompts.first?["name"]?.stringValue == "start_a_scene")
        #expect(catalogue.mimeType(for: "example://project") == "application/json")
        #expect(catalogue.mimeType(for: "example://unknown") == "application/json")
    }

    @Test("tools/list, resources/list and prompts/list are the catalogue, and nothing the server made up")
    func listingsComeFromTheCatalogue() async throws {
        let server = await initialisedServer(FakeEngine())

        let tools = try #require(await server.handle(line: request(1, "tools/list"))?["result"]?["tools"]?.arrayValue)
        #expect(tools.count == 1)
        // MCP's three keys, in MCP's order; the engine's private one goes no
        // further than this.
        #expect(tools[0].objectValue?.keys == ["name", "description", "inputSchema"])
        #expect(tools[0]["inputSchema"] == FakeEngine.catalogue["tools"]?[0]?["inputSchema"])

        let resources = try #require(
            await server.handle(line: request(2, "resources/list"))?["result"]?["resources"]?.arrayValue)
        #expect(resources.map { $0["uri"]?.stringValue } == ["example://project", "example://script"])
        #expect(resources[1]["mimeType"]?.stringValue == "text/markdown")

        let prompts = try #require(
            await server.handle(line: request(3, "prompts/list"))?["result"]?["prompts"]?.arrayValue)
        #expect(prompts[0]["name"]?.stringValue == "start_a_scene")
        #expect(prompts[0]["arguments"]?[0]?["required"] == true)

        let templates = try #require(await server.handle(line: request(4, "resources/templates/list")))
        #expect(templates["result"]?["resourceTemplates"] == [])
    }

    @Test("initialize carries the engine's instructions and its name for itself")
    func initializeQuotesTheEngine() async throws {
        let server = MCPServer(engine: FakeEngine())
        let reply = try #require(await server.handle(line:
            request(1, "initialize", ["protocolVersion": "2025-06-18"])))
        #expect(reply["result"]?["instructions"]?.stringValue == "Example is a shot-score server.")
        #expect(reply["result"]?["serverInfo"] == ["name": "example", "version": "9.9"])
    }

    @Test("a listing with no engine behind it is an error that says why")
    func listingWithoutEngine() async throws {
        let server = MCPServer(engine: FakeEngine(ready: false))
        let reply = try #require(await server.handle(line: request(1, "tools/list")))
        #expect(reply["error"]?["code"]?.numberValue == -32603)
        #expect(reply["error"]?["message"]?.stringValue == "the engine is not ready — ask again in a moment")
    }
}
