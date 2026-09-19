// One end of one connection on the local channel: bytes in as lines, lines
// out as bytes, and neither direction ever blocking (§4.3, D54, PD16).
//
// This was `SocketServer.Connection`, private to the server, until the
// viewer's end of the channel (`SessionLink`, N6) needed exactly the same
// thing: a descriptor that is read when there is something to read, written
// when there is room, and closed once, by whoever gets there first. Two
// copies of the write path would have been two chances to bring back the
// bug it exists to prevent — so there is one, and both ends of the protocol
// stand on it.
//
// Writes are non-blocking and buffered, which is not a refinement: the app's
// first server wrote straight to a blocking descriptor on its one queue, and
// a `catalogue` reply is tens of kilobytes. When a client stopped reading —
// exiting because its host closed stdin, which was the ordinary way a
// session ended — the socket buffer filled and `write` blocked the queue for
// ever. The server stayed alive, listening, accepting connections, and
// answering none of them; every later client was told the server had gone
// by a server that was running fine. The clients are different now (D54: a
// viewer, not a helper) and the bug would be the same one: a viewer put to
// sleep mid-read would stop an agent's session, and a server busy with an
// export would stall a viewer's every other request behind one `write`. So
// what cannot be written now waits in `outbox`, and a write source says when
// there is room.
//
// The owner's queue's, and only that queue's: made on it, called on it, and
// its callbacks come back on it. That is the whole of the argument for
// `@unchecked Sendable` — the compiler cannot see a queue, so it is told.

import Foundation

final class LineConnection: @unchecked Sendable {
    /// Why a connection ended. The two ends put it differently — to a server
    /// an end of file is a client leaving, to a viewer it is the server
    /// going — so this says what happened and leaves the words to them.
    enum End: Sendable, Equatable {
        /// The peer closed its end, or the read failed.
        case endOfFile
        /// A line ran past `maxLineBytes` (LineBuffer.swift).
        case lineTooLong
        /// More than `maxQueuedBytes` waiting for a peer that is not reading.
        case notReading
        /// A write was refused: EPIPE, the peer has gone.
        case writeFailed
        /// `close()` was called on this end.
        case closedHere
    }

    private let fd: Int32
    private let name: String
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private let onLine: (String) -> Void
    private let onClose: (End) -> Void
    private let maxQueuedBytes: Int
    private var inbox: LineBuffer
    private var outbox: [UInt8] = []
    /// `outbox[..<sent]` has gone. Advancing an index and compacting now
    /// and then, rather than removing from the front after every write,
    /// which for a five-megabyte reply leaving eight kilobytes at a time
    /// is a copy of the lot six hundred times over.
    private var sent = 0
    private var writing = false
    private var reading = false
    private var closed = false

    /// Takes the descriptor over: it is closed by this object and by nobody
    /// else. `onLine` and `onClose` are called on `queue`; `onClose` exactly
    /// once. Nothing is read until `resume()`.
    init(fd: Int32, name: String, queue: DispatchQueue, maxLineBytes: Int, maxQueuedBytes: Int,
         onLine: @escaping (String) -> Void, onClose: @escaping (End) -> Void) {
        self.fd = fd
        self.name = name
        self.onLine = onLine
        self.onClose = onClose
        self.maxQueuedBytes = maxQueuedBytes
        inbox = LineBuffer(limit: maxLineBytes)

        // Non-blocking, and EPIPE rather than SIGPIPE — a peer that goes
        // away must be an error code, not a signal that kills the server
        // and the session of the agent it was serving, or the viewer that
        // was about to say the server had gone.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        UnixSocket.closeOnExec(fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        writeSource.setEventHandler { [weak self] in self?.flush() }
        // One cancel handler closes the descriptor, and only after both
        // sources have stopped using it. Both run on the one queue, so
        // the count needs no lock; it needs a box, to be shared.
        let remaining = Remaining()
        let closeWhenDone = {
            remaining.count -= 1
            if remaining.count == 0 { Darwin.close(fd) }
        }
        readSource.setCancelHandler(handler: closeWhenDone)
        writeSource.setCancelHandler(handler: closeWhenDone)
    }

    private final class Remaining: @unchecked Sendable { var count = 2 }

    /// Starts reading. Once: a second call, or one after `close()`, is
    /// nothing — a source resumed twice is a crash, not a no-op.
    func resume() {
        guard !reading else { return }
        reading = true
        readSource.resume()
    }

    /// One read per event, not a loop to EAGAIN: the source fires again
    /// while there is more, and in between the queue gets to serve whoever
    /// else is on it. A peer pouring lines in cannot starve the rest.
    private func readAvailable() {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            // End of file. A line with no newline dies with it: a line
            // is not a line until it has ended (LineBuffer.swift).
            close(.endOfFile)
            return
        }
        let (lines, overflowed) = chunk.withUnsafeBytes { inbox.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        for line in lines {
            // A handler may hang up, or stop the server, in answer to a
            // line. What had been sent after that is not delivered to
            // somebody who has said they are done.
            if closed { return }
            Log.say("recv \(name) \(line.prefix(70))")
            onLine(line)
        }
        if overflowed && !closed {
            Log.say("close \(name): a line ran past the limit")
            close(.lineTooLong)
        }
    }

    /// One line; the newline is added if it is not there. Never blocks.
    func write(_ line: String) {
        guard !closed else { return }
        outbox.append(contentsOf: line.utf8)
        if !line.hasSuffix("\n") { outbox.append(0x0A) }
        if outbox.count - sent > maxQueuedBytes {
            Log.say("close \(name): \(outbox.count - sent) bytes queued and it is not reading")
            close(.notReading)
            return
        }
        flush()
    }

    /// Writes what it can and leaves the rest for the write source. The
    /// source only runs while there is something to send, so an idle
    /// connection costs nothing.
    private func flush() {
        while sent < outbox.count && !closed {
            let written = outbox.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
            }
            if written > 0 {
                sent += written
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if sent > (1 << 20) { outbox.removeFirst(sent); sent = 0 }
                if !writing { writing = true; writeSource.resume() }
                return
            }
            close(.writeFailed)   // EPIPE: the peer has gone
            return
        }
        if !closed {
            // All of it went. A small buffer is kept for the next line; a
            // five-megabyte one is given back.
            outbox.removeAll(keepingCapacity: outbox.capacity <= (1 << 16))
            sent = 0
        }
        if writing { writing = false; writeSource.suspend() }
    }

    func close() { close(.closedHere) }

    private func close(_ end: End) {
        guard !closed else { return }
        Log.say("close \(name) (\(end))")
        closed = true
        outbox = []
        sent = 0
        // A suspended source cannot be cancelled, so resume it first. And a
        // read source that was never resumed is suspended too.
        if !writing { writeSource.resume() }
        writing = false
        if !reading { reading = true; readSource.resume() }
        readSource.cancel()
        writeSource.cancel()
        onClose(end)
    }
}
