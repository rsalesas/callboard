// `RemoteEngine` against the other end of the line protocol (§4.3, D54):
// a Unix socket in a temporary directory, with a few lines of server behind
// it that answer the way `engine/packages/channel/src/line.ts` does —
// `{id, result}`, `{id, error}`, and `{updated}` whenever it likes.

import Foundation
import os
import Testing
import CallboardJSON
@testable import CallboardMCP

/// The server's half, scripted. Blocking POSIX on a thread of its own: it
/// is a test double for a process, and behaves like one.
private final class LineServer: Sendable {
    let directory: URL
    let path: String
    private let listener: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let received = OSAllocatedUnfairLock(initialState: [JSON]())

    /// In place of a reply: close the connection on the caller instead.
    static let hangUp: JSON = "hang up"

    /// Every frame any client has sent, in order.
    var frames: [JSON] { received.withLock { $0 } }

    /// `respond` is handed each request and returns the raw lines to write
    /// back, which go out in one `write` — so a test that wants an
    /// `updated` to arrive before its reply, or straight after it, gets
    /// exactly that.
    init(respond: @escaping @Sendable (JSON) -> [JSON]) throws {
        // sun_path holds 104 bytes, and the temporary directory has spent
        // half of them before we start: short names.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("us-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("s.sock").path

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(path.utf8.count < capacity, "socket path too long for the test: \(path)")
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strcpy($0, source) }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            throw EngineError("could not listen at \(path): \(errno)")
        }

        let stopped = stopped, received = received
        Thread {
            while !stopped.withLock({ $0 }) {
                guard Self.readable(listener) else { continue }
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

                var pending: [UInt8] = []
                var chunk = [UInt8](repeating: 0, count: 65536)
                serving: while !stopped.withLock({ $0 }) {
                    guard Self.readable(connection) else { continue }
                    let count = read(connection, &chunk, chunk.count)
                    if count <= 0 { break }
                    pending.append(contentsOf: chunk[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Array(pending[..<newline])
                        pending.removeSubrange(...newline)
                        guard let frame = try? JSON.parse(bytes: line) else { continue }
                        received.withLock { $0.append(frame) }
                        let replies = respond(frame)
                        if replies == [LineServer.hangUp] { break serving }
                        let bytes = Array(replies.map { $0.stringified() + "\n" }.joined().utf8)
                        if !bytes.isEmpty, write(connection, bytes, bytes.count) < 0 { break serving }
                    }
                }
                close(connection)
            }
            close(listener)
        }.start()
    }

    private static func readable(_ fd: Int32) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&poller, 1, 20) > 0
    }

    func stop() {
        stopped.withLock { $0 = true }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// What `handleFrame` in line.ts does, for a project with one tool.
private func lineProtocol(_ frame: JSON) -> [JSON] {
    let id = frame["id"] ?? .null
    if let hello = frame["hello"] {
        return [["id": id, "result": ["client": hello["client"] ?? .null, "ok": true]]]
    }
    if frame["catalogue"] != nil { return [["id": id, "result": FakeEngine.catalogue]] }
    if let call = frame["call"] {
        switch call["name"]?.stringValue {
        case "place":
            // PD16: the push precedes the reply to the call that caused it.
            // A second change — somebody else's — lands just after.
            return [
                ["updated": ["uri": "example://project"]],
                ["log": ["level": "info", "message": "placed"]],
                ["id": id, "result": ["ok": true, "summary": ["shot": "sh1"], "changed": ["standins.hero"],
                                     "data": ["echo": call["args"] ?? .null]]],
                ["updated": ["uri": "example://warnings"]],
            ]
        case "stall":
            return []
        case "vanish":
            return [LineServer.hangUp]
        default:
            return [["id": id, "error": ["code": "E_UNKNOWN_ID", "error": "no tool \"nope\"",
                                         "hint": "call tools/list — the catalogue is the whole surface"]]]
        }
    }
    if let read = frame["read"] {
        guard read["uri"]?.stringValue == "example://project" else {
            return [["id": id, "error": ["code": "E_UNKNOWN_ID", "error": "no resource",
                                         "hint": "available: example://project"]]]
        }
        return [["id": id, "result": ["title": "Rooftop", "scenes": []]]]
    }
    if let prompt = frame["prompt"] {
        return [["id": id, "result": ["text": .string("Block this: \(prompt["args"]?["note"]?.stringValue ?? "")")]]]
    }
    return [["id": id, "error": ["code": "E_UNKNOWN_ID", "error": "unrecognised frame", "hint": ""]]]
}

@Suite("RemoteEngine")
struct RemoteEngineTests {
    @Test("hello, catalogue, call, an update nobody asked for, read — in that order, over one connection")
    func session() async throws {
        let server = try LineServer(respond: lineProtocol)
        defer { server.stop() }
        let engine = RemoteEngine(socketPath: server.path, timeout: 5, client: "the-tests")

        let catalogue = try await engine.catalogue()
        #expect(catalogue == FakeEngine.catalogue)

        let arguments: JSON = ["kind": "capsule", "zeta": 1, "alpha": 2]
        let envelope = try await engine.call(name: "place", arguments: arguments)
        #expect(envelope["ok"] == true)
        // Order survives both directions of the socket.
        #expect(envelope.objectValue?.keys == ["ok", "summary", "changed", "data"])
        #expect(envelope["data"]?["echo"] == arguments)

        // One `updated` came before the reply and one after it; neither was
        // mistaken for the reply, and neither was lost.
        var updates = await engine.drainUpdates()
        let body = try await engine.read(uri: "example://project")
        #expect(body == ["title": "Rooftop", "scenes": []])
        updates += await engine.drainUpdates()
        #expect(updates == ["example://project", "example://warnings"])
        #expect(await engine.drainUpdates().isEmpty)

        let prompt = try await engine.prompt(name: "start_a_scene", arguments: ["note": "a roof"])
        #expect(prompt["text"]?.stringValue == "Block this: a roof")

        // What the server saw: hello first and once, then the rest, ids
        // counting up.
        let frames = server.frames
        #expect(frames.map { $0.objectValue?.keys.last } == ["hello", "catalogue", "call", "read", "prompt"])
        #expect(frames[0]["hello"]?["client"]?.stringValue == "the-tests")
        #expect(frames.map { $0["id"]?.numberValue } == [1, 2, 3, 4, 5])
        await engine.disconnect()
    }

    @Test("a refused call comes back as the envelope; a refused read is thrown")
    func refusals() async throws {
        let server = try LineServer(respond: lineProtocol)
        defer { server.stop() }
        let engine = RemoteEngine(socketPath: server.path, timeout: 5)

        // The line protocol strips `ok: false` to make an error frame;
        // `EngineClient.call` promises the envelope, so it is put back.
        let envelope = try await engine.call(name: "nope", arguments: [:])
        #expect(envelope == [
            "ok": false, "code": "E_UNKNOWN_ID", "error": "no tool \"nope\"",
            "hint": "call tools/list — the catalogue is the whole surface",
        ])

        await #expect(throws: EngineError("no resource", code: "E_UNKNOWN_ID", hint: "available: example://project")) {
            try await engine.read(uri: "example://nope")
        }
        await engine.disconnect()
    }

    /// The old helper filed a timeout under E_APP_GONE and retried
    /// everything so filed — which sent a slow call a second time.
    @Test("a call that is not answered in time is reported once, and never sent twice")
    func timeout() async throws {
        let server = try LineServer(respond: lineProtocol)
        defer { server.stop() }
        let engine = RemoteEngine(socketPath: server.path, timeout: 0.2)

        let started = Date()
        await #expect(throws: EngineError.self) { try await engine.call(name: "stall", arguments: [:]) }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(server.frames.filter { $0["call"]?["name"]?.stringValue == "stall" }.count == 1)

        // The session is not lost with it: the next call reconnects, says
        // hello again, and is answered.
        #expect(try await engine.call(name: "place", arguments: [:])["ok"] == true)
        #expect(server.frames.filter { $0["hello"] != nil }.count == 2)
        await engine.disconnect()
    }

    @Test("a server that hangs up mid-call is E_SERVER_GONE, and the next call finds it again")
    func hangUp() async throws {
        let server = try LineServer(respond: lineProtocol)
        defer { server.stop() }
        let engine = RemoteEngine(socketPath: server.path, timeout: 5)

        do {
            _ = try await engine.call(name: "vanish", arguments: [:])
            Issue.record("expected the call to fail")
        } catch let error as EngineError {
            #expect(error.code == EngineError.gone)
            #expect(!error.hint.isEmpty)
        }
        #expect(server.frames.filter { $0["call"]?["name"]?.stringValue == "vanish" }.count == 1)
        #expect(await engine.isConnected == false)
        #expect(try await engine.call(name: "place", arguments: [:])["ok"] == true)
        await engine.disconnect()
    }

    /// Was "says what to do when there is no app and no harness". The two
    /// tests that stood beside it — finding the app's bundle, and the
    /// three-second launch budget — went with `AppConnection`: under D54
    /// nothing here launches anything.
    @Test("says what to do when there is no server at the socket")
    func explainsAMissingServer() async {
        let engine = RemoteEngine(socketPath: "/tmp/example-absent-\(UUID().uuidString).sock", product: example,
                                  serverDescription: "Example server",
                                  unreachableHint: "a host starts one by launching `example`")
        do {
            _ = try await engine.call(name: "project_info", arguments: [:])
            Issue.record("expected an EngineError")
        } catch let error as EngineError {
            // The hint has to name a next step: whoever reads this has no
            // other way to find out what is wrong.
            #expect(error.code == EngineError.gone)
            #expect(error.hint.contains("dev-engine") || error.hint.contains("example"))
        } catch {
            Issue.record("expected an EngineError, got \(error)")
        }
    }

    /// The whole arrangement `--dev` sets up, and the one the old helper
    /// was: MCP on one side, the line protocol on the other.
    @Test("the MCP layer over a RemoteEngine is the old helper, and still works")
    func bridged() async throws {
        let server = try LineServer(respond: lineProtocol)
        defer { server.stop() }
        let engine = RemoteEngine(socketPath: server.path, timeout: 5)
        let mcp = MCPServer(engine: engine)

        let initialize = try #require(await mcp.handle(line:
            request(1, "initialize", ["protocolVersion": "2025-06-18"])))
        #expect(initialize["result"]?["instructions"]?.stringValue == "Example is a shot-score server.")
        _ = await mcp.handle(line: request(2, "resources/subscribe", ["uri": "example://project"]))

        let reply = try #require(await mcp.handle(line: request(3, "tools/call", ["name": "place"])))
        #expect(reply["result"]?["isError"] == false)
        let refused = try #require(await mcp.handle(line: request(4, "tools/call", ["name": "nope"])))
        #expect(refused["result"]?["isError"] == true)

        let notifications = await mcp.flushNotifications()
        #expect(notifications.map { $0["params"]?["uri"]?.stringValue } == ["example://project"])
        await engine.disconnect()
    }
}
