import Foundation

// Planner: who plays which block. Ported from public/js/planner.js (plan decision #34, ADR-003); the JS file is the
// reference, and every function here gives exactly what its JS twin gives, so the shared examples in shared/examples/
// hold for both apps. Decisions: docs/PLAN.md #6 (schedules), #7 (grid, swaps), #20 (starting five), #21 and #22
// (sub rule), ADR-001 (fixed blocks: minutes are blocks × block length, no clock).

/// A PlanError's message is the same text as the JavaScript PlanError's, so the Swift sim prints the same line.
public struct PlanError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The length of a match in fixed blocks (decision #6).
public struct ScheduleShape: Equatable, Sendable {
    public let blocks: Int
    public let blockSeconds: Int
    public let blocksPerQuarter: Int
}

/// A plan: the grid holds, for each block, the five players on court in ascending order.
public struct Plan: Equatable, Sendable {
    public var schedule: String
    public var blocks: Int
    public var blockSeconds: Int
    public var blocksPerQuarter: Int
    public var players: [Int]
    public var start: [Int]
    public var grid: [[Int]]
    public var sitLimitRelaxed: Bool

    public init(schedule: String, blocks: Int, blockSeconds: Int, blocksPerQuarter: Int, players: [Int], start: [Int],
                grid: [[Int]], sitLimitRelaxed: Bool) {
        self.schedule = schedule
        self.blocks = blocks
        self.blockSeconds = blockSeconds
        self.blocksPerQuarter = blocksPerQuarter
        self.players = players
        self.start = start
        self.grid = grid
        self.sitLimitRelaxed = sitLimitRelaxed
    }
}

/// What `planStats` gives: seconds per player, subs per change and the longest sit and stint.
public struct PlanStats: Equatable, Sendable {
    public var minutes: [Int: Int]
    public var subsPerChange: [Int]
    public var longestBenchSeconds: Int
    public var longestStintSeconds: Int
}

public enum Planner {
    public static let schedules: [String: ScheduleShape] = [
        "equal": ScheduleShape(blocks: 12, blockSeconds: 200, blocksPerQuarter: 3),
        "five": ScheduleShape(blocks: 8, blockSeconds: 300, blocksPerQuarter: 2),
    ]

    public static let onCourt = 5
    public static let maxSubs = 3
    public static let maxSitSeconds = 900
    public static let maxStintSeconds = 600
    public static let nodeBudget = 50_000
    static let twoSubBudget = 3_000
    static let candidatesPerK = 24
    public static let completeBudget = 50_000

    static func scheduleOf(_ name: String) throws(PlanError) -> ScheduleShape {
        guard let schedule = schedules[name] else { throw PlanError("unknown schedule \"\(name)\": use equal or five") }
        return schedule
    }

    static func checkPlayers(_ players: [Int], _ start: [Int]) throws(PlanError) {
        if players.count < onCourt { throw PlanError("at least \(onCourt) players must be present") }
        if Set(players).count != players.count { throw PlanError("players must be distinct") }
        if start.count != onCourt || Set(start).count != onCourt {
            throw PlanError("the starting five must have \(onCourt) different players")
        }
        for p in start where !players.contains(p) { throw PlanError("starting five player \(p) is not present") }
    }

    /// Like the JS `shuffled`: a Fisher–Yates shuffle that draws from `random` from the last place down.
    static func shuffled(_ list: [Int], _ random: inout SeededRandom) -> [Int] {
        var out = list
        var i = out.count - 1
        while i > 0 {
            let j = Int((random.next() * Double(i + 1)).rounded(.down))
            out.swapAt(i, j)
            i -= 1
        }
        return out
    }

    /// Blocks per player: as equal as possible. The places that cannot be split equally go first to the players in
    /// `extraPriority` (in its order; history uses it, decision #10), then to players in seeded random order. Always
    /// draws from `random` for the shuffle, as the JS does, so the draws that follow stay the same.
    public static func blockTargets(_ players: [Int], totalPlaces: Int, random: inout SeededRandom,
                                    extraPriority: [Int] = []) -> [Int: Int] {
        let rest = shuffled(players.filter { !extraPriority.contains($0) }, &random)
        guard !players.isEmpty else { return [:] }
        let base = totalPlaces / players.count
        let extras = totalPlaces - base * players.count
        let order = extraPriority.filter { players.contains($0) } + rest
        let lucky = Set(order.prefix(max(0, extras)))
        return Dictionary(players.map { ($0, base + (lucky.contains($0) ? 1 : 0)) }, uniquingKeysWith: { $1 })
    }

    /// `moves` (optional, from the history's catch-up, decision #28): [to, from] pairs of present players, most
    /// important first; each moves one block from `from` to `to`, and a player is in at most one pair. The plan takes
    /// as many moves from the front as still plan within the limits the plain plan (without moves) keeps: the cap of
    /// 2 or 3 subs, the stint limit and the 15:00 sit limit (#21), so catch-up never relaxes a limit the plain plan
    /// keeps; when none fit, it is the plain plan.
    public static func makePlan(players: [Int], start: [Int], schedule: String = "equal", seed: Int = 1,
                                extraPriority: [Int] = [], moves: [[Int]] = []) throws(PlanError) -> Plan {
        let shape = try scheduleOf(schedule)
        try checkPlayers(players, start)
        try checkMoves(moves, players)
        let first = start.sorted()
        func attempt(_ count: Int, maxLevel: Int? = nil) throws(PlanError) -> GridSearchResult? {
            var random = SeededRandom(seed: seed)
            var targets = blockTargets(players, totalPlaces: onCourt * shape.blocks, random: &random,
                                       extraPriority: extraPriority)
            for move in moves.prefix(count) {
                let to = move[0], from = move[1]
                if targets[from]! < 1 || targets[to]! >= shape.blocks { return nil }
                targets[to]! += 1
                targets[from]! -= 1
            }
            return try searchGrid(prefix: [first], players: players, targets: targets, blocks: shape.blocks,
                                  blockSeconds: shape.blockSeconds, random: &random, maxLevel: maxLevel)
        }
        // Without a maxLevel, the search throws rather than give nil, and the plain attempt has no moves to refuse.
        let plain = try attempt(0)!
        var found: GridSearchResult?
        var count = moves.count
        while count > 0 && found == nil {
            found = try attempt(count, maxLevel: plain.level)
            count -= 1
        }
        let result = found ?? plain
        return Plan(schedule: schedule, blocks: shape.blocks, blockSeconds: shape.blockSeconds,
                    blocksPerQuarter: shape.blocksPerQuarter, players: players, start: first, grid: result.grid,
                    sitLimitRelaxed: result.sitLimitRelaxed)
    }

    /// The JS also refuses a list that is not an array, or a pair that holds something other than numbers; Swift's
    /// types rule those out.
    static func checkMoves(_ moves: [[Int]], _ players: [Int]) throws(PlanError) {
        var seen = Set<Int>()
        for pair in moves {
            if pair.count != 2 { throw PlanError("each catch-up move is a [to, from] player pair") }
            for p in pair {
                if !players.contains(p) { throw PlanError("catch-up move: player \(p) is not in the plan") }
                if seen.contains(p) { throw PlanError("catch-up move: player \(p) is in more than one move") }
                seen.insert(p)
            }
        }
    }

    /// Exchanges two players' rows. Both must be in the starting five, or both not, so the starting five stays as
    /// picked.
    public static func swapPlayers(_ plan: Plan, _ a: Int, _ b: Int) throws(PlanError) -> Plan {
        for p in [a, b] where !plan.players.contains(p) { throw PlanError("player \(p) is not in the plan") }
        if a == b { throw PlanError("pick two different players to swap") }
        if plan.start.contains(a) != plan.start.contains(b) {
            throw PlanError("swap two starters or two bench players, so the starting five stays as picked")
        }
        func swap(_ p: Int) -> Int { p == a ? b : p == b ? a : p }
        var out = plan
        out.grid = plan.grid.map { court in court.map(swap).sorted() }
        return out
    }

    public static func planStats(_ plan: Plan) -> PlanStats {
        let grid = plan.grid
        var minutes: [Int: Int] = [:]
        var longestSit = 0
        var longestStint = 0
        for p in plan.players {
            var count = 0, sit = 0, stint = 0
            for court in grid {
                if court.contains(p) {
                    count += 1; stint += 1; sit = 0
                } else {
                    sit += 1; stint = 0
                }
                longestSit = max(longestSit, sit)
                longestStint = max(longestStint, stint)
            }
            minutes[p] = count * plan.blockSeconds
        }
        let subsPerChange = grid.indices.dropFirst().map { i in grid[i].filter { !grid[i - 1].contains($0) }.count }
        return PlanStats(minutes: minutes, subsPerChange: subsPerChange,
                         longestBenchSeconds: longestSit * plan.blockSeconds,
                         longestStintSeconds: longestStint * plan.blockSeconds)
    }
}
