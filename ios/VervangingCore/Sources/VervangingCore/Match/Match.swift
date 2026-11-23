import Foundation

// The match engine, ported from public/js/match.js (ADR-003); the JS file is the reference, and every function here
// gives exactly what its JS twin gives, so the shared examples in shared/examples/ hold for both apps. Decisions:
// docs/PLAN.md #4 (blocks, minutes = blocks × length; no clock, ADR-001), #8 and #9 (in the zone), #12 (live
// screen), #11 and #21 (uit and terug, the sub rule for players marked uit), #17 (undo, one step), #24 and #25 (Extra
// minuten), #27 (minutes at a glance).

/// Who goes off and who comes on at the next wissel, each ascending.
public struct NextChange: Equatable, Sendable {
    public var off: [Int]
    public var on: [Int]
}

/// When the current block ends on the official clock, which counts down from 10:00 each quarter.
public enum SubTime: Equatable, Sendable {
    /// A wissel inside the quarter, at this many seconds on the clock (6:40 and 3:20 in the equal schedule, 5:00 in
    /// the 5-minute one).
    case sub(clockSeconds: Int)
    case endQuarter
    case endMatch
}

/// One line of the minutes at a glance (decision #27).
public struct MinutesEntry: Equatable, Sendable {
    public var player: Int
    public var seconds: Int
    public var onCourt: Bool
    public var out: Bool
}

/// A live action as the runner writes it (applyAction in match.js).
public enum MatchAction: Equatable, Sendable {
    case wissel(keep: Int? = nil, bench: Int? = nil, extra: Bool = false)
    case undo
    case uit(Int)
    case terug(Int)
}

/// The sub rule for a live plan (decision #21), as capHolds and subsAllowed in match.js.
public enum Match {
    /// At most `Planner.maxSubs` subs at the change into block `k` (0-based), except that a player marked uit who is
    /// on court must leave whatever the count: the change may have as many subs as the players it takes off for
    /// being uit.
    public static func subsAllowed(_ grid: [[Int]], _ k: Int, out: [Int]) -> Int {
        let forced = grid[k - 1].filter { out.contains($0) && !grid[k].contains($0) }.count
        return max(Planner.maxSubs, forced)
    }

    /// True when every change after block `fromChange` (0-based index of the block the change starts from) keeps the
    /// sub rule.
    public static func capHolds(_ grid: [[Int]], fromChange: Int, out: [Int]) -> Bool {
        var k = max(1, fromChange + 1)
        while k < grid.count {
            let subs = grid[k].filter { !grid[k - 1].contains($0) }.count
            if subs > subsAllowed(grid, k, out: out) { return false }
            k += 1
        }
        return true
    }

    /// The current block as it is on court: a player marked uit there left at once and a replacement came on.
    static func actualRow(_ row: [Int], _ replaced: [Replacement]) -> [Int] {
        row.map { p in replaced.first { $0.starter == p }?.replacement ?? p }.sorted()
    }

    /// The grid with the current block as it is on court: the one to count subs on and to plan from.
    static func actualGrid(_ grid: [[Int]], block: Int, _ replaced: [Replacement]) -> [[Int]] {
        var actual = grid
        actual[block - 1] = actualRow(grid[block - 1], replaced)
        return actual
    }
}

extension MatchState {
    /// A new match from a plan (Planner.makePlan, after swaps): block 1 is being played, nothing to undo.
    public static func start(_ plan: Plan, setupSavedAt: String? = nil) -> MatchState {
        MatchState(setupSavedAt: setupSavedAt, schedule: plan.schedule, blocks: plan.blocks,
                   blockSeconds: plan.blockSeconds, blocksPerQuarter: plan.blocksPerQuarter, players: plan.players,
                   base: plan.grid, grid: plan.grid, out: [], replaced: [], extra: [], block: 1, ended: false,
                   previous: nil)
    }

    var available: [Int] { players.filter { !out.contains($0) } }

    /// The players on court in the current block, ascending, with replacements for players who went uit in it.
    public var onCourt: [Int] { Match.actualRow(grid[block - 1], replaced) }

    /// The live plan with the current block as it is on court (what the sub rule is checked on).
    public var livePlan: [[Int]] { Match.actualGrid(grid, block: block, replaced) }

    public var canUndo: Bool { previous != nil }

    /// Who goes off and who comes on at the next wissel; nil at the last block or after the end.
    public var nextChange: NextChange? {
        if ended || block >= blocks { return nil }
        let now = onCourt
        let next = grid[block]
        return NextChange(off: now.filter { !next.contains($0) }.sorted(), on: next.filter { !now.contains($0) }.sorted())
    }

    /// When the current block ends on the official clock.
    public var subTime: SubTime {
        if block >= blocks { return .endMatch }
        let inQuarter = (block - 1) % blocksPerQuarter // 0-based place of the block in its quarter
        if inQuarter == blocksPerQuarter - 1 { return .endQuarter }
        return .sub(clockSeconds: blocksPerQuarter * blockSeconds - (inQuarter + 1) * blockSeconds)
    }

    /// The quarter of the current block, 1-based.
    public var quarter: Int { (block - 1) / blocksPerQuarter + 1 }

    /// Seconds per player so far: blocks started (the current one included) × block length.
    public var minutesSoFar: [Int: Int] {
        var minutes = Dictionary(players.map { ($0, 0) }, uniquingKeysWith: { $1 })
        for court in grid.prefix(block) {
            for p in court { minutes[p, default: 0] += blockSeconds }
        }
        return minutes
    }

    /// Seconds each player got through Extra minuten in this match.
    public var extraSeconds: [Int: Int] {
        var seconds = Dictionary(players.map { ($0, 0) }, uniquingKeysWith: { $1 })
        for p in extra { seconds[p, default: 0] += blockSeconds }
        return seconds
    }

    /// The minutes at a glance: one entry per player in player order.
    public var minutesOverview: [MinutesEntry] {
        let minutes = minutesSoFar
        let court = onCourt
        return players.map { MinutesEntry(player: $0, seconds: minutes[$0]!, onCourt: court.contains($0),
                                          out: out.contains($0)) }
    }

    /// The incoming player the app proposes to keep on the bench when a player stays on: the one with the most
    /// minutes so far, ties to the lowest number (decision #9).
    public var proposedBench: Int? {
        guard let change = nextChange, !change.on.isEmpty else { return nil }
        let minutes = minutesSoFar
        return change.on.min { minutes[$0]! != minutes[$1]! ? minutes[$0]! > minutes[$1]! : $0 < $1 }
    }

    /// "wissel": on to the next block; at the last block it ends the match. After the end it changes nothing.
    /// `keep` (and optionally `bench`) apply in the zone at this change; with `extra`, as Extra minuten (#25).
    /// Throws MatchError for an action that cannot apply (and passes on a PlanError from the planner, as match.js).
    public func wissel(keep: Int? = nil, bench: Int? = nil, extra: Bool = false) throws -> MatchState {
        if ended { return self }
        var next = self
        next.previous = snapshot
        if block >= blocks {
            if keep != nil { throw MatchError("no change left: this is the last block") }
            next.ended = true // the last block's replacements stay: they finished the match
            return next
        }
        if extra && keep == nil { throw MatchError("extra minuten needs a player to keep on") }
        if let keep { next.grid = try keepOn(keep, bench: bench, extra: extra) }
        next.block = block + 1
        next.replaced = []
        if extra, let keep { next.extra = self.extra + [keep] }
        return next
    }

    /// "undo": back to the state before the last action, one step only. With nothing to undo it changes nothing.
    public func undo() -> MatchState {
        guard let previous else { return self }
        var back = self
        back.block = previous.block
        back.ended = previous.ended
        back.grid = previous.grid
        back.out = previous.out
        back.replaced = previous.replaced
        back.extra = previous.extra
        back.previous = nil
        return back
    }

    public func applying(_ action: MatchAction) throws -> MatchState {
        switch action {
        case let .wissel(keep, bench, extra): return try wissel(keep: keep, bench: bench, extra: extra)
        case .undo: return undo()
        case let .uit(player): return try uit(player)
        case let .terug(player): return try terug(player)
        }
    }

    /// In the zone at the coming change: `keep` (due off) stays on for the next block, `bench` (due on; the proposal
    /// by default) stays off. The benched player gets back the zone player's next planned block where the benched
    /// player is not on yet. When that would break the sub cap, the blocks after the next one are replanned to the
    /// original totals; with no later block, the difference stays.
    func keepOn(_ keep: Int, bench: Int?, extra: Bool) throws -> [[Int]] {
        guard let change = nextChange else { throw MatchError("no change left: this is the last block") }
        if out.contains(keep) { throw MatchError("player \(keep) is out and cannot stay on") }
        if !change.off.contains(keep) { throw MatchError("player \(keep) is not due off at this change") }
        let chosen = bench ?? proposedBench
        guard let q = chosen, change.on.contains(q) else {
            throw MatchError("player \(chosen.map(String.init) ?? "null") is not due on at this change")
        }
        let next = block // 0-based index of the next block
        let totals = Planner.blockCounts(grid, players: players)
        var kept = grid
        kept[next] = (kept[next].filter { $0 != q } + [keep]).sorted()
        let fixed = next + 1 // blocks 1..next+1 are now fixed
        if fixed >= blocks { return kept } // the last change: the difference stays
        if extra { return try extraOn(kept, keep: keep, totals: totals, fixed: fixed) }

        for k in fixed..<blocks {
            if !kept[k].contains(keep) || kept[k].contains(q) { continue }
            var swapped = kept
            swapped[k] = (swapped[k].filter { $0 != keep } + [q]).sorted()
            if Match.capHolds(Match.actualGrid(swapped, block: block, replaced), fromChange: next, out: out) {
                return swapped
            }
        }
        func replan(_ targets: [Int: Int]) -> [[Int]]? {
            try? Planner.replanRemaining(grid: kept, players: players, available: available, fromBlock: fixed,
                                         targets: targets, blockSeconds: blockSeconds, seed: block)
        }
        // Original totals (zone player one block back, benched player one block more); else keep the difference;
        // else the last-resort repair, which holds the sub cap whatever the totals.
        if let grid = replan(totals) ?? replan(Planner.blockCounts(kept, players: players)) { return grid }
        return try Planner.repairRemaining(grid: kept, players: players, available: available, fromBlock: fixed)
    }

    /// Extra minuten (decision #25): the kept player plays the block on top and gives nothing back. Their match total
    /// becomes the planned total plus one block (never more); the places left after the next block go to the other
    /// available players, fewest blocks first, under the sub rule. Ties are tried in several orders, then with the
    /// others up to two blocks apart; only when no plan fits does the last-resort repair run, after which the kept
    /// player is swapped out of later blocks until their total is exactly planned plus one (where the sub rule
    /// allows it).
    func extraOn(_ kept: [[Int]], keep: Int, totals: [Int: Int], fixed: Int) throws -> [[Int]] {
        let avail = available
        let prefix = Planner.blockCounts(Array(kept.prefix(fixed)), players: players)
        let left = blocks - fixed
        let target = min(totals[keep]! + 1, prefix[keep]! + left)
        let others = avail.filter { $0 != keep }
        func shareOut(_ order: [Int], spread: Int) -> [Int: Int]? {
            var targets = prefix
            targets[keep] = target
            var places = Planner.onCourt * left - (target - prefix[keep]!)
            while places > 0 {
                var best: Int?
                for p in order {
                    if targets[p]! - prefix[p]! >= left { continue }
                    if best == nil || targets[p]! < targets[best!]! - (spread - 1) { best = p }
                }
                guard let best else { return nil }
                targets[best]! += 1
                places -= 1
            }
            return targets
        }
        // match.js shuffles with `sort(() => random() - 0.5)`; the V8 sort port makes the same draws in the same order.
        var random = SeededRandom(seed: block * 31 + keep)
        var orders = [others.sorted()]
        for _ in 0..<12 { orders.append(javaScriptSorted(others) { _, _ in random.next() - 0.5 }) }
        for spread in [1, 2] {
            for order in orders {
                guard let targets = shareOut(order, spread: spread) else { continue }
                if let grid = try? Planner.replanRemaining(grid: kept, players: players, available: avail,
                                                           fromBlock: fixed, targets: targets,
                                                           blockSeconds: blockSeconds, seed: block) {
                    return grid
                }
            }
        }
        let repaired = try Planner.repairRemaining(grid: kept, players: players, available: avail, fromBlock: fixed)
        return holdTotal(repaired, keep: keep, target: target, fixed: fixed, avail: avail)
    }

    /// Swaps `keep` out of later blocks (latest first) for an available bench player with the fewest blocks, while
    /// their total is above `target` and the sub rule still holds, so a reward is never more than the one block
    /// recorded.
    func holdTotal(_ grid: [[Int]], keep: Int, target: Int, fixed: Int, avail: [Int]) -> [[Int]] {
        var result = grid
        var k = result.count - 1
        while k >= fixed && Planner.blockCounts(result, players: players)[keep]! > target {
            defer { k -= 1 }
            if !result[k].contains(keep) { continue }
            let counts = Planner.blockCounts(result, players: players)
            let bench = avail.filter { $0 != keep && !result[k].contains($0) }
                .sorted { counts[$0]! != counts[$1]! ? counts[$0]! < counts[$1]! : $0 < $1 }
            for p in bench {
                var swapped = result
                swapped[k] = (swapped[k].filter { $0 != keep } + [p]).sorted()
                if Match.capHolds(Match.actualGrid(swapped, block: block, replaced), fromChange: block - 1, out: out) {
                    result = swapped
                    break
                }
            }
        }
        return result
    }
}

// Uit and terug (decision #11, and the owner's decision on #9 of 22 Nov 2026), ported from match.js.
extension MatchState {
    /// "uit": `player` plays no more this match. On court, they leave at once and a replacement comes on: a player due
    /// on at the next wissel when there is one, else a bench player; fewest minutes first, ties to the lowest number.
    /// The current block still counts for the player who started it. The rest of the plan is recalculated only when
    /// `player` was planned in a later block. Possible in the last block too.
    public func uit(_ player: Int) throws -> MatchState {
        if ended { throw MatchError("the match has ended") }
        if !players.contains(player) { throw MatchError("player \(player) is not in this match") }
        if out.contains(player) { throw MatchError("player \(player) is already out") }
        let newOut = (out + [player]).sorted()
        if players.count - newOut.count < Planner.onCourt {
            throw MatchError("at least \(Planner.onCourt) players must be available")
        }
        let court = onCourt
        let minutes = minutesSoFar
        func fewest(_ a: Int, _ b: Int) -> Bool { minutes[a]! != minutes[b]! ? minutes[a]! < minutes[b]! : a < b }
        let nextRow = block < blocks ? grid[block] : nil
        var newReplaced = replaced
        var fromNext = false
        if court.contains(player) {
            // A starter of this block who already left it (uit, even when back with terug, which counts from the next
            // block) does not come back on in the same block.
            let startedHere = grid[block - 1]
            func pick(_ list: [Int]) -> Int? {
                list.filter { !newOut.contains($0) && !court.contains($0) && !startedHere.contains($0) }
                    .sorted(by: fewest).first
            }
            let early = nextRow.flatMap(pick)
            guard let replacement = early ?? pick(players) else { throw MatchError("no player is left to come on") }
            fromNext = early != nil
            if let i = newReplaced.firstIndex(where: { $0.replacement == player }) {
                newReplaced[i].replacement = replacement // the player was a replacement already
            } else {
                newReplaced.append(Replacement(starter: player, replacement: replacement))
            }
        }
        var next = self
        next.out = newOut
        next.replaced = newReplaced
        next.previous = snapshot
        let plannedLater = grid[block...].contains { $0.contains(player) }
        if !plannedLater { return next }
        // The replacement came from the next wissel, so that wissel stays as planned, without the uit player: a player
        // due off stays on in their place when one is needed (fewest minutes first). Only the blocks after it are
        // recalculated.
        var fixedNext: [Int]?
        if fromNext, let nextRow {
            var row = nextRow.filter { $0 != player }
            if row.count < Planner.onCourt {
                let now = Match.actualRow(grid[block - 1], newReplaced)
                let free = { (list: [Int]) in list.filter { !newOut.contains($0) && !row.contains($0) }.sorted(by: fewest) }
                // Always found: at least five players are available and the row holds four of them.
                guard let stay = free(now).first ?? free(players).first else {
                    throw MatchError("no player is left to come on")
                }
                row.append(stay)
            }
            fixedNext = row
        }
        next.grid = try respread(out: newOut, replaced: newReplaced, fixedNext: fixedNext)
        return next
    }

    /// "terug": `player` is available again from the next block on.
    public func terug(_ player: Int) throws -> MatchState {
        if ended { throw MatchError("the match has ended") }
        if !out.contains(player) { throw MatchError("player \(player) is not out") }
        if block >= blocks { throw MatchError("no block left: this is the last block") }
        let newOut = out.filter { $0 != player }
        var next = self
        next.grid = try respread(out: newOut, replaced: replaced, fixedNext: nil)
        next.out = newOut
        next.previous = snapshot
        return next
    }

    /// Re-spreads the blocks after the current one over the players who are not out (decision #11). Targets come
    /// from the credited grid (minutes); the search plans from the current block as it is on court, so a replacement
    /// already on is not counted as coming on, and the current block keeps its credited line-up afterwards. With
    /// `fixedNext`, the next block is set to that line-up first and only the blocks after it are planned.
    func respread(out newOut: [Int], replaced newReplaced: [Replacement], fixedNext: [Int]?) throws -> [[Int]] {
        let avail = players.filter { !newOut.contains($0) }
        if avail.count < Planner.onCourt { throw MatchError("at least \(Planner.onCourt) players must be available") }
        var base = grid
        if let fixedNext { base[block] = fixedNext.sorted() }
        let fromBlock = fixedNext != nil ? block + 1 : block
        let targets = try Planner.evenTargets(grid: base, players: players, available: avail, fromBlock: fromBlock)
        let actual = Match.actualGrid(base, block: block, newReplaced)
        let credited = Planner.blockCounts(Array(base.prefix(fromBlock)), players: players)
        let onCourtCounts = Planner.blockCounts(Array(actual.prefix(fromBlock)), players: players)
        let searchTargets = Dictionary(players.map { ($0, targets[$0]! + onCourtCounts[$0]! - credited[$0]!) },
                                       uniquingKeysWith: { $1 })
        var planned: [[Int]]
        do {
            planned = try Planner.replanRemaining(grid: actual, players: players, available: avail,
                                                  fromBlock: fromBlock, targets: searchTargets,
                                                  blockSeconds: blockSeconds, seed: block)
        } catch {
            // No plan meets the targets under the sub rule: never refuse a player who is out, repair instead.
            planned = try Planner.repairRemaining(grid: actual, players: players, available: avail,
                                                  fromBlock: fromBlock)
        }
        planned[block - 1] = grid[block - 1]
        return planned
    }
}
