// `String.prototype.localeCompare`, for the strings the engine sorts with it
// (PD14).
//
// The old engine calls it in four places, always with no locale and no
// options: twice in the prompt compiler, to put two hints at one instant in
// mark-id order; once in `list_comments`, for two comments at one instant;
// and once in `list_refs`, over file names. What reaches them is narrow. A
// mark is `m<digits>` and a comment `c<digits>`; every other id is
// `[A-Za-z0-9_-]`; a ref that came in through `import_ref` was sanitised to
// `[A-Za-z0-9._-]` first. So this is not ICU. It is the part of ICU those
// strings can reach, written down as a table.
//
// WHAT IT COVERS: printable ASCII, U+0020 to U+007E, exactly — the order
// Node 24 (ICU 77, CLDR root, which for these characters is also `en`)
// gives, held to it by `fixtures/js/collation.json`: the ninety-five
// characters sorted, and some six thousand pairs. Over that alphabet the
// root collation is two comparisons, one after the other:
//
//   First the strings are compared character by character with case set
//   aside: space, then the punctuation in CLDR's order (`_` and `-` lead
//   it, in that order, and `.` is further in), then the symbols, then the
//   digits, then the letters. None of them is ignored — "a-b" sorts before
//   "ab" because `-` sorts before `b`, not because it is skipped — and a
//   digit is a character, not a number: "10" sorts before "9", and "m10"
//   before "m2". A string that runs out first sorts first.
//
//   Only if that finds nothing — the two are the same but for case — does
//   case decide, at the first place they differ, lowercase first: "a"
//   before "A", and "aB" before "Ab". So case never outranks a letter:
//   "a" sorts before "B", and "A" before "ab".
//
// WHAT IT DOES NOT: anything else. A character outside that range is given
// a place after `z`, in code point order, with no case — which is
// deterministic, and total, and is not what ICU does with an accent (é
// sorts with e), a control character (ignored entirely) or a script. The
// only way one gets here is a file a person dropped into `refs/` by hand
// under such a name, and the cost of being wrong about it is the order of
// two lines in `list_refs`. Nor does it take a locale, and the old engine
// implicitly did — the machine's: a Dane's `list_refs` could sort "aa"
// after "z". The new engine sorts the same everywhere.

extension JS {
    /// The first-level order of printable ASCII, case set aside: what Node
    /// makes of sorting the characters one by one.
    private static let primaryOrder = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz"

    /// A rank for each ASCII code; 0 where the table has nothing to say.
    private static let primaryRank: [UInt32] = {
        var ranks = [UInt32](repeating: 0, count: 128)
        for (rank, scalar) in primaryOrder.unicodeScalars.enumerated() {
            ranks[Int(scalar.value)] = UInt32(rank + 1)
            // An uppercase letter is its lowercase, at this level.
            if scalar.value >= 0x61, scalar.value <= 0x7A { ranks[Int(scalar.value) - 0x20] = UInt32(rank + 1) }
        }
        return ranks
    }()

    private static func primary(_ scalar: Unicode.Scalar) -> UInt32 {
        if scalar.value < 128, primaryRank[Int(scalar.value)] != 0 { return primaryRank[Int(scalar.value)] }
        return 0x100 + scalar.value                         // after `z`, by code point — see the header
    }

    private static func isUpper(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x41 && scalar.value <= 0x5A }

    /// `a.localeCompare(b)`, as −1, 0 or 1 — which is what V8 returns, and
    /// all any caller reads of it is the sign.
    public static func localeCompare(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        for (p, q) in zip(x, y) {
            let (m, n) = (primary(p), primary(q))
            if m != n { return m < n ? -1 : 1 }
        }
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        for (p, q) in zip(x, y) where isUpper(p) != isUpper(q) { return isUpper(p) ? 1 : -1 }
        return 0
    }
}
