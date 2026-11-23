import Foundation
import Testing

// Command-line regression tests for `vervanging-sim match` and check-examples' match examples: they run the built sim,
// which `swift test` builds with the tests and puts next to the test bundle, and compare what it prints with what
// `node scripts/sim.mjs match` prints for the same arguments (the expected texts below are Node's output).

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

private func match(_ players: Int, _ actions: String, schedule: String = "equal", seed: Int = 3) throws -> SimRun {
    try sim(["match", "--players", "\(players)", "--start", "1,2,3,4,5", "--schedule", schedule, "--seed", "\(seed)",
             "--actions", actions, "--json"])
}

private func invalid(_ message: String) -> SimRun { SimRun(status: 2, stdout: "", stderr: "sim: \(message)\n") }

private let unknownAction = ": use wissel, undo (optionally with *<count>), wissel:keep=P[:extra][:bench=Q], uit=P or "
    + "terug=P"

@Suite struct SimMatchCommandTests {
    // Contract C2 of #98: a whole match of wissels, everyone at 1000 seconds.
    @Test func elevenWisselsGiveEveryPlayerTheSameMinutes() throws {
        let players = (1...12).map { p in
            "{\"player\":\(p),\"seconds\":1000,\"onCourt\":\([1, 3, 7, 8, 10].contains(p)),\"out\":false}"
        }
        #expect(try match(12, "wissel*11") == SimRun(status: 0, stdout: """
            {"block":12,"blocks":12,"ended":false,"onCourt":[1,3,7,8,10],"minutes":{"1":1000,"2":1000,"3":1000,\
            "4":1000,"5":1000,"6":1000,"7":1000,"8":1000,"9":1000,"10":1000,"11":1000,"12":1000},"extraSeconds":{"1":0,\
            "2":0,"3":0,"4":0,"5":0,"6":0,"7":0,"8":0,"9":0,"10":0,"11":0,"12":0},"overview":[
            """ + players.joined(separator: ",") + "]}\n", stderr: ""))
    }

    // Contracts C3 to C5: with seed 3, player 1 is not due off at the second change, as Node says.
    @Test func aKeepOfAPlayerNotDueOffIsInvalidInput() throws {
        #expect(try match(12, "wissel,wissel:keep=1,undo") == invalid("player 1 is not due off at this change"))
        #expect(try match(11, "wissel,wissel:keep=1:extra") == invalid("player 1 is not due off at this change"))
        #expect(try match(12, "wissel:keep=99") == invalid("player 99 is not due off at this change"))
    }

    @Test func extraMinutenWithAChosenBenchPlayerThenUndo() throws {
        #expect(try match(10, "wissel,wissel:keep=4:extra:bench=8,wissel*2,undo", schedule: "five", seed: 2)
            == SimRun(status: 0, stdout: """
            {"block":4,"blocks":8,"ended":false,"onCourt":[1,6,7,8,9],"minutes":{"1":600,"2":900,"3":300,"4":900,\
            "5":600,"6":300,"7":900,"8":300,"9":600,"10":600},"extraSeconds":{"1":0,"2":0,"3":0,"4":300,"5":0,"6":0,\
            "7":0,"8":0,"9":0,"10":0},"overview":[{"player":1,"seconds":600,"onCourt":true,"out":false},{"player":2,\
            "seconds":900,"onCourt":false,"out":false},{"player":3,"seconds":300,"onCourt":false,"out":false},\
            {"player":4,"seconds":900,"onCourt":false,"out":false},{"player":5,"seconds":600,"onCourt":false,\
            "out":false},{"player":6,"seconds":300,"onCourt":true,"out":false},{"player":7,"seconds":900,\
            "onCourt":true,"out":false},{"player":8,"seconds":300,"onCourt":true,"out":false},{"player":9,\
            "seconds":600,"onCourt":true,"out":false},{"player":10,"seconds":600,"onCourt":false,"out":false}]}

            """, stderr: ""))
    }

    @Test func actionsAreReadAsSimMjsReadsThem() throws {
        #expect(try match(10, "wissel*0") == invalid("action \"wissel*0\": the count must be 1 to 1000"))
        #expect(try match(10, "wissel*1001") == invalid("action \"wissel*1001\": the count must be 1 to 1000"))
        #expect(try match(10, ",,wissel*0005,,undo,") == (try match(10, "wissel*4")))
        for item in ["wissel:extra", "wissel:keep=4:bench=8:extra", "wissel*", "WISSEL", "wissel ", "wissel*１",
                     "uit=x", "jump"] {
            #expect(try match(10, item) == invalid("unknown action \"\(item)\"" + unknownAction), "\(item)")
        }
        // JavaScript splits on the comma itself, even where a combining mark follows it.
        #expect(try match(10, "wissel,\u{301}wissel") == invalid("unknown action \"\u{301}wissel\"" + unknownAction))
        // The actions are read before the plan is made, so an unknown action is named before too few players.
        #expect(try sim(["match", "--players", "3", "--start", "1,2,3", "--actions", "jump"])
            == invalid("unknown action \"jump\"" + unknownAction))
        #expect(try sim(["match", "--players", "3", "--start", "1,2,3", "--actions", "wissel"])
            == invalid("at least 5 players must be present"))
    }

    @Test func theWisselRulesRefuseAsMatchJsDoes() throws {
        #expect(try match(10, "wissel*11,wissel:keep=1") == invalid("no change left: this is the last block"))
        #expect(try match(10, "wissel*12,wissel:keep=1") == (try match(10, "wissel*12")), "after the end: no change")
        #expect(try match(10, "wissel:keep=4:bench=4", seed: 1) == invalid("player 4 is not due on at this change"))
        #expect(try match(10, "wissel:keep=0") == invalid("player 0 is not due off at this change"))
    }

    // A number beyond what a player can have prints as JavaScript prints it (with seed 2, 4 is due off at block 2).
    @Test func aHugePlayerNumberPrintsAsJavaScriptPrintsIt() throws {
        #expect(try match(10, "wissel:keep=99999999999999999999999")
            == invalid("player 1e+23 is not due off at this change"))
        #expect(try match(10, "wissel:keep=9007199254740993")
            == invalid("player 9007199254740992 is not due off at this change"))
        #expect(try match(10, "wissel,wissel:keep=4:bench=18446744073709551616", schedule: "five", seed: 2)
            == invalid("player 18446744073709552000 is not due on at this change"))
        #expect(try match(10, "wissel,wissel:keep=4:extra:bench=9223372036854775807", schedule: "five", seed: 2)
            == invalid("player 9223372036854776000 is not due on at this change"))
    }

    @Test func uitAndTerugAreNotRunYet() throws {
        #expect(try match(10, "uit=3") == invalid("uit and terug are not in the Swift sim yet"))
        #expect(try match(10, "wissel,terug=1") == invalid("uit and terug are not in the Swift sim yet"))
    }

    // Contract C1 of #98, and the uit and terug examples named as skipped until #99.
    @Test func checkExamplesRunsTheMatchExamples() throws {
        let filtered = try sim(["check-examples", "shared/examples", "--only", "match", "--without", "uit,terug"])
        #expect(filtered.status == 0)
        let lines = filtered.stdout.split(separator: "\n")
        #expect(lines.count == 1, "nothing skipped, nothing mismatched: \(filtered.stdout)")
        let counts = lines.last!.split(separator: " ")[0].split(separator: "/")
        #expect(lines.last!.hasSuffix(" match examples match") && counts.count == 2 && counts[0] == counts[1]
                && Int(counts[0])! > 0)

        let all = try sim(["check-examples", "shared/examples", "--only", "match"])
        #expect(all.status == 0)
        #expect(all.stdout.contains("(the Swift sim has no uit or terug yet): "))
        #expect(all.stdout.contains("match-equal-10-uit-terug.json"))
        #expect(all.stdout.hasSuffix(lines.last! + "\n"), "the same examples run; the others are named")
    }

    @Test func withoutTakesCommaSeparatedActionWords() throws {
        #expect(try sim(["check-examples", "shared/examples", "--without", "uit,,terug"]) == SimRun(
            status: 2, stdout: "", stderr: "--without takes comma-separated action words, not \"uit,,terug\"\n"))
        #expect(try sim(["check-examples", "shared/examples", "--without"]).status == 2)
        // Leaving out every match action leaves only the match examples without actions, such as the start.
        let run = try sim(["check-examples", "shared/examples", "--only", "match", "--without",
                           "wissel,undo,keep,extra,bench,uit,terug,jump"])
        #expect(run == SimRun(status: 0, stdout: "1/1 match examples match\n", stderr: ""))
    }
}
