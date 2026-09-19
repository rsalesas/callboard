// Where a server and whoever attaches to it agree to meet (§4.3, PD18). One
// definition, used by both sides — a socket path that two processes derive
// separately is a bug waiting for a refactor.
//
// Under PD1 there was one meeting place, `channel.sock`, because there was
// one server: the app. Under D54 every host launches its own, so the place
// is a directory — `sessions/` — holding one socket and one descriptor per
// server, named for its pid: `<pid>.sock` and `<pid>.json`. A pid is the one
// name two live processes cannot share, and the one a reader can check
// without asking anybody (`kill(pid, 0)`), which is what lets the app "check
// pid liveness rather than trusting a file".
//
// A value and not a namespace of statics, as the app's `Support` was. The
// environment is read once, where the value is made, so a test builds one
// over a temporary directory and never touches the process's environment —
// `setenv` under parallel tests is a race with every other test that reads
// it.

import Foundation

public struct SupportPaths: Sendable, Equatable {
    /// Whose paths these are: it names the default directory, the fallback
    /// directory and the environment variable that overrides them.
    public let product: Product

    /// `~/Library/Application Support/<product name>`, or wherever
    /// `<PREFIX>_SUPPORT_DIR` says.
    public let directory: String

    public init(directory: String, product: Product) {
        self.directory = directory
        self.product = product
    }

    public init(product: Product,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory()) {
        self.product = product
        // An empty override is no override: `<PREFIX>_SUPPORT_DIR=` would
        // otherwise put the sessions directory at the filesystem's root.
        if let override = environment[product.environmentVariable("SUPPORT_DIR")], !override.isEmpty {
            directory = override
        } else {
            directory = home + "/Library/Application Support/" + product.supportDirectoryName
        }
    }

    /// What this process's own environment says.
    public static func current(for product: Product) -> SupportPaths { SupportPaths(product: product) }

    /// One socket and one descriptor per running server.
    public var sessions: String { directory + "/sessions" }

    /// `sessions/<pid>.json`. Always here, whatever became of the socket:
    /// this is the file a reader lists, and it says where the socket is.
    public func descriptorPath(pid: Int32) -> String { "\(sessions)/\(pid).json" }

    /// `sessions/<pid>.sock` — or, when that will not fit, a short path
    /// under `/tmp`.
    ///
    /// `sockaddr_un.sun_path` is 104 bytes on macOS, terminator included,
    /// and nothing can be done about it: a longer path cannot be bound, by
    /// anyone. The default is comfortably inside (a twenty-character user
    /// name leaves thirty bytes spare), but `<PREFIX>_SUPPORT_DIR` can be
    /// anything, and a sandboxed host's container path is already long. So
    /// the socket moves and the descriptor stays: the descriptor records the
    /// real path, and nobody was ever meant to derive a socket's path when
    /// they could read it.
    public func socketPath(pid: Int32) -> String {
        let preferred = "\(sessions)/\(pid).sock"
        return SupportPaths.fits(preferred) ? preferred : "\(fallbackDirectory)/\(tag)-\(pid).sock"
    }

    /// True when `socketPath(pid:)` is not under `sessions/`.
    public func usesFallback(pid: Int32) -> Bool { !SupportPaths.fits("\(sessions)/\(pid).sock") }

    /// Whether a path can be bound at all: its bytes and a terminator within
    /// `sun_path`.
    public static func fits(_ path: String) -> Bool { path.utf8.count < sunPathCapacity }

    public static let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// `/tmp/<command>-<uid>`: `/tmp` and not `NSTemporaryDirectory()`,
    /// because the point is to be short and the per-user temporary directory
    /// is fifty bytes before it has said anything.
    public var fallbackDirectory: String { "/tmp/\(product.command)-\(getuid())" }

    /// Eight hex digits of the support directory's path (FNV-1a). Two
    /// support directories on one machine — a test's and the real one, a
    /// sandboxed host's and an unsandboxed one's — share `/tmp` and may meet
    /// the same pid at different times; this keeps their sockets apart.
    private var tag: String {
        var hash: UInt32 = 2_166_136_261
        for byte in directory.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    // MARK: - Making them

    /// Makes the support directory and `sessions/` under it, both 0700 —
    /// and, for a pid whose socket will not fit there, the fallback
    /// directory too. The channel is the whole tool surface (§10), and the
    /// directory's mode is what keeps another user from so much as seeing
    /// which projects are open.
    public func ensure(forSocketOf pid: Int32? = nil) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(atPath: sessions, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // `createDirectory` leaves a directory that was already there as it
        // found it. One of ours that has drifted is put back; one that is
        // not ours is somebody's deliberate arrangement and is left alone.
        SupportPaths.tighten(sessions)
        if let pid, usesFallback(pid: pid) { try ensureFallbackDirectory() }
    }

    /// `/tmp` is everybody's, so this directory is made with more suspicion
    /// than the other two: it must be a real directory — not a symlink left
    /// where we would look — owned by this user and closed to the rest, or
    /// nothing is bound inside it.
    func ensureFallbackDirectory() throws {
        let path = fallbackDirectory
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw TransportError(.system, "could not make \(path): \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw TransportError(.system, "\(path) is not a directory of this user's, so no socket will be put in it")
        }
        SupportPaths.tighten(path)
    }

    private static func tighten(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) != 0 else { return }
        chmod(path, 0o700)
    }
}

/// What this target throws when the fault is the machine's and not a
/// caller's to be told about in an envelope: a socket that will not bind, a
/// descriptor that will not write. (A refusal an agent should read is a
/// `Failure`, and only the lock makes one.)
public struct TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The path cannot be bound: longer than `sun_path`.
        case pathTooLong
        /// A live server is already listening there.
        case alreadyListening
        /// Something is at the path, and it is not a socket of ours to clear.
        case occupied
        /// Started twice, or used after `stop()`.
        case state
        /// A system call said no; the description has its words.
        case system
    }

    public let kind: Kind
    public let description: String

    public init(_ kind: Kind, _ description: String) {
        self.kind = kind
        self.description = description
    }
}
