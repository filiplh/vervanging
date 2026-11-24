import Foundation
import Testing
@testable import VervangingCore

// "Minuten tot nu" (#54), ported from minutesPlayed in public/js/live.js and the "minutes so far" tests in
// public/js/live.test.js: only finished blocks count, at every block; after the end every block counts; a starter
// taken uit keeps the block once it is played; an Extra minuten block counts once it is played.

private func start(_ schedule: String = "equal", _ n: Int = 12) throws -> MatchState {
    let plan = try Planner.makePlan(players: Array(1...n), start: [1, 2, 3, 4, 5], schedule: schedule, seed: 3)
    return MatchState.start(plan)
}

/// The seconds from the grid for the first `played` blocks, by player (`playedFrom` in live.test.js).
private func playedFrom(_ state: MatchState, _ played: Int) -> [Int: Int] {
    Dictionary(uniqueKeysWithValues: state.players.map { id in
        (id, state.grid.prefix(played).filter { $0.contains(id) }.count * state.blockSeconds)
    })
}

@Suite struct MinutesPlayedTests {
    @Test func atTipOffEveryoneHasNothing() throws {
        let state = try start()
        #expect(state.minutesPlayed == Dictionary(uniqueKeysWithValues: (1...12).map { ($0, 0) }))
        #expect(state.playedOverview.allSatisfy { $0.seconds == 0 })
        #expect(state.playedOverview.filter(\.onCourt).map(\.player) == state.onCourt)
    }

    @Test func onlyFinishedBlocksCountAtEveryBlock() throws {
        var state = try start()
        for block in 1...12 {
            #expect(state.block == block)
            #expect(state.minutesPlayed == playedFrom(state, block - 1), "block \(block)")
            #expect(state.playedOverview.map(\.seconds) == state.players.map { playedFrom(state, block - 1)[$0]! })
            state = try state.wissel()
        }
        #expect(state.ended)
    }

    @Test func aRunningBlockIsTheBlocksBeforeIt() throws {
        let state = try start().wissel().wissel().wissel()
        #expect(state.block == 4)
        #expect(state.minutesPlayed == playedFrom(state, 3))
        #expect(state.minutesPlayed.values.reduce(0, +) == 3 * 5 * 200)
        let court = state.onCourt
        for entry in state.playedOverview {
            #expect(entry.onCourt == court.contains(entry.player))
            #expect(!entry.out)
        }
    }

    @Test func afterTheEndEveryBlockCountsAndNobodyIsOnCourt() throws {
        var state = try start("five", 9)
        for _ in 0..<8 { state = try state.wissel() }
        #expect(state.ended)
        #expect(state.minutesPlayed == state.minutesSoFar)
        #expect(state.minutesPlayed == playedFrom(state, 8))
        #expect(state.playedOverview.allSatisfy { !$0.onCourt })
    }

    @Test func undoOfTheEndStopsCountingTheLastBlock() throws {
        var state = try start("five", 9)
        for _ in 0..<8 { state = try state.wissel() }
        let back = state.undo()
        #expect(back.block == 8)
        #expect(!back.ended)
        #expect(back.minutesPlayed == playedFrom(back, 7))
    }

    @Test func twelvePlayersEndAtSixteenFortyEach() throws {
        var state = try start()
        for _ in 0..<12 { state = try state.wissel() }
        #expect(Set(state.minutesPlayed.values) == [1000])
    }

    @Test func aStarterTakenUitKeepsTheBlockOnceItIsPlayed() throws {
        let state = try start()
        let starter = state.grid[0][0]
        let afterUit = try state.uit(starter)
        let replacement = try #require(afterUit.onCourt.first { !state.grid[0].contains($0) })
        #expect(afterUit.minutesPlayed[starter] == 0, "block 1 is not finished yet")
        #expect(afterUit.playedOverview.first { $0.player == starter }?.out == true)
        let next = try afterUit.wissel()
        #expect(next.minutesPlayed[starter] == 200, "the block counts for the starter")
        #expect(next.minutesPlayed[replacement] == 0, "the replacement is not credited for block 1")
    }

    @Test func anExtraMinutenBlockCountsOnceItIsPlayed() throws {
        let state = try start()
        let keep = state.grid[0].first { !state.grid[1].contains($0) }!
        let kept = try state.wissel(keep: keep, extra: true)
        #expect(kept.onCourt.contains(keep))
        #expect(kept.minutesPlayed[keep] == 200, "only block 1 is finished")
        #expect(try kept.wissel().minutesPlayed[keep] == 400, "the extra block counts after it is played")
    }
}
