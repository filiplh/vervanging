import Foundation
import Testing
@testable import VervangingCore

// Ported from the wissel, undo, in the zone, Extra minuten, save and restore and minutes parts of
// public/js/match.test.js (plan decisions #8, #9, #12, #17, #18, #24, #25, #27). The uit and terug parts come with
// #99. The shared examples check the exact output through `vervanging-sim check-examples`.

private func range(_ n: Int) -> [Int] { Array(1...n) }

private func planFor(_ schedule: String, _ n: Int = 12, seed: Int = 1) throws -> Plan {
    try Planner.makePlan(players: range(n), start: [1, 2, 3, 4, 5], schedule: schedule, seed: seed)
}

private func times(_ state: MatchState, _ n: Int) throws -> MatchState {
    var s = state
    for _ in 0..<n { s = try s.wissel() }
    return s
}

private func roundTrip(_ state: MatchState) throws -> MatchState {
    try JSONDecoder().decode(MatchState.self, from: JSONEncoder().encode(state))
}

private func json(_ state: MatchState) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
}

private func restore(_ object: [String: Any], _ plan: Plan, _ saved: String?) -> MatchState? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return MatchState.restored(json: data, plan: plan, setupSavedAt: saved)
}

private func dueOff(_ state: MatchState) -> [Int] { state.nextChange!.off }

private func totalsAtEnd(_ state: MatchState) throws -> Set<Int> {
    Set(try times(state, state.blocks).minutesSoFar.values)
}

private func clock(_ time: SubTime) -> String {
    switch time {
    case let .sub(seconds): "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    case .endQuarter: "endQuarter"
    case .endMatch: "endMatch"
    }
}

@Suite struct MatchTests {
    @Test func aNewMatchIsAtBlockOneWithTheBasisvijfOnCourtAndNothingToUndo() throws {
        let state = MatchState.start(try planFor("equal"), setupSavedAt: "saved-1")
        #expect(state.version == MatchState.currentVersion)
        #expect(state.version == 2)
        #expect(state.block == 1)
        #expect(state.ended == false)
        #expect(state.canUndo == false)
        #expect(state.setupSavedAt == "saved-1")
        #expect(state.onCourt == [1, 2, 3, 4, 5])
        #expect(state.minutesSoFar == [1: 200, 2: 200, 3: 200, 4: 200, 5: 200, 6: 0, 7: 0, 8: 0, 9: 0, 10: 0, 11: 0,
                                       12: 0])
    }

    @Test(arguments: [("equal", 12, 200, ["6:40", "3:20", "endQuarter"]), ("five", 8, 300, ["5:00", "endQuarter"])])
    func wisselThroughAWholeMatch(schedule: String, blocks: Int, blockSeconds: Int, clocks: [String]) throws {
        let plan = try planFor(schedule, 9)
        var state = MatchState.start(plan)
        var seen: [String] = []
        for b in 1...blocks {
            #expect(state.block == b)
            #expect(state.ended == false)
            #expect(state.onCourt == plan.grid[b - 1])
            #expect(state.quarter == (b + plan.blocksPerQuarter - 1) / plan.blocksPerQuarter)
            seen.append(clock(state.subTime))
            // Minutes so far: the blocks started, the current one included.
            var sofar = plan
            sofar.grid = Array(plan.grid.prefix(b))
            #expect(state.minutesSoFar == Planner.planStats(sofar).minutes)
            if b < blocks {
                #expect(state.nextChange == NextChange(off: plan.grid[b - 1].filter { !plan.grid[b].contains($0) },
                                                       on: plan.grid[b].filter { !plan.grid[b - 1].contains($0) }))
            } else {
                #expect(state.nextChange == nil)
            }
            state = try state.wissel()
            #expect(state.canUndo)
        }
        #expect(state.ended)
        #expect(state.block == blocks)
        // Each quarter repeats the pattern; the very last block says einde match.
        var expected = Array(repeating: clocks, count: blocks / plan.blocksPerQuarter).flatMap { $0 }
        expected[expected.count - 1] = "endMatch"
        #expect(seen == expected)
        #expect(state.minutesSoFar == Planner.planStats(plan).minutes)
        #expect(state.minutesSoFar.values.reduce(0, +) == 5 * blocks * blockSeconds)
        // A wissel after the end changes nothing.
        #expect(try state.wissel() == state)
    }

    @Test func undoAfterAWisselGoesBackOneBlockOneStepOnly() throws {
        let start = MatchState.start(try planFor("equal"))
        let back = try times(start, 2).undo()
        #expect(back.block == 2)
        #expect(back.ended == false)
        #expect(back.canUndo == false)
        #expect(back.undo() == back, "a second undo changes nothing")
        #expect(back.minutesSoFar == (try times(start, 1)).minutesSoFar)
        #expect(try back.wissel().block == 3, "play goes on after an undo")
    }

    @Test func undoAfterTheMatchEndedReopensTheLastBlock() throws {
        let done = try times(MatchState.start(try planFor("five")), 8)
        #expect(done.ended)
        let back = done.undo()
        #expect(back.ended == false)
        #expect(back.block == 8)
        #expect(back.subTime == .endMatch)
        #expect(try back.wissel().ended)
    }

    @Test func undoWithNothingToUndoChangesNothing() throws {
        let state = MatchState.start(try planFor("equal"))
        #expect(state.undo() == state)
        #expect(state.undo().block == 1)
        #expect(state.undo().onCourt == [1, 2, 3, 4, 5])
    }

    @Test func applyingRunsWisselAndUndo() throws {
        let state = MatchState.start(try planFor("equal"))
        #expect(try state.applying(.wissel()).block == 2)
        #expect(try state.applying(.wissel()).applying(.undo).block == 1)
        let atTwo = try state.wissel()
        let keep = dueOff(atTwo)[0]
        #expect(try atTwo.applying(.wissel(keep: keep)) == (try atTwo.wissel(keep: keep)))
    }

    @Test func theStateIsJSONAndComesBackExactlyAtAnyBlock() throws {
        let plan = try planFor("equal")
        var state = MatchState.start(plan, setupSavedAt: "saved-1")
        for _ in 0...12 {
            let copy = try roundTrip(state)
            #expect(copy == state)
            let restored = MatchState.restored(json: try JSONEncoder().encode(state), plan: plan,
                                               setupSavedAt: "saved-1")
            #expect(restored == state)
            #expect(restored?.minutesSoFar == state.minutesSoFar)
            state = try state.wissel()
        }
        // After an undo, the restored state cannot undo again either.
        let undone = try times(MatchState.start(plan, setupSavedAt: "saved-1"), 4).undo()
        #expect(MatchState.restored(try roundTrip(undone), plan: plan, setupSavedAt: "saved-1") == undone)
    }

    @Test func theStoredJSONHasTheWebAppsFieldsWithNullForEmpty() throws {
        let object = try json(MatchState.start(try planFor("equal")))
        #expect(Set(object.keys) == ["version", "setupSavedAt", "schedule", "blocks", "blockSeconds",
                                     "blocksPerQuarter", "players", "base", "grid", "out", "replaced", "extra", "block",
                                     "ended", "previous"])
        #expect(object["setupSavedAt"] is NSNull)
        #expect(object["previous"] is NSNull)
        #expect(object["version"] as? Int == 2)
        var withPair = MatchState.start(try planFor("equal"))
        withPair.replaced = [Replacement(starter: 1, replacement: 6)]
        #expect(try json(withPair)["replaced"] as? [[Int]] == [[1, 6]])
        #expect(try roundTrip(withPair).replaced == withPair.replaced)
    }

    @Test func restoringRefusesDamagedStatesAndStatesOfAnotherSetup() throws {
        let plan = try planFor("equal")
        let good = try json(try times(MatchState.start(plan, setupSavedAt: "saved-1"), 3))
        func with(_ key: String, _ value: Any) -> [String: Any] {
            var copy = good
            copy[key] = value
            return copy
        }
        let grid = good["grid"] as! [[Int]]
        let damaged: [[String: Any]] = [
            [:],
            with("version", 3),
            with("version", 1),
            with("setupSavedAt", "saved-2"),
            with("setupSavedAt", NSNull()),
            with("schedule", "five"),
            with("blockSeconds", 300),
            with("grid", Array(grid.dropFirst())),
            with("grid", [[1, 2, 3, 4, 6]] + grid.dropFirst()),
            with("players", [1, 2, 3]),
            with("block", 0),
            with("block", 13),
            with("block", 2.5),
            with("block", "3"),
            with("ended", "no"),
            with("ended", true), // ended before the last block
            with("previous", ["block": 99, "ended": false]),
            with("previous", "x"),
            good.filter { $0.key != "previous" }, // the field must be there, as null when empty
        ]
        for raw in damaged { #expect(restore(raw, plan, "saved-1") == nil, "\(raw.keys.sorted())") }
        for bytes in ["null", "7", "\"x\"", "[]", "{", ""] {
            #expect(MatchState.restored(json: Data(bytes.utf8), plan: plan, setupSavedAt: "saved-1") == nil, "\(bytes)")
        }
        #expect(restore(good, try planFor("equal", 12, seed: 2), "saved-1") == nil, "another plan")
        #expect(restore(with("previous", NSNull()), plan, "saved-1")?.previous == nil)

        // History that would make undo jump: forward, skipped, an ended point before the last block. (match.test.js
        // also refuses history at the current block and at block 1, but only because those entries have no grid: an
        // uit or terug leaves history at the same block, so with a grid they restore, here as in match.js.)
        let fourAt = try times(MatchState.start(plan, setupSavedAt: "saved-1"), 3)
        func previous(_ state: MatchState, block: Int, ended: Bool) throws -> [String: Any] {
            var copy = state
            copy.previous = MatchSnapshot(block: block, ended: ended, grid: state.grid, out: [], replaced: [], extra: [])
            return try json(copy)
        }
        for (block, ended) in [(10, false), (1, false), (3, true)] {
            #expect(restore(try previous(fourAt, block: block, ended: ended), plan, "saved-1") == nil, "\(block)")
        }
        #expect(restore(try previous(fourAt, block: 3, ended: false), plan, "saved-1") != nil, "the real history")
        let first = MatchState.start(plan, setupSavedAt: "saved-1")
        #expect(restore(try previous(first, block: 1, ended: false), plan, "saved-1") != nil)
        #expect(restore(try previous(fourAt, block: 4, ended: false), plan, "saved-1") != nil)
        #expect(restore(try previous(first, block: 2, ended: false), plan, "saved-1") == nil, "history ahead")

        // An ended match: its history must be the active last block, never an ended point or another block.
        let done = try times(MatchState.start(plan, setupSavedAt: "saved-1"), 12)
        #expect(MatchState.restored(try roundTrip(done), plan: plan, setupSavedAt: "saved-1") == done)
        for (block, ended) in [(12, true), (11, false), (5, false)] {
            #expect(restore(try previous(done, block: block, ended: ended), plan, "saved-1") == nil, "\(block)")
        }
        // The JS reviewer's reproduction: block 3 (two wissels) with previous block 10 must not restore.
        let two = try times(MatchState.start(plan, setupSavedAt: "saved-1"), 2)
        #expect(MatchState.restored(two, plan: plan, setupSavedAt: "saved-1") == two)
        #expect(restore(try previous(two, block: 10, ended: false), plan, "saved-1") == nil)
    }

    // ---------- in the zone (#9) ----------

    @Test(arguments: 1...5)
    func inTheZoneTheKeptPlayerStaysOnTheBenchedPlayerStaysOffAndTheBlockComesBack(seed: Int) throws {
        let plan = try planFor("equal", 12, seed: seed)
        let atTwo = try MatchState.start(plan).wissel() // block 2
        for keep in dueOff(atTwo) {
            let bench = atTwo.proposedBench!
            let next = try atTwo.wissel(keep: keep)
            #expect(next.onCourt.contains(keep), "the zone player is on court in the next block")
            #expect(!next.onCourt.contains(bench), "the proposed incoming player stays on the bench")
            #expect(Planner.maxSubsFrom(next.grid) <= 3, "never more than 3 subs per change")
            #expect(try totalsAtEnd(next) == [1000], "seed \(seed), keep \(keep): equal at the end")
            #expect(Array(next.grid.prefix(2)) == Array(atTwo.grid.prefix(2)), "blocks already played do not change")
        }
    }

    @Test func inTheZoneTheProposalIsTheIncomingPlayerWithTheMostMinutesTiesToTheLowestNumber() throws {
        let state = try times(MatchState.start(try planFor("equal")), 3) // block 4
        let minutes = state.minutesSoFar
        let on = state.nextChange!.on
        let best = on.map { minutes[$0]! }.max()!
        #expect(state.proposedBench == on.filter { minutes[$0] == best }.min())
    }

    @Test func inTheZoneWithAChosenBenchPlayer() throws {
        let state = try MatchState.start(try planFor("equal")).wissel()
        let change = state.nextChange!
        let bench = change.on.first { $0 != state.proposedBench }!
        let next = try state.wissel(keep: change.off[0], bench: bench)
        #expect(next.onCourt.contains(change.off[0]))
        #expect(!next.onCourt.contains(bench))
        #expect(try totalsAtEnd(next) == [1000])
    }

    @Test func inTheZoneAtTheLastChangeNoBlockLeftSoTheDifferenceStays() throws {
        let state = try times(MatchState.start(try planFor("equal")), 10) // block 11
        let keep = dueOff(state)[0]
        let bench = state.proposedBench!
        let minutes = try state.wissel(keep: keep).wissel().minutesSoFar
        #expect(minutes[keep] == 1200)
        #expect(minutes[bench] == 800)
        #expect(minutes.values.filter { $0 == 1000 }.count == 10)
    }

    @Test func inTheZoneIsRefusedForAPlayerNotDueOffABenchPlayerNotDueOnAndAtTheLastBlock() throws {
        let state = try MatchState.start(try planFor("equal")).wissel()
        if let stays = state.onCourt.first(where: { !dueOff(state).contains($0) }) {
            #expect(throws: MatchError("player \(stays) is not due off at this change")) {
                try state.wissel(keep: stays)
            }
        }
        #expect(throws: MatchError("player \(state.onCourt[0]) is not due on at this change")) {
            try state.wissel(keep: dueOff(state)[0], bench: state.onCourt[0])
        }
        #expect(throws: MatchError("no change left: this is the last block")) {
            try times(MatchState.start(try planFor("equal")), 11).wissel(keep: 1)
        }
        // After the end, a wissel changes nothing, whatever it asks.
        let done = try times(MatchState.start(try planFor("equal")), 12)
        #expect(try done.wissel(keep: 99, extra: true) == done)
        // A player marked uit cannot be kept on (F1); uit itself comes with #99, so the state is set by hand here.
        var out = state
        out.out = [dueOff(state)[0]]
        #expect(throws: MatchError("player \(dueOff(state)[0]) is out and cannot stay on")) {
            try out.wissel(keep: dueOff(state)[0])
        }
    }

    @Test func undoPutsBackExactlyOneStepAfterInTheZone() throws {
        let base = try MatchState.start(try planFor("equal")).wissel()
        let zone = try base.wissel(keep: dueOff(base)[0])
        var undone = zone.undo(), expected = base
        undone.previous = nil
        expected.previous = nil
        #expect(undone == expected)
        #expect(zone.undo().canUndo == false)
    }

    @Test func savedStatesAfterInTheZoneRoundTripAndRestore() throws {
        let plan = try planFor("equal")
        let atTwo = try MatchState.start(plan, setupSavedAt: "s").wissel()
        let zone = try atTwo.wissel(keep: dueOff(atTwo)[0])
        #expect(MatchState.restored(json: try JSONEncoder().encode(zone), plan: plan, setupSavedAt: "s") == zone)
        // Damaged: the first block changed in the history; someone out plays later.
        var history = zone
        history.previous!.grid[0] = [1, 2, 3, 4, 6]
        #expect(MatchState.restored(history, plan: plan, setupSavedAt: "s") == nil)
        var bad = zone
        bad.out = [bad.grid[11][0]]
        #expect(MatchState.restored(bad, plan: plan, setupSavedAt: "s") == nil)
    }

    @Test(arguments: ["equal", "five"])
    func inTheZoneAtTheSecondToLastChangeKeepsTheCapOfThree(schedule: String) throws {
        for n in 8...12 {
            for seed in 1...30 {
                let plan = try planFor(schedule, n, seed: seed)
                let state = try times(MatchState.start(plan), plan.blocks - 3) // into the second-to-last block
                for keep in state.nextChange!.off {
                    let next = try state.wissel(keep: keep)
                    #expect(Planner.maxSubsFrom(next.grid, fromChange: state.block - 1) <= 3,
                            "\(schedule) \(n) seed \(seed) keep \(keep)")
                }
            }
        }
    }

    @Test func randomSequencesKeepTheSubRuleOneStepUndoAndSaveAndRestore() throws {
        var cases = 0
        for schedule in ["equal", "five"] {
            for n in 8...12 {
                for seed in 1...25 {
                    let plan = try planFor(schedule, n, seed: seed)
                    var random = SeededRandom(seed: seed * 97 + n)
                    var state = MatchState.start(plan, setupSavedAt: "s")
                    while !state.ended {
                        let before = state
                        let x = random.next()
                        let keepable = state.nextChange?.off ?? []
                        if x < 0.2 && !keepable.isEmpty {
                            state = try state.wissel(keep: keepable[0], extra: random.next() < 0.3)
                        } else if x < 0.3 {
                            state = state.undo()
                        } else {
                            state = try state.wissel()
                        }
                        cases += 1
                        #expect(Match.capHolds(state.livePlan, fromChange: state.block - 1, out: state.out),
                                "\(schedule) \(n) seed \(seed) block \(state.block)")
                        let played = min(before.block, state.block) - 1
                        #expect(Array(state.grid.prefix(played)) == Array(before.grid.prefix(played)),
                                "played blocks never change")
                        #expect(MatchState.restored(try roundTrip(state), plan: plan, setupSavedAt: "s") == state,
                                "every state saves and restores")
                        if state.previous != nil { #expect(state.undo().canUndo == false) }
                    }
                }
            }
        }
        #expect(cases > 2000)
    }

    // ---------- Extra minuten (#31, decision #25) ----------

    @Test(arguments: ["equal", "five"])
    func extraMinutenTheKeptPlayerEndsOneBlockAboveThePlannedTotal(schedule: String) throws {
        for n in 8...12 {
            for seed in 1...3 {
                let plan = try planFor(schedule, n, seed: seed)
                let atTwo = try MatchState.start(plan).wissel()
                let planned = Planner.blockCounts(plan.grid, players: plan.players)
                for keep in atTwo.nextChange!.off {
                    let next = try atTwo.wissel(keep: keep, extra: true)
                    #expect(next.onCourt.contains(keep))
                    #expect(Match.capHolds(next.livePlan, fromChange: next.block - 1, out: next.out),
                            "\(schedule) \(n) seed \(seed) keep \(keep)")
                    let end = try times(next, plan.blocks)
                    let blocks = end.minutesSoFar.mapValues { $0 / plan.blockSeconds }
                    #expect(blocks[keep] == planned[keep]! + 1, "the reward is kept, not given back")
                    let others = blocks.filter { $0.key != keep }.map(\.value)
                    #expect(others.max()! - others.min()! <= 1, "\(others)")
                    #expect(end.extraSeconds[keep] == plan.blockSeconds)
                }
            }
        }
    }

    @Test func inTheZoneWithoutExtraStillGivesTheBlockBack() throws {
        let atTwo = try MatchState.start(try planFor("equal")).wissel()
        let keep = atTwo.nextChange!.off[0]
        #expect(try totalsAtEnd(try atTwo.wissel(keep: keep)) == [1000])
        #expect(try atTwo.wissel(keep: keep).extraSeconds.values.filter { $0 > 0 } == [])
    }

    @Test func extraMinutenAtTheLastChangeAndWithAChosenBenchPlayer() throws {
        let plan = try planFor("equal")
        let last = try times(MatchState.start(plan), 10)
        let keep = last.nextChange!.off[0]
        let end = try last.wissel(keep: keep, extra: true).wissel()
        #expect(end.minutesSoFar[keep] == 1200)
        #expect(end.extraSeconds[keep] == 200)
        let atTwo = try MatchState.start(plan).wissel()
        let change = atTwo.nextChange!
        let bench = change.on.first { $0 != atTwo.proposedBench }!
        #expect(!(try atTwo.wissel(keep: change.off[0], bench: bench, extra: true)).onCourt.contains(bench))
        #expect(throws: MatchError("extra minuten needs a player to keep on")) { try atTwo.wissel(extra: true) }
        // At the last block, a wissel without a player to keep ends the match, Extra minuten or not.
        #expect(try times(MatchState.start(plan), 11).wissel(extra: true).ended)
    }

    @Test func extraMinutenUndoTakesItBackAndTheStateSavesAndRestores() throws {
        let plan = try planFor("equal")
        let atTwo = try MatchState.start(plan, setupSavedAt: "s").wissel()
        let keep = atTwo.nextChange!.off[0]
        let next = try atTwo.wissel(keep: keep, extra: true)
        #expect(next.extra == [keep])
        #expect(next.undo().extra == [])
        #expect(MatchState.restored(try roundTrip(next), plan: plan, setupSavedAt: "s") == next)
        // A web state saved before Extra minuten has no list; it reads as none.
        var old = try json(atTwo)
        old["extra"] = nil
        var previous = old["previous"] as! [String: Any]
        previous["extra"] = nil
        old["previous"] = previous
        #expect(restore(old, plan, "s")?.extra == [])
        for extra: Any in ["x", [99], Array(repeating: keep, count: 12)] {
            var bad = try json(next)
            bad["extra"] = extra
            #expect(restore(bad, plan, "s") == nil, "\(extra)")
        }
        var twice = next
        twice.extra = [keep, keep]
        #expect(MatchState.restored(twice, plan: plan, setupSavedAt: "s") == nil, "one wissel adds at most one entry")
    }

    @Test func extraMinutenLateWithAChosenBenchPlayerTheRewardIsExactlyOneBlock() throws {
        // The JS review's reproduction (PR #37): 11 players, 5-minute schedule, seed 1, Extra minuten at the sixth
        // change, where only the repair fits.
        let plan = try planFor("five", 11, seed: 1)
        let planned = Planner.blockCounts(plan.grid, players: plan.players)
        var state = try times(MatchState.start(plan), 5)
        state = try state.wissel(keep: 1, bench: 9, extra: true)
        #expect(Match.capHolds(state.livePlan, fromChange: state.block - 1, out: state.out))
        let end = try times(state, plan.blocks)
        #expect(end.minutesSoFar[1] == (planned[1]! + 1) * plan.blockSeconds)
        #expect(end.extraSeconds[1] == plan.blockSeconds)
        // Every keep and bench pair at every change, 8 to 12 players: the kept player ends at planned + 1, never more.
        for schedule in ["equal", "five"] {
            for n in stride(from: 8, through: 12, by: 2) {
                let p = try planFor(schedule, n, seed: 3)
                let base = Planner.blockCounts(p.grid, players: p.players)
                var s = MatchState.start(p)
                for b in 1..<p.blocks {
                    let change = s.nextChange!
                    for keep in change.off {
                        for bench in change.on {
                            let done = try times(try s.wissel(keep: keep, bench: bench, extra: true), p.blocks)
                            #expect(done.minutesSoFar[keep]! / p.blockSeconds == base[keep]! + 1,
                                    "\(schedule) \(n) block \(b) keep \(keep) bench \(bench)")
                        }
                    }
                    s = try s.wissel()
                }
            }
        }
    }

    @Test(arguments: ["equal", "five"])
    func minutesOverviewListsEveryPlayerInOrderWithSecondsOnCourtAndOut(schedule: String) throws {
        func check(_ state: MatchState, _ label: String) {
            let overview = state.minutesOverview
            #expect(overview.map(\.player) == state.players, "\(label): player order")
            let minutes = state.minutesSoFar
            let court = state.onCourt
            for e in overview {
                #expect(e.seconds == minutes[e.player], "\(label): seconds of \(e.player)")
                #expect(e.onCourt == court.contains(e.player), "\(label): on court \(e.player)")
                #expect(e.out == state.out.contains(e.player), "\(label): out \(e.player)")
            }
            #expect(overview.filter(\.onCourt).count == 5, "\(label): five on court")
        }
        var state = MatchState.start(try planFor(schedule))
        for b in 1...state.blocks {
            check(state, "\(schedule) block \(b)")
            state = try state.wissel()
        }
        check(state, "\(schedule) ended")
        #expect(Array(MatchState.start(try planFor(schedule)).minutesOverview.prefix(2)) == [
            MinutesEntry(player: 1, seconds: schedule == "equal" ? 200 : 300, onCourt: true, out: false),
            MinutesEntry(player: 2, seconds: schedule == "equal" ? 200 : 300, onCourt: true, out: false),
        ])
    }

    // The exact grids after in the zone and Extra minuten, as public/js/match.js gives them (printed by Node), so a
    // drift in the swap-back, the replan or the V8 shuffle shows here and not only in the sim examples.
    @Test func inTheZoneAndExtraMinutenGiveTheJavaScriptGrids() throws {
        let atTwo = try MatchState.start(try planFor("equal", 10, seed: 3)).wissel()
        #expect(try atTwo.wissel(keep: dueOff(atTwo)[0]).grid == expectedZoneGrid)
        let late = try times(MatchState.start(try planFor("five", 11, seed: 1)), 5)
        #expect(try late.wissel(keep: 1, bench: 9, extra: true).grid == expectedLateExtraGrid)
        // Extra minuten where the sorted order finds no plan and a shuffled one does: the second shuffle (spread 1),
        // and the fourth shuffle with the others up to two blocks apart (spread 2).
        let shuffled = try times(MatchState.start(try planFor("equal", 9, seed: 2)), 9)
        #expect(try shuffled.wissel(keep: 2, extra: true).grid == expectedShuffledExtraGrid)
        let spread = try times(MatchState.start(try planFor("five", 12, seed: 4)), 5)
        #expect(try spread.wissel(keep: 2, extra: true).grid == expectedSpreadExtraGrid)
    }
}

private let expectedZoneGrid = [[1, 2, 3, 4, 5], [1, 4, 5, 6, 7], [1, 4, 6, 7, 9], [2, 7, 8, 9, 10], [2, 3, 8, 9, 10],
                                [1, 3, 5, 6, 10], [3, 4, 5, 6, 8], [4, 6, 7, 8, 9], [1, 2, 4, 7, 9], [1, 2, 5, 7, 10],
                                [2, 3, 5, 8, 10], [3, 6, 8, 9, 10]]
private let expectedLateExtraGrid = [[1, 2, 3, 4, 5], [2, 3, 4, 9, 10], [4, 6, 9, 10, 11], [6, 7, 8, 10, 11],
                                     [1, 5, 6, 7, 8], [1, 2, 3, 5, 8], [1, 2, 3, 4, 11], [2, 3, 4, 7, 9]]
private let expectedShuffledExtraGrid = [[1, 2, 3, 4, 5], [1, 4, 5, 6, 9], [1, 6, 7, 8, 9], [2, 3, 6, 7, 8],
                                         [2, 3, 4, 5, 8], [1, 3, 4, 5, 9], [1, 5, 6, 7, 9], [2, 6, 7, 8, 9],
                                         [2, 3, 4, 6, 7], [1, 2, 3, 4, 8], [1, 2, 4, 8, 9], [3, 5, 7, 8, 9]]
private let expectedSpreadExtraGrid = [[1, 2, 3, 4, 5], [1, 3, 4, 8, 10], [6, 7, 8, 10, 12], [5, 6, 9, 11, 12],
                                       [1, 2, 7, 9, 11], [2, 3, 4, 7, 10], [2, 7, 8, 10, 12], [3, 5, 6, 8, 12]]
