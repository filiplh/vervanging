import Foundation
import Testing

// Command-line tests for `vervanging-sim history`, the --history and --use-history options of `plan`, and how
// check-examples counts an unreadable example. They run the built sim, which `swift test` builds with the tests and
// puts next to the test bundle, from the repo root, and compare what it prints with what `node scripts/sim.mjs`
// prints for the same arguments (the expected texts below are Node's output).

private final class TestBundleMarker {}

private struct SimRun: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func sim(_ arguments: [String]) throws -> SimRun {
    let products = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
    let process = Process()
    process.executableURL = products.appendingPathComponent("vervanging-sim")
    process.arguments = arguments
    process.currentDirectoryURL = repoRoot
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

private func invalid(_ message: String) -> SimRun { SimRun(status: 2, stdout: "", stderr: "sim: \(message)\n") }

@Suite struct SimHistoryCommandTests {
    // C2 and C4 of #97.
    @Test func historyPrintsTheSeasonTotalsOfAFile() throws {
        #expect(try sim(["history", "--history", "scripts/fixtures/history-sample.json", "--json"]) == SimRun(
            status: 0, stdout: """
            {"matches":2,"totals":{"1":0,"2":0,"3":0,"4":0,"5":3000,"6":3000,"7":3000,"8":3000,"9":3000,"10":3000,\
            "11":3000,"12":3000}}

            """, stderr: ""))
        #expect(try sim(["history", "--history", "scripts/fixtures/history-empty.json", "--json"])
            == SimRun(status: 0, stdout: "{\"matches\":0,\"totals\":{}}\n", stderr: ""))
    }

    // C5 of #97, and the other files readHistory refuses.
    @Test func aMissingOrUnreadableHistoryFileExits2WithOneLine() throws {
        #expect(try sim(["history", "--history", "scripts/fixtures/does-not-exist.json"])
            == invalid("cannot read the history file \"scripts/fixtures/does-not-exist.json\" (ENOENT)"))
        #expect(try sim(["history", "--history", "scripts/fixtures"])
            == invalid("cannot read the history file \"scripts/fixtures\" (EISDIR)"))
        #expect(try sim(["history", "--history", "scripts/fixtures/history-empty.json/x"])
            == invalid("cannot read the history file \"scripts/fixtures/history-empty.json/x\" (ENOTDIR)"))
        #expect(try sim(["history", "--history", "scripts/sim.mjs"])
            == invalid("the history file \"scripts/sim.mjs\" is not valid JSON"))
        #expect(try sim(["history", "--json"]) == invalid("--history <file> is required"))
        #expect(try sim(["history", "--history"]) == invalid("--history needs a value"))
    }

    // C3 of #97.
    @Test func planWithUseHistoryLetsThePlayerBehindCatchUp() throws {
        #expect(try sim(["plan", "--players", "12", "--start", "1,2,3,4,5", "--schedule", "equal", "--seed", "5",
                         "--history", "scripts/fixtures/history-catchup.json", "--use-history", "--json"]) == SimRun(
            status: 0, stdout: """
            {"blocks":12,"blockSeconds":200,"grid":[[1,2,3,4,5],[1,2,4,11,12],[2,6,7,11,12],[6,7,8,10,12],\
            [3,7,8,9,10],[1,3,5,8,9],[1,4,5,9,11],[1,2,4,11,12],[2,6,7,11,12],[6,7,8,10,12],[3,5,6,8,10],\
            [3,4,5,9,10]],"minutes":{"1":1000,"2":1000,"3":1000,"4":1000,"5":1000,"6":1000,"7":1000,"8":1000,\
            "9":800,"10":1000,"11":1000,"12":1200},"subsPerChange":[2,2,2,2,2,2,2,2,2,2,2],"longestBenchSeconds":800,\
            "sitLimitRelaxed":false}

            """, stderr: ""))
    }

    @Test func planReadsTheHistoryFileBeforeItChecksTheSchedule() throws {
        let base = ["plan", "--players", "10", "--start", "1,2,3,4,5", "--schedule", "bad"]
        #expect(try sim(base + ["--history", "nope.json", "--use-history"])
            == invalid("cannot read the history file \"nope.json\" (ENOENT)"))
        #expect(try sim(base + ["--use-history"]) == invalid("--use-history needs --history <file>"))
        #expect(try sim(base + ["--history", "scripts/fixtures/history-sample.json"])
            == invalid("unknown schedule \"bad\": use equal or five"))
    }

    @Test func historyWithoutUseHistoryLeavesThePlanAsTheSeedGivesIt() throws {
        let base = ["plan", "--players", "12", "--start", "1,2,3,4,5", "--seed", "42"]
        let plain = try sim(base)
        #expect(plain.status == 0)
        #expect(try sim(base + ["--history", "scripts/fixtures/history-catchup.json"]) == plain)
        #expect(try sim(base + ["--history", "scripts/fixtures/history-catchup.json", "--use-history"]) != plain)
    }

    // Validation of #119 ("Also seen"): an unreadable example dropped out of the count, so the last line read as a
    // full match.
    @Test func checkExamplesCountsAnUnreadableExampleAsAMismatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vervanging-check-examples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let examples = repoRoot.appendingPathComponent("shared/examples")
        for name in ["plan-equal-10.json", "history-sample.json"] {
            try FileManager.default.copyItem(at: examples.appendingPathComponent(name),
                                             to: dir.appendingPathComponent(name))
        }
        var broken = try Data(contentsOf: examples.appendingPathComponent("plan-five-8.json"))
        broken.append(contentsOf: Array("{".utf8))
        try broken.write(to: dir.appendingPathComponent("plan-five-8.json"))

        #expect(try sim(["check-examples", dir.path, "--only", "plan"]) == SimRun(status: 1, stdout: """
            cannot read plan-five-8.json: not valid JSON
            1/2 plan examples match

            """, stderr: ""))
        #expect(try sim(["check-examples", dir.path]) == SimRun(status: 1, stdout: """
            cannot read plan-five-8.json: not valid JSON
            2/3 examples match

            """, stderr: ""))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("plan-five-8.json"))
        #expect(try sim(["check-examples", dir.path]) == SimRun(status: 0, stdout: "2/2 examples match\n", stderr: ""))
    }
}
