import Foundation

/// The planner's seeded generator, ported bit for bit from `seededRandom` in `public/js/planner.js` (mulberry32).
///
/// All arithmetic wraps at 32 bits (`&+`, `&*`), as `Math.imul` and `>>> 0` do in JavaScript, so the same seed gives
/// the same sequence, and so the same plan, in both apps (ADR-003).
public struct SeededRandom: Sendable {
    private var state: UInt32

    /// Takes the low 32 bits of `seed`, as `Number(seed) >>> 0` does; a seed whose low 32 bits are 0 counts as 1.
    public init(seed: Int) {
        let low = UInt32(truncatingIfNeeded: seed)
        state = low == 0 ? 1 : low
    }

    /// The next value, in [0, 1).
    public mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

extension Double {
    /// The text JavaScript's `String(number)` gives for this value (ECMAScript Number::toString): the shortest digits
    /// that read back as the same value, with a plain decimal point from 1e-7 up to below 1e21 and an exponent
    /// outside that range. Lets the Swift runner print exactly what scripts/sim.mjs prints.
    public var javaScriptString: String {
        if isNaN { return "NaN" }
        if isInfinite { return self < 0 ? "-Infinity" : "Infinity" }
        if self == 0 { return "0" }
        if self < 0 { return "-" + (-self).javaScriptString }
        // Swift's description also gives the shortest round-trip digits, as "123.45", "0.001" or "1.2e-07".
        let text = "\(self)"
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(pieces[0])
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        var digits = whole + fraction
        // value = 0.digits × 10^n, the n of the ECMAScript algorithm.
        var n = whole.count + exponent
        while digits.hasPrefix("0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        let k = digits.count
        if k <= n && n <= 21 { return digits + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 {
            let cut = digits.index(digits.startIndex, offsetBy: n)
            return digits[..<cut] + "." + digits[cut...]
        }
        if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + digits }
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let head = String(digits.first!)
        let tail = digits.dropFirst()
        return head + (tail.isEmpty ? "" : "." + tail) + "e" + sign + String(abs(e))
    }
}
