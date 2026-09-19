// Bytes in, lines out (§4.3's local channel: one JSON object per line).
//
// A socket promises bytes, not messages. A read may end in the middle of a
// line, in the middle of a character, or hold forty lines at once, and none
// of that is the sender's doing or the reader's business: a line is what
// lies between two 0x0A bytes, and until its newline has arrived it is not
// a line.
//
// Split on the byte 0x0A and on nothing else. Not on "a newline" as `String`
// or `Character` understand one — U+2028 and U+2029 are line separators to
// Unicode and perfectly legal inside a JSON string, and JavaScript's
// `JSON.stringify` writes them raw; a reader that split on them would cut a
// comment in half. In UTF-8 no byte of any multi-byte character is 0x0A, so
// the byte test is exact, and a character split across two reads is whole
// again by the time its line is decoded.
//
// What this does not do is judge a line. It is decoded as UTF-8 with
// replacement characters where the bytes are not, and handed up; whoever
// parses it answers the sender with the parser's own complaint, which is
// more use to them than a closed connection. A trailing 0x0D is left where
// it is — JSON calls it whitespace. An empty line is nothing and is
// skipped. The one thing refused here is size: see `limit`.

struct LineBuffer {
    /// The most bytes one line may run to. A client that sends a gigabyte
    /// and never a newline is otherwise a client that can take the server's
    /// memory; past this the connection is closed (by the server — this only
    /// reports it), because the alternative, discarding up to the next
    /// newline and carrying on, leaves the sender waiting thirty seconds for
    /// a reply to a request nobody read. The largest honest line is a
    /// project read, under 50 KB by construction (§16.3); the default leaves
    /// three orders of magnitude over it.
    let limit: Int

    private var bytes: [UInt8] = []
    /// `bytes[..<scanned]` is known to hold no newline, so a long line that
    /// arrives in a thousand reads is searched once, not a thousand times.
    private var scanned = 0

    init(limit: Int) { self.limit = limit }

    /// Bytes held for a line that has not ended yet.
    var pending: Int { bytes.count }

    /// Takes what a read produced and gives back the lines it completed, in
    /// order. `overflowed` is true when a line — finished or not — has run
    /// past `limit`; the lines before it are still returned, because they
    /// were sent and were fine.
    mutating func append(_ chunk: UnsafeRawBufferPointer) -> (lines: [String], overflowed: Bool) {
        bytes.append(contentsOf: chunk)
        var lines: [String] = []
        var start = 0
        var overflowed = false
        while let newline = bytes[scanned...].firstIndex(of: 0x0A) {
            let line = bytes[start..<newline]
            start = newline + 1
            scanned = start
            if line.count > limit { overflowed = true; break }
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        if !overflowed { scanned = bytes.count }
        bytes.removeFirst(start)
        scanned -= start
        if bytes.count > limit { overflowed = true }
        return (lines, overflowed)
    }
}
