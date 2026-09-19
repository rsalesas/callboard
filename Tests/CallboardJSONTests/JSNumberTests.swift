// PD14: the language's arithmetic is part of the file format.
//
// Every case here is an answer JavaScript gave, recorded by
// `engine/scripts/gen-fixtures.mjs` — 2,740 doubles, carried as bits so both
// sides start from the same value: the engine's own domain after its two
// roundings, every tie near zero at every scale it rounds at, the decimals
// that are famously not what they look like, and six hundred bit patterns
// chosen at random.

import Testing
import CallboardJSON

@Suite("JavaScript's numbers") struct JSNumberTests {
    let cases: [JSON]
    init() throws { cases = try Fixtures.json("js/numbers.json").arrayValue! }

    @Test("Number → String lays the shortest digits out the way ECMA-262 does")
    func numberToString() {
        var wrong: [String] = []
        for c in cases {
            let x = Double(bits: c["bits"]!.stringValue!)
            let ours = JS.string(x)
            if ours != c["string"]!.stringValue! { wrong.append("\(c["bits"]!.stringValue!): \(ours) ≠ \(c["string"]!.stringValue!)") }
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(cases.count): \(wrong.prefix(8))")
    }

    @Test("Math.round sends a half toward +∞, and keeps the sign of a zero")
    func mathRound() {
        var wrong: [String] = []
        for c in cases {
            let x = Double(bits: c["bits"]!.stringValue!)
            let ours = JS.round(x).bitPattern
            if ours != UInt64(c["round"]!.stringValue!, radix: 16)! { wrong.append("\(x) → \(JS.round(x))") }
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(cases.count): \(wrong.prefix(8))")
    }

    @Test("toFixed rounds the exact value half up, which printf does not")
    func toFixed() {
        var wrong: [String] = []
        for c in cases {
            guard let fixed = c["fixed"]!.arrayValue else { continue }
            let x = Double(bits: c["bits"]!.stringValue!)
            for (digits, expected) in zip([0, 1, 2, 3, 4, 6], fixed) where JS.toFixed(x, digits) != expected.stringValue! {
                wrong.append("\(x).toFixed(\(digits)): \(JS.toFixed(x, digits)) ≠ \(expected.stringValue!)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(8))")
    }

    @Test("the cases somebody will one day be sure are wrong")
    func landmarks() {
        #expect(JS.string(3) == "3")                       // not "3.0"
        #expect(JS.string(2.4) == "2.4")
        #expect(JS.string(1e-7) == "1e-7")                 // not "1e-07"
        #expect(JS.string(0.000001) == "0.000001")
        #expect(JS.string(1e21) == "1e+21")
        // Spelled as the double it is: Swift 6.4 warns that the integer
        // literal "is not exactly representable", which is the point of it.
        #expect(JS.string(1.2345678901234568e20) == "123456789012345680000")
        #expect(JS.string(-0.0) == "0")
        #expect(JS.round(-2.5) == -2)                      // `.rounded()` says −3
        #expect(JS.round(2.5) == 3)                        // banker's rounding says 2
        #expect(JS.round(0.49999999999999994) == 0)        // floor(x + 0.5) says 1
        #expect(JS.toFixed(0.125, 2) == "0.13")            // printf says 0.12
        #expect(JS.toFixed(1.005, 2) == "1.00")            // because it is 1.00499999999999989…
        #expect(JS.round(1.23456789, scale: 1e4) == 1.2346)
    }
}
