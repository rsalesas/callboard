// The framing, with no socket in the room (§4.3: one JSON object per line).
// Everything the server believes about where a line ends is in `LineBuffer`,
// so it is held to it here, a byte at a time, where a failure names the
// framing and not a race.

import Testing
@testable import CallboardTransport

private func feed(_ buffer: inout LineBuffer, _ bytes: [UInt8]) -> (lines: [String], overflowed: Bool) {
    bytes.withUnsafeBytes { buffer.append($0) }
}

@Suite("bytes in, lines out") struct LineBufferTests {
    @Test("a partial line waits for its newline, however many reads that takes")
    func partialLines() {
        var buffer = LineBuffer(limit: 1024)
        #expect(feed(&buffer, Array("{\"id\":".utf8)).lines == [])
        #expect(feed(&buffer, Array("1}".utf8)).lines == [])
        #expect(buffer.pending == 8)
        #expect(feed(&buffer, Array("\n{\"id\":2}\n{\"id\"".utf8)).lines == ["{\"id\":1}", "{\"id\":2}"])
        #expect(feed(&buffer, Array(":3}\n".utf8)).lines == ["{\"id\":3}"])
        #expect(buffer.pending == 0)
    }

    @Test("a character split across two reads is whole by the time its line is")
    func splitCharacter() {
        var buffer = LineBuffer(limit: 1024)
        let line = Array("caf\u{E9} \u{1F3AC}\n".utf8)
        var lines: [String] = []
        // One byte at a time: every multi-byte character is split everywhere
        // it can be.
        for byte in line { lines += feed(&buffer, [byte]).lines }
        #expect(lines == ["caf\u{E9} \u{1F3AC}"])
    }

    @Test("U+2028 and U+2029 are text, not line ends: only the byte 0x0A is")
    func lineSeparators() {
        var buffer = LineBuffer(limit: 1024)
        let text = "{\"note\":\"one\u{2028}two\u{2029}three\u{85}four\"}"
        #expect(feed(&buffer, Array((text + "\n").utf8)).lines == [text])
    }

    @Test("empty lines are nothing, and a carriage return is left for the parser to call whitespace")
    func emptyLines() {
        var buffer = LineBuffer(limit: 1024)
        #expect(feed(&buffer, Array("\n\n{}\r\n\n".utf8)).lines == ["{}\r"])
    }

    @Test("bytes that are not UTF-8 arrive as replacement characters, for the parser to refuse in its own words")
    func malformed() {
        var buffer = LineBuffer(limit: 1024)
        #expect(feed(&buffer, [0x7B, 0xFF, 0x7D, 0x0A]).lines == ["{\u{FFFD}}"])
    }

    @Test("a line past the limit is reported, finished or not, and the lines before it are still delivered")
    func oversized() {
        var unfinished = LineBuffer(limit: 8)
        let first = feed(&unfinished, Array("{}\n123456789".utf8))
        #expect(first.lines == ["{}"] && first.overflowed)

        var finished = LineBuffer(limit: 8)
        let second = feed(&finished, Array("{}\n123456789\n{}\n".utf8))
        #expect(second.lines == ["{}"] && second.overflowed)

        var exact = LineBuffer(limit: 8)
        let third = feed(&exact, Array("12345678\n".utf8))
        #expect(third.lines == ["12345678"] && !third.overflowed)
    }
}
