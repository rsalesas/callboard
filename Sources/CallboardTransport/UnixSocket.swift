// The few lines of POSIX that the server, the session directory and the
// tests' clients would otherwise each write for themselves: a `sockaddr_un`
// from a path, and the question "is anybody listening there?".
//
// That question has one honest way of being asked, which is to connect. A
// socket file says nothing by existing — a server that was killed leaves its
// file behind, and the file looks exactly as it did while it was served — so
// both the server (before it clears a stale file out of its way) and the
// directory (before it offers a session to the app) ask the kernel instead
// of the filesystem (PD18: "checks … rather than trusting a file").

import Foundation

public enum UnixSocket {
    /// Calls `body` with the address of `path`, or returns nil when the path
    /// cannot be one: `sun_path` is 104 bytes and a longer path is not
    /// truncated, it is refused.
    public static func withAddress<Result>(_ path: String,
                                    _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result? {
        guard SupportPaths.fits(path) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = SupportPaths.sunPathCapacity
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, source, capacity) }
            }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    public enum Probe: Equatable {
        /// Somebody accepted, or would have: the socket is served.
        case listening
        /// A socket file with nobody behind it — what a dead server leaves.
        case refused
        /// Nothing at the path.
        case absent
        /// Something at the path that is not a socket.
        case notASocket
    }

    /// Connects and hangs up at once. The server at the other end sees a
    /// client arrive and leave without a word, which is an ordinary thing
    /// for a client to do and costs it one id.
    ///
    /// Anything that is not a plain refusal counts as `listening`. The two
    /// callers both *delete* on `refused`, and a wrong `listening` costs a
    /// stale entry for a while where a wrong `refused` would cost a live
    /// server its socket.
    public static func probe(_ path: String) -> Probe {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .absent }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return .notASocket }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .listening }
        defer { close(fd) }
        // Non-blocking, so a probe can never be what hangs a caller: a
        // Unix-domain connect either completes at once or fails at once.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        guard let result = withAddress(path, { connect(fd, $0, $1) }) else { return .refused }
        if result == 0 { return .listening }
        switch errno {
        case ECONNREFUSED: return .refused
        case ENOENT: return .absent
        default: return .listening
        }
    }

    /// Descriptors this process opens are its own. Without close-on-exec a
    /// child — an encoder, a host's helper, anything `Process` starts —
    /// inherits them, and an inherited lock or listening socket outlives the
    /// server that made it: exactly the stale state D55 says cannot exist.
    public static func closeOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD, 0) | FD_CLOEXEC)
    }
}
