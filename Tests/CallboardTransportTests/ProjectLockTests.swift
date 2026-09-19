// One holder to a root, a refusal that says who holds it, and a lock that
// goes when its process does.
//
// `flock` belongs to the open file description, so two `ProjectLock`s in one
// process are two holders as far as the kernel is concerned, and most of
// this can be said without a second process. The claim that cannot — "the
// lock dies with its process" — is made against a real one, killed.
//
// Callboard reports refusals as facts (`ProjectLock.Refusal`); what a
// product says about them is the product's business, and is tested there.

import Foundation
import Testing
@testable import CallboardTransport

private func refusal(_ body: () throws -> Void) -> ProjectLock.Refusal? {
    do { try body(); return nil } catch { return error as? ProjectLock.Refusal }
}

private func isHeld(_ refusal: ProjectLock.Refusal?) -> Bool {
    if case .held = refusal { return true }
    return false
}

private func heldBy(_ refusal: ProjectLock.Refusal?) -> ProjectLock.Holder?? {
    if case let .held(_, _, holder) = refusal { return .some(holder) }
    return nil
}

private func resolved(_ path: String) -> String {
    realpath(path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? path
}

@Suite("one holder to a root, by a lock that dies with its process") struct ProjectLockTests {
    private let agent = ProjectLock.Holder(pid: ProcessInfo.processInfo.processIdentifier, client: "claude-ai",
                                           started: "2026-09-18T09:00:00.000Z")
    private let viewer = ProjectLock.Holder(pid: ProcessInfo.processInfo.processIdentifier, client: "app",
                                            started: "2026-09-18T09:30:00.000Z")
    private func lock(_ holder: ProjectLock.Holder) -> ProjectLock { ProjectLock(holder: holder, product: example) }

    @Test("the lock file is named for the product")
    func fileName() {
        #expect(lock(agent).fileName == ".example.lock")
    }

    @Test("a second holder is refused the root, told who holds it, and let in once it is released")
    func refusedThenReleased() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        let first = lock(agent), second = lock(viewer)

        try first.acquire(root: root)
        #expect(ProjectLock.holder(of: root, fileName: first.fileName) == agent)

        let refused = try #require(refusal { try second.acquire(root: root) })
        #expect(refused == .held(root: root, lockFile: resolved(root) + "/.example.lock", holder: agent))
        #expect(second.heldRoots == [])
        // Being refused took nothing from the holder, and changed nothing in its record.
        #expect(ProjectLock.holder(of: root, fileName: first.fileName) == agent)

        first.release(root: root)
        // The file stays (deleting it races); what it said is wiped.
        let lockFile = root + "/" + first.fileName
        #expect(FileManager.default.fileExists(atPath: lockFile))
        #expect(ProjectLock.holder(of: root, fileName: first.fileName) == nil)
        #expect(mode(of: lockFile) == 0o644)

        try second.acquire(root: root)
        #expect(ProjectLock.holder(of: root, fileName: first.fileName) == viewer)
        #expect(heldBy(refusal { try first.acquire(root: root) }) == .some(viewer))
        second.release(root: root)
    }

    @Test("a product can throw its own error instead of the refusal")
    func productError() throws {
        struct Refused: Error, Equatable { let words: String }
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        let first = lock(agent)
        let second = ProjectLock(holder: viewer, product: example) { refusal in
            if case let .held(_, _, holder) = refusal { return Refused(words: "held by \(holder?.client ?? "nobody")") }
            return refusal
        }
        try first.acquire(root: root)
        #expect(throws: Refused(words: "held by claude-ai")) { try second.acquire(root: root) }
        first.release(root: root)
    }

    @Test("taking a root this holder already holds takes nothing, and every acquire is answered by one release")
    func reacquire() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        let mine = lock(agent), theirs = lock(viewer)

        try mine.acquire(root: root)
        try mine.acquire(root: root)
        #expect(mine.heldRoots.count == 1)

        mine.release(root: root)
        #expect(isHeld(refusal { try theirs.acquire(root: root) }), "one release of two: still held")
        mine.release(root: root)
        try theirs.acquire(root: root)
        mine.release(root: root)       // one too many is nothing, and not theirs
        #expect(isHeld(refusal { try mine.acquire(root: root) }))
        theirs.releaseAll()
        try mine.acquire(root: root)
    }

    @Test("two spellings of one folder are one lock")
    func aliases() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet"), link = scratch.file("current")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
        let mine = lock(agent), theirs = lock(viewer)

        try mine.acquire(root: root)
        #expect(isHeld(refusal { try theirs.acquire(root: link) }))
        #expect(isHeld(refusal { try theirs.acquire(root: root + "/refs/..") }))

        try mine.acquire(root: link)
        mine.release(root: root)
        #expect(isHeld(refusal { try theirs.acquire(root: root) }))
        mine.release(root: link)
        try theirs.acquire(root: root)
    }

    @Test("two roots are two locks")
    func twoRoots() throws {
        let scratch = try Scratch()
        let mine = lock(agent), theirs = lock(viewer)
        try mine.acquire(root: scratch.file("a"))
        try theirs.acquire(root: scratch.file("b"))
        #expect(mine.heldRoots.count == 1 && theirs.heldRoots.count == 1)
        #expect(isHeld(refusal { try theirs.acquire(root: scratch.file("a")) }))
    }

    @Test("a lock that is dropped is a lock let go")
    func droppedLock() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        do {
            let passing = lock(agent)
            try passing.acquire(root: root)
        }
        try lock(viewer).acquire(root: root)
    }

    @Test("a root that cannot be written in is refused with the system's reason")
    func unwritable() throws {
        let scratch = try Scratch()
        let root = scratch.file("read-only")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        chmod(root, 0o500)
        defer { chmod(root, 0o700) }
        let refused = try #require(refusal { try lock(agent).acquire(root: root) })
        guard case let .cannotOpen(_, reason) = refused else { Issue.record("expected cannotOpen, got \(refused)"); return }
        #expect(reason.contains("Permission denied"))
    }

    // ------------------------------------------------- another process ---

    /// A process that takes the lock the way any program would, says so, and
    /// sits on it. It writes no record, so the refusal has to cope with a
    /// holder it cannot name.
    private func holdingProcess(_ lockFile: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "use Fcntl qw(:flock); open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print qq(locked\\n); sleep 120",
                             lockFile]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let said = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard said == "locked\n" else { throw TestFailure(description: "the helper said \(said.debugDescription)") }
        return process
    }

    @Test("a lock held by a process that is killed is there for the taking at once: no stale lock, and nothing to force")
    func diesWithItsProcess() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let lockFile = root + "/.example.lock"
        let holder = try holdingProcess(lockFile)
        defer { if holder.isRunning { holder.terminate() } }

        // Named by the path the filesystem knows it by (/var is /private/var),
        // and with no holder, because this one wrote no record.
        #expect(refusal { try lock(agent).acquire(root: root) }
                == .held(root: root, lockFile: resolved(root) + "/.example.lock", holder: nil))

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        let mine = lock(agent)
        try mine.acquire(root: root)
        #expect(ProjectLock.holder(of: root, fileName: mine.fileName) == agent)
    }

    @Test("a record left by a holder that died names nobody")
    func staleRecord() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let lockFile = root + "/.example.lock"
        try "{\"pid\":\(try deadPid()),\"client\":\"claude-ai\",\"started\":\"2026-09-17T09:00:00.000Z\"}\n"
            .write(toFile: lockFile, atomically: true, encoding: .utf8)
        let holder = try holdingProcess(lockFile)
        defer { holder.terminate() }

        #expect(heldBy(refusal { try lock(viewer).acquire(root: root) }) == .some(nil))
    }

    @Test("a child this holder starts does not inherit the lock")
    func notInherited() throws {
        let scratch = try Scratch()
        let root = scratch.file("street-meet")
        let mine = lock(agent)
        try mine.acquire(root: root)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        mine.release(root: root)
        try lock(viewer).acquire(root: root)
    }
}
