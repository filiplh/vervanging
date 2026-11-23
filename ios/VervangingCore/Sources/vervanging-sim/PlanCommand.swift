import Foundation
import VervangingCore

// The plan command, ported from planFrom and main in scripts/sim.mjs: the same checks in the same order, the same
// messages and the same JSON, byte for byte.

/// JavaScript's `Number(text)` (ECMAScript StringToNumber): surrounding white space is ignored, an empty text is 0,
/// and decimal, `0x`, `0o` and `0b` literals and Infinity are read; anything else is NaN.
func javaScriptNumber(_ text: String) -> Double {
    let space: Set<Unicode.Scalar> = ["\u{9}", "\u{A}", "\u{B}", "\u{C}", "\u{D}", "\u{20}", "\u{A0}", "\u{1680}",
                                      "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}"]
    func isSpace(_ s: Unicode.Scalar) -> Bool { space.contains(s) || (0x2000...0x200A).contains(s.value) }
    var scalars = Array(text.unicodeScalars)
    while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    let s = String(String.UnicodeScalarView(scalars))
    if s.isEmpty { return 0 }
    for (prefix, radix) in [("0x", 16), ("0X", 16), ("0o", 8), ("0O", 8), ("0b", 2), ("0B", 2)] where s.hasPrefix(prefix) {
        let digits = s.dropFirst(2)
        guard !digits.isEmpty else { return .nan }
        var value = 0.0
        for c in digits {
            guard let d = c.hexDigitValue, d < radix else { return .nan }
            value = value * Double(radix) + Double(d)
        }
        return value
    }
    var body = Substring(s)
    var sign = 1.0
    if let c = body.first, c == "+" || c == "-" {
        sign = c == "-" ? -1 : 1
        body = body.dropFirst()
    }
    if body == "Infinity" { return sign * .infinity }
    // StrUnsignedDecimalLiteral: digits [. digits] or . digits, then an optional exponent; checked here because
    // Double(String) also takes forms such as "nan", "inf" and hexadecimal floats.
    var rest = body[...]
    let whole = rest.prefix { $0.isASCII && $0.isNumber }
    rest = rest.dropFirst(whole.count)
    var fraction = Substring("")
    if rest.first == "." {
        rest = rest.dropFirst()
        fraction = rest.prefix { $0.isASCII && $0.isNumber }
        rest = rest.dropFirst(fraction.count)
    }
    guard !whole.isEmpty || !fraction.isEmpty else { return .nan }
    var exponent = ""
    if let e = rest.first, e == "e" || e == "E" {
        rest = rest.dropFirst()
        var exponentSign = ""
        if let c = rest.first, c == "+" || c == "-" {
            exponentSign = String(c)
            rest = rest.dropFirst()
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return .nan }
        rest = rest.dropFirst(digits.count)
        exponent = "e" + exponentSign + digits
    }
    guard rest.isEmpty else { return .nan }
    // Written out in full ("1." as "1.0", ".5" as "0.5"), the form Double(String) reads, correctly rounded as in JS.
    let literal = (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction) + exponent
    guard let value = Double(literal) else { return .nan }
    return sign * value
}

/// JavaScript's `Number.isInteger`.
func isJavaScriptInteger(_ value: Double) -> Bool { value.isFinite && value.rounded(.towardZero) == value }

/// The largest whole number a Double holds exactly; the sim takes player numbers and counts up to it.
let largestExactWhole = 9_007_199_254_740_992.0

/// Like `numberList` in sim.mjs. ⚠ A whole number beyond 2^53 is refused here as not a player number, where sim.mjs
/// would take it (and then say the player is not present); no example uses one.
func numberList(_ text: String, _ name: String) throws -> [Int] {
    let list = text.split(separator: ",", omittingEmptySubsequences: true).map { javaScriptNumber(String($0)) }
    guard list.allSatisfy({ isJavaScriptInteger($0) && abs($0) <= largestExactWhole }) else {
        throw UsageError("--\(name) must be comma-separated player numbers")
    }
    return list.map { Int($0) }
}

/// Like `positiveInt` in sim.mjs; the value as a Double, since a seed may go beyond Int.
func positiveInt(_ text: String, _ name: String) throws -> Double {
    let n = javaScriptNumber(text)
    guard isJavaScriptInteger(n), n >= 1 else { throw UsageError("--\(name) must be a whole number of 1 or more") }
    return n
}

func planFrom(_ opts: [String: String]) throws -> Plan {
    guard let playersText = opts["players"] else { throw UsageError("--players is required") }
    guard let startText = opts["start"] else { throw UsageError("--start is required") }
    let countValue = try positiveInt(playersText, "players")
    // ⚠ sim.mjs fails with a RangeError (exit status 1) on a count it cannot make an array of; the Swift sim refuses
    // a count beyond 2^53 as invalid input instead. No example uses one.
    guard countValue <= largestExactWhole else { throw UsageError("--players must be a whole number of 1 or more") }
    let players = Array(1...Int(countValue))
    let start = try numberList(startText, "start")
    // seededRandom takes `Number(seed) >>> 0`: the seed modulo 2^32.
    let seed = try opts["seed"].map { Int(UInt32(fmod(try positiveInt($0, "seed"), 4_294_967_296))) } ?? 1
    if opts["history"] != nil {
        throw UsageError("--history is not in the Swift sim yet: it comes with the history rules (#97)")
    }
    if opts["use-history"] != nil { throw UsageError("--use-history needs --history <file>") }
    let schedule = opts["schedule"] ?? "equal"
    if Planner.schedules[schedule] == nil { throw UsageError("unknown schedule \"\(schedule)\": use equal or five") }
    var plan = try Planner.makePlan(players: players, start: start, schedule: schedule, seed: seed)
    if let swapText = opts["swap"] {
        let pair = try numberList(swapText, "swap")
        if pair.count != 2 { throw UsageError("--swap takes two player numbers") }
        plan = try Planner.swapPlayers(plan, pair[0], pair[1])
    }
    return plan
}

/// The plan command's output: the JSON.stringify text of sim.mjs's result object, with its key order. Every value is
/// a whole number, a boolean or a list or object of them; the keys of `minutes` are player numbers, which a
/// JavaScript object lists in ascending order.
func planJSON(_ opts: [String: String]) throws -> String {
    let plan = try planFrom(opts)
    let stats = Planner.planStats(plan)
    func list(_ values: [Int]) -> String { "[" + values.map(String.init).joined(separator: ",") + "]" }
    let grid = "[" + plan.grid.map(list).joined(separator: ",") + "]"
    let minutes = "{" + stats.minutes.keys.sorted().map { "\"\($0)\":\(stats.minutes[$0]!)" }.joined(separator: ",")
        + "}"
    return "{\"blocks\":\(plan.blocks),\"blockSeconds\":\(plan.blockSeconds),\"grid\":\(grid),"
        + "\"minutes\":\(minutes),\"subsPerChange\":\(list(stats.subsPerChange)),"
        + "\"longestBenchSeconds\":\(stats.longestBenchSeconds),\"sitLimitRelaxed\":\(plan.sitLimitRelaxed)}"
}
