import Testing
@testable import VervangingCore

// The V8 sort port (JavaScriptSort.swift) against Node 22: every expected value below is what
// `Array.prototype.sort` gave in Node for the same input and the same comparator draws (seededRandom from planner.js),
// with the number of comparator calls. Below 64 elements V8 sorts one run (count, reverse, binary insertion); from 64
// on it merges runs with galloping, which the 70- and 300-element cases reach.

private func shuffled(_ n: Int, seed: Int) -> (order: [Int], calls: Int) {
    var random = SeededRandom(seed: seed)
    var calls = 0
    let order = javaScriptSorted(Array(1...n)) { _, _ in
        calls += 1
        return random.next() - 0.5
    }
    return (order, calls)
}

@Suite struct JavaScriptSortTests {
    @Test func aRandomComparatorShufflesAsNodeDoes() {
        // The Extra minuten shuffle of match.js: block 3, keep 4, so seededRandom(3 * 31 + 4).
        #expect(shuffled(11, seed: 97) == ([1, 6, 11, 8, 5, 2, 4, 10, 3, 7, 9], 26))
        #expect(shuffled(40, seed: 5) == ([30, 1, 2, 38, 13, 36, 12, 26, 33, 34, 14, 6, 20, 21, 19, 28, 11, 39, 32, 27,
                                           15, 29, 9, 7, 8, 4, 25, 31, 35, 22, 18, 23, 40, 3, 10, 17, 37, 16, 5, 24],
                                          158))
        #expect(shuffled(70, seed: 9) == ([31, 38, 51, 2, 37, 3, 15, 12, 32, 19, 64, 49, 8, 41, 36, 30, 40, 53, 59, 44,
                                           65, 57, 13, 56, 27, 6, 11, 5, 1, 55, 67, 63, 68, 4, 9, 17, 21, 14, 62, 35,
                                           48, 52, 7, 29, 45, 39, 58, 25, 24, 26, 66, 16, 47, 50, 60, 69, 10, 61, 54,
                                           42, 46, 34, 70, 43, 18, 33, 23, 20, 22, 28], 322))
    }

    @Test func aMostlyConsistentComparatorGallopsAsNodeDoes() {
        var random = SeededRandom(seed: 11)
        var values = SeededRandom(seed: 12)
        let input = (0..<300).map { _ in Int(values.next() * 1000) }
        var calls = 0
        let out = javaScriptSorted(input) { a, b in
            calls += 1
            return random.next() < 0.97 ? Double(a - b) : random.next() - 0.5
        }
        // A 32-bit rolling hash of the whole order, (h * 31 + v) >>> 0, as computed in Node.
        let hash = out.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
        #expect(calls == 2033)
        #expect(hash == 509_101_088)
        #expect(Array(out.prefix(12)) == [0, 1, 1, 2, 5, 13, 16, 19, 29, 30, 36, 36])
        #expect(out.sorted() == input.sorted(), "a permutation of the input")
    }

    @Test func aConsistentComparatorSortsStably() {
        let pairs = (0..<200).map { ($0 % 7, $0) }
        let out = javaScriptSorted(pairs) { Double($0.0 - $1.0) }
        #expect(out.map(\.1) == pairs.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.1))
        #expect(javaScriptSorted([Int]()) { _, _ in 0 } == [])
        #expect(javaScriptSorted([5]) { _, _ in 0 } == [5])
    }
}
