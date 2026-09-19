// What the transport's tests stand on: a directory of their own, a client
// that is nothing but POSIX, and somewhere to put events until a test asks
// for them.
//
// Every test makes its own directory and its own socket in it, so nothing
// here has a fixed path or a port, and the suites can run in parallel with
// each other and with a second copy of themselves. The names are short on
// purpose: `sun_path` holds 104 bytes and the per-user temporary directory
// has spent half of them before a test has said anything.

import Foundation
import os
import Testing
import CallboardJSON
@testable import CallboardTransport

/// A directory that goes when the test does.
final class Scratch: Sendable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "us-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ name: String) -> String { path + "/" + name }
    var socket: String { file("s.sock") }
}

struct TestFailure: Error, CustomStringConvertible { let description: String }

/// The client's half, blocking, on the caller's thread: a test double for a
/// process, and it behaves like one. `RemoteEngine` is the real client and
/// is used where a whole exchange is wanted; this is for the tests that need
/// to misbehave — half a line, no reading, no goodbye.
final class RawClient: @unchecked Sendable {
    // `@unchecked`: each test uses its client from one place at a time, and
    // the buffer is only touched by whoever is reading.
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var scanned = 0
    private var closed = false

    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure(description: "socket: \(errno)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = UnixSocket.withAddress(path) { connect(fd, $0, $1) }
        guard connected == 0 else {
            // Not closed here: every stored property is set, so `deinit`
            // runs for an init that throws, and it closes. Closing twice is
            // not harmless — between the two, another test's socket can be
            // given the same number, and the second close is then of theirs.
            let code = errno
            throw TestFailure(description: "could not connect to \(path): \(String(cString: strerror(code)))")
        }
    }

    deinit { close() }

    func close() {
        if !closed { Darwin.close(fd) }
        closed = true
    }

    /// Exactly these bytes, no newline added: a test that wants half a line
    /// sends half a line.
    func send(_ text: String) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw TestFailure(description: "write: \(String(cString: strerror(errno)))") }
            offset += written
        }
    }

    enum Read: Equatable {
        case line(String)
        case endOfFile
        case timedOut
    }

    /// The next line, the end of the connection, or neither in time.
    func read(timeout: TimeInterval = 5) -> Read {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // Only what has not been searched already: five megabytes
            // arrive eight kilobytes at a time, and searching the lot after
            // every read is what takes the twenty seconds, not the socket.
            if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                scanned = 0
                return .line(line)
            }
            scanned = buffer.count
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 0.25) * 1000))
            if ready <= 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 1 << 18)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return .endOfFile }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func line(timeout: TimeInterval = 5) throws -> String {
        guard case .line(let text) = read(timeout: timeout) else {
            throw TestFailure(description: "no line arrived")
        }
        return text
    }
}

/// Events, kept, and a way to wait for some without sleeping for a guess.
final class Recorder: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [SocketEvent]())

    func record(_ event: SocketEvent) { events.withLock { $0.append(event) } }
    var all: [SocketEvent] { events.withLock { $0 } }

    var handlers: SocketServer.Handlers {
        SocketServer.Handlers(opened: { [self] in record(.opened($0)) },
                              line: { [self] in record(.line($0, $1)) },
                              closed: { [self] in record(.closed($0)) })
    }

    /// True once `satisfied` is, or false when five seconds were not enough.
    func wait(timeout: TimeInterval = 5, until satisfied: @Sendable ([SocketEvent]) -> Bool) async -> Bool {
        await eventually(timeout: timeout) { satisfied(self.all) }
    }
}

/// Polls, politely: the thing waited for happens on a dispatch queue or in
/// another process, and there is nothing to await but time.
func eventually(timeout: TimeInterval = 5, _ satisfied: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if satisfied() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return satisfied()
}

/// A server that answers every line with `{id, result: {client, echo}}` —
/// the line protocol's reply shape, naming the connection it came in on, so
/// a client can tell that the reply it got is its own.
final class EchoServer: Sendable {
    let server: SocketServer
    let recorder = Recorder()

    init(at path: String, maxLineBytes: Int = SocketServer.defaultMaxLineBytes) throws {
        let recorder = recorder
        let box = OSAllocatedUnfairLock<SocketServer?>(initialState: nil)
        server = SocketServer(handlers: SocketServer.Handlers(
            opened: { recorder.record(.opened($0)) },
            line: { clientId, line in
                recorder.record(.line(clientId, line))
                guard let frame = try? JSON.parse(line), frame.objectValue != nil else { return }
                let reply: JSON = ["id": frame["id"] ?? .null,
                                   "result": ["client": .string(clientId), "echo": frame["echo"] ?? .null]]
                box.withLock { $0 }?.send(to: clientId, line: reply.stringified())
            },
            closed: { recorder.record(.closed($0)) }), maxLineBytes: maxLineBytes)
        box.withLock { $0 = server }
        try server.start(at: path)
    }

    func stop() { server.stop() }
}

/// A pid that belonged to a process and no longer does.
func deadPid() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

func mode(of path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}
