// The servers that are running, as the viewer sees them (§4.3: the app
// "lists the servers that are running, attaches to one over its local
// channel"; PD18: it "watches the directory and checks pid liveness rather
// than trusting a file").
//
// `sessions/` is written by many processes and owned by none of them. Every
// server adds its own row and is supposed to remove it; a server that is
// killed removes nothing. So reading the directory is also what cleans it:
// a descriptor whose process is gone, or whose socket nobody answers, is
// deleted by whoever notices, because there is no one else whose job it
// could be — D54 took away the long-lived process that might have kept
// house.
//
// Two tests, and they catch different things. `kill(pid, 0)` finds the
// server that died; it is silent and costs nothing. But pids are recycled,
// and a descriptor can outlive its server long enough for its pid to belong
// to somebody's text editor — so the socket is tried as well, and a socket
// that refuses is a server that is not there, whoever has the pid now. The
// cost of trying is that a live server sees a client come and go without a
// word; it is built to shrug at that (SocketServer.swift).

import Foundation

public struct SessionDirectory: Sendable {
    public let paths: SupportPaths

    public init(_ paths: SupportPaths) { self.paths = paths }

    /// The live sessions, oldest first — by `started`, which is one format
    /// in UTC and so sorts as text, and then by pid so that two servers
    /// started in one millisecond still have an order that does not change
    /// between two listings.
    ///
    /// - Parameter probeSockets: false to check pids only, leaving every
    ///   server undisturbed. The watcher's slow recheck uses it: what that
    ///   is looking for is a server that died, and a dead pid says so.
    public func list(probeSockets: Bool = true) -> [SessionDescriptor] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.sessions)) ?? []
        var live: [SessionDescriptor] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = "\(paths.sessions)/\(name)"
            guard let descriptor = SessionDescriptor.read(at: path) else {
                // Not ours to interpret — but if the file is named for a
                // process that is gone, it is nobody's, and it goes.
                if let pid = Int32(name.dropLast(".json".count)), pid > 0, !SessionDirectory.isAlive(pid) {
                    unlink(path)
                }
                continue
            }
            guard SessionDirectory.isAlive(descriptor.pid) else {
                Log.say("pruning \(name): pid \(descriptor.pid) is gone")
                SessionDirectory.prune(path, socket: descriptor.socket)
                continue
            }
            if probeSockets, UnixSocket.probe(descriptor.socket) != .listening {
                Log.say("pruning \(name): nobody answers at \(descriptor.socket)")
                SessionDirectory.prune(path, socket: descriptor.socket)
                continue
            }
            live.append(descriptor)
        }
        return live.sorted { ($0.started, $0.pid) < ($1.started, $1.pid) }
    }

    /// `kill` with signal 0 sends nothing and checks everything. ESRCH is
    /// the only answer that means "no such process"; EPERM means there is
    /// one and it is not ours to signal, which is alive all the same.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// The descriptor, and the socket file it points at if that is a socket
    /// nobody is serving. The path came out of a file anyone in this
    /// directory could have written, so it is unlinked only when it is what
    /// it says: a regular file named there is left exactly where it is.
    private static func prune(_ descriptorPath: String, socket: String) {
        unlink(descriptorPath)
        if UnixSocket.probe(socket) == .refused { unlink(socket) }
    }

    // MARK: - Watching

    /// The list now, and again whenever it changes. A directory's `write`
    /// event is what adding, removing or renaming an entry in it raises, and
    /// a descriptor is rewritten by rename — so a server starting, stopping
    /// or opening another project all arrive here.
    ///
    /// Debounced by a tenth of a second, because one change is several
    /// events (the temp file, the rename, and a prune is a change of its
    /// own), and yielded only when the list differs from the last one
    /// yielded, because the viewer redraws on every element.
    ///
    /// A server that is killed changes nothing in the directory, so there is
    /// no event for the one case the app most needs to hear about. Hence
    /// `recheckEvery`: a pid-only listing on a slow timer. Nil turns it off.
    ///
    /// Ends when the consumer stops listening; cancel the task, or let the
    /// stream go.
    public func watch(debounce: TimeInterval = 0.1, recheckEvery: TimeInterval? = 2) -> AsyncStream<[SessionDescriptor]> {
        let (stream, continuation) = AsyncStream<[SessionDescriptor]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let watcher = Watcher(directory: self, debounce: debounce, recheckEvery: recheckEvery, continuation: continuation)
        continuation.onTermination = { _ in watcher.stop() }
        watcher.start()
        return stream
    }

    /// State on one serial queue and nowhere else, which is the argument for
    /// `@unchecked Sendable` here as it is for the server: `start` and
    /// `stop` hop onto the queue, and the sources and the timer fire on it.
    private final class Watcher: @unchecked Sendable {
        private let queue = DispatchQueue(label: "callboard.session-directory")
        private let onQueueKey = DispatchSpecificKey<Bool>()
        private let directory: SessionDirectory
        private let debounce: TimeInterval
        private let recheckEvery: TimeInterval?
        private let continuation: AsyncStream<[SessionDescriptor]>.Continuation

        private var source: DispatchSourceFileSystemObject?
        private var timer: DispatchSourceTimer?
        private var pending: DispatchWorkItem?
        private var last: [SessionDescriptor]?
        private var stopped = false

        init(directory: SessionDirectory, debounce: TimeInterval, recheckEvery: TimeInterval?,
             continuation: AsyncStream<[SessionDescriptor]>.Continuation) {
            self.directory = directory
            self.debounce = debounce
            self.recheckEvery = recheckEvery
            self.continuation = continuation
            queue.setSpecific(key: onQueueKey, value: true)
        }

        func start() {
            queue.async { [self] in
                guard !stopped else { return }
                // Attached before the first listing, not after: a server
                // that starts in between is then an event, where the other
                // way round it would be nothing until the next one.
                attach()
                publish(probeSockets: true)
                if let recheckEvery {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + recheckEvery, repeating: recheckEvery, leeway: .milliseconds(250))
                    timer.setEventHandler { [weak self] in self?.publish(probeSockets: false) }
                    timer.resume()
                    self.timer = timer
                }
            }
        }

        /// Waits until it has stopped, so that a consumer who cancels and
        /// then removes the directory is not racing a watcher that would see
        /// it go and helpfully make it again.
        func stop() {
            let halt = { [self] in
                stopped = true
                pending?.cancel()
                pending = nil
                source?.cancel()
                source = nil
                timer?.cancel()
                timer = nil
            }
            if DispatchQueue.getSpecific(key: onQueueKey) == true { halt() } else { queue.sync(execute: halt) }
        }

        /// Opens the directory for events only — O_EVTONLY does not keep a
        /// volume from unmounting — and makes it first if need be: the app
        /// may well be running before any server ever has.
        private func attach() {
            source?.cancel()
            source = nil
            try? directory.paths.ensure()
            let fd = open(directory.paths.sessions, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else {
                Log.say("cannot watch \(directory.paths.sessions): \(String(cString: strerror(errno)))")
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .delete, .rename, .revoke],
                                                                   queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // The directory itself was removed or moved: what is open is
                // no longer the place servers write to. Look again at the
                // path.
                if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) { self.attach() }
                self.changed()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }

        private func changed() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.publish(probeSockets: true) }
            pending = work
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }

        private func publish(probeSockets: Bool) {
            guard !stopped else { return }
            let list = directory.list(probeSockets: probeSockets)
            if list == last { return }
            last = list
            continuation.yield(list)
        }
    }
}
