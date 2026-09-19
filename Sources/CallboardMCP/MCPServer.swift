// A Model Context Protocol server — newline-delimited JSON-RPC 2.0 (§10.1,
// D9). Cloned from Vaelora's proven implementation and extended with what
// §10 needs that Vaelora did not have: resources, resource subscriptions,
// prompts, logging, and notifications.
//
// Hand-rolled rather than taken from an SDK, per PD1 and PD13: Vaelora's
// version is already in service against the same hosts, and `kit` has no
// dependencies. When this was written it was a bridge with no engine in it;
// D54 moved the engine into the same process, and the one thing that
// changed here is what the server is handed — an `EngineClient` rather than
// a connection to an app. It still knows no tool by name. Swapping in the
// official Swift MCP SDK later is a change inside this file.
//
// This file does not touch stdout. It turns one line into at most one
// reply, and says which notifications are owed; `StdioTransport` owns the
// pipe. That is what lets every behaviour below be tested without one.
//
// Everything is `CallboardJSON`, not `JSONSerialization` (PD14): an
// envelope's keys reach the host in the order the engine wrote them, and a
// reply is `JSON.stringify`'s compact form, which has no raw newline in it.
// One consequence worth knowing: a JSON-RPC id is a `Double` on its way
// through, so an integer id above 2⁵³ would not come back as it went in.
// Hosts count from zero or send strings.

import CallboardJSON

public actor MCPServer {
    private let engine: any EngineClient
    private var catalogue: Catalogue?
    /// URIs a client has asked to be told about. MCP wants a subscription
    /// per resource; the engine tells us about all of them, so this is the
    /// filter rather than anything the engine needs to know.
    private var subscribed = Set<String>()
    private var initialised = false

    private let name: String
    private let version: String

    /// - Parameters:
    ///   - name, version: what `serverInfo` says when the engine's catalogue
    ///     does not say otherwise — typically the product's command and version.
    public init(engine: any EngineClient, name: String = "mcp-server", version: String = "0") {
        self.engine = engine
        self.name = name
        self.version = version
    }

    /// Whether anybody is waiting to hear about a change — which is the
    /// only time it is worth asking the engine while the host is quiet.
    public var hasSubscriptions: Bool { initialised && !subscribed.isEmpty }

    /// Handles one line. Returns the reply, or nil for a notification —
    /// which must never be answered.
    ///
    /// An actor is re-entrant across an `await`, and the engine is awaited
    /// below; what keeps requests one at a time is the transport, which
    /// does not read the next line until this returns. A host's stdio
    /// transport is one pipe, and serialising keeps replies in order.
    public func handle(line: String) async -> JSON? {
        guard let message = try? JSON.parse(line), message.objectValue != nil else {
            return ["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "parse error"]]
        }
        guard let method = message["method"]?.stringValue else { return nil }
        let params = message["params"]?.objectValue == nil ? JSON.object(JSONObject()) : message["params"]!
        diagnostic("← \(method)")

        guard let id = message["id"], !id.isNull else {
            // Notifications. `initialized` is the only one that means
            // anything to us, and it means "carry on".
            return nil
        }

        switch method {
        case "initialize":   return await handleInitialize(id: id, params: params)
        case "ping":         return reply(id: id, result: [:])
        case "tools/list":   return await listing(id: id, key: "tools") { $0.tools }
        case "tools/call":   return await callTool(id: id, params: params)
        case "resources/list": return await listing(id: id, key: "resources") { $0.resources }
        case "resources/templates/list": return reply(id: id, result: ["resourceTemplates": []])
        case "resources/read": return await readResource(id: id, params: params)
        case "resources/subscribe":
            if let uri = params["uri"]?.stringValue { subscribed.insert(uri) }
            return reply(id: id, result: [:])
        case "resources/unsubscribe":
            if let uri = params["uri"]?.stringValue { subscribed.remove(uri) }
            return reply(id: id, result: [:])
        case "prompts/list": return await listing(id: id, key: "prompts") { $0.prompts }
        case "prompts/get":  return await getPrompt(id: id, params: params)
        case "logging/setLevel": return reply(id: id, result: [:])
        default:
            return reply(id: id, code: -32601, message: "method '\(method)' is not supported")
        }
    }

    // MARK: - Handshake

    private func handleInitialize(id: JSON, params: JSON) async -> JSON {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = MCP_PROTOCOL_VERSIONS.contains(requested) ? requested : MCP_PROTOCOL_VERSIONS[0]
        initialised = true

        // The instructions come from the engine, not from here (PD1): the
        // MCP layer knows no tool by name, and §10.2's text lives with the
        // vocabulary it quotes. If the engine cannot answer yet, answer the
        // handshake anyway and ask again on the first real call — refusing
        // to initialize would make the host give up on the server entirely.
        let catalogue = try? await loadCatalogue()
        let server: JSON = catalogue?.server
            ?? ["name": .string(name), "version": .string(self.version)]
        return reply(id: id, result: [
            "protocolVersion": .string(version),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["subscribe": true, "listChanged": false],
                "prompts": ["listChanged": false],
                "logging": [:],
            ],
            "serverInfo": server,
            "instructions": .string(catalogue?.instructions ?? ""),
        ])
    }

    // MARK: - Catalogue-driven listings

    /// Asked for once and kept: what a server offers is decided by what it
    /// was started with (Q15), which is why every capability above says
    /// `listChanged: false`. A failure is *not* kept, so the next request
    /// asks again.
    private func loadCatalogue() async throws -> Catalogue {
        if let catalogue { return catalogue }
        let loaded = Catalogue(try await engine.catalogue())
        catalogue = loaded
        return loaded
    }

    private func listing(id: JSON, key: String, _ pick: (Catalogue) -> [JSON]) async -> JSON {
        do { return reply(id: id, result: .object(JSONObject([(key, .array(pick(try await loadCatalogue())))]))) }
        catch let error as EngineError {
            // A readable message beats an empty list here: the host shows
            // the server as broken either way, and this way the reason is
            // in the transcript.
            diagnostic("catalogue unavailable: \(error.description)")
            return reply(id: id, code: -32603, message: error.sentence)
        } catch {
            return reply(id: id, code: -32603, message: "\(error)")
        }
    }

    // MARK: - Tools

    private func callTool(id: JSON, params: JSON) async -> JSON {
        guard let name = params["name"]?.stringValue else {
            return reply(id: id, code: -32602, message: "missing tool name")
        }
        // Passed through untouched when it is an object; validation is the
        // engine's, which is what keeps "forwards unchanged" true for the
        // part that matters.
        let arguments = params["arguments"]?.objectValue == nil ? JSON.object(JSONObject()) : params["arguments"]!
        do {
            let envelope = try await engine.call(name: name, arguments: arguments)
            // §10.4: a refusal is a result the model can read and act on,
            // not a JSON-RPC error. The envelope goes through as it came —
            // the MCP layer "never rewrites them" (PD1) — and `isError` is
            // read off it rather than decided here.
            return reply(id: id, result: content(pretty(strippingImage(envelope)),
                                                 isError: envelope["ok"]?.boolValue == false,
                                                 image: imageIn(envelope)))
        } catch let error as EngineError {
            // No answer at all is still reported the way a refusal is, so
            // the model reads a code and a hint instead of a transport
            // error it can do nothing with.
            return reply(id: id, result: content(pretty(error.envelope), isError: true))
        } catch {
            return reply(id: id, result: content("\(error)", isError: true))
        }
    }

    private func content(_ text: String, isError: Bool, image: (data: String, mimeType: String)? = nil) -> JSON {
        var blocks: [JSON] = [["type": "text", "text": .string(text)]]
        // PD1: "`look` additionally returns a JPEG the helper wraps as an
        // image content block." The wrapping is the server's now, and it
        // still knows no tool by name — it looks for an image in the
        // envelope, not for a tool called look, so a later tool that
        // returns a frame needs nothing here.
        if let image {
            blocks.append(["type": "image", "data": .string(image.data), "mimeType": .string(image.mimeType)])
        }
        return ["content": .array(blocks), "isError": .bool(isError)]
    }

    /// An envelope's `data` carrying base64 image bytes, if it has one.
    private func imageIn(_ envelope: JSON) -> (data: String, mimeType: String)? {
        guard let data = envelope["data"],
              let base64 = data["data"]?.stringValue,
              let mimeType = data["mimeType"]?.stringValue,
              mimeType.hasPrefix("image/") else { return nil }
        return (base64, mimeType)
    }

    /// The same envelope with the image bytes taken out of the text block.
    /// Base64 in the transcript as well as in the image block would double
    /// what the frame costs the agent's context, which is the one thing
    /// §16.3 budgets `look` against. The note stands where the bytes stood,
    /// so the rest of the envelope reads in the order it was written.
    private func strippingImage(_ envelope: JSON) -> JSON {
        guard let image = imageIn(envelope),
              var outer = envelope.objectValue, var data = outer["data"]?.objectValue else { return envelope }
        // The engine says how many bytes the frame is; if one ever does
        // not, the base64 says it too — four characters to three bytes,
        // less the padding.
        let count = data["bytes"]?.numberValue.map(JS.string)
            ?? String(image.data.utf8.count / 4 * 3 - image.data.utf8.reversed().prefix { $0 == 0x3D }.count)
        data["data"] = .string("<\(count) bytes, returned as an image>")
        outer["data"] = .object(data)
        return .object(outer)
    }

    // MARK: - Resources

    private func readResource(id: JSON, params: JSON) async -> JSON {
        guard let uri = params["uri"]?.stringValue else {
            return reply(id: id, code: -32602, message: "missing resource uri")
        }
        do {
            let body = try await engine.read(uri: uri)
            let mime = (try? await loadCatalogue())?.mimeType(for: uri) ?? "application/json"
            return reply(id: id, result: [
                "contents": [["uri": .string(uri), "mimeType": .string(mime), "text": .string(pretty(body))]],
            ])
        } catch let error as EngineError {
            return reply(id: id, code: -32602, message: error.sentence)
        } catch {
            return reply(id: id, code: -32603, message: "\(error)")
        }
    }

    /// Turns what the engine says has changed into MCP notifications, for
    /// the URIs a client actually subscribed to, and hands them to whoever
    /// owns the pipe. Whether a host forwards them to its agent is the
    /// host's business (S4) — the design assumes it does not, and the agent
    /// rereads.
    ///
    /// A URI named twice in one drain is announced once. The notification
    /// says "this changed, read it again", and saying so twice in a row
    /// tells a host nothing the first did not; a run of edits between two
    /// flushes used to cost one line each.
    public func flushNotifications() async -> [JSON] {
        guard initialised else { return [] }
        var seen = Set<String>()
        return await engine.drainUpdates()
            .filter { subscribed.contains($0) && seen.insert($0).inserted }
            .map { ["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": .string($0)]] }
    }

    // MARK: - Prompts

    private func getPrompt(id: JSON, params: JSON) async -> JSON {
        guard let name = params["name"]?.stringValue else {
            return reply(id: id, code: -32602, message: "missing prompt name")
        }
        // MCP's prompt arguments are strings; anything else a host sends is
        // dropped here rather than handed to a template that would print it.
        let arguments = JSONObject((params["arguments"]?.objectValue?.pairs ?? [])
            .filter { $0.value.stringValue != nil }
            .map { ($0.key, $0.value) })
        do {
            let result = try await engine.prompt(name: name, arguments: .object(arguments))
            guard let text = result["text"]?.stringValue else {
                throw EngineError("the prompt came back in a shape this server does not understand")
            }
            return reply(id: id, result: [
                "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]],
            ])
        } catch let error as EngineError {
            return reply(id: id, code: -32602, message: error.sentence)
        } catch {
            return reply(id: id, code: -32603, message: "\(error)")
        }
    }

    // MARK: - Shared

    private func reply(id: JSON, result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func reply(id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    /// What goes in a text block: a string as it is, anything else as the
    /// two-space `JSON.stringify` the project file itself is written in —
    /// keys in the engine's order, not the alphabet's, so an envelope reads
    /// `ok` first the way §10.4 draws it.
    private func pretty(_ value: JSON) -> String {
        value.stringValue ?? value.stringified(indent: 2)
    }
}
