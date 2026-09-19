// `Math.hypot`, which is V8's and not C's (PD14).
//
// ECMA-262 asks only for "an implementation-approximated value", so the
// answer is whatever the engine under the old engine computed — and V8 does
// not call the platform's `hypot`. It scales every argument by the largest,
// sums the squares of the quotients with Kahan compensation, and multiplies
// the root back up (`src/builtins/math.tq`, MathHypot). Every step of that is
// an operation IEEE 754 fixes — a division, a product, a sum, a difference, a
// square root — so written out here it is V8's answer to the bit, where C's
// more carefully rounded `hypot` is a different answer more than one time in
// three.
//
// Measured, not supposed. In Node 24 (V8 13.6) this algorithm reproduced
// `Math.hypot(a, b)` for 2,000,000 of 2,000,000 seeded pairs, where
// `Math.sqrt(a*a + b*b)` managed 1,205,414. Against the 614 pairs in
// fixtures/core/camera-project.json, `JS.hypot` is bit-identical for all
// 614 and Foundation's `hypot` for 388, a last place out for the rest
// (CameraProjectTests prints both counts, so a change in either is seen).
//
// The camera's pitch stands on this (`aimAt`), and a pitch is baked into a
// rail key and rounded at 1e-4, which is where a last place gets to choose.

extension JS {
    /// `Math.hypot(a, b)`, as V8 computes it.
    public static func hypot(_ a: Double, _ b: Double) -> Double {
        // Infinity wins over NaN, as the specification has it — and V8's
        // loop never records a NaN as the maximum, because `NaN > max` is
        // false, which is the same trick this comparison plays.
        let absA = abs(a), absB = abs(b)
        var max = 0.0
        if absA > max { max = absA }
        if absB > max { max = absB }
        if max == .infinity { return .infinity }
        if a.isNaN || b.isNaN { return .nan }
        if max == 0 { return 0 }

        // Kahan summation to avoid rounding errors.
        // Summing the squares of the quotients
        var sum = 0.0, compensation = 0.0
        for value in [absA, absB] {
            let n = value / max
            let summand = n * n - compensation
            let preliminary = sum + summand
            compensation = (preliminary - sum) - summand
            sum = preliminary
        }
        return sum.squareRoot() * max
    }
}
