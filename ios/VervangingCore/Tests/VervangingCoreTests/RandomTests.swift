import Testing
@testable import VervangingCore

/// The expected values are what `seededRandom` in public/js/planner.js gives, printed by Node with `String(value)`.
@Suite struct RandomTests {
    private func first(_ count: Int, seed: Int) -> [Double] {
        var generator = SeededRandom(seed: seed)
        return (0..<count).map { _ in generator.next() }
    }

    @Test(arguments: [
        (42, [0.6011037519201636, 0.44829055899754167, 0.8524657934904099, 0.6697340414393693, 0.17481389874592423]),
        (1, [0.6270739405881613, 0.002735721180215478, 0.5274470399599522, 0.9810509674716741, 0.9683778982143849]),
        (123_456_789, [0.2577907438389957, 0.9707721115555614, 0.7853280142880976, 0.20616457983851433, 0.30307188746519387]),
        (4_294_967_295, [0.8964226141106337, 0.189478256739676, 0.7156526781618595, 0.9440599093213677, 0.8452364315744489]),
    ])
    func matchesTheJavaScriptValues(seed: Int, expected: [Double]) {
        #expect(first(5, seed: seed) == expected)
    }

    @Test func seedZeroCountsAsOne() {
        #expect(first(5, seed: 0) == first(5, seed: 1))
    }

    @Test func seedTakesTheLowThirtyTwoBitsLikeUnsignedShift() {
        // Number(-1) >>> 0 is 4294967295; Number(2 ** 32 + 5) >>> 0 is 5.
        #expect(first(5, seed: -1) == first(5, seed: 4_294_967_295))
        #expect(first(5, seed: 4_294_967_296 + 5) == first(5, seed: 5))
        #expect(first(5, seed: 4_294_967_296) == first(5, seed: 1))
    }

    @Test func printsTheValuesTheWayJavaScriptDoes() {
        #expect(first(3, seed: 42).map(\.javaScriptString)
            == ["0.6011037519201636", "0.44829055899754167", "0.8524657934904099"])
        #expect(0.002735721180215478.javaScriptString == "0.002735721180215478")
    }

    @Test(arguments: [
        (0.0, "0"), (1.0, "1"), (-2.5, "-2.5"), (100.0, "100"), (0.00001, "0.00001"), (0.000001, "0.000001"),
        (0.0000001, "1e-7"), (2.3283064365386963e-10, "2.3283064365386963e-10"), (1e21, "1e+21"),
        (123456789012345680000.0, "123456789012345680000"), (1.5e300, "1.5e+300"),
    ])
    func formatsNumbersLikeJavaScript(value: Double, text: String) {
        #expect(value.javaScriptString == text)
    }
}
