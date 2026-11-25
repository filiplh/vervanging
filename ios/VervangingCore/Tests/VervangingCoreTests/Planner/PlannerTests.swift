import Testing
@testable import VervangingCore

// Ported from public/js/planner.test.js (plan decisions #6 schedules, #7 grid and swaps, #20 starting five, #21 and
// #22 the sub rule). The exact expected grids below are what public/js/planner.js gives for the same input, printed by
// Node; the shared examples check the rest through `vervanging-sim check-examples`.

private func range(_ n: Int) -> [Int] { Array(1...n) }

private func plan(_ n: Int, start: [Int] = [1, 2, 3, 4, 5], schedule: String = "equal", seed: Int = 1,
                  extraPriority: [Int] = [], moves: [[Int]] = []) throws -> Plan {
    try Planner.makePlan(players: range(n), start: start, schedule: schedule, seed: seed,
                         extraPriority: extraPriority, moves: moves)
}

private let starts = [[1, 2, 3, 4, 5], [3, 5, 7, 8, 2], [4, 5, 6, 7, 8]]
private let a3Cases: [(String, Int, [Int])] = ["equal", "five"].flatMap { schedule in
    (8...12).flatMap { n in starts.map { (schedule, n, $0) } }
}

@Suite struct PlannerTests {
    // Plan assumption A3: a plan that meets decision #21 exists for 8 to 12 players, both schedules, any starting five.
    @Test(arguments: a3Cases)
    func meetsTheSubRule(schedule: String, n: Int, start: [Int]) throws {
        let plan = try plan(n, start: start, schedule: schedule, seed: 7)
        let stats = Planner.planStats(plan)
        let shape = Planner.schedules[schedule]!

        #expect(plan.grid.count == shape.blocks)
        #expect(plan.grid[0] == start.sorted())
        for court in plan.grid { #expect(Set(court).count == 5) }

        let minutes = Array(stats.minutes.values)
        #expect(minutes.reduce(0, +) == 5 * shape.blocks * shape.blockSeconds)
        #expect(minutes.max()! - minutes.min()! <= shape.blockSeconds, "shares differ by at most one block")

        #expect(stats.subsPerChange.max()! <= 3, "never more than 3 subs per change")
        #expect(plan.sitLimitRelaxed == false, "no case from 8 to 12 players needs the sit limit relaxed")
        #expect(stats.longestBenchSeconds <= 900, "nobody sits more than 15:00 in a row")
        if schedule == "equal" && n == 12 {
            #expect(stats.subsPerChange.allSatisfy { $0 == 2 }, "equal minutes with 12 players: 2 subs at every change")
            #expect(minutes.allSatisfy { $0 == 1000 }, "equal minutes with 12 players: 16:40 each")
        }
    }

    @Test func fiveMinuteScheduleWithTwelveGivesFourPlayersAnExtraBlock() throws {
        let minutes = Array(Planner.planStats(try plan(12, schedule: "five", seed: 3)).minutes.values)
        #expect(minutes.filter { $0 == 1200 }.count == 4)
        #expect(minutes.filter { $0 == 900 }.count == 8)
    }

    @Test func theSameSeedGivesTheSamePlan() throws {
        #expect(try plan(11, schedule: "five", seed: 5).grid == plan(11, schedule: "five", seed: 5).grid)
    }

    @Test func extraBlocksGoToThePlayersInExtraPriorityFirst() {
        var random = SeededRandom(seed: 1)
        let targets = Planner.blockTargets(range(12), totalPlaces: 40, random: &random, extraPriority: [9, 10, 11, 12])
        #expect([9, 10, 11, 12].map { targets[$0]! } == [4, 4, 4, 4])
        #expect(targets.values.filter { $0 == 4 }.count == 4)
    }

    @Test func swappingTwoBenchPlayersExchangesTheirRowsAndKeepsTheTotals() throws {
        let original = try plan(12)
        let swapped = try Planner.swapPlayers(original, 6, 7)
        for (i, court) in original.grid.enumerated() {
            #expect(swapped.grid[i] == court.map { $0 == 6 ? 7 : $0 == 7 ? 6 : $0 }.sorted())
        }
        #expect(Planner.planStats(swapped).subsPerChange == Planner.planStats(original).subsPerChange)
    }

    @Test func aSwapBetweenAStarterAndABenchPlayerIsRefused() throws {
        let original = try plan(12)
        #expect(throws: PlanError.self) { try Planner.swapPlayers(original, 1, 6) }
        #expect(throws: PlanError.self) { try Planner.swapPlayers(original, 6, 6) }
        #expect(throws: PlanError.self) { try Planner.swapPlayers(original, 6, 13) }
    }

    @Test(arguments: [
        (12, [1, 2, 3, 4], "equal", "starting five"),
        (12, [1, 1, 2, 3, 4], "equal", "starting five"),
        (12, [1, 2, 3, 4, 13], "equal", "not present"),
        (4, [1, 2, 3, 4, 5], "equal", "at least 5"),
        (12, [1, 2, 3, 4, 5], "six", "unknown schedule"),
    ])
    func invalidInputIsRefusedWithAPlanError(n: Int, start: [Int], schedule: String, message: String) {
        let error = #expect(throws: PlanError.self) {
            try Planner.makePlan(players: range(n), start: start, schedule: schedule)
        }
        #expect(error?.message.contains(message) == true, "\(error?.message ?? "no error")")
    }

    @Test func exactlyFivePlayersPlayEveryBlock() throws {
        let stats = Planner.planStats(try plan(5))
        #expect(stats.minutes.values.allSatisfy { $0 == 2400 })
        #expect(stats.subsPerChange.allSatisfy { $0 == 0 })
    }

    // #169: 13 players in the 5-minute schedule can keep every sit at 15:00, every stint at 15:00 (the planner's stint
    // limit there: 3 blocks) and the cap of 3, with 3 subs at every change. The quick search ran out of nodes before
    // it found such a plan and relaxed the sit limit (25:00 sits); the exhaustive search finds it. extraPriority [6]
    // gives no starter an extra block, [1] gives one starter one.
    @Test(arguments: [[Int](), [6], [1]])
    func thirteenPlayersInTheFiveMinuteScheduleKeepTheSitLimit(extraPriority: [Int]) throws {
        for seed in 1...5 {
            let plan = try plan(13, schedule: "five", seed: seed, extraPriority: extraPriority)
            let stats = Planner.planStats(plan)
            #expect(plan.sitLimitRelaxed == false, "seed \(seed)")
            #expect(stats.longestBenchSeconds <= 900, "seed \(seed): nobody sits more than 15:00 in a row")
            #expect(stats.longestStintSeconds <= 900, "seed \(seed): nobody plays more than 15:00 in a row")
            #expect(stats.subsPerChange.max()! <= 3, "seed \(seed): never more than 3 subs per change")
            let minutes = Array(stats.minutes.values)
            #expect(minutes.max()! - minutes.min()! <= 300, "seed \(seed): shares differ by at most one block")
        }
    }

    // With 14 or 15 players in the 5-minute schedule no plan keeps 15:00 sits under the cap of 3 (an exact search
    // over every split of the extra blocks, #169): the exhaustive search says so, and the planner relaxes the sit
    // limit (never the cap) and says so.
    @Test(arguments: [14, 15])
    func fourteenOrFifteenPlayersInTheFiveMinuteScheduleRelaxTheSitLimitNotTheSubCap(n: Int) throws {
        for seed in 1...5 {
            let plan = try plan(n, schedule: "five", seed: seed)
            #expect(plan.sitLimitRelaxed == true, "seed \(seed)")
            #expect(Planner.planStats(plan).subsPerChange.max()! <= 3, "seed \(seed)")
        }
    }

    @Test func theExhaustiveFillGridFindsTheThirteenPlayerPlansTheQuickOneMissesAndNoneForFourteen() {
        func fill(_ n: Int, _ extraPriority: [Int], exhaustive: Bool) -> [[Int]]? {
            var random = SeededRandom(seed: 1)
            let targets = Planner.blockTargets(range(n), totalPlaces: 40, random: &random, extraPriority: extraPriority)
            return Planner.fillGrid(prefix: [[1, 2, 3, 4, 5]], players: range(n), targets: targets, blocks: 8,
                                    maxSit: 3, maxStint: 3, random: &random, exhaustive: exhaustive)
        }
        for extraPriority in [[6], [1]] {
            #expect(fill(13, extraPriority, exhaustive: false) == nil, "the quick search runs out of nodes")
            let grid = fill(13, extraPriority, exhaustive: true)
            #expect(grid != nil, "a plan for extraPriority \(extraPriority)")
            if let grid {
                let stats = Planner.planStats(Plan(schedule: "five", blocks: 8, blockSeconds: 300, blocksPerQuarter: 2,
                                                   players: range(13), start: [1, 2, 3, 4, 5], grid: grid,
                                                   sitLimitRelaxed: false))
                #expect(stats.longestBenchSeconds <= 900 && stats.longestStintSeconds <= 900)
                #expect(stats.subsPerChange == [3, 3, 3, 3, 3, 3, 3])
            }
        }
        #expect(fill(14, [], exhaustive: true) == nil)
    }

    @Test func evenTargetsGivesThePlacesLeftToTheFewestBlocksFirstNothingToPlayersWhoAreOut() throws {
        let plan = try plan(12)
        let available = range(12).filter { $0 != 1 }
        let targets = try Planner.evenTargets(grid: plan.grid, players: plan.players, available: available, fromBlock: 4)
        let played = Planner.blockCounts(Array(plan.grid.prefix(4)), players: plan.players)
        #expect(targets[1] == played[1], "an out player gets no more blocks")
        let others = available.map { targets[$0]! }
        #expect(others.max()! - others.min()! <= 1)
        #expect(targets.values.reduce(0, +) == 60)
    }

    @Test func replanRemainingKeepsTheFixedBlocksMeetsTheTargetsAndTheCapOfThree() throws {
        let plan = try plan(12, seed: 2)
        let available = range(12).filter { $0 != 3 }
        let targets = try Planner.evenTargets(grid: plan.grid, players: plan.players, available: available, fromBlock: 5)
        let grid = try Planner.replanRemaining(grid: plan.grid, players: plan.players, available: available,
                                               fromBlock: 5, targets: targets, blockSeconds: 200)
        #expect(Array(grid.prefix(5)) == Array(plan.grid.prefix(5)))
        #expect(Planner.blockCounts(grid, players: plan.players) == targets)
        #expect(grid.dropFirst(5).allSatisfy { !$0.contains(3) })
        #expect(Planner.maxSubsFrom(grid, fromChange: 4) <= 3)
        #expect(throws: PlanError.self) {
            try Planner.replanRemaining(grid: plan.grid, players: plan.players, available: [1, 2, 3, 4], fromBlock: 5,
                                        targets: targets, blockSeconds: 200)
        }
    }

    @Test func repairRemainingHoldsTheCapAndDropsPlayersWhoAreNotAvailable() throws {
        let plan = try plan(12, seed: 4)
        let available = range(12).filter { $0 != 2 && $0 != 7 }
        let grid = try Planner.repairRemaining(grid: plan.grid, players: plan.players, available: available, fromBlock: 3)
        #expect(Array(grid.prefix(3)) == Array(plan.grid.prefix(3)))
        #expect(grid.dropFirst(3).allSatisfy { $0.count == 5 && !$0.contains(2) && !$0.contains(7) })
        #expect(Planner.maxSubsFrom(grid, fromChange: 2) <= 3)
        #expect(throws: PlanError.self) {
            try Planner.repairRemaining(grid: plan.grid, players: plan.players, available: [1, 2, 3, 4], fromBlock: 3)
        }
    }

    @Test func movesShiftOneBlockPerPair() throws {
        let minutes = Planner.planStats(try plan(12, moves: [[12, 6]])).minutes
        #expect(minutes[12] == 1200)
        #expect(minutes[6] == 800)
    }

    // The JS test also refuses a list that is not an array and pairs that hold strings or fractions; Swift's types
    // rule those out, so only the lists that type-check are ported.
    @Test(arguments: [
        [[12]], [[12, 6, 7]], [[12, 12]], [[12, 6], [12, 7]], [[12, 6], [11, 6]], [[13, 6]], [[12, 0]],
    ] as [[[Int]]])
    func aBadMoveListIsRefusedWithAPlanError(moves: [[Int]]) {
        #expect(throws: PlanError.self) { try plan(12, moves: moves) }
    }

    // #41: when the plain plan only fits with the sit limit relaxed (the last search level), catch-up moves are tried
    // up to that level only; a move list that does not fit there gives no error.
    @Test func whenThePlainPlanRelaxesTheSitLimitAndNoMoveFitsItIsThePlainPlan() throws {
        let plain = try plan(16, start: [1, 2, 14, 11, 4], schedule: "five", seed: 3)
        #expect(plain.sitLimitRelaxed == true)
        #expect(try plan(16, start: [1, 2, 14, 11, 4], schedule: "five", seed: 3, moves: [[3, 5]]) == plain)
    }

    // The case from #40's review: priority and moves are what catchUp gives for scripts/fixtures/history-sit-relaxed.json
    // with these players, the five-minute schedule and seed 3. All four moves do not fit at the last level; the plan
    // takes the first three, which do.
    @Test func whenThePlainPlanRelaxesTheSitLimitItTakesTheMovesFromTheFrontThatStillFit() throws {
        let priority = [14, 9, 4, 2, 5, 6, 10, 1, 3, 12, 11, 13, 7, 16, 8, 15]
        let start = [15, 8, 16, 7, 13]
        #expect(try plan(16, start: start, schedule: "five", seed: 3, extraPriority: priority).sitLimitRelaxed == true)
        let moves = [[3, 15], [12, 8], [11, 16], [13, 7]]
        #expect(try plan(16, start: start, schedule: "five", seed: 3, extraPriority: priority, moves: moves)
            == plan(16, start: start, schedule: "five", seed: 3, extraPriority: priority,
                    moves: Array(moves.prefix(3))))
    }
}

/// The same input through public/js/planner.js and the Swift planner gives the same grid (decision #35). The priority
/// and moves are what catchUp in public/js/history.js gives for the named fixture in scripts/fixtures/, so these cover
/// the planner's half of the plan examples that use --use-history, which the Swift sim runs once #97 ports catchUp.
@Suite struct PlannerMatchesJavaScriptTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fixture: String
        let n: Int
        let start: [Int]
        let schedule: String
        let seed: Int
        let priority: [Int]
        let moves: [[Int]]
        let grid: [[Int]]
        let relaxed: Bool
        var testDescription: String { "\(fixture), \(schedule), \(n) players" }
    }

    static let cases: [Case] = [
        Case(fixture: "history-catchup", n: 12, start: [1, 2, 3, 4, 5], schedule: "equal", seed: 1,
             priority: [12, 5, 11, 3, 7, 10, 4, 2, 9, 6, 1, 8], moves: [[12, 8]],
             grid: [[1, 2, 3, 4, 5], [1, 4, 5, 10, 12], [4, 7, 10, 11, 12], [6, 7, 9, 11, 12], [3, 6, 7, 8, 9],
                    [2, 3, 5, 8, 9], [1, 2, 5, 8, 10], [1, 4, 5, 10, 12], [4, 7, 10, 11, 12], [3, 6, 7, 11, 12],
                    [2, 3, 6, 9, 11], [1, 2, 6, 8, 9]], relaxed: false),
        Case(fixture: "history-catchup", n: 12, start: [1, 2, 3, 4, 5], schedule: "five", seed: 1,
             priority: [12, 5, 11, 3, 7, 10, 4, 2, 9, 6, 1, 8], moves: [],
             grid: [[1, 2, 3, 4, 5], [2, 3, 5, 11, 12], [5, 7, 8, 11, 12], [6, 7, 8, 9, 10], [1, 4, 8, 9, 10],
                    [1, 2, 3, 4, 12], [3, 5, 6, 11, 12], [6, 7, 9, 10, 11]], relaxed: false),
        Case(fixture: "history-reward", n: 12, start: [1, 2, 3, 4, 5], schedule: "equal", seed: 1,
             priority: [5, 11, 3, 7, 10, 4, 2, 12, 9, 6, 1, 8], moves: [],
             grid: [[1, 2, 3, 4, 5], [1, 4, 5, 8, 10], [4, 7, 8, 10, 12], [7, 9, 10, 11, 12], [3, 6, 7, 9, 11],
                    [2, 3, 5, 6, 11], [1, 2, 4, 5, 6], [1, 2, 4, 8, 10], [1, 7, 8, 10, 12], [3, 7, 8, 9, 12],
                    [3, 6, 9, 11, 12], [2, 5, 6, 9, 11]], relaxed: false),
        Case(fixture: "history-sample", n: 12, start: [1, 2, 3, 4, 5], schedule: "equal", seed: 1,
             priority: [3, 4, 2, 1, 5, 11, 7, 10, 12, 9, 6, 8], moves: [[3, 8], [4, 6], [2, 9], [1, 12]],
             grid: [[1, 2, 3, 4, 5], [3, 4, 5, 7, 10], [3, 7, 10, 11, 12], [6, 9, 10, 11, 12], [1, 6, 8, 9, 12],
                    [1, 2, 4, 8, 9], [2, 4, 5, 7, 8], [3, 4, 5, 7, 10], [3, 5, 10, 11, 12], [1, 3, 6, 11, 12],
                    [1, 2, 6, 9, 11], [2, 6, 7, 8, 9]], relaxed: false),
        Case(fixture: "history-sit-relaxed", n: 16, start: [15, 8, 16, 7, 13], schedule: "five", seed: 3,
             priority: [14, 9, 4, 2, 5, 6, 10, 1, 3, 12, 11, 13, 7, 16, 8, 15],
             moves: [[3, 15], [12, 8], [11, 16], [13, 7]],
             grid: [[7, 8, 13, 15, 16], [7, 10, 11, 13, 14], [3, 4, 10, 11, 14], [3, 4, 5, 10, 12], [1, 2, 4, 5, 12],
                    [1, 2, 6, 9, 12], [2, 6, 9, 11, 14], [1, 3, 5, 6, 9]], relaxed: true),
        // #169: the exhaustive search's plans for 13 players in the 5-minute schedule (no history fixture).
        Case(fixture: "none (h=0)", n: 13, start: [1, 2, 3, 4, 5], schedule: "five", seed: 1, priority: [6], moves: [],
             grid: [[1, 2, 3, 4, 5], [4, 5, 6, 7, 8], [6, 8, 9, 10, 11], [1, 10, 11, 12, 13], [1, 2, 3, 4, 13],
                    [2, 3, 5, 6, 7], [6, 7, 8, 9, 12], [9, 10, 11, 12, 13]], relaxed: false),
        Case(fixture: "none (h=1)", n: 13, start: [1, 2, 3, 4, 5], schedule: "five", seed: 1, priority: [1], moves: [],
             grid: [[1, 2, 3, 4, 5], [1, 5, 6, 7, 8], [7, 8, 9, 10, 11], [2, 10, 11, 12, 13], [2, 3, 4, 5, 13],
                    [1, 3, 4, 6, 7], [1, 6, 8, 9, 12], [9, 10, 11, 12, 13]], relaxed: false),
    ]

    @Test(arguments: cases)
    func planWithPriorityAndMovesMatchesTheJavaScript(_ c: Case) throws {
        let plan = try plan(c.n, start: c.start, schedule: c.schedule, seed: c.seed, extraPriority: c.priority,
                            moves: c.moves)
        #expect(plan.grid == c.grid)
        #expect(plan.sitLimitRelaxed == c.relaxed)
    }

    @Test func liveChangesMatchTheJavaScript() throws {
        let plan2 = try plan(12, seed: 2)
        let available = range(12).filter { $0 != 3 }
        let targets = try Planner.evenTargets(grid: plan2.grid, players: plan2.players, available: available,
                                              fromBlock: 5)
        #expect(targets == [1: 6, 2: 6, 3: 3, 4: 5, 5: 5, 6: 5, 7: 5, 8: 5, 9: 5, 10: 5, 11: 5, 12: 5])
        #expect(try Planner.replanRemaining(grid: plan2.grid, players: plan2.players, available: available,
                                            fromBlock: 5, targets: targets, blockSeconds: 200, seed: 9)
            == [[1, 2, 3, 4, 5], [2, 3, 4, 8, 10], [3, 6, 7, 8, 10], [6, 7, 8, 11, 12], [1, 6, 9, 11, 12],
                [1, 2, 5, 9, 11], [1, 2, 4, 5, 10], [2, 4, 7, 8, 10], [4, 6, 7, 8, 12], [6, 7, 9, 11, 12],
                [1, 5, 9, 11, 12], [1, 2, 5, 9, 10]])

        let plan4 = try plan(12, seed: 4)
        #expect(plan4.grid == [[1, 2, 3, 4, 5], [2, 3, 5, 9, 10], [3, 7, 8, 9, 10], [6, 7, 8, 10, 11],
                               [4, 6, 8, 11, 12], [1, 4, 5, 11, 12], [1, 2, 4, 5, 9], [2, 3, 5, 7, 9],
                               [3, 6, 7, 9, 10], [6, 7, 8, 10, 12], [1, 6, 8, 11, 12], [1, 2, 4, 11, 12]])
        // Five players uit at once from block 3: only seven are left.
        #expect(try Planner.repairRemaining(grid: plan4.grid, players: plan4.players,
                                            available: range(12).filter { ![2, 7, 1, 3, 4].contains($0) },
                                            fromBlock: 3)
            == [[1, 2, 3, 4, 5], [2, 3, 5, 9, 10], [3, 7, 8, 9, 10], [6, 8, 9, 10, 11], [6, 8, 9, 11, 12],
                [5, 6, 8, 11, 12], [5, 6, 8, 9, 11], [5, 6, 8, 9, 11], [5, 6, 8, 9, 10], [5, 6, 8, 10, 12],
                [5, 6, 8, 11, 12], [5, 6, 8, 11, 12]])
        #expect(try Planner.repairRemaining(grid: plan4.grid, players: plan4.players,
                                            available: range(12).filter { $0 != 2 && $0 != 7 }, fromBlock: 3)
            == [[1, 2, 3, 4, 5], [2, 3, 5, 9, 10], [3, 7, 8, 9, 10], [3, 6, 8, 10, 11], [4, 6, 8, 11, 12],
                [1, 4, 5, 11, 12], [1, 4, 5, 9, 11], [1, 3, 4, 5, 9], [1, 3, 6, 9, 10], [1, 6, 8, 10, 12],
                [1, 6, 8, 11, 12], [1, 4, 6, 11, 12]])
    }
}

@Suite struct PlannerHelperTests {
    @Test func combinationsComeInTheOrderOfTheJavaScriptRecursion() {
        var seen: [[Int]] = []
        Planner.forEachCombination(of: [7, 3, 9, 1], 2) { seen.append($0) }
        #expect(seen == [[7, 3], [7, 9], [7, 1], [3, 9], [3, 1], [9, 1]])
        var none: [[Int]] = []
        Planner.forEachCombination(of: [7, 3], 0) { none.append($0) }
        #expect(none == [[]])
        var tooMany = 0
        Planner.forEachCombination(of: [7, 3], 3) { _ in tooMany += 1 }
        #expect(tooMany == 0)
    }

    @Test func stableSortedKeepsTheOrderOfEqualKeys() {
        let key: [Double] = [0.5, 0.1, 0.5, 0.9, 0.1]
        #expect(Planner.stableSorted([0, 1, 2, 3, 4], by: key, increasing: true) == [1, 4, 0, 2, 3])
        #expect(Planner.stableSorted([0, 1, 2, 3, 4], by: key, increasing: false) == [3, 0, 2, 1, 4])
    }

    @Test func planStatsCountsSecondsSubsAndTheLongestSitAndStint() {
        let plan = Plan(schedule: "five", blocks: 3, blockSeconds: 300, blocksPerQuarter: 2, players: range(6),
                        start: [1, 2, 3, 4, 5], grid: [[1, 2, 3, 4, 5], [1, 2, 3, 4, 6], [1, 2, 3, 4, 6]],
                        sitLimitRelaxed: false)
        let stats = Planner.planStats(plan)
        #expect(stats.minutes == [1: 900, 2: 900, 3: 900, 4: 900, 5: 300, 6: 600])
        #expect(stats.subsPerChange == [1, 0])
        #expect(stats.longestBenchSeconds == 600)
        #expect(stats.longestStintSeconds == 900)
    }
}
