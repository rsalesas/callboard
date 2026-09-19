// An engine that is somewhere else: the line protocol (§4.3, D54), client
// side. One JSON object per line over a Unix-domain socket in the user's
// own domain — `hello`, `catalogue`, `call`, `read`, `prompt`, answered by
// `{id, result}` or `{id, error: {code, error, hint}}`, with `{updated}`
// and `{log}` arriving whenever the server has something to say.
//
// This is `Channel.swift` and `AppConnection.swift` from the old helper,
// minus the half that went away. Under PD1 the helper was the *only* client
// of this protocol and the app was the server, so connecting included
// finding the app's bundle and launching it through LaunchServices. Under
// D54 the server is what a host launches, and nothing here starts anything:
// the clients of this protocol are now the ones that attach to a server
// somebody else started — a product's own `open` and `status` commands, the viewer when
// it arrives (N6), and the tests, for which it is a useful double. Which
// socket to attach to is the caller's business; discovery by descriptor
// (PD18) arrives with the transport work.
//
// Synchronous request/response on purpose, as it always was: one thing in
// flight, a blocking write and a read with a deadline. What is new is where
// it blocks. The actor runs on a serial queue of its own rather than the
// cooperative pool, so a server that takes its thirty seconds ties up this
// actor's thread and nobody else's — and the actor keeps the state to
// itself without a lock or an `@unchecked`.

import Foundation
import CallboardJSON
import CallboardTransport

public actor RemoteEngine: EngineClient {
    private let queue = DispatchSerialQueue(label: "callboard.remote-engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let socketPath: String
    private let timeout: TimeInterval
    private let client: String
    private let serverDescription: String
    private let unreachableHint: String

    private var fd: Int32 = -1
    private var buffer: [UInt8] = []
    private var nextID = 0
    private var saidHello = false

    /// Unsolicited frames seen while waiting for a reply. `updated` arrives
    /// whenever any client mutates the document, which can be in the middle
    /// of our own round trip — it precedes the reply to the call that
    /// caused it (PD16) — so they are collected rather than discarded and
    /// drained when asked for.
    private var pendingUpdates: [String] = []

    /// - Parameters:
    ///   - timeout: how long one reply may take. Thirty seconds is the old
    ///     helper's figure; an export's caller will want longer, a test
    ///     much less.
    ///   - client: named in the server's log and in the witness's list of
    ///     who is attached, so two clients on one project are
    ///     distinguishable.
    ///   - product: whose environment to consult: `<PREFIX>_CLIENT` names the
    ///     client when `client` does not.
    ///   - serverDescription: what the other end is called in errors — "no
    ///     <this> is listening at …". A product passes its own.
    ///   - unreachableHint: said when nothing is listening: how to start one.
    public init(socketPath: String, timeout: TimeInterval = 30, client: String? = nil,
                product: Product? = nil, serverDescription: String = "server", unreachableHint: String = "") {
        self.socketPath = socketPath
        self.timeout = timeout
        self.client = client
            ?? product.flatMap { ProcessInfo.processInfo.environment[$0.environmentVariable("CLIENT")] }
            ?? ProcessInfo.processInfo.processName
        self.serverDescription = serverDescription
        self.unreachableHint = unreachableHint
    }

    deinit { if fd >= 0 { close(fd) } }

    /// The development harness's socket (PD4), or wherever
    /// `<PREFIX>_SOCKET` says. A shipped server listens at
    /// `sessions/<pid>.sock` under the same directory (PD18) and is found
    /// by its descriptor, not by this; this default goes with the harness
    /// at N8.
    public static func defaultSocketPath(for product: Product,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment[product.environmentVariable("SOCKET")]
            ?? SupportPaths(product: product, environment: environment).directory + "/channel.sock"
    }

    public var isConnected: Bool { fd >= 0 }

    // MARK: - EngineClient

    public func catalogue() throws -> JSON {
        try result(of: ["catalogue": [:]])
    }

    /// The line protocol sends a refusal as an `error` frame, having taken
    /// the envelope's `ok: false` off it; `EngineClient` wants the envelope,
    /// so it is put back. The other three fields are the server's, verbatim.
    public func call(name: String, arguments: JSON) throws -> JSON {
        switch try answer(to: ["call": ["name": .string(name), "args": arguments]]) {
        case .result(let envelope): return envelope
        case .refusal(let error): return error.envelope
        }
    }

    public func read(uri: String) throws -> JSON {
        try result(of: ["read": ["uri": .string(uri)]])
    }

    public func prompt(name: String, arguments: JSON) throws -> JSON {
        try result(of: ["prompt": ["name": .string(name), "args": arguments]])
    }

    /// Also looks at the socket, without waiting: a change somebody else
    /// made while this client was idle is sitting there unread, and nothing
    /// else is going to read it until the next request.
    public func drainUpdates() -> [String] {
        if fd >= 0 { absorbUnsolicited() }
        defer { pendingUpdates = [] }
        return pendingUpdates
    }

    public func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        buffer = []
        saidHello = false
    }

    // MARK: - Connecting

    /// Connects if not already, and says hello. Every request goes through
    /// here, so a client that started before its server did still works
    /// from the first call that finds one.
    private func ensureConnected() throws {
        if fd >= 0 && saidHello { return }
        try connect()
        _ = try exchange(["hello": ["client": .string(client)]])
        saidHello = true
    }

    private func connect() throws {
        disconnect()
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw EngineError("could not create a socket: \(errno)") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxLength else {
            close(socketFD)
            throw EngineError("socket path is too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { destination in
                    _ = strcpy(destination, source)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, size) }
        }
        guard connected == 0 else {
            close(socketFD)
            throw EngineError("no \(serverDescription) is listening at \(socketPath)", hint: unreachableHint)
        }
        // EPIPE rather than SIGPIPE. A server that has gone away is the
        // ordinary case this type exists to report, and the default action
        // of the signal is to kill the process that was about to report it.
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
    }

    // MARK: - Request/response

    /// What came back. An `error` frame is an answer — the far end heard
    /// the question and said no — and is kept apart from a thrown
    /// `EngineError`, which means there was no answer: `call` has to tell
    /// the two apart, because only one of them is an envelope.
    private enum Answer {
        case result(JSON)
        case refusal(EngineError)
    }

    /// The line never left in full, so the server cannot have acted on it.
    private struct Unsent: Error { let error: EngineError }

    /// Runs one request, reconnecting once if the connection turns out to
    /// have dropped since it was last used. A viewer stays attached for
    /// hours; a server restarted underneath it should cost one reconnect,
    /// not the session.
    ///
    /// Only a request that was **never sent** is sent again. The old helper
    /// retried on anything it filed under E_APP_GONE, and that included a
    /// timeout and a connection that closed after the request had gone —
    /// so a slow `call` was made twice, and a commit the server had already
    /// taken could be taken again. Once the line is out, whatever happens
    /// next is reported, not repeated.
    private func answer(to body: JSON) throws -> Answer {
        // A server that went away while we were idle has left an
        // end-of-file to be read; finding it now is a clean reconnect
        // rather than a request written into a closed socket.
        if fd >= 0 { absorbUnsolicited() }
        for attempt in 1...2 {
            do {
                try ensureConnected()
                return try exchange(body)
            } catch let unsent as Unsent {
                disconnect()
                if attempt == 2 { throw unsent.error }
            }
        }
        throw EngineError("not connected to the \(serverDescription)")
    }

    private func result(of body: JSON) throws -> JSON {
        switch try answer(to: body) {
        case .result(let value): return value
        case .refusal(let error): throw error
        }
    }

    private func exchange(_ body: JSON) throws -> Answer {
        guard fd >= 0 else { throw Unsent(error: EngineError("not connected to the \(serverDescription)")) }
        nextID += 1
        let id = Double(nextID)
        var frame = JSONObject([("id", .number(id))])
        for pair in body.objectValue?.pairs ?? [] { frame[pair.key] = pair.value }
        try writeAll(Array((JSON.object(frame).stringified() + "\n").utf8))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let object = try readFrame(before: deadline) else {
                // A reply that turns up later would be read as the answer
                // to nothing; a connection this far behind is not worth
                // keeping.
                disconnect()
                throw EngineError("the server did not answer within \(JS.string(timeout)) seconds",
                                  hint: "it may still be working; ask again, or look at what it is doing")
            }
            // Unsolicited: keep it and go on waiting for our own reply.
            if absorb(object) { continue }
            guard object["id"]?.numberValue == id else { continue }
            if let error = object["error"] {
                return .refusal(EngineError(error["error"]?.stringValue ?? "the call failed",
                                            code: error["code"]?.stringValue ?? "E_UNKNOWN_ID",
                                            hint: error["hint"]?.stringValue ?? ""))
            }
            return .result(object["result"] ?? .null)
        }
    }

    /// True if the frame was one nobody asked for, and has been dealt with.
    private func absorb(_ object: JSON) -> Bool {
        if let uri = object["updated"]?["uri"]?.stringValue {
            pendingUpdates.append(uri)
            return true
        }
        if let log = object["log"] {
            diagnostic("[server] \(log["message"]?.stringValue ?? "")")
            return true
        }
        return false
    }

    /// Whatever has arrived while nothing was in flight. Never blocks.
    private func absorbUnsolicited() {
        // Already past: `readFrame` polls with no wait and comes back with
        // nil the moment there is nothing complete to read.
        let now = Date.distantPast
        while true {
            do {
                guard let object = try readFrame(before: now) else { return }
                // With no request in flight anything that is not
                // unsolicited is a reply nobody is waiting for.
                _ = absorb(object)
            } catch {
                disconnect()
                return
            }
        }
    }

    // MARK: - Framing

    private func writeAll(_ bytes: [UInt8]) throws {
        var remaining = bytes[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                disconnect()
                throw Unsent(error: EngineError("the server closed the connection",
                                                hint: "its host may have quit; the document autosaves, so nothing is lost"))
            }
            remaining = remaining.dropFirst(written)
        }
    }

    /// One JSON object, or nil once the deadline has passed. A partial line
    /// is held — a socket promises bytes, not messages — and a line that
    /// does not parse is dropped rather than ending the session, as the
    /// other end does with ours.
    private func readFrame(before deadline: Date) throws -> JSON? {
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let object = try? JSON.parse(bytes: line), object.objectValue != nil { return object }
            }
            let remaining = deadline.timeIntervalSinceNow
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(0, min(remaining, 1)) * 1000))
            if ready < 0 { if errno == EINTR { continue }; throw gone("the connection failed") }
            if ready == 0 {
                if remaining <= 0 { return nil }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; throw gone("the connection failed") }
            if count == 0 { throw gone("the server closed the connection") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func gone(_ what: String) -> EngineError {
        disconnect()
        return EngineError(what, hint: "its host may have quit; the document autosaves, so nothing is lost")
    }
}
