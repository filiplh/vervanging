import Foundation

/// `Date.parse(text)` for the date-time format ECMAScript defines (what `new Date().toISOString()` writes, the form
/// the history stores): milliseconds since 1970-01-01T00:00:00Z, or nil where JavaScript gives NaN.
///
/// Read: `YYYY`, `YYYY-MM` or `YYYY-MM-DD` (or a six-digit year with a sign, not `-000000`), then optionally
/// `THH:mm`, `:ss` and `.` with one or more digits (the first three count), then `Z` or `±HH:mm`. As in V8 (Node 22,
/// checked by hand), a day of 1 to 31 is taken in every month and runs on into the next one (`2026-02-30` is
/// 2 March), `24:00` is midnight at the end of the day, and a time beyond ±8.64e15 ms is NaN.
///
/// ⚠ A date-time without `Z` or an offset is local time in JavaScript; here it is read as UTC. ⚠ V8 also falls back
/// to its own looser parser (`2026-11-22 10:00Z`, a lower-case `t` or `z`, `+0100`, other date texts) where this
/// gives nil. The web app writes neither; both only change whether a hand-made `clearedAt` is kept.
func javaScriptISOTime(_ text: String) -> Double? {
    var units = Array(text.utf8)[...]
    func digits(_ count: Int) -> Int? {
        guard units.count >= count else { return nil }
        var value = 0
        for unit in units.prefix(count) {
            guard (0x30...0x39).contains(unit) else { return nil }
            value = value * 10 + Int(unit - 0x30)
        }
        units = units.dropFirst(count)
        return value
    }
    func take(_ char: Character) -> Bool {
        guard units.first == char.asciiValue else { return false }
        units = units.dropFirst()
        return true
    }

    let year: Int
    if let sign = units.first, sign == 0x2B || sign == 0x2D { // + -
        units = units.dropFirst()
        guard let value = digits(6), !(sign == 0x2D && value == 0) else { return nil }
        year = sign == 0x2D ? -value : value
    } else {
        guard let value = digits(4) else { return nil }
        year = value
    }
    var month = 1, day = 1
    if take("-") {
        guard let m = digits(2), (1...12).contains(m) else { return nil }
        month = m
        if take("-") {
            guard let d = digits(2), (1...31).contains(d) else { return nil }
            day = d
        }
    }
    var hour = 0, minute = 0, second = 0, millisecond = 0, offsetMinutes = 0
    if take("T") {
        guard let h = digits(2), take(":"), let m = digits(2) else { return nil }
        hour = h
        minute = m
        if take(":") {
            guard let s = digits(2) else { return nil }
            second = s
            if take(".") {
                var fraction: [UInt8] = []
                while let unit = units.first, (0x30...0x39).contains(unit) {
                    fraction.append(unit - 0x30)
                    units = units.dropFirst()
                }
                guard !fraction.isEmpty else { return nil }
                for (place, digit) in zip([100, 10, 1], fraction) { millisecond += Int(digit) * place }
            }
        }
        guard hour < 24 || (hour == 24 && minute == 0 && second == 0 && millisecond == 0), minute < 60, second < 60
        else { return nil }
        if !take("Z"), let sign = units.first, sign == 0x2B || sign == 0x2D {
            units = units.dropFirst()
            guard let oh = digits(2), take(":"), let om = digits(2), oh < 24, om < 60 else { return nil }
            offsetMinutes = (sign == 0x2D ? -1 : 1) * (oh * 60 + om)
        }
    }
    guard units.isEmpty else { return nil }

    // Days from 1970-01-01 to the first of this month (proleptic Gregorian calendar), then the day runs on from there.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let shiftedMonth = (month + 9) % 12
    let dayOfYear = (153 * shiftedMonth + 2) / 5
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let days = era * 146_097 + dayOfEra - 719_468 + (day - 1)
    let milliseconds = Double(days) * 86_400_000
        + Double(((hour * 60 + minute - offsetMinutes) * 60 + second) * 1000 + millisecond)
    return abs(milliseconds) <= 8.64e15 ? milliseconds : nil
}
