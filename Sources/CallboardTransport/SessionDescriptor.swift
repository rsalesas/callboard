// What a running server says about itself, written beside its socket
// (§4.3: it "publishes the server's local channel … with a descriptor naming
// the project it serves"; PD18).
//
// The app's server wrote one too — `channel.json`, so a person or
// a `status` command could see which process was listening without
// guessing. With one server that was a courtesy. With a server per host it
// is how the viewer finds anything at all: `sessions/` is the list of what
// is running, and each `<pid>.json` is a row of it — which project, opened
// by which host, since when, reachable where.
//
// It is a claim, not a fact. A server that is killed does not get to tidy
// up, so its descriptor outlives it, and a reader that believed the file
// would offer a session that is not there. `SessionDirectory` does not
// believe it (PD18: "checks pid liveness rather than trusting a file"): the
// pid must be alive and the socket must answer, or the row is dropped and
// the file deleted, since nobody else is going to.
//
// Ordered JSON, by the package's own writer, for the reason everything else
// here is: a person will `cat` this, and a file whose keys move about
// between two writes of the same thing reads as though something changed.

import Foundation
import CallboardJSON

public struct SessionDescriptor: Sendable, Equatable {
    /// The project a server has loaded. `root` is what D55's lock is on;
    /// `id` is the project's own (D51), which is what tells the viewer that
    /// the project it had open under another path is this one.
    public struct Project: Sendable, Equatable {
        public var root: String
        public var id: String
        public var title: String?

        public init(root: String, id: String, title: String?) {
            self.root = root
            self.id = id
            self.title = title
        }
    }

    /// Where the socket really is — `sessions/<pid>.sock`, or the short path
    /// it fell back to (SupportPaths.swift). Read it; never derive it.
    public var socket: String
    public var pid: Int32
    /// ISO 8601, UTC: `SessionDescriptor.timestamp()`.
    public var started: String
    /// The MCP host's name as it gave it in `initialize` — "claude-ai",
    /// "Claude Code" — or `"app"` for a server the viewer started itself
    /// (D57). It is what E_PROJECT_LOCKED's hint calls the holder.
    public var client: String
    /// Nil until something is opened: a server is running, and findable,
    /// from before its first project was opened.
    public var project: Project?
    public var version: String

    public static let startedByTheApp = "app"

    public init(socket: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                started: String = SessionDescriptor.timestamp(), client: String,
                project: Project? = nil, version: String) {
        self.socket = socket
        self.pid = pid
        self.started = started
        self.client = client
        self.project = project
        self.version = version
    }

    /// Now, the way `DiskHost.now()` writes it: one format, in UTC, so that
    /// two of them compare as text in the order they happened.
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - JSON

    public var json: JSON {
        let project: JSON = self.project.map {
            ["root": .string($0.root), "id": .string($0.id), "title": $0.title.map(JSON.string) ?? .null]
        } ?? .null
        return [
            "socket": .string(socket),
            "pid": .number(Double(pid)),
            "started": .string(started),
            "client": .string(client),
            "project": project,
            "version": .string(version),
        ]
    }

    /// Nil for anything that is not one of these — half a file, another
    /// program's JSON, a descriptor from a version that means something else
    /// by the same words. A reader skips what it cannot read; it does not
    /// guess.
    public init?(json: JSON) {
        guard let socket = json["socket"]?.stringValue,
              let pid = json["pid"]?.numberValue, pid >= 1, pid <= Double(Int32.max), pid == pid.rounded(),
              let started = json["started"]?.stringValue,
              let client = json["client"]?.stringValue,
              let version = json["version"]?.stringValue,
              let project = json["project"] else { return nil }
        if project.isNull {
            self.project = nil
        } else {
            guard let root = project["root"]?.stringValue, let id = project["id"]?.stringValue,
                  let title = project["title"] else { return nil }
            guard title.isNull || title.stringValue != nil else { return nil }
            self.project = Project(root: root, id: id, title: title.stringValue)
        }
        self.socket = socket
        self.pid = Int32(pid)
        self.started = started
        self.client = client
        self.version = version
    }

    // MARK: - On disk

    /// Writes — or rewrites — `sessions/<pid>.json`. Called once the socket
    /// is listening, and again whenever the loaded project changes:
    /// Opening, creating or saving-as a project each
    /// leave the server serving something else, and the file has to say so.
    ///
    /// By a temp file and a rename, as the store writes a project (D29) and
    /// for the same reason turned round: there, so a crash cannot leave half
    /// a document; here, so the viewer — which is watching this directory,
    /// and reads the moment it changes — cannot read half a descriptor. The
    /// temp file's name begins with a dot and does not end in `.json`, so a
    /// listing in between does not take it for a session.
    public func write(in paths: SupportPaths) throws {
        try paths.ensure()
        let path = paths.descriptorPath(pid: pid)
        let temporary = "\(paths.sessions)/.\(pid).json.\(UUID().uuidString.prefix(8)).tmp"
        let text = json.stringified(indent: 2) + "\n"

        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw TransportError(.system, "could not write \(temporary): \(String(cString: strerror(errno)))")
        }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else {
                let code = errno
                close(fd)
                unlink(temporary)
                throw TransportError(.system, "could not write \(temporary): \(String(cString: strerror(code)))")
            }
            offset += written
        }
        close(fd)
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw TransportError(.system, "could not replace \(path): \(String(cString: strerror(code)))")
        }
    }

    /// On a clean exit. Not finding it is fine — that is what was wanted.
    public static func remove(pid: Int32 = ProcessInfo.processInfo.processIdentifier, in paths: SupportPaths) {
        unlink(paths.descriptorPath(pid: pid))
    }

    /// The descriptor at a path, or nil if there is not a readable one.
    public static func read(at path: String) -> SessionDescriptor? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSON.parse(bytes: Array(data)) else { return nil }
        return SessionDescriptor(json: json)
    }
}
