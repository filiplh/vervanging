import Foundation

/// What `searchGrid` gives: the grid, whether the 15:00 sit limit had to go, and the level that found it (0 to 5).
public struct GridSearchResult: Equatable, Sendable {
    public var grid: [[Int]]
    public var sitLimitRelaxed: Bool
    public var level: Int
}

extension Planner {
    /// `list` sorted by `key`, in increasing order when `increasing`, else decreasing; equal keys keep their order.
    /// This is what JavaScript's stable `Array.prototype.sort` gives with `(a, b) => key(a) - key(b)` (or
    /// `key(b) - key(a)`). An insertion sort: the lists are a handful of players.
    static func stableSorted(_ list: [Int], by key: [Double], increasing: Bool) -> [Int] {
        var out = list
        for i in out.indices.dropFirst() {
            let item = out[i]
            var j = i
            while j > 0 && (increasing ? key[item] < key[out[j - 1]] : key[item] > key[out[j - 1]]) {
                out[j] = out[j - 1]
                j -= 1
            }
            out[j] = item
        }
        return out
    }
}

extension Planner {
    /// Calls `body` with every way to pick `k` items from `list`, in the order of the JS `combinations`: those with
    /// the head first, then those without it, which is the lexicographic order of the picked places. The array passed
    /// to `body` is reused between calls.
    static func forEachCombination(of list: [Int], _ k: Int, _ body: ([Int]) -> Void) {
        if k < 0 || k > list.count { return }
        var places = Array(0..<k)
        var picked = places.map { list[$0] }
        while true {
            body(picked)
            // Move the last place that can still move one step on, and put the places after it right behind it.
            var i = k - 1
            while i >= 0 && places[i] == list.count - k + i { i -= 1 }
            if i < 0 { return }
            places[i] += 1
            picked[i] = list[places[i]]
            for j in (i + 1)..<k {
                places[j] = places[j - 1] + 1
                picked[j] = list[places[j]]
            }
        }
    }

    /// Fills blocks prefix.count ..< blocks so every player reaches its target, with at most `maxSubs` changes per sub
    /// moment (trying 2 first, then 1, then 3, then 0), no sit longer than `maxSit` blocks and no stint longer than
    /// `maxStint` blocks. `available` limits who may play the remaining blocks (nil: every player). Every player needs
    /// a target, and every player on the prefix must be in `players`. Returns the full grid, or nil when none is found
    /// within `budget` search nodes.
    ///
    /// By default it tries only the `candidatesPerK` best line-ups per sub count, so nil can also mean "not found".
    /// With `exhaustive` (#169) it tries every line-up the limits allow and never searches the same state twice: the
    /// state is what each player still needs, their sit and stint so far and whether they may play, so two players with
    /// the same state are interchangeable. Nil then means no such plan exists, unless the budget ran out.
    ///
    /// Draws one value per player from `random` for the tie-breaking noise, as the JS does; with `exhaustive` it draws
    /// none and the noise is 0, as in the JS. The search works on each player's place in `players` rather than the
    /// number, which keeps the debug build quick; the order in which it tries line-ups is the JS order.
    public static func fillGrid(prefix: [[Int]], players: [Int], available: [Int]? = nil, targets: [Int: Int],
                                blocks: Int, maxSit: Int, maxStint: Int, maxSubs: Int = Planner.maxSubs,
                                budget: Int = Planner.nodeBudget, random: inout SeededRandom,
                                exhaustive: Bool = false) -> [[Int]]? {
        let n = players.count
        var index: [Int: Int] = [:]
        for (i, p) in players.enumerated() where index[p] == nil { index[p] = i }
        let target = players.map { targets[$0] ?? 0 }
        var played = [Int](repeating: 0, count: n)
        var sit = [Int](repeating: 0, count: n)
        var stint = [Int](repeating: 0, count: n)
        for court in prefix {
            for i in 0..<n {
                if court.contains(players[i]) {
                    played[i] += 1; stint[i] += 1; sit[i] = 0
                } else {
                    sit[i] += 1; stint[i] = 0
                }
            }
        }
        let availableSet = Set(available ?? players)
        let avail = players.map { availableSet.contains($0) }
        let noise = exhaustive ? [Double](repeating: 0, count: n) : players.map { _ in random.next() * 1e-3 }
        var grid = prefix
        var nodes = 0
        // With `exhaustive`: the states from which no plan can be completed. Blocks fill one by one, so the players'
        // states are enough without the grid itself; their order does not count. The JS keys the same states.
        var failed = Set<[Int]>()
        func stateKey() -> [Int] {
            var codes = (0..<n).map { i in
                ((((target[i] - played[i] + 64) * 128 + sit[i]) * 128 + stint[i]) * 2 + (avail[i] ? 1 : 0)) * 2
                    + (target[i] > 0 ? 1 : 0)
            }
            codes.sort()
            return [grid.count] + codes
        }

        // left = blocks still to fill after the one just placed
        func feasible(_ left: Int) -> Bool {
            for i in 0..<n {
                let need = target[i] - played[i]
                if need < 0 || need > left { return false }
                if need > 0 && !avail[i] { return false }
                if sit[i] > maxSit && avail[i] && target[i] > 0 { return false }
                if stint[i] > maxStint { return false }
                // a player who is done sits out the rest of the match: that tail counts as a sit too
                if need == 0 && avail[i] && sit[i] + left > maxSit { return false }
            }
            return true
        }

        func step() -> Bool {
            if grid.count == blocks { return true }
            let key = exhaustive ? stateKey() : []
            if exhaustive && failed.contains(key) { return false }
            nodes += 1
            if nodes > budget { return false }
            let left = blocks - grid.count // including the block being chosen
            // The current line-up as places in `players`, in its order on the grid.
            let current = grid[grid.count - 1].map { index[$0]! }
            var isCurrent = [Bool](repeating: false, count: n)
            for i in current { isCurrent[i] = true }
            // The JS computes urgency inside its comparators and sums; the state does not change while the candidates
            // are built, so computing it once per player gives the same values.
            var need = [Int](repeating: 0, count: n)
            var urgency = [Double](repeating: 0, count: n)
            for i in 0..<n {
                need[i] = target[i] - played[i]
                urgency[i] = Double(need[i]) / Double(left) + Double(sit[i]) * 0.05 - Double(stint[i]) * 0.05
                    + noise[i]
            }
            // Forced moves: who must leave, who must stay, who must come on for the limits and targets to hold.
            let mustOut = current.filter { !avail[$0] || need[$0] == 0 || stint[$0] >= maxStint }
            let mustStay = current.filter { !mustOut.contains($0) && need[$0] == left }
            let freeOut = stableSorted(current.filter { !mustOut.contains($0) && !mustStay.contains($0) },
                                       by: urgency, increasing: true)
            let bench = (0..<n).filter { !isCurrent[$0] && avail[$0] && need[$0] > 0 }
            let mustIn = bench.filter { need[$0] == left || sit[$0] >= maxSit }
            let freeIn = stableSorted(bench.filter { !mustIn.contains($0) }, by: urgency, increasing: false)
            if mustOut.count > maxSubs || mustIn.count > maxSubs { return false }
            var candidates: [[Int]] = []
            for k in [2, 1, 3, 0] {
                if k > maxSubs || k < mustOut.count || k < mustIn.count { continue }
                // Each side's picks with their urgency sums, summed in the JS order (the forced players first).
                var outPicks: [[Int]] = [], outSums: [Double] = []
                forEachCombination(of: freeOut, k - mustOut.count) { extra in
                    let outs = mustOut + extra
                    outPicks.append(outs)
                    outSums.append(outs.reduce(0.0) { $0 + urgency[$1] })
                }
                var inPicks: [[Int]] = [], inSums: [Double] = []
                forEachCombination(of: freeIn, k - mustIn.count) { extra in
                    let ins = mustIn + extra
                    inPicks.append(ins)
                    inSums.append(ins.reduce(0.0) { $0 + urgency[$1] })
                }
                // Candidate c pairs outPicks[c / inPicks.count] with inPicks[c % inPicks.count], in the JS order.
                if exhaustive {
                    // Every candidate, best score first; ties keep the JS order, as its stable sort does.
                    let all = (0..<(outPicks.count * inPicks.count)).map { c in
                        (c: c, score: inSums[c % inPicks.count] - outSums[c / inPicks.count])
                    }
                    for (c, _) in all.sorted(by: { $0.score > $1.score || ($0.score == $1.score && $0.c < $1.c) }) {
                        let outs = outPicks[c / inPicks.count]
                        candidates.append(current.filter { !outs.contains($0) } + inPicks[c % inPicks.count])
                    }
                    continue
                }
                // The JS sorts them all, best score first with ties in that order (its sort is stable), and keeps the
                // first candidatesPerK; keeping the best ones in a short ordered list gives the same ones in the same
                // order without sorting them all.
                var best: [Int] = [], bestScores: [Double] = []
                best.reserveCapacity(candidatesPerK + 1)
                bestScores.reserveCapacity(candidatesPerK + 1)
                for c in 0..<(outPicks.count * inPicks.count) {
                    let score = inSums[c % inPicks.count] - outSums[c / inPicks.count]
                    // A tie goes after the candidates already kept, which come earlier in the JS order.
                    if best.count == candidatesPerK && score <= bestScores[best.count - 1] { continue }
                    var at = best.count
                    while at > 0 && bestScores[at - 1] < score { at -= 1 }
                    best.insert(c, at: at)
                    bestScores.insert(score, at: at)
                    if best.count > candidatesPerK {
                        best.removeLast()
                        bestScores.removeLast()
                    }
                }
                for c in best {
                    let outs = outPicks[c / inPicks.count]
                    candidates.append(current.filter { !outs.contains($0) } + inPicks[c % inPicks.count])
                }
            }
            var onNext = [Bool](repeating: false, count: n)
            for next in candidates {
                let saved = (played, sit, stint)
                for i in 0..<n { onNext[i] = false }
                for i in next { onNext[i] = true }
                for i in 0..<n {
                    if onNext[i] {
                        played[i] += 1; stint[i] += 1; sit[i] = 0
                    } else {
                        sit[i] += 1; stint[i] = 0
                    }
                }
                grid.append(next.map { players[$0] }.sorted())
                if feasible(left - 1) && step() { return true }
                grid.removeLast()
                (played, sit, stint) = saved
                if nodes > budget { return false }
            }
            if exhaustive { failed.insert(key) }
            return false
        }

        return step() ? grid : nil
    }

    /// Tries a cap of 2 subs with the strict limits, then a cap of 3, then drops the stint limit, then the sit limit
    /// (never the cap of 3; plan assumption A3). A limit is dropped only after an exhaustive search with it found
    /// nothing (#169): the quick search alone gave up 15:00 sits for 13 players in the 5-minute schedule, where plans
    /// exist. The exhaustive level for a limit comes right after the quick one and draws nothing from `random`, so a
    /// plan found before it stays the same. `level` in the result says how far it went (0 to 5). With `maxLevel`, it
    /// goes no further than that level and gives nil when no plan is found up to it, the last level included (#41);
    /// without `maxLevel`, it throws PlanError when no level finds a plan. The quick levels draw from the same
    /// `random`.
    public static func searchGrid(prefix: [[Int]], players: [Int], available: [Int]? = nil, targets: [Int: Int],
                                  blocks: Int, blockSeconds: Int, random: inout SeededRandom,
                                  maxLevel: Int? = nil) throws(PlanError) -> GridSearchResult? {
        let sitBlocks = maxSitSeconds / blockSeconds
        let stintBlocks = max(1, maxStintSeconds / blockSeconds)
        let stint = max(stintBlocks, 3)
        // A cap of 2 first: 3 subs only where 2 cannot keep the limits (decision #21).
        let levels: [(maxSubs: Int, maxSit: Int, maxStint: Int, budget: Int, sitLimitRelaxed: Bool,
                      exhaustive: Bool)] = [
            (2, sitBlocks, stint, twoSubBudget, false, false),
            (3, sitBlocks, stint, nodeBudget, false, false),
            (3, sitBlocks, stint, exhaustiveBudget, false, true),
            (3, sitBlocks, blocks, nodeBudget, false, false),
            (3, sitBlocks, blocks, exhaustiveBudget, false, true),
            (3, blocks, blocks, nodeBudget, true, false),
        ]
        for (index, level) in levels.enumerated() {
            if let maxLevel, index > maxLevel { return nil }
            if let grid = fillGrid(prefix: prefix, players: players, available: available, targets: targets,
                                   blocks: blocks, maxSit: level.maxSit, maxStint: level.maxStint,
                                   maxSubs: level.maxSubs, budget: level.budget, random: &random,
                                   exhaustive: level.exhaustive) {
                return GridSearchResult(grid: grid, sitLimitRelaxed: level.sitLimitRelaxed, level: index)
            }
        }
        if maxLevel != nil { return nil }
        throw PlanError("no plan found within the substitution limit of \(maxSubs)")
    }
}
