import Foundation
import Testing
@testable import VervangingCore

// Ported from the uit and terug parts of public/js/match.test.js (plan decisions #11 and #21, and the owner's
// decision on #9 of 22 Nov 2026: a player marked uit on court is replaced at once). The shared examples check the
// exact output through `vervanging-sim check-examples`; the last test pins match.js's grids for the replan, the repair
// and the fixed next block.

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

private func refused(_ message: String, _ action: () throws -> MatchState) {
    #expect(throws: MatchError(message)) { try action() }
}

private func pairs(_ state: MatchState) -> [[Int]] { state.replaced.map { [$0.starter, $0.replacement] } }

@Suite struct MatchUitTests {
    @Test(arguments: [2, 9])
    func uitTheOthersEndAtMostOneBlockApart(at: Int) throws {
        let start = try times(MatchState.start(try planFor("equal")), at - 1)
        let player = start.onCourt[0]
        let out = try start.uit(player)
        #expect(out.block == at, "uit does not move to the next block")
        #expect(Array(out.grid.prefix(at)) == Array(start.grid.prefix(at)), "played blocks and the current block stay")
        #expect(out.grid[at...].allSatisfy { !$0.contains(player) })
        #expect(Planner.maxSubsFrom(out.grid, fromChange: at - 1) <= 3)
        let minutes = try times(out, 12).minutesSoFar
        let others = minutes.filter { $0.key != player }.map(\.value)
        #expect(others.max()! - others.min()! <= 200, "\(others)")
        #expect(minutes[player] == Planner.blockCounts(Array(start.grid.prefix(at)), players: start.players)[player]!
            * 200)
    }

    @Test func terugThePlayerIsBackFromTheNextBlockOnAndCatchesUp() throws {
        let start = try times(MatchState.start(try planFor("equal")), 2) // block 3
        let player = start.onCourt[0]
        let out = try times(try start.uit(player), 3) // block 6
        let back = try out.terug(player)
        #expect(back.out == [])
        #expect(back.grid[6...].contains { $0.contains(player) }, "plays again in a later block")
        #expect(Planner.maxSubsFrom(back.grid, fromChange: 5) <= 3)
        let minutes = Array(try times(back, 12).minutesSoFar.values)
        #expect(minutes.max()! - minutes.min()! <= 400, "\(minutes)")
    }

    @Test func uitAndTerugAreRefusedWhereTheyCannotApply() throws {
        let six = MatchState.start(try planFor("equal", 6))
        refused("at least 5 players must be available") { try six.uit(1).uit(2) }
        let state = MatchState.start(try planFor("equal"))
        refused("player 1 is already out") { try state.uit(1).uit(1) }
        refused("player 1 is not out") { try state.terug(1) }
        refused("player 13 is not in this match") { try state.uit(13) }
        let ended = try times(state, 12)
        refused("the match has ended") { try ended.uit(1) }
        refused("the match has ended") { try ended.terug(1) }
        let last = try times(state.uit(1), 11)
        refused("no block left: this is the last block") { try last.terug(1) }
    }

    @Test func undoPutsBackExactlyOneStepAfterUitAndTerug() throws {
        let base = try MatchState.start(try planFor("equal")).wissel()
        let player = base.onCourt[0]
        let out = try base.uit(player)
        var expected = base
        expected.previous = nil
        #expect(out.undo() == expected)
        let back = try out.terug(player)
        let undone = back.undo()
        #expect(undone.out == out.out)
        #expect(undone.grid == out.grid)
        #expect(undone.replaced == out.replaced)
        #expect(undone.canUndo == false, "one step only")
    }

    @Test func applyingRunsUitAndTerug() throws {
        let state = try MatchState.start(try planFor("equal")).wissel()
        #expect(try state.applying(.uit(1)) == (try state.uit(1)))
        let out = try state.uit(1)
        #expect(try out.applying(.terug(1)) == (try out.terug(1)))
    }

    @Test func savedStatesAfterUitRoundTripAndRestore() throws {
        let plan = try planFor("equal")
        let atTwo = try MatchState.start(plan, setupSavedAt: "s").wissel()
        let zone = try atTwo.wissel(keep: dueOff(atTwo)[0])
        let out = try zone.uit(zone.onCourt[0])
        #expect(MatchState.restored(try roundTrip(out), plan: plan, setupSavedAt: "s") == out)
        // Damaged: someone who is out plays later; history whose played blocks differ.
        var bad = try json(out)
        var grid = bad["grid"] as! [[Int]]
        grid[11] = Array((out.out + grid[11].filter { !out.out.contains($0) }).prefix(5))
        bad["grid"] = grid
        #expect(restore(bad, plan, "s") == nil)
        var history = try json(out)
        var previous = history["previous"] as! [String: Any]
        var previousGrid = previous["grid"] as! [[Int]]
        previousGrid[0] = [1, 2, 3, 4, 6]
        previous["grid"] = previousGrid
        history["previous"] = previous
        #expect(restore(history, plan, "s") == nil)
    }

    @Test(arguments: ["equal", "five"])
    func uitIsNeverRefusedForPlanningReasons(schedule: String) throws {
        // One or two players out at any block, any count from 8 to 12.
        for n in 8...12 {
            for seed in [1, 2, 3, 10] {
                let plan = try planFor(schedule, n, seed: seed)
                for at in 1...plan.blocks {
                    let state = try times(MatchState.start(plan), at - 1).uit(1).uit(6)
                    #expect(Planner.maxSubsFrom(state.livePlan, fromChange: at - 1) <= 3,
                            "\(schedule) \(n) seed \(seed) block \(at)")
                    #expect(state.livePlan[(at - 1)...].allSatisfy { !$0.contains(1) && !$0.contains(6) })
                }
            }
        }
    }

    // ---------- review of PR #19: mixed actions ----------

    @Test func aPlayerMarkedUitCannotBeKeptOnInTheZone() throws {
        let out = try MatchState.start(try planFor("equal")).uit(1)
        #expect(!out.onCourt.contains(1), "the out player left at once")
        #expect(!dueOff(out).contains(1), "so is not due off either")
        refused("player 1 is out and cannot stay on") { try out.wissel(keep: 1) }
    }

    @Test func fourPlayersUitAtOnceEachIsReplacedAndTheSubRuleHolds() throws {
        var state = MatchState.start(try planFor("equal"))
        for p in [1, 2, 3, 4] { state = try state.uit(p) }
        #expect(state.onCourt.allSatisfy { ![1, 2, 3, 4].contains($0) }, "replacements on court at once")
        #expect(state.replaced.count == 4)
        #expect(state.livePlan.allSatisfy { court in [1, 2, 3, 4].allSatisfy { !court.contains($0) } })
        #expect(Match.capHolds(state.livePlan, fromChange: 0, out: state.out))
        #expect(state.minutesSoFar.filter { $0.value > 0 }.keys.sorted() == [1, 2, 3, 4, 5],
                "the block counts for the starters, not the replacements")
    }

    @Test func damagedPlansAndUndoSnapshotsWithPlayersOutAreRefused() throws {
        let plan = try planFor("equal")
        var fiveSubs = try json(MatchState.start(plan, setupSavedAt: "s"))
        var grid = fiveSubs["grid"] as! [[Int]]
        grid[1] = [6, 7, 8, 9, 10]
        fiveSubs["grid"] = grid
        #expect(restore(fiveSubs, plan, "s") == nil, "a five-sub change with nobody out")
        var badHistory = try json(try MatchState.start(plan, setupSavedAt: "s").wissel())
        var previous = badHistory["previous"] as! [String: Any]
        previous["out"] = [1]
        badHistory["previous"] = previous
        #expect(restore(badHistory, plan, "s") == nil, "undo would bring back an out player still planned")
    }

    @Test func randomMixedSequencesKeepTheSubRuleOneStepUndoAndSaveAndRestore() throws {
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
                        do {
                            let keepable = state.nextChange?.off.filter { !state.out.contains($0) } ?? []
                            if x < 0.2 && !keepable.isEmpty {
                                state = try state.wissel(keep: keepable[0])
                            } else if x < 0.35 {
                                let pool = state.available
                                state = try state.uit(pool[Int(random.next() * Double(pool.count))])
                            } else if x < 0.45 && !state.out.isEmpty {
                                state = try state.terug(state.out[Int(random.next() * Double(state.out.count))])
                            } else if x < 0.5 {
                                state = state.undo()
                            } else {
                                state = try state.wissel()
                            }
                        } catch let error as MatchError {
                            let expected = ["last block", "at least 5", "no change left", "the match has ended",
                                            "no player is left"]
                            #expect(expected.contains { error.message.contains($0) }, "\(error.message)")
                            state = try state.wissel()
                        }
                        cases += 1
                        let label = "\(schedule) \(n) seed \(seed) block \(state.block)"
                        #expect(Match.capHolds(state.livePlan, fromChange: state.block - 1, out: state.out), "\(label)")
                        if !state.ended {
                            #expect(state.livePlan[(state.block - 1)...].allSatisfy { court in
                                court.allSatisfy { !state.out.contains($0) }
                            }, "\(label)")
                        }
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

    // ---------- uit during a block: immediate replacement (owner's decision on #9) ----------

    @Test func uitOnCourtAPlayerDueOnComesOnAtOnceAndTheBlockCountsForTheStarter() throws {
        let plan = try planFor("equal") // block 1 [1,2,3,4,5], block 2 [1,3,4,6,9]
        #expect(Array(plan.grid.prefix(2)) == [[1, 2, 3, 4, 5], [1, 3, 4, 6, 9]])
        let state = try MatchState.start(plan).uit(2)
        #expect(state.block == 1)
        #expect(state.onCourt == [1, 3, 4, 5, 6], "the fewest-minutes player due on (6 before 9 on a tie)")
        #expect(pairs(state) == [[2, 6]])
        #expect(state.minutesSoFar[2] == 200)
        #expect(state.minutesSoFar[6] == 0, "the replacement gets nothing for this block")
        #expect(!state.nextChange!.on.contains(6), "6 is on already, so the next wissel has one change less")
        let next = try state.wissel()
        #expect(next.replaced == [], "replacements end with the block")
        #expect(next.onCourt.contains(6))
    }

    @Test func uitOnCourtInTheLastBlockTheBenchPlayerWithTheFewestMinutesComesOn() throws {
        let state = try times(MatchState.start(try planFor("equal")), 11) // block 12
        let player = state.onCourt[0]
        let out = try state.uit(player)
        #expect(out.replaced.count == 1)
        let pair = out.replaced[0]
        #expect(pair.starter == player)
        let minutes = state.minutesSoFar
        let bench = state.players.filter { !state.onCourt.contains($0) }
        let fewest = bench.map { minutes[$0]! }.min()!
        #expect(pair.replacement == bench.filter { minutes[$0] == fewest }.min())
        #expect(out.grid == state.grid, "nothing left to recalculate")
        #expect(try out.wissel().minutesSoFar[player] == state.minutesSoFar[player])
    }

    @Test func uitRecalculatesOnlyWhenThePlayerWasPlannedLater() throws {
        let plan = try planFor("equal")
        var state = MatchState.start(plan)
        var checked = false
        for b in 1..<plan.blocks {
            let later = state.grid[b...]
            if let lone = state.onCourt.first(where: { p in later.allSatisfy { !$0.contains(p) } }) {
                #expect(try state.uit(lone).grid == state.grid, "no recalculation")
                checked = true
                break
            }
            state = try state.wissel()
        }
        #expect(checked, "a block with an on-court player not planned again")
    }

    @Test func aReplacementWhoGoesUitTooIsReplacedInTurn() throws {
        let s1 = try MatchState.start(try planFor("equal")).uit(2)
        let s2 = try s1.uit(6)
        #expect(!s2.onCourt.contains(2) && !s2.onCourt.contains(6))
        #expect(s2.replaced.count == 1, "still one starter replaced")
        #expect(s2.undo().replaced == s1.replaced)
        #expect(MatchState.restored(try roundTrip(s2), plan: try planFor("equal")) == s2)
    }

    @Test func damagedReplacementPairsAreRefusedOnLoad() throws {
        let plan = try planFor("equal")
        let good = try json(try MatchState.start(plan, setupSavedAt: "s").uit(2))
        #expect(restore(good, plan, "s") != nil)
        let damaged: [Any] = [[[2, 3]], [[7, 6]], [[2, 6], [2, 9]], [[2, 2]], "x", [[2]]]
        for replaced in damaged {
            var copy = good
            copy["replaced"] = replaced
            #expect(restore(copy, plan, "s") == nil, "\(replaced)")
        }
        var ended = try json(try times(MatchState.start(plan, setupSavedAt: "s"), 12))
        ended["replaced"] = [[1, 6]]
        #expect(restore(ended, plan, "s") == nil, "after the end: pairs of the last block only (1 did not start it)")
    }

    @Test func aStarterWhoLeftAndCameBackWithTerugIsNotPickedAsAReplacementInThatBlock() throws {
        let plan = try planFor("equal", 8)
        var state = MatchState.start(plan, setupSavedAt: "s")
        for action: MatchAction in [.wissel(), .wissel(), .uit(6), .terug(6), .uit(3)] {
            state = try state.applying(action)
        }
        let row = state.grid[state.block - 1]
        #expect(state.replaced.allSatisfy { !row.contains($0.replacement) }, "no starter of this block comes back on")
        #expect(Set(state.onCourt).count == 5)
        #expect(MatchState.restored(try roundTrip(state), plan: plan, setupSavedAt: "s") == state, "the state reloads")
        let next = try state.wissel()
        #expect(MatchState.restored(try roundTrip(next), plan: plan, setupSavedAt: "s") == next,
                "and so does the next block, with its undo snapshot")
        #expect(MatchState.restored(try roundTrip(next.undo()), plan: plan, setupSavedAt: "s") == next.undo())
    }

    @Test func uitInTheLastBlockTheReplacementIsStillOnCourtAfterEindeMatch() throws {
        let plan = try planFor("equal")
        let last = try times(MatchState.start(plan), 11)
        let out = try last.uit(last.onCourt[0])
        let ended = try out.wissel()
        #expect(ended.ended)
        #expect(ended.onCourt == out.onCourt, "the line-up that finished the match")
        #expect(MatchState.restored(try roundTrip(ended), plan: plan) == ended)
        #expect(ended.minutesSoFar == (try last.wissel()).minutesSoFar,
                "minutes unchanged: the block counts for the starter")
    }

    @Test func minutesOverviewAfterUitMarksTheReplacementOnCourtAndThePlayerOut() throws {
        let out = try MatchState.start(try planFor("equal")).uit(1)
        let overview = out.minutesOverview
        #expect(overview.map(\.player) == out.players)
        for e in overview {
            #expect(e.seconds == out.minutesSoFar[e.player])
            #expect(e.onCourt == out.onCourt.contains(e.player))
            #expect(e.out == out.out.contains(e.player))
        }
        #expect(overview.filter(\.onCourt).count == 5)
        #expect(overview[0] == MinutesEntry(player: 1, seconds: 200, onCourt: false, out: true))
    }

    // The exact states after uit and terug, as public/js/match.js gives them (printed by Node), so a drift in the
    // replacement, the fixed next block, the targets, the replan or the repair shows here and not only in the sim.
    @Test func uitAndTerugGiveTheJavaScriptGrids() throws {
        // The replacement comes from the next block, which held the uit player: 4, due off, stays on in their place.
        let stay = try MatchState.start(try planFor("equal", 8, seed: 1)).uit(1)
        #expect(stay.grid[1] == [2, 3, 4, 7, 8] && pairs(stay) == [[1, 7]])
        #expect(stay.grid == expectedStayGrid)
        // uit for a bench player: no replacement, the blocks from the next one on are re-spread.
        let bench = try MatchState.start(try planFor("equal", 12, seed: 3)).uit(12)
        #expect(bench.grid == expectedBenchGrid && bench.replaced == [] && bench.out == [12])
        // terug from the next block on.
        let terug = try times(try times(MatchState.start(try planFor("five", 10, seed: 3)), 1).uit(3), 1).terug(3)
        #expect(terug.grid == expectedTerugGrid && terug.out == [])
        // Late, with players out: no plan meets the targets, so the repair runs.
        let late = try times(MatchState.start(try planFor("equal", 11, seed: 3)), 9)
        let repaired = try late.uit(1).uit(2).terug(1)
        #expect(repaired.grid == expectedRepairGrid && repaired.out == [2])
    }
}

private let expectedStayGrid = [[1, 2, 3, 4, 5], [2, 3, 4, 7, 8], [4, 5, 6, 7, 8], [2, 3, 5, 6, 8], [2, 3, 4, 6, 7],
                                [3, 4, 5, 7, 8], [2, 4, 5, 6, 8], [2, 3, 5, 6, 7], [3, 4, 6, 7, 8], [2, 4, 5, 7, 8],
                                [2, 3, 4, 5, 6], [2, 3, 6, 7, 8]]
private let expectedBenchGrid = [[1, 2, 3, 4, 5], [1, 4, 5, 8, 10], [4, 7, 8, 10, 11], [6, 7, 9, 10, 11],
                                 [2, 3, 6, 7, 9], [1, 2, 3, 5, 9], [1, 3, 4, 5, 8], [4, 5, 8, 10, 11],
                                 [4, 6, 7, 10, 11], [2, 6, 7, 9, 11], [1, 2, 3, 6, 9], [1, 2, 3, 5, 8]]
private let expectedTerugGrid = [[1, 2, 3, 4, 5], [1, 3, 4, 6, 8], [1, 6, 8, 9, 10], [5, 6, 7, 9, 10],
                                 [2, 3, 5, 7, 10], [2, 3, 4, 5, 8], [1, 4, 7, 8, 9], [2, 6, 7, 9, 10]]
private let expectedRepairGrid = [[1, 2, 3, 4, 5], [2, 4, 5, 7, 11], [4, 6, 7, 9, 11], [6, 8, 9, 10, 11],
                                  [1, 3, 8, 9, 10], [1, 2, 3, 7, 8], [2, 3, 4, 5, 7], [4, 5, 6, 7, 11],
                                  [3, 5, 6, 10, 11], [6, 8, 9, 10, 11], [4, 7, 8, 9, 10], [3, 5, 6, 8, 9]]
