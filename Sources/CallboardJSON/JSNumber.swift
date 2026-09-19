// JavaScript's arithmetic, where the file format and the prompt lean on it
// (PD14).
//
// Three places the old engine lets the language decide, and the new one has
// to decide the same way:
//
//   Number → String. `String(Math.round(t * 100) / 100)` gives "2.4" and
//   "3", never "2.40" or "3.0"; a baked rail key serialises as `1e-7`, not
//   `1e-07`. Swift prints the same shortest round-trip DIGITS as V8 and
//   lays them out differently, so this takes Swift's digits and applies
//   ECMA-262's Number::toString layout to them.
//
//   Math.round. Half goes UP — toward +∞ — not to even and not away from
//   zero: Math.round(-2.5) is -2, and `.rounded()` says -3. Every stored
//   coordinate passes through it (1e-6 in the ops, 1e-4 in the camera bake).
//
//   toFixed. Rounds the EXACT decimal value of the double, half up, so
//   0.125.toFixed(2) is "0.13" where printf's round-half-even says "0.12" —
//   and 1.005.toFixed(2) is "1.00" in both, because 1.005 is not 1.005.

import Foundation

public enum JS {
    /// ECMA-262 Number::toString, radix 10.
    public static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == 0 { return "0" }                        // and so is −0
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value < 0 { return "-" + string(-value) }

        // Swift's description is the shortest string that round-trips, and
        // among those the closest — the same digits the specification asks
        // for. Reduce it to those digits and a decimal exponent.
        let (digits, n) = shortestDigits(value)
        let k = digits.count

        if k <= n, n <= 21 {
            return String(decoding: digits, as: UTF8.self) + String(repeating: "0", count: n - k)
        }
        if 0 < n, n <= 21 {
            return String(decoding: digits[..<n], as: UTF8.self) + "." + String(decoding: digits[n...], as: UTF8.self)
        }
        if -6 < n, n <= 0 {
            return "0." + String(repeating: "0", count: -n) + String(decoding: digits, as: UTF8.self)
        }
        let exponent = n - 1
        let sign = exponent < 0 ? "-" : "+"
        let mantissa = k == 1
            ? String(decoding: digits, as: UTF8.self)
            : String(decoding: digits[..<1], as: UTF8.self) + "." + String(decoding: digits[1...], as: UTF8.self)
        return mantissa + "e" + sign + String(abs(exponent))
    }

    /// The significant digits of a positive finite double, with no leading
    /// or trailing zeros, and `n` such that the value is 0.d₁d₂…dₖ × 10ⁿ.
    static func shortestDigits(_ value: Double) -> (digits: [UInt8], n: Int) {
        let text = Array(value.description.utf8)
        var mantissa = text[...]
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
            mantissa = text[..<e]
            exponent = Int(String(decoding: text[(e + 1)...], as: UTF8.self))!
        }
        var digits: [UInt8] = []
        var pointAt: Int? = nil
        for byte in mantissa {
            if byte == UInt8(ascii: ".") { pointAt = digits.count } else { digits.append(byte) }
        }
        var n = (pointAt ?? digits.count) + exponent
        while digits.count > 1, digits.last == UInt8(ascii: "0") { digits.removeLast() }
        while digits.count > 1, digits.first == UInt8(ascii: "0") { digits.removeFirst(); n -= 1 }
        return (digits, n)
    }

    /// `Math.round`: the nearest integer, a half going toward +∞.
    ///
    /// Not `floor(x + 0.5)`: for 0.49999999999999994 the sum rounds up to
    /// 1.0 before the floor sees it, and JavaScript answers 0. `x − ⌊x⌋` is
    /// exact in binary floating point, so comparing it to a half is too.
    public static func round(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let floor = value.rounded(.down)
        let rounded = value - floor >= 0.5 ? floor + 1 : floor
        // −0.4 rounds to −0, and −0 to itself. Nothing prints the
        // difference — but a fixture that compares bits sees it, and it is
        // cheaper to be right than to explain why not.
        return rounded == 0 && value.sign == .minus ? -0.0 : rounded
    }

    /// The idiom the ops and the bake both use: `Math.round(n * s) / s`.
    public static func round(_ value: Double, scale: Double) -> Double {
        round(value * scale) / scale
    }

    /// `Number.prototype.toFixed`, for the 0…100 digits it allows and the
    /// magnitudes (below 10²¹) where it does not fall back to toString.
    public static func toFixed(_ value: Double, _ digits: Int) -> String {
        precondition((0...100).contains(digits), "toFixed takes 0 to 100 digits")
        if value.isNaN { return "NaN" }
        if abs(value) >= 1e21 || value.isInfinite { return string(value) }

        // The exact decimal expansion of the double — printf on this
        // platform is exact — rounded half up by hand, because the library
        // rounds half to even and the specification does not.
        let exact = Array(String(format: "%.1100f", abs(value)).utf8)
        let point = exact.firstIndex(of: UInt8(ascii: "."))!
        var kept = Array(exact[..<point]) + Array(exact[(point + 1)..<(point + 1 + digits)])
        let next = exact[point + digits + 1]
        if next >= UInt8(ascii: "5") {
            var i = kept.count - 1
            while true {
                if i < 0 { kept.insert(UInt8(ascii: "1"), at: 0); break }
                if kept[i] == UInt8(ascii: "9") { kept[i] = UInt8(ascii: "0"); i -= 1 } else { kept[i] += 1; break }
            }
        }
        let whole = kept.count - digits
        var text = String(decoding: kept[..<whole], as: UTF8.self)
        if digits > 0 { text += "." + String(decoding: kept[whole...], as: UTF8.self) }
        // "-0.00" is what JavaScript prints for a small negative, and "0.00"
        // for −0 itself: the sign follows `value < 0`, not the sign bit.
        return value < 0 ? "-" + text : text
    }
}
