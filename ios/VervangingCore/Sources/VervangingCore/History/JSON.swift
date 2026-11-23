import Foundation

// What the history needs of JavaScript's JSON and objects (public/js/history.js stores its value with JSON.stringify
// and reads it back with JSON.parse), so the Swift history reads the same files and gives the same totals in the same
// key order as the web app (ADR-003). Strings are compared by their UTF-16 code units, as JavaScript compares them:
// Swift's `==` on String would also call canonically equivalent texts equal ("é" and "e" + U+0301).

/// A key compared by its UTF-16 code units, as a JavaScript property key is.
struct CodeUnitKey: Hashable, Sendable {
    let units: [UInt16]
    init(_ text: String) { units = Array(text.utf16) }
}

/// True when `a` and `b` are the same JavaScript string: the same UTF-16 code units.
func sameCodeUnits(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }

/// True when `key` is an array index (a whole number from 0 to 2^32 − 2 written without leading zeros). A JavaScript
/// object lists those keys first, in ascending order, and its other keys after them in the order they were added.
func isArrayIndex(_ key: String) -> Bool {
    let units = Array(key.utf8)
    guard !units.isEmpty, units.count <= 10, units.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
    if units.count > 1 && units[0] == 0x30 { return false }
    return UInt64(key)! <= 4_294_967_294
}

/// An object with JavaScript's key order: array-index keys first in ascending order, then the other keys in the order
/// they were first added. Setting a key that is already there changes its value and keeps its place, as in
/// JavaScript. Equality ignores the order, as `assert.deepStrictEqual` does.
public struct JSObject<Value>: Sendable where Value: Sendable {
    private var insertionKeys: [String] = []
    private var values: [Value] = []
    private var positions: [CodeUnitKey: Int] = [:]

    public init() {}

    public subscript(key: String) -> Value? {
        get { positions[CodeUnitKey(key)].map { values[$0] } }
        set {
            guard let newValue else { preconditionFailure("JSObject keys are never removed") }
            if let at = positions[CodeUnitKey(key)] {
                values[at] = newValue
            } else {
                positions[CodeUnitKey(key)] = values.count
                insertionKeys.append(key)
                values.append(newValue)
            }
        }
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// The keys in the order `Object.keys` gives them.
    public var keys: [String] {
        let indices = insertionKeys.filter(isArrayIndex).sorted { UInt64($0)! < UInt64($1)! }
        return indices + insertionKeys.filter { !isArrayIndex($0) }
    }

    /// The entries in the order `Object.entries` gives them.
    public var entries: [(key: String, value: Value)] { keys.map { ($0, self[$0]!) } }
}

extension JSObject: ExpressibleByDictionaryLiteral {
    /// The keys are added in the order written; a key written twice keeps its first place and its last value.
    public init(dictionaryLiteral elements: (String, Value)...) {
        for (key, value) in elements { self[key] = value }
    }
}

extension JSObject: Equatable where Value: Equatable {
    public static func == (lhs: JSObject, rhs: JSObject) -> Bool {
        lhs.count == rhs.count && lhs.insertionKeys.allSatisfy { lhs[$0] == rhs[$0] }
    }
}

extension JSObject: CustomStringConvertible {
    public var description: String {
        "[" + entries.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ") + "]"
    }
}

/// A value as JSON.parse gives it, kept only to the depth the history reads (`JSONValue.parse`): an array or object
/// below that depth is `.deeper`, checked for valid JSON but with its contents left out.
indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSObject<JSONValue>)
    case deeper(isArray: Bool)

    /// The value of `key` when this is an object, as `value[key]` in JavaScript (`nil` for undefined).
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}

/// The text is not JSON, so JSON.parse would throw.
public struct NotJSON: Error, Equatable, Sendable {}

extension JSONValue {
    /// JSON.parse over `text`, with its grammar exactly (ECMA-404 as ECMAScript reads it): white space is only space,
    /// tab, line feed and carriage return; numbers are read as the nearest Double, so 1e400 is Infinity; in an object a
    /// later duplicate key replaces the value and keeps the first place. Arrays and objects nested `keep` levels deep
    /// or more are checked but not kept (`.deeper`). The parser keeps its own stack, so any nesting depth that
    /// JSON.parse reads is read here too, without running out of call stack.
    ///
    /// ⚠ A `\u` escape of a lone surrogate (half of a UTF-16 pair) becomes U+FFFD here, where JavaScript keeps the lone
    /// code unit: two texts that differ only there would read as the same. The web app never writes one.
    static func parse(_ text: String, keep: Int) throws(NotJSON) -> JSONValue {
        var parser = JSONParser(units: Array(text.utf16), keep: keep)
        return try parser.parse()
    }
}

private struct JSONParser {
    let units: [UInt16]
    let keep: Int
    var pos = 0

    private struct Frame {
        let isArray: Bool
        let kept: Bool
        var elements: [JSONValue] = []
        var object = JSObject<JSONValue>()
        var key = ""
    }

    init(units: [UInt16], keep: Int) {
        self.units = units
        self.keep = keep
    }

    private static let space: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D]

    mutating func skipSpace() {
        while pos < units.count && Self.space.contains(units[pos]) { pos += 1 }
    }

    mutating func expect(_ unit: UInt16) throws(NotJSON) {
        guard pos < units.count && units[pos] == unit else { throw NotJSON() }
        pos += 1
    }

    mutating func parse() throws(NotJSON) -> JSONValue {
        var stack: [Frame] = []
        while true {
            skipSpace()
            guard pos < units.count else { throw NotJSON() }
            var value: JSONValue
            switch units[pos] {
            case 0x7B, 0x5B: // { [
                let isArray = units[pos] == 0x5B
                pos += 1
                stack.append(Frame(isArray: isArray, kept: stack.count < keep))
                skipSpace()
                if pos < units.count && units[pos] == (isArray ? 0x5D : 0x7D) { // ] }
                    pos += 1
                    value = close(stack.removeLast())
                } else {
                    if !isArray { try readKey(into: &stack[stack.count - 1]) }
                    continue
                }
            case 0x22: value = .string(try readString())
            case 0x74: try literal("true"); value = .bool(true)
            case 0x66: try literal("false"); value = .bool(false)
            case 0x6E: try literal("null"); value = .null
            case 0x2D, 0x30...0x39: value = .number(try readNumber())
            default: throw NotJSON()
            }
            // Hand the finished value to the open array or object, closing each one that ends here.
            while true {
                guard !stack.isEmpty else {
                    skipSpace()
                    guard pos == units.count else { throw NotJSON() }
                    return value
                }
                let top = stack.count - 1
                if stack[top].kept {
                    if stack[top].isArray {
                        stack[top].elements.append(value)
                    } else {
                        stack[top].object[stack[top].key] = value
                    }
                }
                skipSpace()
                guard pos < units.count else { throw NotJSON() }
                if units[pos] == 0x2C { // ,
                    pos += 1
                    if !stack[top].isArray { try readKey(into: &stack[top]) }
                    break
                }
                try expect(stack[top].isArray ? 0x5D : 0x7D)
                value = close(stack.removeLast())
            }
        }
    }

    private func close(_ frame: Frame) -> JSONValue {
        guard frame.kept else { return .deeper(isArray: frame.isArray) }
        return frame.isArray ? .array(frame.elements) : .object(frame.object)
    }

    /// `"key"` and the colon after it.
    private mutating func readKey(into frame: inout Frame) throws(NotJSON) {
        skipSpace()
        guard pos < units.count && units[pos] == 0x22 else { throw NotJSON() }
        frame.key = try readString()
        skipSpace()
        try expect(0x3A) // :
    }

    private mutating func literal(_ word: String) throws(NotJSON) {
        for unit in word.utf16 { try expect(unit) }
    }

    private mutating func readString() throws(NotJSON) -> String {
        pos += 1 // the opening quote
        var out: [UInt16] = []
        while true {
            guard pos < units.count else { throw NotJSON() }
            let unit = units[pos]
            pos += 1
            switch unit {
            case 0x22: return String(decoding: out, as: UTF16.self)
            case 0x00...0x1F: throw NotJSON()
            case 0x5C: // backslash
                guard pos < units.count else { throw NotJSON() }
                let escape = units[pos]
                pos += 1
                switch escape {
                case 0x22, 0x5C, 0x2F: out.append(escape) // " \ /
                case 0x62: out.append(0x08) // b
                case 0x66: out.append(0x0C) // f
                case 0x6E: out.append(0x0A) // n
                case 0x72: out.append(0x0D) // r
                case 0x74: out.append(0x09) // t
                case 0x75: // u
                    guard pos + 4 <= units.count else { throw NotJSON() }
                    var code: UInt16 = 0
                    for digit in units[pos..<(pos + 4)] {
                        let value: UInt16
                        switch digit {
                        case 0x30...0x39: value = digit - 0x30
                        case 0x41...0x46: value = digit - 0x41 + 10
                        case 0x61...0x66: value = digit - 0x61 + 10
                        default: throw NotJSON()
                        }
                        code = code << 4 | value
                    }
                    pos += 4
                    out.append(code)
                default: throw NotJSON()
                }
            default: out.append(unit)
            }
        }
    }

    /// -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?, read as the nearest Double (Swift's Double(String) rounds
    /// correctly, as JavaScript does, and gives ±Infinity beyond the largest Double).
    private mutating func readNumber() throws(NotJSON) -> Double {
        let start = pos
        func isDigit(_ i: Int) -> Bool { i < units.count && (0x30...0x39).contains(units[i]) }
        if units[pos] == 0x2D { pos += 1 }
        guard isDigit(pos) else { throw NotJSON() }
        if units[pos] == 0x30 {
            pos += 1
        } else {
            while isDigit(pos) { pos += 1 }
        }
        if pos < units.count && units[pos] == 0x2E { // .
            pos += 1
            guard isDigit(pos) else { throw NotJSON() }
            while isDigit(pos) { pos += 1 }
        }
        if pos < units.count && (units[pos] == 0x65 || units[pos] == 0x45) { // e E
            pos += 1
            if pos < units.count && (units[pos] == 0x2B || units[pos] == 0x2D) { pos += 1 }
            guard isDigit(pos) else { throw NotJSON() }
            while isDigit(pos) { pos += 1 }
        }
        let literal = String(decoding: units[start..<pos], as: UTF16.self)
        guard let value = Double(literal) else { throw NotJSON() }
        return value
    }
}

/// JSON.stringify of a string (ECMAScript QuoteJSONString): `"` and `\` escaped, the short escapes for backspace,
/// tab, line feed, form feed and carriage return, `\u00xx` (lower-case hex) for the other control characters, and
/// everything else as it is. A Swift string holds no lone surrogate, so the escape for one is never needed.
func javaScriptQuoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{09}": out += "\\t"
        case "\u{0A}": out += "\\n"
        case "\u{0C}": out += "\\f"
        case "\u{0D}": out += "\\r"
        case "\u{00}"..."\u{1F}":
            let hex = String(scalar.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// JSON.stringify of a number: its JavaScript text, or `null` for NaN and ±Infinity.
func javaScriptJSONNumber(_ value: Double) -> String { value.isFinite ? value.javaScriptString : "null" }

/// JSON.stringify of an object of numbers, in its key order.
func javaScriptJSON(_ object: JSObject<Double>) -> String {
    "{" + object.entries.map { javaScriptQuoted($0.key) + ":" + javaScriptJSONNumber($0.value) }
        .joined(separator: ",") + "}"
}
