// D55: "a project root is held by one server at a time, by a lock that dies
// with its process. Opening a root another live server holds fails."
//
// The lock is an advisory `flock` on `<root>/<product.lockFileName>` (PD18), held
// by keeping the file open for as long as the project is loaded. Everything
// D55 promises comes from whose lock it is: the kernel's. A server that
// exits, crashes or is killed has its descriptors closed for it, and the
// lock goes with them — so there is no stale lock, which is why there is no
// "force" and no clean-up tool, and why this file has no code for either. A
// lock *file* — one whose existence is the lock — would have needed all
// three.
//
// The kernel knows that the root is held and not by whom, and
// E_PROJECT_LOCKED owes the agent a hint "naming the holder — its host and
// how long it has held the root". So the holder writes that into the lock
// file, once it has the lock, and a server that is refused reads it. The
// record is a courtesy laid over the lock and never consulted for the
// decision: a record with no lock behind it (its writer died) refuses
// nobody, and a lock with no readable record still refuses, and says that it
// cannot say who.
//
// `flock` locks belong to the open file description, not to the process, so
// two of these in one process, each opening the file for itself, do refuse
// one another — which is what makes D55 testable without a second process,
// and is also a trap: a store that reopens the root it has open must not be
// refused by itself. Hence one table per `ProjectLock`, keyed by the root
// as the filesystem resolves it, and counted: taking a root this lock
// already holds takes nothing from the kernel and adds one to the count, and
// each `release` gives one back. Counted rather than ignored, because the
// store is promised that every `acquire` is answered by one `release`
// (ProjectLocking.swift), and two spellings of one folder — a symlink, a
// `..` — are one lock here: moving from one spelling to the other is an
// acquire then a release, and with a count the root is still held after it.
//
// One thing is deliberately not refused. Some filesystems — network mounts,
// mostly — do not do `flock` at all, and answer ENOTSUP. A project there is
// opened without a lock rather than not opened: the choice is between a
// guard that is missing where it was unlikely to be needed and a person who
// cannot use their NAS, and the record is still written, so the hint is
// still there for whoever looks.

// Callboard reports a refusal as facts — which root, which file, who holds it
// — and a product decides what to say about them: `refuse` turns a `Refusal`
// into whatever error that product's callers expect, and by default throws
// the `Refusal` itself.

import Foundation
import CallboardJSON
import os

public final class ProjectLock: Sendable {
    /// Why `acquire` did not take a root.
    public enum Refusal: Error, Sendable, Equatable {
        /// Another live process holds it. `holder` is what its record says,
        /// or nil when the record could not be read or names a dead process.
        case held(root: String, lockFile: String, holder: Holder?)
        /// The lock file could not be opened: `reason` is the system's words.
        case cannotOpen(path: String, reason: String)
        /// The file opened but could not be locked, for a reason other than
        /// being held.
        case cannotLock(path: String, reason: String)
    }

    /// What a holder says about itself: the three fields of its session
    /// descriptor that a stranger needs in order to go and find it.
    public struct Holder: Sendable, Equatable {
        public var pid: Int32
        public var client: String
        public var started: String

        public init(pid: Int32 = ProcessInfo.processInfo.processIdentifier, client: String,
                    started: String = SessionDescriptor.timestamp()) {
            self.pid = pid
            self.client = client
            self.started = started
        }

        public init(_ descriptor: SessionDescriptor) {
            self.init(pid: descriptor.pid, client: descriptor.client, started: descriptor.started)
        }

        var json: JSON { ["pid": .number(Double(pid)), "client": .string(client), "started": .string(started)] }

        init?(json: JSON) {
            guard let pid = json["pid"]?.numberValue, pid >= 1, pid <= Double(Int32.max), pid == pid.rounded(),
                  let client = json["client"]?.stringValue,
                  let started = json["started"]?.stringValue else { return nil }
            self.init(pid: Int32(pid), client: client, started: started)
        }
    }

    /// The file in a project root whose lock is the project's lock.
    public let fileName: String

    private struct Held {
        var fd: Int32
        var count: Int
    }

    private struct State {
        /// By resolved root.
        var held: [String: Held] = [:]
        /// What each root was called when it was taken, so that a release
        /// finds its lock even if the folder has since been moved or removed
        /// and no longer resolves to anything.
        var resolved: [String: String] = [:]
    }

    private let holder: Holder
    private let refuse: @Sendable (Refusal) -> any Error
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - holder: this server, as it will be named to a server that is
    ///     refused. Build it from the session descriptor, so the two agree.
    ///   - product: names the lock file.
    ///   - refuse: what `acquire` throws for a refusal; the refusal itself
    ///     unless a product wants its own error and its own words.
    public init(holder: Holder, product: Product, refuse: @escaping @Sendable (Refusal) -> any Error = { $0 }) {
        self.holder = holder
        self.fileName = product.lockFileName
        self.refuse = refuse
    }

    deinit {
        // Dropping is releasing. The kernel would do it at exit; this is for
        // a lock that is dropped while the process goes on — a test's, or a
        // server rebuilt inside one process.
        state.withLock { for held in $0.held.values { ProjectLock.letGo(held.fd) } }
    }

    /// The roots this lock holds, as the filesystem resolves them.
    public var heldRoots: [String] { state.withLock { $0.held.keys.sorted() } }

    // MARK: - ProjectLocking

    public func acquire(root: String) throws {
        let holder = holder
        try state.withLock { state in
            // The folder has to be there to be resolved, and for the lock
            // file to go in. The store has already made it; anybody else's
            // caller is saved the trouble.
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let key = ProjectLock.resolve(root)
            if state.held[key] != nil {
                state.held[key]!.count += 1
                state.resolved[root] = key
                return
            }

            let path = key + "/" + fileName
            // O_CLOEXEC, or every child this server ever starts inherits the
            // descriptor, and with it the lock: the server dies, the encoder
            // it spawned lives on, and the root stays held by nobody anyone
            // can name. 0644: the record is for other people to read.
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else {
                throw refuse(.cannotOpen(path: path, reason: String(cString: strerror(errno))))
            }

            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EWOULDBLOCK {
                    close(fd)
                    throw refuse(ProjectLock.refusal(root: root, lockFile: path))
                }
                if code != ENOTSUP && code != EOPNOTSUPP {
                    close(fd)
                    throw refuse(.cannotLock(path: path, reason: String(cString: strerror(code))))
                }
                // No locks on this filesystem: see the header.
                Log.say("\(path): this filesystem has no flock; holding the project without one")
            }

            ProjectLock.write(holder, to: fd)
            state.held[key] = Held(fd: fd, count: 1)
            state.resolved[root] = key
        }
    }

    public func release(root: String) {
        state.withLock { state in
            let key = state.resolved[root] ?? ProjectLock.resolve(root)
            guard var held = state.held[key] else { return }
            held.count -= 1
            if held.count > 0 {
                state.held[key] = held
                return
            }
            ProjectLock.letGo(held.fd)
            state.held[key] = nil
            state.resolved = state.resolved.filter { $0.value != key }
        }
    }

    /// Everything, whatever the counts: for a server on its way out that
    /// would rather not leave it to the kernel.
    public func releaseAll() {
        state.withLock { state in
            for held in state.held.values { ProjectLock.letGo(held.fd) }
            state = State()
        }
    }

    /// The record is wiped while the lock is still held, so nobody can read
    /// a holder that is no longer holding; then closing the descriptor drops
    /// the lock. The file stays. Deleting it races: a server that opened it
    /// a moment ago would lock a file that is no longer at the path, and the
    /// next one would make a new file there and lock that — two holders,
    /// each with a perfectly good lock.
    ///
    /// Unlocked, and then closed — not just closed. Closing drops the lock
    /// only when it is the last reference to the open file description, and
    /// for a moment it may not be: a child being spawned on another thread
    /// holds a copy of every descriptor from the instant it is made until
    /// its exec closes the close-on-exec ones. A release that lands in that
    /// moment would leave the root locked, by nobody, for the few
    /// microseconds it takes — long enough to refuse the server that was
    /// waiting for exactly this release. (It did: the tests start children
    /// in parallel with releases, and one acquire in a few hundred was
    /// refused by a lock with no holder.) `LOCK_UN` acts on the description
    /// itself, whoever else has a reference to it.
    private static func letGo(_ fd: Int32) {
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }

    // MARK: - The holder's record

    private static func write(_ holder: Holder, to fd: Int32) {
        let bytes = Array((holder.json.stringified() + "\n").utf8)
        ftruncate(fd, 0)
        _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Who the lock file at `root` says holds it, if it says. This is the
    /// record and only the record: it does not ask whether the lock is held.
    public static func holder(of root: String, fileName: String) -> Holder? {
        record(at: resolve(root) + "/" + fileName)
    }

    private static func record(at path: String) -> Holder? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSON.parse(bytes: Array(data)) else { return nil }
        return Holder(json: json)
    }

    /// A held root's refusal, with the holder read from its record.
    ///
    /// The holder takes the lock and then writes its name, so there is a
    /// moment — microseconds — in which the lock is held and the record is
    /// empty, or is still the last holder's, whose process is gone. A record
    /// naming a dead process is not the holder's, so it is read again, a few
    /// times over a few milliseconds, before giving up and saying so.
    private static func refusal(root: String, lockFile: String) -> Refusal {
        var found: Holder?
        for attempt in 0..<4 {
            if attempt > 0 { usleep(5_000) }
            if let record = record(at: lockFile), SessionDirectory.isAlive(record.pid) {
                found = record
                break
            }
        }
        return .held(root: root, lockFile: lockFile, holder: found)
    }

    // MARK: - Roots

    /// The root as the filesystem has it — symlinks followed, `..` gone — so
    /// that two spellings of one folder are one key. A root that will not
    /// resolve (it was removed) is its own key, standardised as text.
    private static func resolve(_ root: String) -> String {
        if let real = realpath(root, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        return URL(fileURLWithPath: root).standardizedFileURL.path
    }
}
