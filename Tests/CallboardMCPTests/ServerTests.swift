// What the old helper did between a host and an app, and had no tests for
// because it took a running app to see it: a call's envelope on its way to
// the host, the frame `look` returns, a resource, a subscription, a prompt.
// With the engine behind a protocol (D54) each of them is a few lines.

import Foundation
import Testing
import CallboardJSON
@testable import CallboardMCP

@Suite("tools/call")
struct ToolCallTests {
    @Test("a success is a text block holding the envelope, keys in the engine's order")
    func success() async throws {
        let engine = FakeEngine()
        let envelope: JSON = [
            "ok": true,
            "summary": ["project": "Rooftop", "scene": "sc1", "shot": "sh1"],
            "changed": ["standins.hero"],
            "warnings": [],
            "data": ["id": "hero", "at": [0, 0, 1.5]],
        ]
        await engine.answer("place", with: envelope)
        let server = await initialisedServer(engine)

        let reply = try #require(await server.handle(line:
            request(1, "tools/call", ["name": "place", "arguments": ["kind": "capsule", "zeta": 1, "alpha": 2]])))
        let result = try #require(reply["result"])
        #expect(result["isError"] == false)
        #expect(result["content"]?.arrayValue?.count == 1)
        #expect(result["content"]?[0]?["type"]?.stringValue == "text")

        // Verbatim: parsing the text gives the envelope back, order and all
        // (`==` on JSON is order-sensitive), and it opens with `ok` the way
        // §10.4 draws it rather than with whatever sorts first.
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(text) == envelope)
        #expect(text.hasPrefix("{\n  \"ok\": true,\n  \"summary\""))

        // The arguments reach the engine untouched, in the host's order.
        let calls = await engine.calls
        #expect(calls.count == 1)
        #expect(calls[0].name == "place")
        #expect(calls[0].arguments.objectValue?.keys == ["kind", "zeta", "alpha"])
    }

    @Test("a refusal is a result with isError, carrying the envelope verbatim")
    func refusal() async throws {
        let engine = FakeEngine()
        // Deliberately not the order `fail()` builds: whatever the engine
        // wrote is what the host reads, and the MCP layer has no opinion.
        let envelope: JSON = [
            "ok": false,
            "hint": "use one of: red, blue, yellow",
            "code": "E_DUP_COLOR",
            "error": "red is already hero's colour",
        ]
        await engine.answer("place", with: envelope)
        let server = await initialisedServer(engine)

        let reply = try #require(await server.handle(line: request(1, "tools/call", ["name": "place"])))
        // A result, not a JSON-RPC error: the model reads the code and the
        // hint and adjusts (§10.4).
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == true)
        let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(text) == envelope)
        #expect(try JSON.parse(text).objectValue?.keys == ["ok", "hint", "code", "error"])
    }

    @Test("a call with no tool name is the caller's mistake, and says so")
    func missingName() async throws {
        let server = await initialisedServer(FakeEngine())
        let reply = try #require(await server.handle(line: request(1, "tools/call", ["arguments": [:]])))
        #expect(reply["error"]?["code"]?.numberValue == -32602)
    }

    @Test("an image in the envelope is lifted into an image block, and out of the text")
    func imageLifting() async throws {
        let engine = FakeEngine()
        let jpeg = Data((0..<1000).map { UInt8($0 % 251) })
        let base64 = jpeg.base64EncodedString()
        await engine.answer("look", with: [
            "ok": true,
            "summary": ["shot": "sh1"],
            "data": ["view": "camera", "mimeType": "image/jpeg", "data": .string(base64),
                     "bytes": 1000, "width": 768, "height": 432],
        ])
        let server = await initialisedServer(engine)

        let reply = try #require(await server.handle(line: request(1, "tools/call", ["name": "look"])))
        let content = try #require(reply["result"]?["content"]?.arrayValue)
        #expect(content.count == 2)
        #expect(content[1] == ["type": "image", "data": .string(base64), "mimeType": "image/jpeg"])
        #expect(reply["result"]?["isError"] == false)

        // The bytes are in the image block once, not in the transcript too.
        let text = try #require(content[0]["text"]?.stringValue)
        #expect(!text.contains(base64))
        let stripped = try JSON.parse(text)
        #expect(stripped["data"]?["data"]?.stringValue == "<1000 bytes, returned as an image>")
        // Everything else about the frame is still there, where it was.
        #expect(stripped["data"]?.objectValue?.keys == ["view", "mimeType", "data", "bytes", "width", "height"])
        #expect(stripped["data"]?["width"]?.numberValue == 768)
    }

    @Test("counts the bytes itself when the engine did not say")
    func imageWithoutAByteCount() async throws {
        let engine = FakeEngine()
        // 1000 bytes is 1336 characters, the last two of them padding.
        let base64 = Data(repeating: 7, count: 1000).base64EncodedString()
        await engine.answer("look", with: ["ok": true, "data": ["mimeType": "image/png", "data": .string(base64)]])
        let server = await initialisedServer(engine)
        let reply = try #require(await server.handle(line: request(1, "tools/call", ["name": "look"])))
        let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(text)["data"]?["data"]?.stringValue == "<1000 bytes, returned as an image>")
    }

    @Test("leaves alone a `data` that is not an image, whatever it is called")
    func notAnImage() async throws {
        let engine = FakeEngine()
        let envelope: JSON = ["ok": true, "data": ["mimeType": "application/json", "data": "e30="]]
        await engine.answer("export", with: envelope)
        let server = await initialisedServer(engine)
        let reply = try #require(await server.handle(line: request(1, "tools/call", ["name": "export"])))
        #expect(reply["result"]?["content"]?.arrayValue?.count == 1)
        #expect(try JSON.parse(#require(reply["result"]?["content"]?[0]?["text"]?.stringValue)) == envelope)
    }
}

@Suite("resources")
struct ResourceTests {
    @Test("resources/read returns the body as text, under the catalogue's mime type")
    func read() async throws {
        let engine = FakeEngine()
        let body: JSON = ["title": "Rooftop", "id": "p-1", "scenes": [["id": "sc1"]]]
        await engine.serve("example://project", body: body)
        await engine.serve("example://script", body: "INT. ROOFTOP — NIGHT")
        let server = await initialisedServer(engine)

        let project = try #require(await server.handle(line:
            request(1, "resources/read", ["uri": "example://project"])))
        let contents = try #require(project["result"]?["contents"]?[0])
        #expect(contents["uri"]?.stringValue == "example://project")
        #expect(contents["mimeType"]?.stringValue == "application/json")
        #expect(try JSON.parse(#require(contents["text"]?.stringValue)) == body)

        // A body that is already text goes through as text, not as a JSON
        // string with quotes round it.
        let script = try #require(await server.handle(line:
            request(2, "resources/read", ["uri": "example://script"])))
        #expect(script["result"]?["contents"]?[0]?["mimeType"]?.stringValue == "text/markdown")
        #expect(script["result"]?["contents"]?[0]?["text"]?.stringValue == "INT. ROOFTOP — NIGHT")
    }

    @Test("an unknown resource is an error that carries the engine's hint")
    func unknownResource() async throws {
        let server = await initialisedServer(FakeEngine())
        let reply = try #require(await server.handle(line: request(1, "resources/read", ["uri": "example://nope"])))
        #expect(reply["error"]?["code"]?.numberValue == -32602)
        #expect(reply["error"]?["message"]?.stringValue?.contains("available: example://project") == true)
    }

    @Test("announces a change to the URIs a client subscribed to, and to no others")
    func subscriptions() async throws {
        let engine = FakeEngine()
        let server = await initialisedServer(engine)
        #expect(await server.hasSubscriptions == false)

        let subscribed = try #require(await server.handle(line:
            request(1, "resources/subscribe", ["uri": "example://project"])))
        #expect(subscribed["result"] == [:])
        #expect(await server.hasSubscriptions)

        await engine.changed("example://project", "example://warnings", "example://project")
        let notifications = await server.flushNotifications()
        // One, not two: the second says nothing the first did not. And
        // nothing for the URI nobody asked about.
        #expect(notifications == [
            ["jsonrpc": "2.0", "method": "notifications/resources/updated",
             "params": ["uri": "example://project"]],
        ])
        // A notification has no id: it is not something to answer.
        #expect(notifications[0]["id"] == nil)

        // Drained means drained.
        #expect(await server.flushNotifications().isEmpty)

        _ = await server.handle(line: request(2, "resources/unsubscribe", ["uri": "example://project"]))
        await engine.changed("example://project")
        #expect(await server.flushNotifications().isEmpty)
        #expect(await server.hasSubscriptions == false)
    }

    @Test("says nothing before the handshake, and loses nothing by waiting")
    func nothingBeforeInitialize() async throws {
        let engine = FakeEngine()
        let server = MCPServer(engine: engine)
        _ = await server.handle(line: request(1, "resources/subscribe", ["uri": "example://project"]))
        await engine.changed("example://project")
        #expect(await server.flushNotifications().isEmpty)

        _ = await server.handle(line: request(2, "initialize", ["protocolVersion": "2025-06-18"]))
        #expect(await server.flushNotifications().count == 1)
    }
}

@Suite("prompts")
struct PromptTests {
    @Test("prompts/get renders through the engine and wraps the text as a user message")
    func get() async throws {
        let engine = FakeEngine()
        let server = await initialisedServer(engine)
        let reply = try #require(await server.handle(line: request(1, "prompts/get", [
            "name": "start_a_scene",
            "arguments": ["note": "two people argue on a roof", "count": 3],
        ])))
        #expect(reply["result"]?["messages"] == [
            ["role": "user", "content": ["type": "text", "text": "Block this: two people argue on a roof"]],
        ])
        // MCP's prompt arguments are strings; the number never reached the
        // template.
        let asked = await engine.prompts
        #expect(asked.first?.arguments == ["note": "two people argue on a roof"])
    }

    @Test("an unknown prompt is an error naming the ones there are")
    func unknownPrompt() async throws {
        let server = await initialisedServer(FakeEngine())
        let reply = try #require(await server.handle(line: request(1, "prompts/get", ["name": "nope"])))
        #expect(reply["error"]?["code"]?.numberValue == -32602)
        #expect(reply["error"]?["message"]?.stringValue == "no prompt \"nope\" — available: start_a_scene")
    }
}
