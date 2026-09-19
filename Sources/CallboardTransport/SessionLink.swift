// The viewer's end of the local channel (§4.3, §11, D54, D56, D57; PLAN §12
// N6): a connection to a server somebody else started, that asks questions
// and — which is the point — hears things it did not ask about.
//
// `RemoteEngine` already speaks this protocol from the client's side, and it
// cannot be the viewer's client. It reads the socket only while one of its
// own requests is waiting, because that is all a command-line tool needs: a
// question, an answer, goodbye. A window is the other way round. It asks
// almost nothing and is told almost everything — "refresh comes from
// `updated` pushes; the two-second poll goes" (N7) — and the push that
// matters most is the one that arrives while the window is doing nothing at
// all: an agent has placed a stand-in, and a person is looking at a viewport
// that does not show it yet. So this end is always reading. Lines are parsed
// as they arrive, on the link's own queue, whether or not anybody is
// waiting: a reply goes to the caller whose `id` it carries, an `updated`
// goes to `events`, and the end of the connection goes to everybody.
//
// Several requests may be in flight at once, because the server allows it
// and the viewer needs it: an export takes as long as it takes (the engine
// leaves its actor for the GPU, PD16), and a person who starts one has not
// agreed to a frozen window until it is done. Hence ids, a table of who is
// waiting for which, and a timeout that belongs to the request and not to
// the link — thirty seconds is generous for a `read` and nothing like
// enough for an export, so `call` takes its own. A reply that turns up
// after its caller gave up finds nobody under its id and is dropped; the
// connection is none the worse, which is what matching by id buys over
// `RemoteEngine`'s "one thing in flight", where a late reply would be read
// as the answer to the next question and the only safe course was to hang
// up.
//
// Nothing here blocks a thread of the cooperative pool. The actor runs on a
// serial dispatch queue of its own, the same queue its `LineConnection`
// reads and writes on, so a line arriving *is* a job on the actor — no hop,
// no `Task` per line (which would let a reply overtake the `updated` that
// preceded it on the wire, PD16), no lock. Writes are the connection's:
// queued and never waited on, so a server busy elsewhere costs this end
// nothing but memory.
//
// Who a client on this socket is, was settled by its arriving on it: a
// person (§11.3). Nothing the link sends can change that, and nothing in it
// tries to.

import Foundation
import CallboardJSON

/// What a link throws. Either the server refused — an unknown resource, a
/// project that is not open — and these are its three fields, verbatim; or
/// there was no answer at all, and `code` is `gone` or `timedOut`. The code
/// is a string and not Core's closed `ErrorCode` for the reason
/// `EngineError`'s is: a viewer may be attached to a newer server than it
/// was built against, and must be able to repeat a code it has never heard
/// of.
public struct LinkError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var error: String
    public var hint: String

    public init(_ error: String, code: String = LinkError.gone, hint: String = "") {
        self.code = code
        self.error = error
        self.hint = hint
    }

    /// Nothing is on the other end: never connected, hung up, or the server
    /// went. A transport fact, not an Appendix B refusal.
    public static let gone = "E_SERVER_GONE"
    /// The server is there and has not answered in the time this request
    /// was given. It may yet — the link stays up, and the reply, if it
    /// comes, is dropped.
    public static let timedOut = "E_TIMED_OUT"

    public var description: String { hint.isEmpty ? error : "\(error) — \(hint)" }

    /// The §10.4 failure, in the order `fail()` has always built it.
    public var envelope: JSON {
        ["ok": false, "code": .string(code), "error": .string(error), "hint": .string(hint)]
    }
}

public actor SessionLink {
    public enum Event: Sendable, Equatable {
        /// A resource changed — its URI. Somebody committed: this client, an
        /// agent, another window. Arrives before the reply to the call that
        /// caused it, when that call was this link's own (PD16).
        case updated(String)
        /// The link has ended, and why, in words for a person. Once, and
        /// last: the stream finishes after it.
        case closed(String)
    }

    private let queue = DispatchSerialQueue(label: "callboard.session-link")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let socketPath: String
    private let timeout: Duration
    private let client: String
    private let serverDescription: String

    /// Pushes, as they arrive — also while nothing is being asked. One
    /// consumer: an `AsyncStream` is not a broadcast, and a second `for
    /// await` would share the events out between the two, not copy them.
    /// Unbounded, because a dropped `updated` is a stale window; what
    /// bounds it is that a URI is a few dozen bytes and a consumer that
    /// has stopped listening has usually stopped existing.
    public nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation

    private enum Answer: Sendable {
        case result(JSON)
        case refusal(LinkError)
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Answer, any Error>
        let alarm: Task<Void, Never>
    }

    private var connection: LineConnection?
    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0
    /// Set once, by whichever of `disconnect`, end-of-file or an error gets
    /// there first. A link is used once: a viewer that loses its server
    /// makes another for the next one, since what it would be reconnecting
    /// to is a different process with a different socket.
    private var ended: String?

    /// - Parameters:
    ///   - timeout: how long one reply may take, unless the request says
    ///     otherwise.
    ///   - client: named in the server's log, so two windows on one project
    ///     can be told apart there. It does not decide who the client *is*.
    ///   - serverDescription: what the other end is called when it is not
    ///     there — "no <this> is listening at …". A product passes its own:
    ///     "Example server".
    public init(socketPath: String, timeout: Duration = .seconds(30), client: String = "viewer",
                serverDescription: String = "server") {
        self.socketPath = socketPath
        self.timeout = timeout
        self.client = client
        self.serverDescription = serverDescription
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        // A link let go of without a goodbye still must not leak a
        // descriptor and two dispatch sources. The connection is the
        // queue's, so that is where it is closed.
        if let connection { queue.async { connection.close() } }
        sink.finish()
    }

    public var isConnected: Bool { connection != nil && ended == nil }

    // MARK: - Connecting

    /// Connects and says hello. Throws if nothing is listening.
    public func connect() async throws {
        guard connection == nil, ended == nil else {
            throw LinkError("a session link connects once", hint: "make another for another server")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LinkError("could not create a socket: \(String(cString: strerror(errno)))") }
        // A Unix-domain connect is answered at once — accepted into the
        // listener's backlog, or refused — so this is not a wait.
        guard let connected = UnixSocket.withAddress(socketPath, { Darwin.connect(fd, $0, $1) }) else {
            Darwin.close(fd)
            throw LinkError("socket path is too long to connect to: \(socketPath)")
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LinkError("no \(serverDescription) is listening at \(socketPath) (\(String(cString: strerror(code))))",
                            hint: "it may have exited; the session list says which servers are running")
        }

        // The callbacks arrive on `queue`, which is this actor's executor:
        // they are already where the actor's state lives, and say so.
        let connection = LineConnection(fd: fd, name: "link", queue: queue,
                                        maxLineBytes: SocketServer.defaultMaxLineBytes,
                                        maxQueuedBytes: SocketServer.defaultMaxQueuedBytes) { [weak self] line in
            self?.assumeIsolated { $0.received(line) }
        } onClose: { [weak self] end in
            self?.assumeIsolated { $0.end(because: SessionLink.words(for: end)) }
        }
        self.connection = connection
        connection.resume()

        do {
            _ = try await result(of: ["hello": ["client": .string(client)]], timeout: timeout)
        } catch {
            end(because: "the server did not answer hello")
            throw error
        }
    }

    /// Hangs up. Whoever is waiting is told; `events` gets its `closed` and
    /// finishes. Harmless to call twice, or on a link that never connected.
    public func disconnect() {
        end(because: "disconnected")
    }

    // MARK: - Asking

    public func catalogue() async throws -> JSON {
        try await result(of: ["catalogue": [:]], timeout: timeout)
    }

    /// The §10.4 envelope, ok or not. A refusal is an answer, so it comes
    /// back as `{ok: false, code, error, hint}` — the line protocol carries
    /// it as an `error` frame, having taken the envelope's `ok` off it, and
    /// it is put back here. What is thrown is the absence of an answer.
    ///
    /// - Parameter timeout: for this call only. An export wants minutes.
    public func call(_ tool: String, _ arguments: JSON = [:], timeout: Duration? = nil) async throws -> JSON {
        switch try await answer(to: ["call": ["name": .string(tool), "args": arguments]], timeout: timeout ?? self.timeout) {
        case .result(let envelope): return envelope
        case .refusal(let refusal): return refusal.envelope
        }
    }

    /// A resource's body. A refusal is thrown, as a `LinkError` with the
    /// server's code, error and hint: a read has no envelope to carry one.
    public func read(_ uri: String, timeout: Duration? = nil) async throws -> JSON {
        try await result(of: ["read": ["uri": .string(uri)]], timeout: timeout ?? self.timeout)
    }

    private func result(of body: JSON, timeout: Duration) async throws -> JSON {
        switch try await answer(to: body, timeout: timeout) {
        case .result(let value): return value
        case .refusal(let refusal): throw refusal
        }
    }

    private func answer(to body: JSON, timeout: Duration) async throws -> Answer {
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Answer, any Error>) in
                // Still on the actor, and nothing has suspended since `id`
                // was taken: registering and writing are one step, so a
                // reply cannot arrive to find nobody waiting for it.
                guard let connection, ended == nil else {
                    continuation.resume(throwing: LinkError(ended.map { "not connected to a server: \($0)" } ?? "not connected to a server",
                                                            hint: "connect() first; a link that has closed is not reused"))
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let alarm = Task { [weak self, timeout] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.expire(id, after: timeout)
                }
                waiters[id] = Waiter(continuation: continuation, alarm: alarm)

                var frame = JSONObject([("id", .number(Double(id)))])
                for pair in body.objectValue?.pairs ?? [] { frame[pair.key] = pair.value }
                connection.write(JSON.object(frame).stringified())
            }
        } onCancel: {
            Task { [weak self] in await self?.abandon(id) }
        }
    }

    private func settle(_ id: Int, _ outcome: Result<Answer, any Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.alarm.cancel()
        waiter.continuation.resume(with: outcome)
    }

    private func expire(_ id: Int, after timeout: Duration) {
        settle(id, .failure(LinkError("the server did not answer within \(timeout)", code: LinkError.timedOut,
                                      hint: "it may still be working; the link is still up, and a long call can be given a longer timeout")))
    }

    /// The caller's task was cancelled. The request has gone and cannot be
    /// called back; its reply will find nobody waiting, and be dropped.
    private func abandon(_ id: Int) {
        settle(id, .failure(CancellationError()))
    }

    // MARK: - Hearing

    private func received(_ line: String) {
        // A line that is not a JSON object is dropped, not fatal — as the
        // other end does with ours.
        guard let frame = try? JSON.parse(line), frame.objectValue != nil else { return }
        if let uri = frame["updated"]?["uri"]?.stringValue {
            sink.yield(.updated(uri))
            return
        }
        if let log = frame["log"] {
            Log.say("[server] \(log["message"]?.stringValue ?? log.stringified())")
            return
        }
        guard let number = frame["id"]?.numberValue, let id = Int(exactly: number) else { return }
        if let error = frame["error"] {
            settle(id, .success(.refusal(LinkError(error["error"]?.stringValue ?? "the call failed",
                                                   code: error["code"]?.stringValue ?? "E_UNKNOWN_ID",
                                                   hint: error["hint"]?.stringValue ?? ""))))
        } else {
            settle(id, .success(.result(frame["result"] ?? .null)))
        }
    }

    /// The one way a link ends, whoever ended it.
    private func end(because reason: String) {
        guard ended == nil else { return }
        ended = reason
        // `close()` calls back into here, and finds `ended` already set.
        connection?.close()
        connection = nil
        let failure = LinkError(reason, hint: "the document autosaves, so nothing is lost; attach again when a server has the project open")
        for id in Array(waiters.keys) { settle(id, .failure(failure)) }
        sink.yield(.closed(reason))
        sink.finish()
    }

    private static func words(for end: LineConnection.End) -> String {
        switch end {
        case .endOfFile: "the server closed the connection"
        case .lineTooLong: "the server sent a line too long to be a frame"
        case .notReading: "the server stopped reading, and too much was waiting to be sent"
        case .writeFailed: "the server has gone"
        case .closedHere: "disconnected"
        }
    }
}
