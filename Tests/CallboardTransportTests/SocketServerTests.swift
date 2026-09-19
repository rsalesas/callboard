// The server's end of the local channel (§4.3, PD18), against real clients
// on a real socket: `RemoteEngine`, which is what will actually attach to
// it, and a raw one for everything a well-behaved client would never do.
//
// One of these is the reason the server is written the way it is: a client
// that stops reading must not stop the server. The app's first server
// blocked for ever on exactly that, and answered nobody again.

import Foundation
import os
import Testing
import CallboardJSON
import CallboardMCP
@testable import CallboardTransport

@Suite("the session socket") struct SocketServerTests {
    // ------------------------------------------------------ round trips ---

    @Test("RemoteEngine — the real client — says hello and is answered, over the event stream an actor would consume")
    func remoteEngine() async throws {
        let scratch = try Scratch()
        let server = SocketServer()
        let events = server.events()
        try server.start(at: scratch.socket)

        // The engine's half, in miniature: one consumer, in order, replying
        // in the line protocol's own shapes.
        let serving = Task {
            var seen: [SocketEvent] = []
            for await event in events {
                seen.append(event)
                guard case .line(let clientId, let line) = event, let frame = try? JSON.parse(line) else { continue }
                let id = frame["id"] ?? .null
                if let hello = frame["hello"] {
                    server.send(to: clientId, line: (["id": id, "result": ["ok": true, "client": hello["client"] ?? .null]] as JSON).stringified())
                } else if frame["catalogue"] != nil {
                    server.send(to: clientId, line: (["updated": ["uri": "example://project"]] as JSON).stringified())
                    server.send(to: clientId, line: (["id": id, "result": ["tools": [], "server": ["name": "example"]]] as JSON).stringified())
                } else {
                    server.send(to: clientId, line: (["id": id, "error": ["code": "E_UNKNOWN_ID", "error": "no resource", "hint": "there is only the catalogue"]] as JSON).stringified())
                }
            }
            return seen
        }

        let engine = RemoteEngine(socketPath: scratch.socket, timeout: 5, client: "transport-tests")
        let catalogue = try await engine.catalogue()
        #expect(catalogue["server"]?["name"]?.stringValue == "example")
        // PD16: the push went first and arrived first.
        #expect(await engine.drainUpdates() == ["example://project"])
        await #expect(throws: (any Error).self) { try await engine.read(uri: "example://nothing") }
        await engine.disconnect()

        #expect(await eventually { server.connectionCount == 0 })
        server.stop()
        // `stop` ends the stream, which is what lets the consumer finish.
        let seen = await serving.value
        #expect(seen.first == .opened("c1") && seen.last == .closed("c1"))
        let lines = seen.compactMap { event -> JSON? in
            if case .line("c1", let line) = event { return try? JSON.parse(line) }
            return nil
        }
        #expect(lines.count == 3)
        #expect(lines[0]["hello"]?["client"]?.stringValue == "transport-tests")
    }

    @Test("several clients at once each get their own replies and nobody else's")
    func severalClients() throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket)
        defer { echo.stop() }

        let failures = OSAllocatedUnfairLock(initialState: [String]())
        let path = scratch.socket
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            do {
                let client = try RawClient(path)
                var connection: String?
                for request in 0..<60 {
                    let payload = "w\(worker)-r\(request)"
                    try client.send((["id": .number(Double(request)), "echo": .string(payload)] as JSON).stringified() + "\n")
                    let reply = try JSON.parse(try client.line())
                    guard reply["id"]?.numberValue == Double(request), reply["result"]?["echo"]?.stringValue == payload else {
                        failures.withLock { $0.append("worker \(worker) asked \(payload) and was told \(reply.stringified())") }
                        return
                    }
                    // The same connection every time, and it is this one.
                    let named = reply["result"]?["client"]?.stringValue
                    if connection == nil { connection = named }
                    if named != connection {
                        let message = "worker \(worker) was \(connection ?? "?") and then \(named ?? "?")"
                        failures.withLock { $0.append(message) }
                    }
                }
                client.close()
            } catch {
                failures.withLock { $0.append("worker \(worker): \(error)") }
            }
        }
        #expect(failures.withLock { $0 } == [])

        let opened = echo.recorder.all.compactMap { event -> String? in
            if case .opened(let id) = event { return id }
            return nil
        }
        // Eight connections, eight ids, c1…c8 in the order they were accepted.
        #expect(opened == (1...8).map { "c\($0)" })
    }

    @Test("a broadcast reaches every client attached, once")
    func broadcast() async throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket)
        defer { echo.stop() }
        let clients = try (0..<3).map { _ in try RawClient(scratch.socket) }
        #expect(await echo.recorder.wait { $0.count == 3 })

        echo.server.broadcast("{\"updated\":{\"uri\":\"example://project\"}}")
        echo.server.send(to: "c2", line: "{\"only\":\"c2\"}\n")
        for client in clients {
            #expect(try client.line() == "{\"updated\":{\"uri\":\"example://project\"}}")
        }
        // …and the line sent to one went to one. (Which RawClient is c2 is
        // the kernel's business, so: exactly one of them has it.)
        let extras = clients.map { $0.read(timeout: 0.3) }
        #expect(extras.filter { $0 == .line("{\"only\":\"c2\"}") }.count == 1)
        #expect(extras.filter { $0 == .timedOut }.count == 2)
    }

    // ------------------------------------------------------- the old bug ---

    @Test("a client that stops reading while five megabytes are written to it does not hold up anybody else")
    func stalledReader() async throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket)
        defer { echo.stop() }

        let stalled = try RawClient(scratch.socket)
        #expect(await echo.recorder.wait { $0 == [.opened("c1")] })
        // Far more than a socket buffer holds, to somebody who is not
        // reading. A blocking write stops here and never comes back.
        let big = String(repeating: "0123456789abcdef", count: (5 << 20) / 16)
        echo.server.send(to: "c1", line: big)

        let other = try RawClient(scratch.socket)
        let started = Date()
        for request in 0..<20 {
            try other.send("{\"id\":\(request),\"echo\":\"still here\"}\n")
            let reply = try JSON.parse(try other.line(timeout: 5))
            #expect(reply["id"]?.numberValue == Double(request))
            #expect(reply["result"]?["client"]?.stringValue == "c2")
        }
        #expect(Date().timeIntervalSince(started) < 5)
        // The server is also still answering its own callers.
        #expect(echo.server.connectionCount == 2)

        // And nothing was lost by waiting: when the first client does read,
        // all of it is there, in order, followed by what was sent after.
        echo.server.send(to: "c1", line: "{\"after\":true}")
        let arrived = try stalled.line(timeout: 20)
        #expect(arrived.utf8.count == big.utf8.count)
        #expect(arrived == big)
        #expect(try stalled.line() == "{\"after\":true}")
    }

    @Test("a client that never reads is closed once what is queued for it passes the bound, and the rest carry on")
    func queueBound() async throws {
        let scratch = try Scratch()
        let recorder = Recorder()
        let server = SocketServer(handlers: recorder.handlers, maxQueuedBytes: 1 << 20)
        try server.start(at: scratch.socket)
        defer { server.stop() }

        let stalled = try RawClient(scratch.socket)
        let chunk = String(repeating: "x", count: 1 << 18)
        for _ in 0..<16 { server.send(to: "c1", line: chunk) }
        #expect(await recorder.wait { $0.contains(.closed("c1")) })
        _ = stalled
    }

    // ---------------------------------------------------------- framing ---

    @Test("a line split across writes is one line, and two lines in one write are two")
    func splitLines() async throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket)
        defer { echo.stop() }
        let client = try RawClient(scratch.socket)

        try client.send("{\"id\":1,\"ec")
        try await Task.sleep(for: .milliseconds(40))
        #expect(!echo.recorder.all.contains { if case .line = $0 { true } else { false } })
        try client.send("ho\":\"one\"}\n{\"id\":2,\"echo\":\"two\"}\n{\"id\":3,")
        try await Task.sleep(for: .milliseconds(40))
        try client.send("\"echo\":\"three\"}\n")

        let replies = try (0..<3).map { _ in try JSON.parse(try client.line())["result"]?["echo"]?.stringValue }
        #expect(replies == ["one", "two", "three"])
        let lines = echo.recorder.all.compactMap { event -> String? in
            if case .line(_, let line) = event { return line }
            return nil
        }
        #expect(lines == ["{\"id\":1,\"echo\":\"one\"}", "{\"id\":2,\"echo\":\"two\"}", "{\"id\":3,\"echo\":\"three\"}"])
    }

    @Test("U+2028 inside a line survives the trip both ways")
    func lineSeparator() throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket)
        defer { echo.stop() }
        let client = try RawClient(scratch.socket)

        // Raw in the JSON, as JavaScript's `JSON.stringify` writes it.
        let note = "first line\u{2028}second line\u{2029}third \u{1F3AC}"
        let request = "{\"id\":7,\"echo\":\"\(note)\"}"
        #expect(request.unicodeScalars.contains("\u{2028}"))
        try client.send(request + "\n")
        let reply = try client.line()
        #expect(try JSON.parse(reply)["result"]?["echo"]?.stringValue == note)
        #expect(echo.recorder.all.contains(.line("c1", request)))
    }

    @Test("a line past the limit closes the connection rather than the server's memory")
    func oversizedLine() async throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket, maxLineBytes: 1024)
        defer { echo.stop() }
        let greedy = try RawClient(scratch.socket)
        try greedy.send("{\"id\":1,\"echo\":\"fine\"}\n" + String(repeating: "x", count: 4096))
        #expect(try greedy.line().contains("fine"))
        #expect(greedy.read() == .endOfFile)
        #expect(await echo.recorder.wait { $0.last == .closed("c1") })

        // …and only that connection.
        let next = try RawClient(scratch.socket)
        try next.send("{\"id\":2,\"echo\":\"next\"}\n")
        #expect(try next.line().contains("next"))
    }

    // ------------------------------------------------------- lifecycles ---

    @Test("a client hanging up is `closed`, once; being hung up on is an end of file and `closed` too")
    func disconnects() async throws {
        let scratch = try Scratch()
        let echo = try EchoServer(at: scratch.socket)
        defer { echo.stop() }

        let leaver = try RawClient(scratch.socket)
        try leaver.send("{\"id\":1,\"echo\":\"bye\"}\n{\"id\":2,\"ec")   // half a line dies with it
        _ = try leaver.line()
        leaver.close()
        #expect(await echo.recorder.wait { $0.contains(.closed("c1")) })
        #expect(echo.recorder.all == [.opened("c1"), .line("c1", "{\"id\":1,\"echo\":\"bye\"}"), .closed("c1")])

        let dropped = try RawClient(scratch.socket)
        #expect(await echo.recorder.wait { $0.contains(.opened("c2")) })
        echo.server.close(client: "c2")
        #expect(dropped.read() == .endOfFile)
        #expect(await echo.recorder.wait { $0.last == .closed("c2") })
        #expect(echo.server.connectionCount == 0)

        // A reply that races a disconnect is ordinary, not an error.
        echo.server.send(to: "c2", line: "{}")
        echo.server.send(to: "c99", line: "{}")
        echo.server.close(client: "c99")
    }

    @Test("stop closes every client, says so, ends the streams and removes the socket file")
    func stop() async throws {
        let scratch = try Scratch()
        let recorder = Recorder()
        let server = SocketServer(handlers: recorder.handlers)
        let events = server.events()
        try server.start(at: scratch.socket)
        #expect(server.path == scratch.socket)
        #expect(mode(of: scratch.socket) == 0o600)

        let clients = try (0..<2).map { _ in try RawClient(scratch.socket) }
        #expect(await recorder.wait { $0.count == 2 })
        server.stop()

        #expect(!FileManager.default.fileExists(atPath: scratch.socket))
        #expect(server.path == nil)
        for client in clients { #expect(client.read() == .endOfFile) }
        #expect(Set(recorder.all) == [.opened("c1"), .opened("c2"), .closed("c1"), .closed("c2")])
        var streamed: [SocketEvent] = []
        for await event in events { streamed.append(event) }   // ends, because the server stopped
        #expect(streamed == recorder.all)

        server.stop()   // twice is once
        #expect(throws: TransportError.self) { try server.start(at: scratch.socket) }
        #expect(throws: TestFailure.self) { _ = try RawClient(scratch.socket) }
    }

    @Test("a handler may stop the server it is being called by")
    func stopFromAHandler() async throws {
        let scratch = try Scratch()
        let box = OSAllocatedUnfairLock<SocketServer?>(initialState: nil)
        let recorder = Recorder()
        let server = SocketServer(handlers: SocketServer.Handlers(
            line: { id, line in
                recorder.record(.line(id, line))
                if line == "stop" { box.withLock { $0 }?.stop() }
            },
            closed: { recorder.record(.closed($0)) }))
        box.withLock { $0 = server }
        defer { box.withLock { $0 = nil } }
        try server.start(at: scratch.socket)

        let client = try RawClient(scratch.socket)
        try client.send("stop\nnever delivered\n")
        #expect(client.read() == .endOfFile)
        #expect(await recorder.wait { $0.contains(.closed("c1")) })
        #expect(recorder.all == [.line("c1", "stop"), .closed("c1")])
    }

    // ------------------------------------------ whose socket is it anyway ---

    @Test("a second server on the same path is refused while the first lives, and welcome once it has stopped")
    func twoServers() throws {
        let scratch = try Scratch()
        let first = try EchoServer(at: scratch.socket)
        let second = SocketServer(handlers: Recorder().handlers)
        #expect { try second.start(at: scratch.socket) } throws: { ($0 as? TransportError)?.kind == .alreadyListening }

        // The refusal took nothing: the first still has its socket.
        let client = try RawClient(scratch.socket)
        try client.send("{\"id\":1,\"echo\":\"mine\"}\n")
        #expect(try JSON.parse(try client.line())["result"]?["echo"]?.stringValue == "mine")
        // (One connection is the probe's, come and gone; one is this.)
        #expect(first.recorder.all.contains(.opened("c2")))

        first.stop()
        let third = try EchoServer(at: scratch.socket)
        defer { third.stop() }
        let again = try RawClient(scratch.socket)
        try again.send("{\"id\":2,\"echo\":\"theirs now\"}\n")
        #expect(try JSON.parse(try again.line())["result"]?["echo"]?.stringValue == "theirs now")
    }

    @Test("a socket file left by a dead server is replaced; anything else at the path is left alone")
    func staleSocket() throws {
        let scratch = try Scratch()
        // What a killed server leaves: bound, never unlinked, nobody home.
        let dead = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(UnixSocket.withAddress(scratch.socket) { bind(dead, $0, $1) } == 0)
        close(dead)
        #expect(UnixSocket.probe(scratch.socket) == .refused)

        let server = try EchoServer(at: scratch.socket)
        defer { server.stop() }
        #expect(UnixSocket.probe(scratch.socket) == .listening)

        let notes = scratch.file("notes.sock")
        try "not a socket".write(toFile: notes, atomically: true, encoding: .utf8)
        let other = SocketServer(handlers: Recorder().handlers)
        #expect { try other.start(at: notes) } throws: { ($0 as? TransportError)?.kind == .occupied }
        #expect(try String(contentsOfFile: notes, encoding: .utf8) == "not a socket")
    }

    @Test("a path too long to bind is refused in words, not truncated into somebody else's")
    func pathTooLong() throws {
        let scratch = try Scratch()
        let long = scratch.file(String(repeating: "n", count: 120) + ".sock")
        let server = SocketServer(handlers: Recorder().handlers)
        #expect { try server.start(at: long) } throws: { ($0 as? TransportError)?.kind == .pathTooLong }
    }
}
