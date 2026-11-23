import Foundation

// The planner's functions for live changes during a match (decisions #8 and #11), ported from public/js/planner.js
// for the Swift match engine. Every player on the grid must be in `players`, and `available` is a subset of it.

extension Planner {
    /// Replans the blocks after `fromBlock` (1-based count of blocks already fixed) so every available player reaches
    /// `targets`, under the same sub rule. Earlier blocks are never changed. Players who are not available get no
    /// more blocks. Returns the full grid; throws PlanError when no plan fits.
    public static func replanRemaining(grid: [[Int]], players: [Int], available: [Int]? = nil, fromBlock: Int,
                                       targets: [Int: Int], blockSeconds: Int,
                                       seed: Int = 1) throws(PlanError) -> [[Int]] {
        if fromBlock < 1 || fromBlock > grid.count {
            throw PlanError("fromBlock must be between 1 and the number of blocks")
        }
        if fromBlock == grid.count { return grid }
        if (available ?? players).count < onCourt { throw PlanError("at least \(onCourt) players must be available") }
        var random = SeededRandom(seed: seed)
        // Without a maxLevel, the search throws rather than give nil.
        return try searchGrid(prefix: Array(grid.prefix(fromBlock)), players: players, available: available,
                              targets: targets, blocks: grid.count, blockSeconds: blockSeconds, random: &random)!.grid
    }

    /// Blocks per player for the rest of the match when who may play changes (uit, terug): the places left after
    /// `fromBlock` go one by one to the available player with the fewest blocks so far (ties: lowest number), so the
    /// match totals end as equal as the remaining blocks allow (decision #11). `fromBlock` is 0 to grid.count.
    public static func evenTargets(grid: [[Int]], players: [Int], available: [Int],
                                   fromBlock: Int) throws(PlanError) -> [Int: Int] {
        let left = grid.count - fromBlock
        let counts = blockCounts(Array(grid.prefix(max(0, fromBlock))), players: players)
        var extra = Dictionary(players.map { ($0, 0) }, uniquingKeysWith: { $1 })
        let pool = players.filter { available.contains($0) }.sorted()
        for _ in stride(from: 0, to: onCourt * left, by: 1) {
            var best: Int?
            for p in pool {
                if extra[p]! >= left { continue }
                if best == nil || counts[p]! + extra[p]! < counts[best!]! + extra[best!]! { best = p }
            }
            guard let best else { throw PlanError("at least \(onCourt) players must be available") }
            extra[best]! += 1
        }
        return Dictionary(players.map { ($0, counts[$0]! + extra[$0]!) }, uniquingKeysWith: { $1 })
    }

    /// Blocks per player in `grid`, for every player in `players` (0 for a player in no block).
    public static func blockCounts(_ grid: [[Int]], players: [Int]) -> [Int: Int] {
        var counts = Dictionary(players.map { ($0, 0) }, uniquingKeysWith: { $1 })
        for court in grid {
            for p in court where counts[p] != nil { counts[p]! += 1 }
        }
        return counts
    }

    /// The most subs at one change, from change `fromChange` on (change i is the move into block i + 1, 0-based).
    public static func maxSubsFrom(_ grid: [[Int]], fromChange: Int = 0) -> Int {
        var most = 0
        var i = max(1, fromChange + 1)
        while i < grid.count {
            most = max(most, grid[i].filter { !grid[i - 1].contains($0) }.count)
            i += 1
        }
        return most
    }

    /// Last resort when no plan meets the targets under the sub rule (late in a match, after several live changes):
    /// keep the planned line-ups as far as possible, but put in an available player for anyone who is not available
    /// (fewest blocks first) and hold every change to at most `maxSubs` subs by keeping available players on instead
    /// (fewest blocks so far come on first). The one exception: players who are not available must leave, so a change
    /// may need as many subs as the unavailable players it takes off, when that is more than `maxSubs` (four players
    /// uit at once). Totals may then differ by more than a block; the minutes on screen show it. Never fails while
    /// `onCourt` players are available. `fromBlock` is 1 or more: block 0 is the starting five.
    public static func repairRemaining(grid: [[Int]], players: [Int], available: [Int]? = nil,
                                       fromBlock: Int) throws(PlanError) -> [[Int]] {
        let available = available ?? players
        if available.count < onCourt { throw PlanError("at least \(onCourt) players must be available") }
        // The JS fails on a missing previous block with a TypeError; Swift says so instead of crashing.
        if fromBlock < 1 && !grid.isEmpty {
            throw PlanError("fromBlock must be between 1 and the number of blocks")
        }
        var out = grid
        var counts = blockCounts(Array(out.prefix(fromBlock)), players: players)
        func fewest(_ a: Int, _ b: Int) -> Bool {
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            return ca != cb ? ca < cb : a < b
        }
        var k = fromBlock
        while k < out.count {
            let prev = out[k - 1]
            var row = out[k].filter { available.contains($0) }
            for p in prev.filter({ available.contains($0) }) + available.sorted(by: fewest) {
                if row.count >= onCourt { break }
                if !row.contains(p) { row.append(p) }
            }
            var incoming = row.filter { !prev.contains($0) }.sorted(by: fewest)
            var stayers = prev.filter { available.contains($0) && !row.contains($0) }.sorted(by: fewest)
            while incoming.count > maxSubs && !stayers.isEmpty {
                let drop = incoming.removeLast() // the incoming player with the most blocks waits
                row[row.firstIndex(of: drop)!] = stayers.removeFirst()
                incoming = row.filter { !prev.contains($0) }.sorted(by: fewest)
            }
            out[k] = row.sorted()
            for p in out[k] where counts[p] != nil { counts[p]! += 1 }
            k += 1
        }
        return out
    }
}
