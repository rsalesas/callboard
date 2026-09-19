// The pipe, end to end: bytes in one descriptor, lines out of another.
// These are the only tests that go through `StdioTransport`; everything
// about *what* is said is tested against `MCPServer` directly.

import Foundation
import os
import Testing
import CallboardJSON
@testable import CallboardMCP
import CallboardTransport

/// A transport between two pipes, as a host holds one.
private struct Session {
    let input = Pipe()
    let output = Pipe()

    func transport(idleInterval: Duration = .milliseconds(500)) -> StdioTransport {
        StdioTransport(input: input.fileHandleForReading.fileDescriptor,
                       output: output.fileHandleForWriting.fileDescriptor,
                       idleInterval: idleInterval)
    }

    func send(_ text: String) { input.fileHandleForWriting.write(Data(text.utf8)) }

    /// The host going away.
    func hangUp() { try? input.fileHandleForWriting.close() }

    /// Everything the server wrote, one parsed message per line. Anything
    /// on the pipe that is not a JSON object on a line of its own fails
    /// here, which is the "stdout carries protocol lines only" rule.
    func transcript() throws -> [JSON] {
        try? output.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.isEmpty || text.hasSuffix("\n"))
        return try text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map {
            let message = try JSON.parse(String($0))
            #expect(message.objectValue != nil)
            return message
        }
    }
}

@Suite("stdio transport")
struct TransportTests {
    /// The session CI pipes into the binary (`.github/workflows/ci.yml`):
    /// the handshake has to work before an engine does, and both replies
    /// have to be out before the process notices its stdin has closed.
    @Test("answers CI's scripted session: initialize at 2025-06-18, then ping")
    func scriptedSession() async throws {
        let session = Session()
        session.send("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}
        {"jsonrpc":"2.0","id":2,"method":"ping"}

        """)
        session.hangUp()
        await session.transport().run(MCPServer(engine: FakeEngine(ready: false), name: example.command, version: "1.0"))

        let replies = try session.transcript()
        #expect(replies.count == 2)
        #expect(replies[0]["id"]?.numberValue == 1)
        #expect(replies[0]["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(replies[0]["result"]?["serverInfo"]?["name"]?.stringValue == "example")
        #expect(replies[1] == ["jsonrpc": "2.0", "id": 2, "result": [:]])
        // CI greps for exactly this, so the compact form is part of the deal.
        #expect(replies[1].stringified().contains(#""id":2"#))
    }

    @Test("skips blank lines, answers a bad one, and takes a last line with no newline after it")
    func untidyInput() async throws {
        let session = Session()
        session.send("\n   \n{not json\n\r\n" + #"{"jsonrpc":"2.0","id":"last","method":"ping"}"#)
        session.hangUp()
        await session.transport().run(MCPServer(engine: FakeEngine()))

        let replies = try session.transcript()
        #expect(replies.count == 2)
        #expect(replies[0]["error"]?["code"]?.numberValue == -32700)
        #expect(replies[1]["id"]?.stringValue == "last")
    }

    /// Why stdin is not read with `FileHandle.bytes.lines`: U+2028 is legal
    /// raw inside a JSON string and is not the end of a line here.
    @Test("a line separator inside a string does not end the line, either way")
    func lineSeparators() async throws {
        let engine = FakeEngine()
        await engine.answer("note", with: ["ok": true, "data": ["text": "first\u{2028}second\u{2029}third"]])
        let session = Session()
        session.send(request(1, "initialize", ["protocolVersion": "2025-06-18"]) + "\n"
            + request(2, "tools/call", ["name": "note", "arguments": ["text": "one\u{2028}two"]]) + "\n")
        session.hangUp()
        await session.transport().run(MCPServer(engine: engine))

        // In: one request, arguments intact.
        let calls = await engine.calls
        #expect(calls.count == 1)
        #expect(calls.first?.arguments["text"]?.stringValue == "one\u{2028}two")

        // Out: two lines exactly, and the separators survive the escape.
        let replies = try session.transcript()
        #expect(replies.count == 2)
        let text = try #require(replies[1]["result"]?["content"]?[0]?["text"]?.stringValue)
        #expect(try JSON.parse(text)["data"]?["text"]?.stringValue == "first\u{2028}second\u{2029}third")
    }

    @Test("notifications follow the reply to the request that caused them")
    func notificationsAfterReply() async throws {
        let engine = FakeEngine()
        let session = Session()
        session.send(request(1, "initialize", ["protocolVersion": "2025-06-18"]) + "\n"
            + request(2, "resources/subscribe", ["uri": "example://project"]) + "\n")

        // An interval this long is no interval: whatever is announced here
        // was announced because of a request.
        let transport = session.transport(idleInterval: .seconds(3600))
        let serving = Task { await transport.run(MCPServer(engine: engine)) }
        // Both requests answered and flushed: the engine has been asked
        // what changed once for each (nothing, so far).
        while await engine.drains < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await engine.changed("example://project")
        session.send(request(3, "ping") + "\n")
        session.hangUp()
        await serving.value

        let lines = try session.transcript()
        #expect(lines.count == 4)
        #expect(lines[2]["id"]?.numberValue == 3)
        #expect(lines[3]["method"]?.stringValue == "notifications/resources/updated")
    }

    /// What the old helper could not do: it looked for updates only after
    /// answering something, so a change a person made in the witness waited
    /// for the agent's next request to be announced.
    @Test("announces a change while the host is saying nothing")
    func notificationsWhileIdle() async throws {
        let engine = FakeEngine()
        let session = Session()
        session.send(request(1, "initialize", ["protocolVersion": "2025-06-18"]) + "\n"
            + request(2, "resources/subscribe", ["uri": "example://project"]) + "\n")

        let transport = session.transport(idleInterval: .milliseconds(10))
        let serving = Task { await transport.run(MCPServer(engine: engine)) }
        while await engine.drains < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await engine.changed("example://project")
        // No further request. The tick finds it.
        while await engine.pendingUpdates > 0 { try await Task.sleep(for: .milliseconds(5)) }
        session.hangUp()
        await serving.value

        let lines = try session.transcript()
        #expect(lines.count == 3)
        #expect(lines[2] == ["jsonrpc": "2.0", "method": "notifications/resources/updated",
                             "params": ["uri": "example://project"]])
    }

    @Test("with nobody subscribed, a quiet host means a quiet server")
    func noTimerWithoutSubscribers() async throws {
        let engine = FakeEngine()
        let session = Session()
        session.send(request(1, "initialize", ["protocolVersion": "2025-06-18"]) + "\n")
        let transport = session.transport(idleInterval: .milliseconds(5))
        let serving = Task { await transport.run(MCPServer(engine: engine)) }
        while await engine.drains < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        // Asked once, after the one request, and not again since.
        #expect(await engine.drains == 1)
        session.hangUp()
        await serving.value
    }
}
