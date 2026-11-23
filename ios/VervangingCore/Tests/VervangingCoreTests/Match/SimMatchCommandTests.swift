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

/// The match command's JSON line for players 1 to `seconds.count` with no Extra minuten, in sim.mjs's key order.
private func json(block: Int, blocks: Int, ended: Bool = false, onCourt: [Int], seconds: [Int], out: [Int]) -> String {
    let players = Array(1...seconds.count)
    let minutes = players.map { "\"\($0)\":\(seconds[$0 - 1])" }.joined(separator: ",")
    let extra = players.map { "\"\($0)\":0" }.joined(separator: ",")
    let overview = players.map {
        "{\"player\":\($0),\"seconds\":\(seconds[$0 - 1]),\"onCourt\":\(onCourt.contains($0)),\"out\":\(out.contains($0))}"
    }.joined(separator: ",")
    let court = onCourt.map(String.init).joined(separator: ",")
    return "{\"block\":\(block),\"blocks\":\(blocks),\"ended\":\(ended),\"onCourt\":[\(court)],\"minutes\":{\(minutes)},"
        + "\"extraSeconds\":{\(extra)},\"overview\":[\(overview)]}\n"
}

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

    // Contracts C2 to C4 of #99: uit and terug, uit in the last block, uit for a bench player (Node's output).
    @Test func uitAndTerugGiveWhatSimMjsGives() throws {
        #expect(try match(10, "wissel,uit=3,wissel,terug=3", schedule: "five") == SimRun(status: 0, stdout: json(
            block: 3, blocks: 8, onCourt: [1, 6, 8, 9, 10], seconds: [900, 300, 600, 600, 300, 600, 0, 600, 300, 300],
            out: []), stderr: ""))
        #expect(try match(12, "wissel*11,uit=1") == SimRun(status: 0, stdout: json(
            block: 12, blocks: 12, onCourt: [2, 3, 7, 8, 10], seconds: Array(repeating: 1000, count: 12), out: [1]),
            stderr: ""))
        #expect(try match(12, "uit=12,wissel") == SimRun(status: 0, stdout: json(
            block: 2, blocks: 12, onCourt: [1, 4, 5, 8, 10], seconds: [400, 200, 200, 400, 400, 0, 0, 200, 0, 200, 0, 0],
            out: [12]), stderr: ""))
    }

    @Test func uitAndTerugRefuseAsMatchJsDoes() throws {
        #expect(try match(12, "uit=13") == invalid("player 13 is not in this match"))
        #expect(try match(12, "uit=0") == invalid("player 0 is not in this match"))
        #expect(try match(12, "uit=1,uit=1") == invalid("player 1 is already out"))
        #expect(try match(12, "terug=4") == invalid("player 4 is not out"))
        #expect(try match(8, "uit=1,uit=2,uit=3,uit=4") == invalid("at least 5 players must be available"))
        #expect(try match(12, "wissel*12,uit=1") == invalid("the match has ended"))
        #expect(try match(12, "wissel*12,terug=1") == invalid("the match has ended"))
        #expect(try match(12, "uit=1,wissel*11,terug=1") == invalid("no block left: this is the last block"))
        #expect(try match(12, "uit=1,wissel:keep=1") == invalid("player 1 is out and cannot stay on"))
        #expect(try match(12, "uit=007") == (try match(12, "uit=7")), "digits read as a number")
    }

    @Test func aHugeUitOrTerugPlayerNumberPrintsAsJavaScriptPrintsIt() throws {
        #expect(try match(12, "uit=99999999999999999999999") == invalid("player 1e+23 is not in this match"))
        #expect(try match(12, "uit=9223372036854775807") == invalid("player 9223372036854776000 is not in this match"))
        #expect(try match(12, "uit=9007199254740993") == invalid("player 9007199254740992 is not in this match"))
        #expect(try match(12, "terug=99999999999999999999999") == invalid("player 1e+23 is not out"))
    }

    // Contract C1 of #99: every shared example runs and matches; nothing is skipped any more.
    @Test func checkExamplesRunsEverySharedExample() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: repoRoot.appendingPathComponent("shared/examples"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "README.md" }
        let all = try sim(["check-examples", "shared/examples"])
        #expect(all == SimRun(status: 0, stdout: "\(files.count)/\(files.count) examples match\n", stderr: ""))

        let matchOnly = try sim(["check-examples", "shared/examples", "--only", "match"])
        #expect(matchOnly.status == 0)
        #expect(!matchOnly.stdout.contains("skipped"), "\(matchOnly.stdout)")
        let uit = files.filter { $0.lastPathComponent.hasPrefix("match-") && $0.lastPathComponent.contains("-uit") }
        #expect(uit.count >= 6, "the uit and terug examples are in the folder")
        // Leaving out uit and terug leaves fewer match examples, all matching.
        let filtered = try sim(["check-examples", "shared/examples", "--only", "match", "--without", "uit,terug"])
        #expect(filtered.status == 0)
        func count(_ run: SimRun) -> Int { Int(run.stdout.split(separator: "/")[0])! }
        #expect(count(filtered) > 0 && count(filtered) + uit.count <= count(matchOnly))
        #expect(filtered.stdout.split(separator: "\n").count == 1, "\(filtered.stdout)")
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
