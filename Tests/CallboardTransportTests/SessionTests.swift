// Where servers are found (PD18): the paths, the descriptor beside each
// socket, and the directory a viewer reads and watches — which believes a
// pid and a socket, and not a file.

import Foundation
import os
import Testing
import CallboardJSON
@testable import CallboardTransport

@Suite("where a server is found") struct SupportPathsTests {
    @Test("the support directory is the environment's, or the home's; an empty override is none")
    func directory() {
        #expect(SupportPaths(product: example, environment: [:], home: "/Users/ada").directory == "/Users/ada/Library/Application Support/Example")
        #expect(SupportPaths(product: example, environment: ["EXAMPLE_SUPPORT_DIR": ""], home: "/Users/ada").directory == "/Users/ada/Library/Application Support/Example")
        let paths = SupportPaths(product: example, environment: ["EXAMPLE_SUPPORT_DIR": "/tmp/elsewhere"], home: "/Users/ada")
        #expect(paths.directory == "/tmp/elsewhere")
        #expect(paths.sessions == "/tmp/elsewhere/sessions")
        #expect(paths.socketPath(pid: 4242) == "/tmp/elsewhere/sessions/4242.sock")
        #expect(paths.descriptorPath(pid: 4242) == "/tmp/elsewhere/sessions/4242.json")
        #expect(!paths.usesFallback(pid: 4242))
    }

    @Test("both directories are made 0700, and one of ours that has drifted is put back")
    func ensure() throws {
        let scratch = try Scratch()
        let paths = SupportPaths(directory: scratch.file("Example"), product: example)
        try paths.ensure()
        #expect(mode(of: paths.directory) == 0o700)
        #expect(mode(of: paths.sessions) == 0o700)
        chmod(paths.sessions, 0o755)
        try paths.ensure()
        #expect(mode(of: paths.sessions) == 0o700)
    }

    @Test("a support directory too long for sun_path moves the socket somewhere short, and the descriptor says where")
    func longPath() async throws {
        let scratch = try Scratch()
        let long = scratch.file(String(repeating: "a-very-long-folder-name/", count: 6) + "Example")
        let paths = SupportPaths(product: example, environment: ["EXAMPLE_SUPPORT_DIR": long])
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(!SupportPaths.fits("\(paths.sessions)/\(pid).sock"))

        let socket = paths.socketPath(pid: pid)
        #expect(paths.usesFallback(pid: pid))
        #expect(socket.hasPrefix("/tmp/example-\(getuid())/") && socket.hasSuffix("-\(pid).sock"))
        #expect(SupportPaths.fits(socket))
        // The descriptor stays where a reader will list it.
        #expect(paths.descriptorPath(pid: pid) == "\(long)/sessions/\(pid).json")
        // Another support directory, same pid: another socket.
        #expect(SupportPaths(directory: long + "2", product: example).socketPath(pid: pid) != socket)

        try paths.ensure(forSocketOf: pid)
        #expect(mode(of: SupportPaths(product: example).fallbackDirectory) == 0o700)
        let server = try EchoServer(at: socket)
        try SessionDescriptor(socket: socket, client: "claude-ai", version: "0.10.0").write(in: paths)

        // Found through the descriptor, and reachable where it says.
        let listed = SessionDirectory(paths).list()
        #expect(listed.map(\.socket) == [socket])
        let client = try RawClient(listed[0].socket)
        try client.send("{\"id\":1,\"echo\":\"by the short road\"}\n")
        #expect(try client.line().contains("by the short road"))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket))
    }
}

@Suite("the descriptor beside the socket") struct SessionDescriptorTests {
    @Test("is ordered JSON, rewritten whole when the project changes, and gone on a clean exit")
    func writeRewriteRemove() throws {
        let scratch = try Scratch()
        let paths = SupportPaths(directory: scratch.path, product: example)
        var descriptor = SessionDescriptor(socket: paths.socketPath(pid: 4242), pid: 4242, started: "2026-09-18T09:00:00.000Z",
                                           client: "claude-ai", version: "0.10.0")
        try descriptor.write(in: paths)
        let path = paths.descriptorPath(pid: 4242)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == """
        {
          "socket": "\(scratch.path)/sessions/4242.sock",
          "pid": 4242,
          "started": "2026-09-18T09:00:00.000Z",
          "client": "claude-ai",
          "project": null,
          "version": "0.10.0"
        }

        """)
        #expect(mode(of: path) == 0o600)
        #expect(SessionDescriptor.read(at: path) == descriptor)

        descriptor.project = .init(root: "/Shots/street-meet", id: "3f2a", title: "Street meet")
        try descriptor.write(in: paths)
        descriptor.project = .init(root: "/Shots/copy", id: "9c1b", title: nil)
        try descriptor.write(in: paths)
        let reread = try #require(SessionDescriptor.read(at: path))
        #expect(reread.project == .init(root: "/Shots/copy", id: "9c1b", title: nil))
        #expect(try JSON.parse(String(contentsOfFile: path, encoding: .utf8))["project"]?.objectValue?.keys == ["root", "id", "title"])
        // Replaced by rename, and the temp files went with the renames.
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.sessions) == ["4242.json"])

        SessionDescriptor.remove(pid: 4242, in: paths)
        #expect(!FileManager.default.fileExists(atPath: path))
        SessionDescriptor.remove(pid: 4242, in: paths)   // not finding it is fine
    }

    @Test("what is not a descriptor is not read as one")
    func rejects() throws {
        let good: JSON = ["socket": "/s", "pid": 12, "started": "t", "client": "app", "project": nil, "version": "1"]
        #expect(SessionDescriptor(json: good)?.client == SessionDescriptor.startedByTheApp)
        for (key, value) in [("pid", JSON.string("12")), ("pid", 0), ("pid", 1.5), ("socket", nil),
                             ("project", ["root": "/r"]), ("project", ["root": "/r", "id": "i", "title": 3])] {
            var object = good.objectValue!
            object[key] = value
            #expect(SessionDescriptor(json: .object(object)) == nil, "\(key): \(value.stringified())")
        }
        #expect(SessionDescriptor(json: ["socket": "/s"]) == nil)
        #expect(SessionDescriptor(json: [1, 2]) == nil)
    }

    @Test("a timestamp is ISO 8601 in UTC, and two of them sort as text in the order they happened")
    func timestamps() {
        let earlier = SessionDescriptor.timestamp(Date(timeIntervalSince1970: 1_789_290_000))
        let later = SessionDescriptor.timestamp(Date(timeIntervalSince1970: 1_789_290_000.25))
        #expect(earlier == "2026-09-13T09:00:00.000Z" && later == "2026-09-13T09:00:00.250Z")
        #expect(earlier < later)
    }
}

@Suite("the sessions directory") struct SessionDirectoryTests {
    /// A session that is really there: this process's pid would do for one,
    /// but a directory wants several, so each borrows the pid of a child
    /// that is kept alive for as long as the session is.
    private final class Session {
        let server: EchoServer
        let child = Process()
        let descriptor: SessionDescriptor

        init(in paths: SupportPaths, started: String, client: String = "claude-ai") throws {
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["120"]
            try child.run()
            let pid = child.processIdentifier
            try paths.ensure(forSocketOf: pid)
            server = try EchoServer(at: paths.socketPath(pid: pid))
            descriptor = SessionDescriptor(socket: paths.socketPath(pid: pid), pid: pid, started: started, client: client, version: "0.10.0")
            try descriptor.write(in: paths)
        }

        /// As a server that was killed goes: no tidying.
        func die() {
            child.terminate()
            child.waitUntilExit()
        }

        deinit {
            if child.isRunning { die() }
            server.stop()
        }
    }

    @Test("lists what is live, oldest first, and removes what is not: a dead pid, a socket nobody answers, a file named for nobody")
    func list() throws {
        let scratch = try Scratch()
        let paths = SupportPaths(directory: scratch.path, product: example)
        let directory = SessionDirectory(paths)
        #expect(directory.list() == [])   // no directory yet is no sessions, not an error

        let second = try Session(in: paths, started: "2026-09-18T10:00:00.000Z", client: "app")
        let first = try Session(in: paths, started: "2026-09-18T09:00:00.000Z")

        // A server that died: its descriptor and its socket file outlive it.
        let gone = try deadPid()
        let staleSocket = paths.socketPath(pid: gone)
        let bound = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(UnixSocket.withAddress(staleSocket) { bind(bound, $0, $1) } == 0)
        close(bound)
        try SessionDescriptor(socket: staleSocket, pid: gone, started: "2026-09-18T08:00:00.000Z", client: "claude-ai", version: "0.10.0").write(in: paths)

        // A pid that is alive — this one — with nobody at the socket: the
        // pid was recycled, or the server has stopped listening.
        let mine = ProcessInfo.processInfo.processIdentifier
        try SessionDescriptor(socket: scratch.file("nobody.sock"), pid: mine, started: "2026-09-18T07:00:00.000Z", client: "claude-ai", version: "0.10.0").write(in: paths)

        // Not descriptors. One is named for a dead process and goes; the
        // other is somebody's file and is none of our business.
        let anotherGone = try deadPid()
        try "{".write(toFile: paths.descriptorPath(pid: anotherGone), atomically: true, encoding: .utf8)
        try "shopping".write(toFile: paths.sessions + "/notes.json", atomically: true, encoding: .utf8)

        #expect(directory.list() == [first.descriptor, second.descriptor])
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.sessions).sorted()
        #expect(left == ["\(first.descriptor.pid).json", "\(first.descriptor.pid).sock",
                         "\(second.descriptor.pid).json", "\(second.descriptor.pid).sock", "notes.json"].sorted())

        // Killed, not stopped: nothing in the directory changes, and the
        // next listing finds out anyway — without knocking, if asked not to.
        first.die()
        #expect(directory.list(probeSockets: false) == [second.descriptor])
        #expect(!FileManager.default.fileExists(atPath: paths.descriptorPath(pid: first.descriptor.pid)))
    }

    @Test("watch yields the list now, and again when a server arrives, changes project, and leaves")
    func watch() async throws {
        let scratch = try Scratch()
        let paths = SupportPaths(directory: scratch.path, product: example)
        let seen = OSAllocatedUnfairLock(initialState: [[SessionDescriptor]]())
        let watching = Task {
            for await list in SessionDirectory(paths).watch(recheckEvery: nil) { seen.withLock { $0.append(list) } }
        }
        defer { watching.cancel() }
        #expect(await eventually { seen.withLock { $0 } == [[]] })

        let session = try Session(in: paths, started: "2026-09-18T09:00:00.000Z")
        let arrived = session.descriptor
        #expect(await eventually { seen.withLock { $0.last } == [arrived] })

        var changing = arrived
        changing.project = .init(root: "/Shots/street-meet", id: "3f2a", title: "Street meet")
        try changing.write(in: paths)
        let moved = changing
        #expect(await eventually { seen.withLock { $0.last } == [moved] })

        session.server.stop()
        SessionDescriptor.remove(pid: moved.pid, in: paths)
        #expect(await eventually { seen.withLock { $0.last } == [] })

        // Nothing is said twice: every list differs from the one before it.
        let all = seen.withLock { $0 }
        #expect(zip(all, all.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test("a server that is killed raises no event, and the slow recheck notices all the same")
    func watchNoticesADeath() async throws {
        let scratch = try Scratch()
        let paths = SupportPaths(directory: scratch.path, product: example)
        let session = try Session(in: paths, started: "2026-09-18T09:00:00.000Z")
        let seen = OSAllocatedUnfairLock(initialState: [[SessionDescriptor]]())
        let watching = Task {
            for await list in SessionDirectory(paths).watch(recheckEvery: 0.2) { seen.withLock { $0.append(list) } }
        }
        defer { watching.cancel() }
        let descriptor = session.descriptor
        #expect(await eventually { seen.withLock { $0.last } == [descriptor] })

        session.die()
        #expect(await eventually { seen.withLock { $0.last } == [] })
    }
}
