// The server's end of the local channel: a Unix-domain socket in the user's
// own domain, one JSON object per line (§4.3, D54, PD18).
//
// This is the app's `SocketServer`, moved to where the engine now lives.
// Under PD1 the app was the server and this listened at `channel.sock` for
// helpers; under D54 each host launches its own server, this listens at
// `sessions/<pid>.sock`, and what connects is the app — a viewer — and
// a product's `open` command. The protocol did not change and neither did the shape:
// POSIX sockets with a DispatchSource per connection rather than NWListener,
// which is the same thing with fewer moving parts for a local,
// one-file-per-server listener, and it mirrors `RemoteEngine`'s own client so
// both ends of the protocol read the same way. Nothing here understands a
// frame: it carries lines, and whoever is handed them does the JSON.
//
// What did change is whose thread it is. The app's was `@MainActor`, because
// everything in the app was. A server has no main actor to speak of — its
// main thread belongs to MCP's stdio — so this runs on a serial queue of its
// own, and every piece of state below is touched on that queue and nowhere
// else. That is the whole of the argument for `@unchecked Sendable`: the
// compiler cannot see a queue, so it is told; and the rule it is told about
// is kept by construction — every public entry point hops onto the queue
// before it reads or writes anything, the DispatchSources are made on it,
// and the handlers are called on it. There is no lock because there is no
// second thread.

import Foundation

/// What happens on the socket, in the order it happened.
public enum SocketEvent: Sendable, Hashable {
    /// A client connected and was given this id: `c1`, `c2`, … — never
    /// reused within a server, so a reply that races a disconnect cannot
    /// reach somebody else.
    case opened(String)
    /// One line from a client, already framed, without its newline.
    case line(String, String)
    /// The client has gone — it hung up, it was closed, or the server
    /// stopped. Exactly once for every `opened`.
    case closed(String)
}

public final class SocketServer: @unchecked Sendable {
    /// Called on the server's queue, one at a time, in order. They should
    /// not block: everything the socket does waits behind them. Calling back
    /// into the server from inside one — `send`, `close`, even `stop` — is
    /// expected and safe.
    public struct Handlers: Sendable {
        public var opened: @Sendable (String) -> Void
        public var line: @Sendable (String, String) -> Void
        public var closed: @Sendable (String) -> Void

        public init(opened: @escaping @Sendable (String) -> Void = { _ in },
                    line: @escaping @Sendable (String, String) -> Void,
                    closed: @escaping @Sendable (String) -> Void = { _ in }) {
            self.opened = opened
            self.line = line
            self.closed = closed
        }
    }

    /// See `LineBuffer.limit`. 64 MiB.
    public static let defaultMaxLineBytes = 64 << 20
    /// The most that may be queued for one client that is not reading.
    /// Writes never block (see `LineConnection`), which means what cannot be
    /// written is kept, and what is kept needs a bound: a viewer suspended
    /// for an afternoon would otherwise collect every `updated` push of the
    /// session. Past this the client is closed — it will find the server
    /// again when it wakes, and the document is on disk (§10.10). 256 MiB.
    public static let defaultMaxQueuedBytes = 256 << 20

    private let queue = DispatchQueue(label: "callboard.socket-server")
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private let handlers: Handlers?
    private let maxLineBytes: Int
    private let maxQueuedBytes: Int

    // Everything from here down: the queue's, and only the queue's.
    private var listenPath: String?
    private var acceptSource: DispatchSourceRead?
    private var connections: [String: LineConnection] = [:]
    private var nextID = 0
    private var stopped = false
    private var streams: [Int: AsyncStream<SocketEvent>.Continuation] = [:]
    private var nextStream = 0

    /// - Parameter handlers: nil for a consumer that would rather read
    ///   `events()`. Both may be used at once; the handlers are called first.
    public init(handlers: Handlers? = nil,
                maxLineBytes: Int = SocketServer.defaultMaxLineBytes,
                maxQueuedBytes: Int = SocketServer.defaultMaxQueuedBytes) {
        self.handlers = handlers
        self.maxLineBytes = maxLineBytes
        self.maxQueuedBytes = maxQueuedBytes
        queue.setSpecific(key: onQueueKey, value: true)
    }

    deinit {
        // A server dropped without `stop()` still must not leave a socket
        // file that looks served. Nobody else can be on the queue with a
        // reference to this object — there are none left — so this is the
        // one place state is touched off it.
        shutDown()
    }

    /// Runs `body` on the queue and waits — or just runs it, when the caller
    /// is already there, which is what makes it safe to call the server from
    /// inside one of its own handlers.
    private func onQueue<Result>(_ body: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    /// The same, without waiting: for `send` and `broadcast`, which an actor
    /// calls and must not be held up by. Order is kept either way — a serial
    /// queue is first in, first out — so an `updated` push sent before a
    /// reply is written before it (PD16).
    private func onQueueLater(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { body() } else { queue.async(execute: body) }
    }

    // MARK: - Listening

    /// Where this server is listening, or nil before `start` and after
    /// `stop`.
    public var path: String? { onQueue { listenPath } }

    public var connectionCount: Int { onQueue { connections.count } }

    /// Binds, and returns once the socket is accepting. The directory is the
    /// caller's to have made (`SupportPaths.ensure`); 0700 on it is half of
    /// what keeps this private, and 0600 on the socket is the other half.
    public func start(at path: String) throws {
        try onQueue {
            guard listenPath == nil, !stopped else {
                throw TransportError(.state, "a socket server starts once: make another")
            }
            try clearTheWay(at: path)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TransportError(.system, "could not create a socket: \(describe(errno))") }
            UnixSocket.closeOnExec(fd)

            guard let bound = UnixSocket.withAddress(path, { Darwin.bind(fd, $0, $1) }) else {
                Darwin.close(fd)
                throw TransportError(.pathTooLong, "socket path is too long to bind (\(path.utf8.count) bytes, and sun_path holds \(SupportPaths.sunPathCapacity - 1)): \(path)")
            }
            guard bound == 0 else {
                let code = errno
                Darwin.close(fd)
                // EADDRINUSE here means a file appeared between the look and
                // the bind: another server, starting at the same moment. It
                // is theirs.
                throw TransportError(code == EADDRINUSE ? .alreadyListening : .system,
                                     "could not bind \(path): \(describe(code))")
            }
            // 0600 before `listen`: the channel is the whole tool surface,
            // and it is this person's alone. Until it listens nobody can
            // connect whatever the mode says, so there is no moment at which
            // the socket is both open for business and open to others.
            chmod(path, 0o600)
            // Non-blocking, so that a client who connects and vanishes
            // between the event and the `accept` costs an EAGAIN and not the
            // queue. The backlog is generous because a full one *refuses*,
            // and a refusal is what a dead server looks like to a probe.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            guard listen(fd, 128) == 0 else {
                let code = errno
                Darwin.close(fd)
                unlink(path)
                throw TransportError(.system, "could not listen on \(path): \(describe(code))")
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(from: fd) }
            // The descriptor is closed by the source, once the source has
            // stopped using it — never out from under it.
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            acceptSource = source
            listenPath = path
            Log.say("listening at \(path)")
        }
    }

    /// A stale socket file from a server that did not shut down cleanly would
    /// make `bind` fail; removing it is what makes a crash recoverable
    /// without a person deleting a file they never made.
    ///
    /// But only a *stale* one. The app's server unlinked whatever was there,
    /// which was right when there was one server and one path; with a server
    /// per host, unlinking a live server's socket takes it off the map while
    /// it goes on running, holding its project's lock, reachable by nobody.
    /// So: connect first. If somebody answers it is theirs and this server
    /// does not start. (A path is `<pid>.sock`, so two live servers never
    /// want the same one and the look-then-bind below has nobody to race;
    /// what is found here is a dead server's file under a recycled pid.)
    private func clearTheWay(at path: String) throws {
        switch UnixSocket.probe(path) {
        case .absent:
            return
        case .listening:
            throw TransportError(.alreadyListening, "another server is already listening at \(path)")
        case .notASocket:
            throw TransportError(.occupied, "\(path) exists and is not a socket, so it is not this server's to remove")
        case .refused:
            Log.say("clearing a stale socket at \(path)")
            unlink(path)
        }
    }

    /// Closes every client, stops listening and removes the socket file.
    /// Every client still attached gets its `closed`; the event streams
    /// finish. Returns when it is done. A stopped server stays stopped.
    public func stop() {
        onQueue { shutDown() }
    }

    private func shutDown() {
        guard !stopped else { return }
        stopped = true
        acceptSource?.cancel()
        acceptSource = nil
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
        if let listenPath {
            unlink(listenPath)
            Log.say("stopped listening at \(listenPath)")
        }
        listenPath = nil
        for stream in streams.values { stream.finish() }
        streams.removeAll()
    }

    // MARK: - Events

    /// The same events the handlers get, as a stream an actor can consume in
    /// order — which is how a connection comes to have "one serial consumer"
    /// (PD16) without the actor being called from a queue it does not own.
    /// Ask for it before `start`, or miss what happened in between. Every
    /// call is a new stream, and each gets everything from then on; it ends
    /// when the server stops. Unbounded, because dropping a line is not an
    /// option and blocking the socket is worse; what bounds it in practice
    /// is that clients wait for a reply before they send again.
    public func events() -> AsyncStream<SocketEvent> {
        let (stream, continuation) = AsyncStream<SocketEvent>.makeStream(bufferingPolicy: .unbounded)
        onQueue {
            guard !stopped else { continuation.finish(); return }
            let token = nextStream
            nextStream += 1
            streams[token] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let server = self else { return }
                server.onQueueLater { server.streams[token] = nil }
            }
        }
        return stream
    }

    private func emit(_ event: SocketEvent) {
        if let handlers {
            switch event {
            case .opened(let id): handlers.opened(id)
            case .line(let id, let line): handlers.line(id, line)
            case .closed(let id): handlers.closed(id)
            }
        }
        for stream in streams.values { stream.yield(event) }
    }

    // MARK: - Connections

    private func acceptAll(from listenFD: Int32) {
        while !stopped {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                return   // EAGAIN: that was all of them
            }
            nextID += 1
            let clientId = "c\(nextID)"

            let connection = LineConnection(fd: fd, name: clientId, queue: queue,
                                            maxLineBytes: maxLineBytes, maxQueuedBytes: maxQueuedBytes) { [weak self] line in
                self?.emit(.line(clientId, line))
            } onClose: { [weak self] _ in
                guard let self, self.connections.removeValue(forKey: clientId) != nil else { return }
                self.emit(.closed(clientId))
            }
            connections[clientId] = connection
            Log.say("accept \(clientId) fd=\(fd) (\(connections.count) live)")
            emit(.opened(clientId))
            // Only now: `opened` is always the first thing said about a
            // client, and its first line cannot arrive before it.
            connection.resume()
        }
    }

    /// Sends one already-encoded line to a client; the newline is added if
    /// it is not there. Unknown ids are ignored: a reply racing a disconnect
    /// is ordinary, not an error. Never blocks and never waits — what a
    /// client is not reading is kept for it (LineConnection.swift).
    public func send(to clientId: String, line: String) {
        onQueueLater { [self] in
            guard let connection = connections[clientId] else {
                Log.say("send to \(clientId): no such connection (\(line.prefix(60)))")
                return
            }
            connection.write(line)
        }
    }

    /// One line to every client attached at the moment it is written.
    public func broadcast(_ line: String) {
        onQueueLater { [self] in
            for connection in Array(connections.values) { connection.write(line) }
        }
    }

    /// Hangs up on one client. It gets its `closed`, like any other.
    public func close(client clientId: String) {
        onQueueLater { [self] in connections[clientId]?.close() }
    }
}

private func describe(_ code: Int32) -> String { String(cString: strerror(code)) }
