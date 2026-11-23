import Foundation

// Team history (docs/PLAN.md decision #10), ported from public/js/history.js (ADR-003); the JS file is the reference,
// and every function here gives what its JS twin gives. Each finished match's seconds per player, kept on the phone
// (ADR-002). With the setup switch on, the places that cannot be split equally go to the players with the fewest
// total seconds so far (ties: random from the plan's seed). Players behind on season minutes also catch up gradually
// (decision #28): at most one block more per match than the equal share, from the present players furthest ahead (at
// most one block less each). Minutes earned through Extra minuten are kept apart per match and left out of these
// comparisons, so a reward stays (decision #28, phase 2 log D8). The season totals (decision #26) still count all
// minutes.
//
// Stored shape (version 1), the JSON the web app stores and scripts/fixtures/history-*.json hold:
//   { useHistory: boolean, clearedAt: string | null,
//     matches: [{ id: string, seconds: { "<player id>": number }, extra?: { "<player id>": number } }] }
// `extra` holds the seconds a player got through Extra minuten in that match (part of `seconds`); matches saved
// before it existed have none. `id` is the match setup's savedAt (one per "Start"). `clearedAt` is when "Wis
// geschiedenis" last emptied it. Player ids are the roster's stable ids, written as whole numbers.

/// One finished match: seconds per player id, and the part of them earned through Extra minuten (nil when none).
public struct HistoryMatch: Equatable, Sendable {
    public var id: String
    public var seconds: JSObject<Double>
    public var extra: JSObject<Double>?

    public init(id: String, seconds: JSObject<Double>, extra: JSObject<Double>? = nil) {
        self.id = id
        self.seconds = seconds
        self.extra = extra
    }
}

/// The season totals (decision #26): the number of saved matches and the total seconds per player id over all of
/// them. A player in no saved match is not in `totals` (counts as 0).
public struct SeasonSummary: Equatable, Sendable {
    public var matches: Int
    public var totals: JSObject<Double>

    /// JSON.stringify of `seasonSummary(history)`: `{"matches":<n>,"totals":{...}}`, what `sim history` prints.
    public var json: String { "{\"matches\":\(matches),\"totals\":\(javaScriptJSON(totals))}" }
}

/// What the planner needs for a match with the history switch on (Planner.makePlan's `extraPriority` and `moves`).
public struct CatchUp: Equatable, Sendable {
    public var priority: [Int]
    public var moves: [[Int]]

    public init(priority: [Int] = [], moves: [[Int]] = []) {
        self.priority = priority
        self.moves = moves
    }
}

public struct History: Equatable, Sendable {
    public var useHistory: Bool
    public var clearedAt: String?
    public var matches: [HistoryMatch]

    /// The empty history (`emptyHistory()`): the switch off, never cleared, no matches.
    public init(useHistory: Bool = false, clearedAt: String? = nil, matches: [HistoryMatch] = []) {
        self.useHistory = useHistory
        self.clearedAt = clearedAt
        self.matches = matches
    }

    /// `normaliseHistory(JSON.parse(text))`: the history read from stored JSON, cleaned so a damaged value never breaks
    /// a screen or the planner. Throws NotJSON only when the text is not JSON (where JSON.parse throws).
    public init(json text: String) throws(NotJSON) {
        // The deepest value the history reads is a number in a match's seconds: top › matches › match › seconds › n.
        self = History.normalised(try JSONValue.parse(text, keep: 4))
    }

    /// `normaliseHistory(raw)`: entries without a non-empty string id or a seconds object are dropped, and so are
    /// seconds that are not finite numbers of 0 or more, or keyed by something other than a whole player id. A later
    /// entry with the same id wins and takes the later place.
    static func normalised(_ raw: JSONValue) -> History {
        var history = History()
        guard case .object = raw else { return history }
        history.useHistory = raw["useHistory"] == .bool(true)
        if case .string(let text)? = raw["clearedAt"], javaScriptISOTime(text) != nil { history.clearedAt = text }
        guard case .array(let entries)? = raw["matches"] else { return history }
        for entry in entries {
            guard case .string(let id)? = entry["id"], !id.isEmpty else { continue }
            guard case .object(let seconds)? = entry["seconds"] else { continue }
            let clean = cleanSeconds(seconds)
            let extra = cleanExtra(entry["extra"], clean)
            history.matches.removeAll { sameCodeUnits($0.id, id) }
            history.matches.append(HistoryMatch(id: id, seconds: clean, extra: extra.isEmpty ? nil : extra))
        }
        return history
    }

    /// The history as the web app stores it, JSON.stringify of the stored shape with its key order.
    public var json: String {
        let matchTexts = matches.map { match in
            "{\"id\":\(javaScriptQuoted(match.id)),\"seconds\":\(javaScriptJSON(match.seconds))"
                + (match.extra.map { ",\"extra\":\(javaScriptJSON($0))" } ?? "") + "}"
        }
        return "{\"useHistory\":\(useHistory),\"clearedAt\":\(clearedAt.map(javaScriptQuoted) ?? "null"),"
            + "\"matches\":[\(matchTexts.joined(separator: ","))]}"
    }

    /// The history with this match's seconds recorded under `id`, replacing an earlier entry for the same match.
    /// `extra` holds the seconds each player got through Extra minuten (`recordMatch`).
    public func recording(_ id: String, seconds: JSObject<Double>, extra: JSObject<Double> = [:]) -> History {
        let clean = History.cleanSeconds(seconds)
        let extraClean = History.cleanExtra(extra, clean)
        var history = self
        history.matches.removeAll { sameCodeUnits($0.id, id) }
        history.matches.append(HistoryMatch(id: id, seconds: clean, extra: extraClean.isEmpty ? nil : extraClean))
        return history
    }

    /// `forgetMatch`.
    public func forgetting(_ id: String) -> History {
        var history = self
        history.matches.removeAll { sameCodeUnits($0.id, id) }
        return history
    }

    /// `hasMatch`.
    public func has(_ id: String) -> Bool { matches.contains { sameCodeUnits($0.id, id) } }

    /// "Wis geschiedenis" (`clearHistory`): no matches left, and `now` (an ISO time) remembered as the moment of
    /// clearing; the switch keeps its setting.
    public func cleared(at now: String) -> History {
        History(useHistory: useHistory, clearedAt: now, matches: [])
    }

    /// True when a match started at `savedAt` (its setup's ISO time) began after the last "Wis geschiedenis", so its
    /// minutes may (still) be recorded when its end screen is reopened (`startedAfterClear`).
    public func startedAfterClear(_ savedAt: String) -> Bool {
        guard let clearedAt else { return true }
        // Date.parse(clearedAt) is NaN for a time this reader does not take: then `started > NaN` is false.
        guard let started = javaScriptISOTime(savedAt), let cleared = javaScriptISOTime(clearedAt) else { return false }
        return started > cleared
    }

    /// Total seconds per player id over all matches in the history (`totalSeconds`).
    public func totalSeconds() -> JSObject<Double> {
        var totals = JSObject<Double>()
        for match in matches {
            for (id, value) in match.seconds.entries { totals[id] = (totals[id] ?? 0) + value }
        }
        return totals
    }

    /// The season totals as the Spelers screen and the runner show them (`seasonSummary`).
    public func seasonSummary() -> SeasonSummary { SeasonSummary(matches: matches.count, totals: totalSeconds()) }

    /// Total seconds per player id over all matches, without the seconds earned through Extra minuten: what catch-up
    /// and the uneven places compare (`catchUpSeconds`; decision #28, rewards stay).
    public func catchUpSeconds() -> JSObject<Double> {
        var totals = totalSeconds()
        for match in matches {
            for (id, value) in (match.extra ?? [:]).entries { totals[id] = totals[id]! - value }
        }
        return totals
    }

    /// The present players ordered for the uneven extra places (`extraPriority`): fewest seconds first (Extra minuten
    /// not counted); a player not in the history counts as 0; players in the history who are not present are
    /// ignored. Ties are put in a random order from `seed`, so the same seed and history give the same plan.
    public func extraPriority(_ players: [Int], seed: Int = 1) -> [Int] {
        let totals = catchUpSeconds()
        var random = SeededRandom(seed: seed)
        let order = Planner.shuffled(players, &random)
        let total = order.map { totals[String($0)] ?? 0 }
        // A stable sort, as Array.prototype.sort is: ties keep the shuffled order. `a < b` is what
        // `total(a) - total(b) < 0` gives for every pair of totals here (no NaN; Infinity ties with Infinity).
        return order.indices.sorted { total[$0] < total[$1] || (total[$0] == total[$1] && $0 < $1) }.map { order[$0] }
    }

    /// Gradual catch-up (`catchUp`, decision #28). `priority` orders the uneven places (as extraPriority); `moves`
    /// lists [behind, ahead] pairs, each moving one block from a present player far ahead to a present player far
    /// behind, pairing the furthest behind with the furthest ahead (most important first), while they are at least one
    /// block apart. The planner takes as many from the front as fit. Each player gets at most one block more than the
    /// equal share (a player who already has an uneven place gets none) and at most one block less. Seconds earned
    /// through Extra minuten are not counted, so a reward is not taken back.
    public func catchUp(_ players: [Int], schedule: ScheduleShape, onCourt: Int = Planner.onCourt, seed: Int = 1)
        -> CatchUp {
        let priority = extraPriority(players, seed: seed)
        // With no players, JavaScript's base is Infinity and nothing is uneven or moves.
        guard !players.isEmpty else { return CatchUp(priority: priority) }
        let totals = catchUpSeconds()
        func total(_ p: Int) -> Double { totals[String(p)] ?? 0 }
        let places = onCourt * schedule.blocks
        let base = places / players.count
        let uneven = Set(priority.prefix(max(0, places - base * players.count)))
        func share(_ p: Int) -> Int { base + (uneven.contains(p) ? 1 : 0) }
        var moves: [[Int]] = []
        var i = 0
        var j = priority.count - 1
        while i < j {
            let behind = priority[i]
            let ahead = priority[j]
            // Written as in JS: Infinity − Infinity is NaN, which is not below a block, so it does not stop the loop.
            if total(ahead) - total(behind) < Double(schedule.blockSeconds) { break }
            if share(behind) + 1 > base + 1 { i += 1; continue }
            if share(ahead) - 1 < base - 1 { j -= 1; continue }
            moves.append([behind, ahead])
            i += 1
            j -= 1
        }
        return CatchUp(priority: priority, moves: moves)
    }

    /// Seconds kept only for whole player ids (`/^\d+$/`: ASCII digits only) with finite values of 0 or more.
    static func cleanSeconds(_ seconds: JSObject<Double>) -> JSObject<Double> {
        var clean = JSObject<Double>()
        for (id, value) in seconds.entries where isPlayerID(id) && value.isFinite && value >= 0 { clean[id] = value }
        return clean
    }

    static func cleanSeconds(_ raw: JSObject<JSONValue>) -> JSObject<Double> {
        var clean = JSObject<Double>()
        for (id, value) in raw.entries {
            if case .number(let n) = value, isPlayerID(id), n.isFinite, n >= 0 { clean[id] = n }
        }
        return clean
    }

    /// Extra seconds are kept only for players with seconds in that match, at most their seconds, and above 0.
    static func cleanExtra(_ extra: JSObject<Double>, _ seconds: JSObject<Double>) -> JSObject<Double> {
        var clean = JSObject<Double>()
        for (id, value) in cleanSeconds(extra).entries where value > 0 {
            if let played = seconds[id] { clean[id] = min(value, played) }
        }
        return clean
    }

    static func cleanExtra(_ raw: JSONValue?, _ seconds: JSObject<Double>) -> JSObject<Double> {
        guard case .object(let object)? = raw else { return [:] }
        return cleanExtra(cleanSeconds(object), seconds)
    }

    static func isPlayerID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}
