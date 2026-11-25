import Foundation

/// What `searchGrid` gives: the grid, whether the 15:00 sit limit had to go, and the level that found it (0 to 5).
public struct GridSearchResult: Equatable, Sendable {
    public var grid: [[Int]]
    public var sitLimitRelaxed: Bool
    public var level: Int
}

/// What `completeFill` gives (#169): the outcome, the grid when found, and the search nodes it used.
public struct CompleteFillResult: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        /// `grid` is the plan.
        case found
        /// The whole search ended within the budget without a plan: a proof that none exists.
        case impossible
        /// The budget ran out first, so nothing is known.
        case exhausted
    }
    public var outcome: Outcome
    public var grid: [[Int]]?
    public var nodes: Int
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
    /// It tries only the `candidatesPerK` best line-ups per sub count, so nil means "not found", not "none exists";
    /// `completeFill` can tell the two apart.
    ///
    /// Draws one value per player from `random` for the tie-breaking noise, as the JS does. The search works on each
    /// player's place in `players` rather than the number, which keeps the debug build quick; the order in which it
    /// tries line-ups is the JS order.
    public static func fillGrid(prefix: [[Int]], players: [Int], available: [Int]? = nil, targets: [Int: Int],
                                blocks: Int, maxSit: Int, maxStint: Int, maxSubs: Int = Planner.maxSubs,
                                budget: Int = Planner.nodeBudget, random: inout SeededRandom) -> [[Int]]? {
        let noise = players.map { _ in random.next() * 1e-3 }
        return search(prefix: prefix, players: players, available: available, targets: targets, blocks: blocks,
                      maxSit: maxSit, maxStint: maxStint, maxSubs: maxSubs, budget: budget, noise: noise,
                      complete: false).grid
    }

    /// The complete search for the same limits (#169): it tries every line-up the limits allow, never searches the
    /// same state twice (a state is what each player still needs, their sit and stint so far and whether they may
    /// play; players with the same state are interchangeable) and skips a state where some player can no longer reach
    /// their target within the sit and stint limits. Both only leave out branches that hold no plan, so it finds the
    /// first plan in its order. It draws nothing from a random generator: ties keep the order of the line-ups. The
    /// outcome is `found`, `impossible` (a proof) or `exhausted` (the budget ran out, nothing is known), as in the JS.
    public static func completeFill(prefix: [[Int]], players: [Int], available: [Int]? = nil, targets: [Int: Int],
                                    blocks: Int, maxSit: Int, maxStint: Int, maxSubs: Int = Planner.maxSubs,
                                    budget: Int = Planner.completeBudget) -> CompleteFillResult {
        let found = search(prefix: prefix, players: players, available: available, targets: targets, blocks: blocks,
                           maxSit: maxSit, maxStint: maxStint, maxSubs: maxSubs, budget: budget,
                           noise: [Double](repeating: 0, count: players.count), complete: true)
        let outcome: CompleteFillResult.Outcome = found.grid != nil ? .found
            : found.exhausted ? .exhausted : .impossible
        return CompleteFillResult(outcome: outcome, grid: found.grid, nodes: found.nodes)
    }

    /// The search behind `fillGrid` (quick: the best `candidatesPerK` per sub count) and `completeFill` (complete).
    static func search(prefix: [[Int]], players: [Int], available: [Int]?, targets: [Int: Int], blocks: Int,
                       maxSit: Int, maxStint: Int, maxSubs: Int, budget: Int, noise: [Double],
                       complete: Bool) -> (grid: [[Int]]?, nodes: Int, exhausted: Bool) {
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
        var grid = prefix
        var nodes = 0
        // Complete search: the states from which no plan can be completed. Blocks fill one by one, so the players'
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
        // Complete search: can one player still play exactly `need` of the `left` blocks to come, from a sit `s` or
        // stint `t` of that many blocks, without a sit over maxSit or a stint over maxStint? Remembered per state.
        var reachable: [Int: Bool] = [:]
        func canFinish(_ need: Int, _ left: Int, _ s: Int, _ t: Int) -> Bool {
            if need < 0 || need > left { return false }
            if left == 0 { return true }
            let key = ((need * 64 + left) * 64 + s) * 64 + t
            if let known = reachable[key] { return known }
            let ok = (t < maxStint && canFinish(need - 1, left - 1, 0, t + 1))
                || (s < maxSit && canFinish(need, left - 1, s + 1, 0))
            reachable[key] = ok
            return ok
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
                if complete && avail[i] && target[i] > 0 && !canFinish(need, left, sit[i], stint[i]) { return false }
            }
            return true
        }

        func step() -> Bool {
            if grid.count == blocks { return true }
            let key = complete ? stateKey() : []
            if complete && failed.contains(key) { return false }
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
                if complete {
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
            if complete { failed.insert(key) }
            return false
        }

        let found = step()
        return (found ? grid : nil, nodes, !found && nodes > budget)
    }

    /// Tries a cap of 2 subs with the strict limits, then a cap of 3, then drops the stint limit, then the sit limit
    /// (never the cap of 3; plan assumption A3). Before it drops a limit it runs the complete search with that limit
    /// (`completeFill`, #169): the quick search alone gave up 15:00 sits for 13 players in the 5-minute schedule,
    /// where plans exist. The limit is dropped when that search is `impossible` (a proof) or `exhausted` (its budget
    /// of `completeBudget` nodes ran out). Exhausted drops the limit without a proof, so that a plan and a live change
    /// never fail for want of time; ⚠ no case tried up to 15 players exhausts the default budget (see #169's PR),
    /// but that is a measurement, not a proof for every input. The complete level for a limit comes right after the
    /// quick one and draws nothing from `random`, so a plan found before it stays the same. `level` in the result
    /// says how far it went (0 to 5). With `maxLevel`, it goes no further than that level and gives nil when no plan
    /// is found up to it, the last level included (#41); without `maxLevel`, it throws PlanError when no level finds
    /// a plan. The quick levels draw from the same `random`.
    public static func searchGrid(prefix: [[Int]], players: [Int], available: [Int]? = nil, targets: [Int: Int],
                                  blocks: Int, blockSeconds: Int, random: inout SeededRandom,
                                  maxLevel: Int? = nil,
                                  completeBudget: Int = Planner.completeBudget) throws(PlanError)
        -> GridSearchResult? {
        let sitBlocks = maxSitSeconds / blockSeconds
        let stintBlocks = max(1, maxStintSeconds / blockSeconds)
        let stint = max(stintBlocks, 3)
        // A cap of 2 first: 3 subs only where 2 cannot keep the limits (decision #21).
        let levels: [(maxSubs: Int, maxSit: Int, maxStint: Int, budget: Int, sitLimitRelaxed: Bool,
                      complete: Bool)] = [
            (2, sitBlocks, stint, twoSubBudget, false, false),
            (3, sitBlocks, stint, nodeBudget, false, false),
            (3, sitBlocks, stint, completeBudget, false, true),
            (3, sitBlocks, blocks, nodeBudget, false, false),
            (3, sitBlocks, blocks, completeBudget, false, true),
            (3, blocks, blocks, nodeBudget, true, false),
        ]
        for (index, level) in levels.enumerated() {
            if let maxLevel, index > maxLevel { return nil }
            let grid = level.complete
                ? completeFill(prefix: prefix, players: players, available: available, targets: targets,
                               blocks: blocks, maxSit: level.maxSit, maxStint: level.maxStint,
                               maxSubs: level.maxSubs, budget: level.budget).grid
                : fillGrid(prefix: prefix, players: players, available: available, targets: targets,
                           blocks: blocks, maxSit: level.maxSit, maxStint: level.maxStint,
                           maxSubs: level.maxSubs, budget: level.budget, random: &random)
            if let grid {
                return GridSearchResult(grid: grid, sitLimitRelaxed: level.sitLimitRelaxed, level: index)
            }
        }
        if maxLevel != nil { return nil }
        throw PlanError("no plan found within the substitution limit of \(maxSubs)")
    }
}
