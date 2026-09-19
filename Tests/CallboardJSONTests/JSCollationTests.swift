// PD14: where the old engine sorted with `localeCompare`, the new one has
// to put the same things in the same order — two hints at one instant in a
// prompt, two comments at one instant in a list, the files in refs/.
//
// Every case here is an answer Node gave (`fixtures/js/collation.json`):
// the ninety-five printable ASCII characters in the order it sorts them,
// and some six thousand pairs — ids, the engine's own `m<digits>`, ref file
// names, and anything printable — each with the sign of `a.localeCompare(b)`.
// The stand-in covers that alphabet and says it covers no more; the last
// test is what it does with the rest, so that is written down too.

import Testing
import CallboardJSON

@Suite("localeCompare, over the strings the engine sorts") struct JSCollationTests {
    let fixture: JSON
    init() throws { fixture = try Fixtures.json("js/collation.json") }

    @Test("every pair Node was asked about, with the same sign")
    func pairs() {
        let pairs = fixture["pairs"]!.arrayValue!
        var wrong: [String] = []
        for p in pairs {
            let (a, b) = (p["a"]!.stringValue!, p["b"]!.stringValue!)
            let ours = JS.localeCompare(a, b)
            if Double(ours) != p["sign"]!.numberValue! { wrong.append("\"\(a)\" vs \"\(b)\": \(ours)") }
        }
        #expect(pairs.count > 5000)
        #expect(wrong.isEmpty, "\(wrong.count) of \(pairs.count): \(wrong.prefix(8))")
    }

    @Test("printable ASCII sorts into the order Node sorts it into")
    func order() {
        let expected = fixture["order"]!.stringValue!
        let ascii = (0x20..<0x7F).map { String(UnicodeScalar(UInt8($0))) }
        // Insertion sort, because it is stable by construction and ninety-
        // five characters can afford it.
        var sorted: [String] = []
        for c in ascii {
            let at = sorted.firstIndex { JS.localeCompare(c, $0) < 0 } ?? sorted.count
            sorted.insert(c, at: at)
        }
        #expect(sorted.joined() == expected)
        #expect(expected.unicodeScalars.count == 95)
    }

    @Test("it is an ordering: antisymmetric, and zero only for the same string")
    func consistent() {
        for p in fixture["pairs"]!.arrayValue! {
            let (a, b) = (p["a"]!.stringValue!, p["b"]!.stringValue!)
            #expect(JS.localeCompare(a, b) == -JS.localeCompare(b, a), "\"\(a)\" vs \"\(b)\"")
            #expect((JS.localeCompare(a, b) == 0) == (a == b), "\"\(a)\" vs \"\(b)\"")
        }
    }

    @Test("the traps, by name")
    func traps() {
        // Case is a tie-break, never a difference of its own.
        #expect(JS.localeCompare("a", "B") == -1)
        #expect(JS.localeCompare("a", "A") == -1)
        #expect(JS.localeCompare("A", "ab") == -1)
        #expect(JS.localeCompare("aB", "Ab") == -1)
        // `_` and `-` are characters, before every digit, and not skipped.
        #expect(JS.localeCompare("a1", "a_1") == 1)
        #expect(JS.localeCompare("a-b", "ab") == -1)
        #expect(JS.localeCompare("_", "-") == -1)
        // A digit is a character and not a number, so m10 is before m2.
        #expect(JS.localeCompare("10", "9") == -1)
        #expect(JS.localeCompare("m10", "m2") == -1)
        #expect(JS.localeCompare("hero", "hero") == 0)
    }

    @Test("outside printable ASCII it is deterministic and total, and is not ICU")
    func outside() {
        // After `z`, by code point, with no case. ICU would put é beside e
        // and ignore a control character; this does neither, and the header
        // of JSCollation.swift says so.
        #expect(JS.localeCompare("z", "é") == -1)
        #expect(JS.localeCompare("é", "z") == 1)
        #expect(JS.localeCompare("é", "ü") == -1)
        #expect(JS.localeCompare("a\u{0}", "a") == 1)
        #expect(JS.localeCompare("東", "京") == 1)
        #expect(JS.localeCompare("東京", "東京") == 0)
    }
}
