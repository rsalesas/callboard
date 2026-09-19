// The pipe a host holds (§10.1, D9): a line in, a line out.
//
// One request at a time, in the order they arrive. A host's stdio transport
// is one pipe, and serialising keeps replies in order — which also means a
// slow call cannot be overtaken by a fast one. Everything that is written
// is written by the one loop below, so two lines can never interleave, and
// stdout carries protocol lines and nothing else.
//
// ## How stdin is read, and why not `FileHandle.bytes.lines`
//
// The obvious async reader is wrong for this protocol. `AsyncLineSequence`
// ends a line at every Unicode line break — U+2028, U+2029, U+0085, VT and
// FF as well as LF and CR — and JSON allows U+2028 and U+2029 *raw* inside
// a string (`JSON.stringify` does not escape them). A host forwarding text
// pasted from a web page would have one request arrive as two halves,
// neither of which parses. Newline-delimited JSON means the byte 0x0A and
// only that.
//
// So a dedicated thread does blocking `read(2)` and splits on 0x0A itself,
// feeding an `AsyncStream` the loop consumes. A thread rather than a task
// because a blocking read must not sit on one of the cooperative pool's few
// threads for the life of the process; a plain `read` rather than a
// readability handler because its end conditions are the ones we want and
// no others: `0` is the host closing the pipe, `EINTR` is retried, anything
// else is treated as the pipe being gone. The stream is finished *after*
// the lines already read have been yielded, so `printf … | <command>` —
// which is how CI drives it — gets every reply before the process exits,
// and a final line with no newline after it is still a line.
//
// ## Updates while the host is quiet
//
// The old helper flushed `notifications/resources/updated` only after a
// reply, so a change made by somebody else — a person in the witness — was
// announced at the host's next request, however long that was. Here the
// same loop also takes a tick, and only while a subscription exists: no
// subscriber, no timer. A tick is an event in the *same* queue as the
// lines, so it is handled between requests and never during one, and the
// single-writer property above holds without a lock around stdout.

import Foundation
import os
import CallboardJSON

public struct StdioTransport: Sendable {
    private let input: Int32
    private let output: Int32
    private let idleInterval: Duration

    /// The descriptors are parameters so a test can hand it two pipes.
    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                idleInterval: Duration = .milliseconds(500)) {
        self.input = input
        self.output = output
        self.idleInterval = idleInterval
    }

    private enum Event: Sendable {
        case line([UInt8])
        case tick
    }

    /// Serves until the input closes or the output cannot be written —
    /// either way the host has gone, and its server goes with it (§4.3).
    public func run(_ server: MCPServer) async {
        // A host that dies mid-reply must cost us an EPIPE we can see, not
        // a signal whose default is to kill the process without a word.
        signal(SIGPIPE, SIG_IGN)

        let (events, continuation) = AsyncStream<Event>.makeStream()
        startReader(continuation)

        // At most one tick waits in the queue at a time, however long the
        // request in front of it takes: an export does not come back to a
        // few hundred of them.
        let tickQueued = OSAllocatedUnfairLock(initialState: false)
        var ticker: Task<Void, Never>?
        defer { ticker?.cancel() }

        loop: for await event in events {
            switch event {
            case .line(let bytes):
                let line = String(decoding: bytes, as: UTF8.self)
                if line.allSatisfy(\.isWhitespace) { continue }
                if let reply = await server.handle(line: line), !write(reply) { break loop }
            case .tick:
                tickQueued.withLock { $0 = false }
            }
            // Whatever changed during that round trip — or, on a tick,
            // since the last one.
            for notification in await server.flushNotifications() {
                if !write(notification) { break loop }
            }

            let wanted = await server.hasSubscriptions
            if wanted, ticker == nil {
                let interval = idleInterval
                ticker = Task {
                    while (try? await Task.sleep(for: interval)) != nil {
                        let alreadyQueued = tickQueued.withLock { queued in
                            defer { queued = true }
                            return queued
                        }
                        if !alreadyQueued { continuation.yield(.tick) }
                    }
                }
            } else if !wanted, let running = ticker {
                running.cancel()
                ticker = nil
            }
        }
        diagnostic("the host has gone; stopping")
    }

    // MARK: - Reading

    private func startReader(_ continuation: AsyncStream<Event>.Continuation) {
        let fd = input
        let thread = Thread {
            var pending: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(contentsOf: chunk[0..<count])
                // A pipe promises bytes, not messages: a partial line is
                // held until its newline arrives.
                while let newline = pending.firstIndex(of: 0x0A) {
                    continuation.yield(.line(Array(pending[..<newline])))
                    pending.removeSubrange(...newline)
                }
            }
            if !pending.isEmpty { continuation.yield(.line(pending)) }
            continuation.finish()
        }
        thread.name = "callboard.stdin"
        thread.start()
    }

    // MARK: - Writing

    /// One message, one line. `stringified()` is `JSON.stringify`'s compact
    /// form, which escapes every control character, so there is no raw
    /// newline in it. It leaves U+2028 and U+2029 raw, as JavaScript does —
    /// legal JSON, but some hosts read their end of the pipe with a line
    /// reader that breaks on them, for the reason given at the top of this
    /// file. They can only occur inside a string, where the escape means
    /// the same thing, so they are escaped on the way out.
    private func write(_ message: JSON) -> Bool {
        let line = message.stringified()
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029") + "\n"
        var bytes = Array(line.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            bytes = bytes.dropFirst(written)
        }
        return true
    }
}
