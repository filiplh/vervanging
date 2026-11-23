import Foundation

// Restoring a saved match state, ported from normaliseMatchState in public/js/match.js: the state read back is
// checked against the plan it must belong to, so a damaged state, one from an unknown version or one from another
// match setup is never restored (the screen then starts a new match).
//
// The web app also migrates its version 1 states (from before in the zone, uit and terug). The iPhone app has only
// ever written version 2, so there is nothing to migrate here, and a version 1 state is refused like any unknown
// version.

extension MatchState {
    /// The stored JSON as a state for `plan`, or nil when it is not valid JSON, not a match state, from another
    /// version or setup, or damaged.
    public static func restored(json data: Data, plan: Plan, setupSavedAt: String? = nil) -> MatchState? {
        guard let stored = try? JSONDecoder().decode(MatchState.self, from: data) else { return nil }
        return restored(stored, plan: plan, setupSavedAt: setupSavedAt)
    }

    /// `stored` checked against `plan`: the state to go on with, or nil when it must not be restored.
    public static func restored(_ stored: MatchState, plan: Plan, setupSavedAt: String? = nil) -> MatchState? {
        let fresh = start(plan, setupSavedAt: setupSavedAt)
        guard stored.version == currentVersion, stored.setupSavedAt == fresh.setupSavedAt else { return nil }
        guard stored.schedule == fresh.schedule, stored.blocks == fresh.blocks,
              stored.blockSeconds == fresh.blockSeconds, stored.blocksPerQuarter == fresh.blocksPerQuarter
        else { return nil }
        guard stored.players == fresh.players, stored.base == fresh.base else { return nil }
        let now = stored.snapshot
        guard fresh.isValidPoint(now) else { return nil }
        // The first block is the coach's starting five and never changes.
        guard now.grid[0].sorted() == fresh.grid[0].sorted() else { return nil }
        guard planHolds(now) else { return nil }
        if let prev = stored.previous {
            // The only history an action leaves: a wissel from the active block just before this one (or, after the
            // end, from the active last block), or an uit or terug on this same active block. Blocks that were
            // already played are the same in both. Anything else would make undo jump, so it is refused.
            guard fresh.isValidPoint(prev), !prev.ended, planHolds(prev) else { return nil }
            let allowed = now.ended ? [fresh.blocks] : [now.block - 1, now.block]
            guard allowed.contains(prev.block) else { return nil }
            guard Array(prev.grid.prefix(prev.block)) == Array(now.grid.prefix(prev.block)) else { return nil }
            // Extra minuten only grow by one entry at a wissel; other actions leave the list as it was.
            let grew = now.extra.count == prev.extra.count + 1 && prev.block == now.block - 1
            guard Array(now.extra.prefix(prev.extra.count)) == prev.extra,
                  now.extra.count == prev.extra.count || grew
            else { return nil }
        }
        var restored = fresh
        restored.grid = now.grid
        restored.out = now.out
        restored.replaced = now.replaced
        restored.extra = now.extra
        restored.block = now.block
        restored.ended = now.ended
        restored.previous = stored.previous
        return restored
    }

    /// From the current block on (as it is on court; after the end, nothing): nobody out plays, and every change
    /// keeps the sub rule.
    static func planHolds(_ p: MatchSnapshot) -> Bool {
        let actual = Match.actualGrid(p.grid, block: p.block, p.replaced)
        let from = p.ended ? p.block : p.block - 1
        return !actual[from...].contains { court in court.contains { p.out.contains($0) } }
            && Match.capHolds(actual, fromChange: p.block - 1, out: p.out)
    }

    /// A block, an end flag, a live plan, the players out, the replacements and the Extra minuten that fit this
    /// (fresh) state's plan.
    func isValidPoint(_ p: MatchSnapshot) -> Bool {
        guard (1...blocks).contains(p.block), !p.ended || p.block == blocks else { return false }
        // The grid: one line-up of five different players of this match per block.
        guard p.grid.count == blocks, p.grid.allSatisfy({ court in
            court.count == Planner.onCourt && Set(court).count == Planner.onCourt && court.allSatisfy(players.contains)
        }) else { return false }
        // The players out: different players of this match, with enough left to play.
        guard Set(p.out).count == p.out.count, p.out.allSatisfy(players.contains),
              players.count - p.out.count >= Planner.onCourt
        else { return false }
        // The replacements of the current block: each starter is in its credited line-up, each replacement is
        // available and not in it, all different.
        let row = p.grid[p.block - 1]
        var seen = Set<Int>()
        for pair in p.replaced {
            guard row.contains(pair.starter), !row.contains(pair.replacement), players.contains(pair.replacement),
                  !p.out.contains(pair.replacement), !seen.contains(pair.starter), !seen.contains(pair.replacement)
            else { return false }
            seen.insert(pair.starter)
            seen.insert(pair.replacement)
        }
        // The Extra minuten: players of this match, at most one per change.
        return p.extra.count < blocks && p.extra.allSatisfy(players.contains)
    }
}
