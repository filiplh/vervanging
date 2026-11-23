import Foundation
import Testing

// Command-line regression tests for `vervanging-sim plan`: they run the built sim, which `swift test` builds with the
// tests and puts next to the test bundle, and compare what it prints with what `node scripts/sim.mjs plan` prints for
// the same arguments (the expected texts below are Node's output).

private final class TestBundleMarker {}

private struct SimRun: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func sim(_ arguments: [String]) throws -> SimRun {
    let products = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
    let process = Process()
    process.executableURL = products.appendingPathComponent("vervanging-sim")
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return SimRun(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                  stderr: String(decoding: stderr, as: UTF8.self))
}

private func plan(seed: String) throws -> SimRun {
    try sim(["plan", "--players", "8", "--start", "1,2,3,4,5", "--seed", seed])
}

@Suite struct SimPlanCommandTests {
    // Review of #119: Number("0xＦ") is NaN in JavaScript; only ASCII digits count in a 0x, 0o or 0b literal.
    @Test(arguments: ["0xＦ", "0x１", "0b１", "0o٣", "0x1_0"])
    func aRadixLiteralWithANonASCIIDigitOrASeparatorIsNotANumber(seed: String) throws {
        #expect(try plan(seed: seed)
            == SimRun(status: 2, stdout: "", stderr: "sim: --seed must be a whole number of 1 or more\n"))
    }

    // Review of #119: Number("0x2000000000000101") is 2^61 + 512, the whole literal rounded once (seed 512 after
    // `>>> 0`); rounding digit by digit gave 2^61 (seed 0, so 1) and another plan.
    @Test func aLongHexSeedIsRoundedAsAWholeLikeJavaScript() throws {
        let run = try plan(seed: "0x2000000000000101")
        #expect(run == SimRun(status: 0, stdout: """
            {"blocks":12,"blockSeconds":200,"grid":[[1,2,3,4,5],[1,2,5,6,7],[1,3,6,7,8],[2,4,6,7,8],[1,2,4,5,8],\
            [1,2,3,5,7],[3,5,6,7,8],[1,4,6,7,8],[1,2,3,4,8],[1,2,3,5,6],[3,4,5,6,7],[2,4,6,7,8]],"minutes":{"1":1600,\
            "2":1600,"3":1400,"4":1400,"5":1400,"6":1600,"7":1600,"8":1400},"subsPerChange":[2,2,2,2,2,2,2,2,2,2,2],\
            "longestBenchSeconds":400,"sitLimitRelaxed":false}

            """, stderr: ""))
        #expect(run == (try plan(seed: "512")))
        #expect(run != (try plan(seed: "1")))
    }

    // Ties round to the even neighbour, as in JavaScript: 2^53 + 3 gives 2^53 + 4 (seed 4); 2^53 + 1 and 2^62 + 3 give
    // 2^53 and 2^62 (seed 0, which counts as 1).
    @Test(arguments: [
        ("0x20000000000003", "4"),
        ("0b100000000000000000000000000000000000000000000000000001", "1"),
        ("0o400000000000000000003", "1"),
        ("0X1F", "31"),
    ])
    func radixSeedsGiveTheSameSeedAsJavaScript(literal: String, seed: String) throws {
        let run = try plan(seed: literal)
        #expect(run.status == 0)
        #expect(run == (try plan(seed: seed)))
    }
}
